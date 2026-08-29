import AppKit
import Combine
import WEKit
import MirageRender

/// Owns the desktop windows: one per screen, each showing the wallpaper the user
/// assigned to that display, and pausing them when nobody can see them.
final class WallpaperController: ObservableObject {
    struct DisplayInfo: Identifiable, Hashable {
        let id: String              // stable-ish display key
        let name: String
        let frame: NSRect
        var isMain: Bool
    }

    @Published private(set) var displays: [DisplayInfo] = []
    /// display id → wallpaper id
    @Published private(set) var assignments: [String: String] = [:]
    @Published private(set) var isPaused = false
    @Published private(set) var lastError: String?

    let library: WallpaperLibrary
    let settings: AppSettings

    private var windows: [String: WallpaperWindow] = [:]
    private var sceneViews: [String: SceneWallpaperView] = [:]
    private var videoViews: [String: VideoWallpaperView] = [:]
    private var imageViews: [String: ImageWallpaperView] = [:]
    /// Building a `SceneRenderer` compiles shaders and uploads textures, which takes
    /// seconds; it runs here so the UI never blocks, and `loadGeneration` discards a
    /// result whose display has since been reassigned.
    private let loaderQueue = DispatchQueue(label: "com.mirage.scene-loader", qos: .userInitiated)
    private var loadGeneration: [String: Int] = [:]
    private var renderContext: RenderContext?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var pauseTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var manuallyPaused = false

    private static let assignmentsKey = "wallpaper.assignments"

    init(library: WallpaperLibrary, settings: AppSettings) {
        self.library = library
        self.settings = settings
        assignments = (UserDefaults.standard.dictionary(forKey: WallpaperController.assignmentsKey) as? [String: String]) ?? [:]
        renderContext = try? RenderContext()
        refreshDisplays()
        NSLog("Mirage: %d displays %@, %d library items, assignments %@",
              displays.count, displays.map(\.id).description, library.items.count, assignments.description)
        restoreAssignments()
        observeSystem()

        settings.$fpsCap
            .sink { [weak self] cap in self?.sceneViews.values.forEach { $0.fpsCap = cap } }
            .store(in: &cancellables)
        settings.$muted.combineLatest(settings.$volume)
            .sink { [weak self] muted, volume in
                self?.videoViews.values.forEach { $0.setMuted(muted, volume: Float(volume)) }
            }
            .store(in: &cancellables)
    }

    // MARK: Displays

    static func key(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display-\(number.uint32Value)"
        }
        return "display-\(Int(screen.frame.origin.x))x\(Int(screen.frame.origin.y))"
    }

    func refreshDisplays() {
        displays = NSScreen.screens.map { screen in
            DisplayInfo(id: WallpaperController.key(for: screen),
                        name: screen.localizedName,
                        frame: screen.frame,
                        isMain: screen == NSScreen.main)
        }
        // Drop windows for displays that went away.
        let live = Set(displays.map(\.id))
        for key in windows.keys.filter({ !live.contains($0) }) {
            guard let window = windows[key] else { continue }
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            windows.removeValue(forKey: key)
            teardownViews(for: key)
        }
        // Re-place the surviving ones.
        for screen in NSScreen.screens {
            windows[WallpaperController.key(for: screen)]?.place(on: screen)
        }
    }

    private func screen(for key: String) -> NSScreen? {
        NSScreen.screens.first { WallpaperController.key(for: $0) == key }
    }

    // MARK: Assignment

    func assign(_ item: WallpaperItem, to displayId: String) {
        assignments[displayId] = item.id
        UserDefaults.standard.set(assignments, forKey: WallpaperController.assignmentsKey)
        show(item, on: displayId)
    }

    func assignToAllDisplays(_ item: WallpaperItem) {
        for display in displays { assign(item, to: display.id) }
    }

    func clear(displayId: String) {
        assignments.removeValue(forKey: displayId)
        UserDefaults.standard.set(assignments, forKey: WallpaperController.assignmentsKey)
        windows[displayId]?.orderOut(nil)
        windows[displayId]?.contentView = nil
        windows[displayId]?.close()
        windows.removeValue(forKey: displayId)
        teardownViews(for: displayId)
    }

    func clearAll() {
        for display in displays { clear(displayId: display.id) }
    }

    func assignedItem(for displayId: String) -> WallpaperItem? {
        assignments[displayId].flatMap { library.item(withId: $0) }
    }

    private func restoreAssignments(onlyMissing: Bool = false) {
        for (displayId, itemId) in assignments {
            if onlyMissing, windows[displayId] != nil { continue }
            guard let item = library.item(withId: itemId) else {
                NSLog("Mirage: no library item %@ for %@", itemId, displayId)
                continue
            }
            NSLog("Mirage: restoring %@ on %@", item.title, displayId)
            show(item, on: displayId)
        }
    }

    // MARK: Presentation

    private func teardownViews(for displayId: String) {
        // Invalidate any scene load still in flight for this display.
        loadGeneration[displayId] = (loadGeneration[displayId] ?? 0) + 1
        videoViews[displayId]?.stop()
        videoViews.removeValue(forKey: displayId)
        sceneViews.removeValue(forKey: displayId)
        imageViews.removeValue(forKey: displayId)
    }

    private func window(for displayId: String) -> WallpaperWindow? {
        guard let screen = screen(for: displayId) else { return nil }
        if let existing = windows[displayId] {
            existing.place(on: screen)
            return existing
        }
        let window = WallpaperWindow(screen: screen)
        windows[displayId] = window
        return window
    }

    func show(_ item: WallpaperItem, on displayId: String) {
        guard let window = window(for: displayId) else { return }
        teardownViews(for: displayId)
        window.contentView = nil
        lastError = nil

        switch item.kind {
        case .video:
            let view = VideoWallpaperView(url: item.contentURL, muted: settings.muted, volume: Float(settings.volume))
            videoViews[displayId] = view
            window.contentView = view
        case .image, .gif:
            let view = ImageWallpaperView(url: item.contentURL)
            imageViews[displayId] = view
            window.contentView = view
        case .scene:
            guard let context = renderContext, let directory = item.projectDirectory else {
                lastError = "No Metal device available"
                window.orderOut(nil)
                return
            }
            // Compiling shaders and uploading textures takes seconds, so build the renderer
            // off the main thread and install it when it is ready.
            let generation = (loadGeneration[displayId] ?? 0) + 1
            loadGeneration[displayId] = generation
            let fpsCap = settings.fpsCap
            loaderQueue.async { [weak self] in
                let outcome: Result<SceneRenderer, Error>
                do {
                    let project = try WEProject.load(directory: directory)
                    let locator = try AssetLocator(project: project,
                                                   assetsDirectories: AssetLocator.defaultAssetsDirectories(),
                                                   fallbackDirectory: ResourceLocator.fallbackAssetsDirectory())
                    outcome = .success(try SceneRenderer(project: project, locator: locator, context: context))
                } catch {
                    outcome = .failure(error)
                }
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration[displayId] == generation,
                          let window = self.windows[displayId] else { return }
                    switch outcome {
                    case .success(let renderer):
                        let view = SceneWallpaperView(renderer: renderer, context: context)
                        view.fpsCap = fpsCap
                        self.sceneViews[displayId] = view
                        window.contentView = view
                        window.orderBack(nil)
                        self.applyPauseState()
                    case .failure(let error):
                        self.lastError = "\(item.title): \(error)"
                        NSLog("Mirage: could not load scene %@: %@", item.title, String(describing: error))
                        window.orderOut(nil)
                    }
                }
            }
            return
        case .web:
            lastError = "Web wallpapers are not supported yet"
            window.orderOut(nil)
            return
        }
        window.orderBack(nil)
        NSLog("Mirage: showing %@ on %@ (window %@)", item.title, displayId, String(describing: window.windowNumber))
        applyPauseState()
    }

    // MARK: Pausing

    var isManuallyPaused: Bool { manuallyPaused }

    func togglePause() {
        manuallyPaused.toggle()
        applyPauseState()
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        let displayToken = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplays()
            self?.restoreAssignments(onlyMissing: true)
        }
        observers.append((center, displayToken))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.applyPauseState()
            }
            observers.append((workspace, token))
        }
        let sleepToken = workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.setPaused(true)
        }
        observers.append((workspace, sleepToken))
        let wakeToken = workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.applyPauseState()
        }
        observers.append((workspace, wakeToken))
        // Idle and battery need polling; once every 5s is cheap.
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.applyPauseState()
        }
    }

    func applyPauseState() {
        var paused = manuallyPaused
        if !paused && settings.pauseOnBattery && PowerState.isOnBattery { paused = true }
        if !paused && settings.pauseWhenIdle {
            paused = PowerState.idleSeconds > Double(settings.idleTimeoutMinutes) * 60
        }
        setPaused(paused, respectingOcclusion: settings.pauseWhenFullscreen)
    }

    private func setPaused(_ paused: Bool, respectingOcclusion: Bool = false) {
        isPaused = paused
        let windowInfo = respectingOcclusion && !paused ? PowerState.visibleWindowInfo() : nil
        for (displayId, view) in sceneViews {
            let covered = windowInfo.map { isCovered(displayId, windowInfo: $0) } ?? false
            view.setPaused(paused || covered)
        }
        for (displayId, view) in videoViews {
            let covered = windowInfo.map { isCovered(displayId, windowInfo: $0) } ?? false
            view.setPaused(paused || covered)
        }
        for (displayId, view) in imageViews {
            let covered = windowInfo.map { isCovered(displayId, windowInfo: $0) } ?? false
            view.setPaused(paused || covered)
        }
    }

    private func isCovered(_ displayId: String, windowInfo: [[String: Any]]) -> Bool {
        guard let screen = screen(for: displayId) else { return false }
        return PowerState.isCovered(screen, windowInfo: windowInfo)
    }

    deinit {
        pauseTimer?.invalidate()
        observers.forEach { $0.center.removeObserver($0.token) }
    }
}
