import Foundation
import AppKit
import WEKit

/// One wallpaper the user can pick: a Wallpaper Engine project folder, or a
/// loose video/image file they dragged in.
struct WallpaperItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case scene, video, web, image, gif

        var label: String {
            switch self {
            case .scene: return "Scene"
            case .video: return "Video"
            case .web: return "Web"
            case .image: return "Image"
            case .gif: return "GIF"
            }
        }

        var symbol: String {
            switch self {
            case .scene: return "square.3.layers.3d"
            case .video: return "play.rectangle"
            case .web: return "globe"
            case .image: return "photo"
            case .gif: return "photo.stack"
            }
        }
    }

    let id: String
    let title: String
    let kind: Kind
    /// The project folder, or the file's own URL for loose media.
    let location: URL
    /// The file to play/render: `scene.json`, the mp4, the html, the image.
    let contentURL: URL
    let previewURL: URL?
    let workshopId: String?
    /// Present for imported Wallpaper Engine items.
    let projectDirectory: URL?

    static func == (a: WallpaperItem, b: WallpaperItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isWallpaperEngineItem: Bool { projectDirectory != nil }
}

/// Scans the folders the user has added and exposes the wallpapers found.
final class WallpaperLibrary: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []
    @Published var searchPaths: [URL] {
        didSet { persistSearchPaths(); rescan() }
    }

    private static let searchPathsKey = "library.searchPaths"
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "bmp", "tiff"]

    init() {
        let stored = (UserDefaults.standard.array(forKey: WallpaperLibrary.searchPathsKey) as? [String]) ?? []
        var paths = stored.map { URL(fileURLWithPath: $0) }
        if paths.isEmpty {
            paths = WallpaperLibrary.defaultSearchPaths()
        }
        searchPaths = paths
        rescan()
    }

    /// Scanning runs off the main thread.
    ///
    /// Reading a folder can block for a long time: the first read of anything
    /// under Documents waits on the system's permission prompt, and a network
    /// volume can stall outright. Doing that during `init` froze the app before
    /// any window appeared, with no clue as to why.
    private let scanQueue = DispatchQueue(label: "com.mirage.library.scan", qos: .userInitiated)
    private var scanGeneration = 0

    /// Where Wallpaper Engine content normally lives on this Mac.
    static func defaultSearchPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = AssetLocator.defaultWorkshopDirectories()
        for candidate in [home.appendingPathComponent("Documents/wallpaper-engine"),
                          home.appendingPathComponent("Downloads/wallpaper-engine")] {
            if FileManager.default.fileExists(atPath: candidate.path) { paths.append(candidate) }
        }
        return paths
    }

    private func persistSearchPaths() {
        UserDefaults.standard.set(searchPaths.map(\.path), forKey: WallpaperLibrary.searchPathsKey)
    }

    func addSearchPath(_ url: URL) {
        guard !searchPaths.contains(url) else { return }
        searchPaths.append(url)
    }

    func removeSearchPath(_ url: URL) {
        searchPaths.removeAll { $0 == url }
    }

    func rescan() {
        scanGeneration += 1
        let generation = scanGeneration
        let roots = searchPaths
        scanQueue.async { [weak self] in
            let found = WallpaperLibrary.scan(roots)
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                self.items = found
            }
        }
    }

    /// Walks the search paths. Pure, so it is safe to run anywhere.
    private static func scan(_ roots: [URL]) -> [WallpaperItem] {
        var found: [WallpaperItem] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if let item = WallpaperLibrary.projectItem(at: entry), seen.insert(item.id).inserted {
                        found.append(item)
                    }
                } else if let item = WallpaperLibrary.looseItem(at: entry), seen.insert(item.id).inserted {
                    found.append(item)
                }
            }
        }
        return found
    }

    /// A Wallpaper Engine workshop folder (`project.json` + content).
    static func projectItem(at directory: URL) -> WallpaperItem? {
        guard let project = try? WEProject.load(directory: directory) else { return nil }
        let kind: WallpaperItem.Kind
        switch project.kind {
        case .scene: kind = .scene
        case .video: kind = .video
        case .web: kind = .web
        default:
            // Some items are just an image with a project.json.
            let ext = (project.file as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) { kind = .image }
            else if ext == "gif" { kind = .gif }
            else { return nil }
        }
        // A scene's `scene.json` normally lives inside `scene.pkg` rather than on disk.
        guard let content = project.fileURL else { return nil }
        let hasContent = (try? content.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            || (kind == .scene && project.packageURL != nil)
        guard hasContent else { return nil }
        return WallpaperItem(id: project.workshopId ?? directory.path,
                             title: project.title,
                             kind: kind,
                             location: directory,
                             contentURL: content,
                             previewURL: project.previewURL,
                             workshopId: project.workshopId,
                             projectDirectory: directory)
    }

    /// A loose video or image file.
    static func looseItem(at url: URL) -> WallpaperItem? {
        let ext = url.pathExtension.lowercased()
        let kind: WallpaperItem.Kind
        if videoExtensions.contains(ext) { kind = .video }
        else if ext == "gif" { kind = .gif }
        else if imageExtensions.contains(ext) { kind = .image }
        else { return nil }
        return WallpaperItem(id: url.path,
                             title: url.deletingPathExtension().lastPathComponent,
                             kind: kind,
                             location: url,
                             contentURL: url,
                             previewURL: kind == .image || kind == .gif ? url : nil,
                             workshopId: nil,
                             projectDirectory: nil)
    }

    /// Import a folder or file the user dropped or picked.
    @discardableResult
    func importItem(at url: URL) -> WallpaperItem? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            if let item = WallpaperLibrary.projectItem(at: url) {
                addSearchPath(url.deletingLastPathComponent())
                return item
            }
            // A folder of wallpapers rather than a single one.
            addSearchPath(url)
            return nil
        }
        guard let item = WallpaperLibrary.looseItem(at: url) else { return nil }
        addSearchPath(url.deletingLastPathComponent())
        return item
    }

    func item(withId id: String) -> WallpaperItem? { items.first { $0.id == id } }

    func items(of kind: WallpaperItem.Kind) -> [WallpaperItem] { items.filter { $0.kind == kind } }
}
