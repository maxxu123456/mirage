import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PerformanceSettings()
                .tabItem { Label("Performance", systemImage: "speedometer") }
            DisplaySettings()
                .tabItem { Label("Displays", systemImage: "display.2") }
        }
        .frame(width: 480)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: WallpaperLibrary

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Mirage at login", isOn: $settings.launchAtLogin)
            }
            Section("Audio") {
                Toggle("Mute wallpaper audio", isOn: $settings.muted)
                HStack {
                    Text("Volume")
                    Slider(value: $settings.volume, in: 0...1)
                    Text("\(Int(settings.volume * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(settings.muted)
            }
            Section("Library Folders") {
                ForEach(library.searchPaths, id: \.self) { path in
                    HStack {
                        Text(path.path).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button("Remove") { library.removeSearchPath(path) }
                            .buttonStyle(.borderless)
                    }
                }
                if library.searchPaths.isEmpty {
                    Text("No folders added.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PerformanceSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Pause Rules") {
                Toggle("Pause when a window covers the screen", isOn: $settings.pauseWhenFullscreen)
                Toggle("Pause on battery power", isOn: $settings.pauseOnBattery)
                Toggle("Pause after idle timeout", isOn: $settings.pauseWhenIdle)
                Picker("Timeout", selection: $settings.idleTimeoutMinutes) {
                    ForEach([1, 5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
                .disabled(!settings.pauseWhenIdle)
            }
            Section("Frame Rate") {
                Picker("FPS cap", selection: $settings.fpsCap) {
                    ForEach([15, 24, 30, 60, 120], id: \.self) { fps in
                        Text("\(fps) FPS").tag(fps)
                    }
                }
                Text("Scene wallpapers render at this rate. Lower is easier on the battery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DisplaySettings: View {
    @EnvironmentObject private var controller: WallpaperController

    var body: some View {
        Form {
            ForEach(controller.displays) { display in
                Section(display.name + (display.isMain ? " (Main)" : "")) {
                    LabeledContent("Resolution",
                                   value: "\(Int(display.frame.width)) × \(Int(display.frame.height))")
                    LabeledContent("Wallpaper",
                                   value: controller.assignedItem(for: display.id)?.title ?? "None")
                    Button("Remove Wallpaper") { controller.clear(displayId: display.id) }
                        .disabled(controller.assignedItem(for: display.id) == nil)
                }
            }
            if let error = controller.lastError {
                Section("Last Error") {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}
