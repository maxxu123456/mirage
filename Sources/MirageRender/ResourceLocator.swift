import Foundation

/// Finds bundled resources whether we run from an .app bundle or from `swift run`.
public enum ResourceLocator {
    /// Root of bundled resources (`Resources/` in the repo, `Contents/Resources` in the app).
    public static func resourcesRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["MIRAGE_RESOURCES"] {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("WEAssets").path) {
            return bundled
        }
        // Source checkout: <repo>/Sources/MirageRender/ResourceLocator.swift → <repo>/Resources
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let res = repo.appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: res.path) { return res }
        return nil
    }

    /// Our own minimal re-implementations of Wallpaper Engine built-ins, used
    /// when the real `assets` folder is unavailable.
    public static func fallbackAssetsDirectory() -> URL? {
        resourcesRoot()?.appendingPathComponent("WEAssets")
    }
}
