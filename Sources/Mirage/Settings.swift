import Foundation
import AppKit
import IOKit.ps
import ServiceManagement

/// User-facing settings, persisted in `UserDefaults`.
final class AppSettings: ObservableObject {
    @Published var pauseWhenFullscreen: Bool { didSet { store(oldValue, pauseWhenFullscreen, "pauseWhenFullscreen") } }
    @Published var pauseOnBattery: Bool { didSet { store(oldValue, pauseOnBattery, "pauseOnBattery") } }
    @Published var pauseWhenIdle: Bool { didSet { store(oldValue, pauseWhenIdle, "pauseWhenIdle") } }
    @Published var idleTimeoutMinutes: Int { didSet { store(oldValue, idleTimeoutMinutes, "idleTimeoutMinutes") } }
    @Published var fpsCap: Int { didSet { store(oldValue, fpsCap, "fpsCap") } }
    @Published var muted: Bool { didSet { store(oldValue, muted, "muted") } }
    @Published var volume: Double { didSet { store(oldValue, volume, "volume") } }
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin(oldValue) } }

    private var isLoading = true

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "pauseWhenFullscreen": true,
            "pauseOnBattery": false,
            "pauseWhenIdle": false,
            "idleTimeoutMinutes": 15,
            "fpsCap": 30,
            "muted": true,
            "volume": 0.0,
        ])
        pauseWhenFullscreen = defaults.bool(forKey: "pauseWhenFullscreen")
        pauseOnBattery = defaults.bool(forKey: "pauseOnBattery")
        pauseWhenIdle = defaults.bool(forKey: "pauseWhenIdle")
        idleTimeoutMinutes = min(24 * 60, max(1, defaults.integer(forKey: "idleTimeoutMinutes")))
        fpsCap = min(240, max(1, defaults.integer(forKey: "fpsCap")))
        muted = defaults.bool(forKey: "muted")
        let storedVolume = defaults.double(forKey: "volume")
        volume = storedVolume.isFinite ? min(1, max(0, storedVolume)) : 0
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = false
        }
        isLoading = false
    }

    private func store<T>(_ old: T, _ new: T, _ key: String) {
        guard !isLoading else { return }
        UserDefaults.standard.set(new, forKey: key)
    }

    private func applyLaunchAtLogin(_ old: Bool) {
        guard !isLoading, old != launchAtLogin else { return }
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Mirage: could not change login item: \(error)")
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

/// Reasons the wallpaper should stop animating, to save power.
enum PowerState {
    /// Seconds since the last user input, from the window-server event source.
    static var idleSeconds: TimeInterval {
        guard let anyEventType = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEventType)
    }

    static var isOnBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }

    /// True when a window covers the usable area of `screen`, either a fullscreen
    /// app or a maximised window leaves no wallpaper visible around the menu bar/dock.
    static func visibleWindowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    static func isCovered(_ screen: NSScreen, windowInfo: [[String: Any]]) -> Bool {
        let screenFrame = screen.visibleFrame
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        guard let primary = NSScreen.screens.first else { return false }
        for info in windowInfo {
            guard let level = info[kCGWindowLayer as String] as? Int, level > desktopLevel,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.95 else { continue }
            // CGWindow bounds use a top-left origin on the primary display.
            let flipped = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY,
                                 width: bounds.width, height: bounds.height)
            if flipped.intersection(screenFrame).equalTo(screenFrame) { return true }
        }
        return false
    }

    static func isCovered(_ screen: NSScreen) -> Bool {
        guard let windowInfo = visibleWindowInfo() else { return false }
        return isCovered(screen, windowInfo: windowInfo)
    }
}
