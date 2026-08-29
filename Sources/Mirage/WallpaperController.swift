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
    /// A wallpaper's edited user properties, keyed by item id then property name.
    /// Stored as plain plist values so `UserDefaults` can hold them directly.
    @Published private(set) var propertyEdits: [String: [String: Any]] = [:]
    @Published private(set) var isPaused = false
    @Published private(set) var lastError: String?

    let library: WallpaperLibrary
    let settings: AppSettings

    private var windows: [String: WallpaperWindow] = [:]
    private var sceneViews: [String: SceneWallpaperView] = [:]
    private var videoViews: [String: VideoWallpaperView] = [:]
    private var imageViews: [String: ImageWallpaperView] = [:]
    private var webViews: [String: WebWallpaperView] = [:]
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
    private static let propertiesKey = "wallpaper.properties"

    init(library: WallpaperLibrary, settings: AppSettings) {
        self.library = library
        self.settings = settings
        assignments = (UserDefaults.standard.dictionary(forKey: WallpaperController.assignmentsKey) as? [String: String]) ?? [:]
        propertyEdits = (UserDefaults.standard.dictionary(forKey: WallpaperController.propertiesKey)
            as? [String: [String: Any]]) ?? [:]
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
                self?.sceneViews.values.forEach { $0.setMuted(muted, volume: Float(volume)) }
                self?.webViews.values.forEach { $0.setMuted(muted) }
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

    // MARK: User properties

    /// The wallpaper's own properties, with the user's edits applied.
    func propertyOverrides(for item: WallpaperItem) -> [String: JSON] {
        guard let stored = propertyEdits[item.id] else { return [:] }
        var out: [String: JSON] = [:]
        for (name, value) in stored { out[name] = JSON(any: value) }
        return out
    }

    /// Edits one property and shows it. A scene that is already on screen takes
    /// the value without reloading; anything else is rebuilt.
    func setProperty(_ name: String, to value: JSON, on item: WallpaperItem) {
        var stored = propertyEdits[item.id] ?? [:]
        stored[name] = value.anyValue
        propertyEdits[item.id] = stored
        UserDefaults.standard.set(propertyEdits, forKey: WallpaperController.propertiesKey)
        for (displayId, assigned) in assignments where assigned == item.id {
            if let view = sceneViews[displayId] {
                view.setUserProperty(name, value)
            } else if let current = library.item(withId: assigned) {
                show(current, on: displayId)
            }
        }
    }

    func resetProperties(for item: WallpaperItem) {
        propertyEdits.removeValue(forKey: item.id)
        UserDefaults.standard.set(propertyEdits, forKey: WallpaperController.propertiesKey)
        for (displayId, assigned) in assignments where assigned == item.id {
            show(item, on: displayId)
        }
        _ = item
    }

    // MARK: Presentation

    private func teardownViews(for displayId: String) {
        // Invalidate any scene load still in flight for this display.
        loadGeneration[displayId] = (loadGeneration[displayId] ?? 0) + 1
        videoViews[displayId]?.stop()
        videoViews.removeValue(forKey: displayId)
        sceneViews[displayId]?.stop()
        sceneViews.removeValue(forKey: displayId)
        webViews[displayId]?.stop()
        webViews.removeValue(forKey: displayId)
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
            // The scene can render at the display's resolution instead of the one
            // the wallpaper was authored at, which is much cheaper on a wallpaper
            // authored larger than the screen, at the cost of some sharpness.
            var outputSize: (Int, Int)?
            if let screen = screen(for: displayId) {
                let scale = screen.backingScaleFactor
                let pixels = (Int((screen.frame.width * scale).rounded()),
                              Int((screen.frame.height * scale).rounded()))
                if pixels.0 > 0, pixels.1 > 0 { outputSize = pixels }
            }
            let scaleToOutput = settings.renderAtDisplayResolution
            let overrides = propertyOverrides(for: item)
            loaderQueue.async { [weak self] in
                let outcome: Result<SceneRenderer, Error>
                do {
                    let project = try WEProject.load(directory: directory)
                    let locator = try AssetLocator(project: project,
                                                   assetsDirectories: AssetLocator.defaultAssetsDirectories(),
                                                   fallbackDirectory: ResourceLocator.fallbackAssetsDirectory())
                    outcome = .success(try SceneRenderer(project: project, locator: locator, context: context,
                                                          propertyOverrides: overrides,
                                                          outputSize: outputSize, scaleToOutput: scaleToOutput))
                } catch {
                    outcome = .failure(error)
                }
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration[displayId] == generation,
                          let window = self.windows[displayId] else { return }
                    switch outcome {
                    case .success(let renderer):
                        let view = SceneWallpaperView(renderer: renderer, context: context,
                                                      muted: self.settings.muted,
                                                      volume: Float(self.settings.volume))
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
            // The wallpaper's user properties reach the page as plain values;
            // the view wraps them the way Wallpaper Engine's JS API expects.
            var properties: [String: Any] = [:]
            if let directory = item.projectDirectory, let project = try? WEProject.load(directory: directory) {
                for definition in project.properties {
                    if let value = definition.defaultValue.anyValue as Any? { properties[definition.name] = value }
                }
            }
            let view = WebWallpaperView(url: item.contentURL, properties: properties, muted: settings.muted)
            webViews[displayId] = view
            window.contentView = view
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
        // Quitting tears the views down explicitly: nothing else guarantees that
        // a wallpaper's audio players stop before the process goes away.
        let quitToken = center.addObserver(forName: NSApplication.willTerminateNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for displayId in Array(self.windows.keys) { self.teardownViews(for: displayId) }
        }
        observers.append((center, quitToken))
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
        for (displayId, view) in webViews {
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
