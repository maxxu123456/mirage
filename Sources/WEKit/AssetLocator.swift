import Foundation

/// Resolves asset paths the way Wallpaper Engine does: first the scene
/// package, then loose files in the project folder, then the Wallpaper
/// Engine `assets` folder(s), then our own bundled fallbacks.
public final class AssetLocator {
    public let projectDirectory: URL
    public let package: WEPackage?
    public let assetsDirectories: [URL]
    public let fallbackDirectory: URL?

    private var jsonCache: [String: JSON] = [:]
    private var textCache: [String: String] = [:]
    private var missing: Set<String> = []
    private var effectIndex: [String: URL]? = nil
    private let lock = NSLock()

    /// Diagnostics: every path that could not be resolved.
    public private(set) var unresolvedPaths: [String] = []

    public init(projectDirectory: URL, package: WEPackage?, assetsDirectories: [URL], fallbackDirectory: URL?) {
        self.projectDirectory = projectDirectory
        self.package = package
        self.assetsDirectories = assetsDirectories
        self.fallbackDirectory = fallbackDirectory
    }

    public convenience init(project: WEProject, assetsDirectories: [URL], fallbackDirectory: URL?) throws {
        let pkg = try project.packageURL.map { try WEPackage(url: $0) }
        self.init(projectDirectory: project.directory, package: pkg, assetsDirectories: assetsDirectories, fallbackDirectory: fallbackDirectory)
    }

    // MARK: Lookup

    public func exists(_ path: String) -> Bool { url(for: path) != nil || (package?.contains(path) ?? false) }

    /// Raw bytes of an asset.
    public func data(_ path: String) -> Data? {
        let p = WEPackage.normalize(path)
        if let pkg = package, let d = pkg.data(named: p) { return d }
        if let u = url(for: p) { return try? Data(contentsOf: u) }
        lock.lock(); defer { lock.unlock() }
        if !missing.contains(p) { missing.insert(p); unresolvedPaths.append(p) }
        return nil
    }

    public func text(_ path: String) -> String? {
        lock.lock()
        if let t = textCache[path] { lock.unlock(); return t }
        lock.unlock()
        guard isWithinFileSizeLimit(path, limit: JSON.maximumDocumentByteCount),
              let d = data(path) else { return nil }
        var s = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        lock.lock(); textCache[path] = s; lock.unlock()
        return s
    }

    public func json(_ path: String) -> JSON? {
        lock.lock()
        if let j = jsonCache[path] { lock.unlock(); return j }
        lock.unlock()
        guard isWithinFileSizeLimit(path, limit: JSON.maximumDocumentByteCount),
              let d = data(path) else { return nil }
        guard let j = try? JSON.parse(d) else { return nil }
        lock.lock(); jsonCache[path] = j; lock.unlock()
        return j
    }

    public func texture(named name: String) -> WETexture? {
        guard let d = textureData(named: name) else { return nil }
        return try? WETexture.decode(d)
    }

    public func textureData(named name: String) -> Data? {
        let path = "materials/\(name).tex"
        guard isWithinFileSizeLimit(path, limit: WEPixelLayout.maximumAllocationByteCount) else { return nil }
        return data(path)
    }

    public func model(_ path: String) -> WEModel? { json(path).map(WEModel.init(json:)) }
    public func material(_ path: String) -> WEMaterial? { json(path).map(WEMaterial.init(json:)) }
    public func effect(_ path: String) -> WEEffect? { json(path).map(WEEffect.init(json:)) }

    /// Shader source for `shaders/<name>.<ext>`; handles workshop compat shaders.
    public func shaderSource(_ name: String, ext: String) -> String? {
        var candidates = ["shaders/\(name).\(ext)"]
        // Workshop shaders may be superseded by compat copies shipped in the assets folder.
        if name.hasPrefix("workshop/") {
            let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 3 {
                let id = parts[1]
                let base = parts.dropFirst(2).joined(separator: "/")
                candidates.insert("zcompat/scene/shaders/\(id)/\(base).\(ext)", at: 0)
                candidates.append("zcompat/scene/shaders/\(id)/\((base as NSString).lastPathComponent).\(ext)")
            }
        }
        for c in candidates where c == candidates.last || exists(c) {
            if let t = text(c) { return t }
        }
        return nil
    }

    /// `#include "x.h"` contents.
    public func includeSource(_ name: String) -> String? {
        var n = name
        if !n.hasSuffix(".h") && !n.hasSuffix(".hlsli") && !n.hasSuffix(".glsl") { n += ".h" }
        if let t = text("shaders/\(n)") { return t }
        // Some includes are given relative to the including shader's folder.
        if let t = text("shaders/effects/\(n)") { return t }
        return nil
    }

    // MARK: Filesystem resolution

    private func isWithinFileSizeLimit(_ path: String, limit: Int) -> Bool {
        let p = WEPackage.normalize(path)
        if let entry = package?.entry(named: p) { return entry.length <= limit }
        guard let file = url(for: p),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return true }
        return size <= limit
    }

    private func url(for path: String) -> URL? {
        let p = WEPackage.normalize(path)
        guard !p.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        let fm = FileManager.default
        let local = projectDirectory.appendingPathComponent(p)
        if fm.fileExists(atPath: local.path) { return local }
        for dir in assetsDirectories {
            let u = dir.appendingPathComponent(p)
            if fm.fileExists(atPath: u.path) { return u }
            if let e = effectFile(p, in: dir) { return e }
        }
        if let fb = fallbackDirectory {
            let u = fb.appendingPathComponent(p)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Stock effects live in `assets/effects/<effect>/{materials,shaders}/effects/<file>` but are
    /// referenced as `materials/effects/<file>` / `shaders/effects/<file>`.
    private func effectFile(_ path: String, in assets: URL) -> URL? {
        guard path.hasPrefix("materials/effects/") || path.hasPrefix("shaders/effects/") else { return nil }
        lock.lock()
        if effectIndex == nil { effectIndex = buildEffectIndex() }
        let idx = effectIndex ?? [:]
        lock.unlock()
        return idx[path] ?? idx[path.lowercased()]
    }

    private func buildEffectIndex() -> [String: URL] {
        var index: [String: URL] = [:]
        let fm = FileManager.default
        for assets in assetsDirectories {
            let effectsDir = assets.appendingPathComponent("effects")
            guard let effects = try? fm.contentsOfDirectory(at: effectsDir, includingPropertiesForKeys: nil) else { continue }
            for effect in effects {
                for kind in ["materials", "shaders"] {
                    let dir = effect.appendingPathComponent(kind)
                    guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                    for case let file as URL in enumerator {
                        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                        // relative path below `<effect>/<kind>/`
                        let rel = file.path.dropFirst(dir.path.count + 1)
                        let key = "\(kind)/\(rel)"
                        if index[key] == nil { index[key] = file }
                        index[key.lowercased()] = index[key.lowercased()] ?? file
                    }
                }
            }
        }
        return index
    }

    // MARK: Well-known locations

    /// Candidate Wallpaper Engine `assets` folders on this machine.
    public static func defaultAssetsDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        candidates.append(home.appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets"))
        candidates.append(home.appendingPathComponent("Library/Application Support/Steam/steamcmd/steamapps/common/wallpaper_engine/assets"))
        candidates.append(home.appendingPathComponent("Library/Application Support/Mirage/assets"))
        return candidates.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("shaders").path) }
    }

    /// Default Steam workshop content folder used by SteamCMD.
    public static func defaultWorkshopDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/431960"),
            home.appendingPathComponent("Library/Application Support/Steam/steamcmd/steamapps/workshop/content/431960"),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
