import SwiftUI
import AppKit

@main
struct MirageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library = WallpaperLibrary()
    @StateObject private var settings = AppSettings()
    @StateObject private var controller: WallpaperController

    init() {
        let library = WallpaperLibrary()
        let settings = AppSettings()
        _library = StateObject(wrappedValue: library)
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: WallpaperController(library: library, settings: settings))
    }

    var body: some Scene {
        Window("Mirage", id: "library") {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(controller)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(controller.isManuallyPaused ? "Resume Wallpapers" : "Pause Wallpapers") {
                    controller.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Mirage", systemImage: "sparkles.tv") {
            MenuBarContent()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(controller)
        }

        Settings {
            SettingsView()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon, and closing the library must not quit.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The menu-bar dropdown: quick apply, pause, and the usual entry points.
struct MenuBarContent: View {
    @EnvironmentObject private var library: WallpaperLibrary
    @EnvironmentObject private var controller: WallpaperController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if library.items.isEmpty {
            Text("No wallpapers found")
            Button("Add a Folder…") { pickFolder() }
        } else {
            Menu("Set Wallpaper") {
                ForEach(library.items.prefix(30)) { item in
                    Button(item.title) { controller.assignToAllDisplays(item) }
                }
            }
        }
        Divider()
        Button(controller.isManuallyPaused ? "Resume" : "Pause") { controller.togglePause() }
        Button("Remove Wallpapers") { controller.clearAll() }
        Divider()
        Button("Open Mirage…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "library")
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Mirage") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            library.addSearchPath(url)
        }
    }
}
