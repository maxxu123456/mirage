import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WEKit

/// The main window: a source list, a grid of wallpapers, and a detail panel with
/// the selected wallpaper's Wallpaper Engine properties.
struct LibraryView: View {
    @EnvironmentObject private var library: WallpaperLibrary
    @EnvironmentObject private var controller: WallpaperController

    enum Section: Hashable {
        case all
        case kind(WallpaperItem.Kind)
        case display(String)
    }

    @State private var section: Section = .all
    @State private var selection: WallpaperItem?
    @State private var search = ""

    private var visibleItems: [WallpaperItem] {
        var items: [WallpaperItem]
        switch section {
        case .all: items = library.items
        case .kind(let kind): items = library.items(of: kind)
        case .display(let id): items = controller.assignedItem(for: id).map { [$0] } ?? []
        }
        if !search.isEmpty {
            items = items.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        return items
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                SwiftUI.Section("Library") {
                    Label("All Wallpapers", systemImage: "square.grid.2x2").tag(Section.all)
                    ForEach(WallpaperItem.Kind.allCases, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(Section.kind(kind))
                    }
                }
                SwiftUI.Section("Displays") {
                    ForEach(controller.displays) { display in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(display.name, systemImage: display.isMain ? "display" : "display.2")
                            Text(controller.assignedItem(for: display.id)?.title ?? "None")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(Section.display(display.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            grid
                .navigationSplitViewColumnWidth(min: 380, ideal: 620)
        } detail: {
            DetailPanel(item: selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search wallpapers")
        .toolbar {
            ToolbarItem {
                Button {
                    addFolder()
                } label: {
                    Label("Add Folder", systemImage: "plus")
                }
                .help("Add a folder of wallpapers")
            }
            ToolbarItem {
                Button {
                    library.rescan()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { library.importItem(at: url) }
                }
            }
            return true
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(visibleItems) { item in
                    WallpaperTile(item: item, isSelected: selection == item, isActive: isActive(item))
                        .onTapGesture { selection = item }
                        .onTapGesture(count: 2) { apply(item) }
                        .contextMenu {
                            Button("Set on All Displays") { controller.assignToAllDisplays(item) }
                            ForEach(controller.displays) { display in
                                Button("Set on \(display.name)") { controller.assign(item, to: display.id) }
                            }
                            Divider()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.location]) }
                        }
                }
            }
            .padding(16)
        }
        .overlay {
            if visibleItems.isEmpty {
                ContentUnavailableView("No Wallpapers",
                                       systemImage: "photo.on.rectangle.angled",
                                       description: Text("Add a folder of Wallpaper Engine items or videos."))
            }
        }
    }

    private func isActive(_ item: WallpaperItem) -> Bool {
        controller.assignments.values.contains(item.id)
    }

    private func apply(_ item: WallpaperItem) {
        if case .display(let id) = section {
            controller.assign(item, to: id)
        } else {
            controller.assignToAllDisplays(item)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { library.addSearchPath(url) }
    }
}

/// One wallpaper in the grid.
struct WallpaperTile: View {
    let item: WallpaperItem
    let isSelected: Bool
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let preview = item.previewURL, let image = NSImage(contentsOf: preview) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.kind.symbol)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                        .padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }

            Text(item.title).font(.callout).lineLimit(1)
            Text(item.kind.label).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Right-hand panel: preview, metadata and the wallpaper's own user properties.
struct DetailPanel: View {
    let item: WallpaperItem?
    @EnvironmentObject private var controller: WallpaperController
    @State private var properties: [WEUserProperty] = []
    /// Bumped after an edit so the controls re-read the store.
    @State private var editRevision = 0

    /// Properties Mirage can offer a control for, minus any hidden by their
    /// own `condition` given the current values.
    private var editableProperties: [WEUserProperty] {
        guard let item else { return [] }
        let store = PropertyStore(properties: properties, overrides: controller.propertyOverrides(for: item))
        return properties.filter { property in
            guard property.isEditable else { return false }
            guard let condition = property.condition, !condition.isEmpty else { return true }
            return store.evaluateCondition(condition)
        }
    }

    private func value(of property: WEUserProperty) -> JSON {
        guard let item else { return property.defaultValue }
        return controller.propertyOverrides(for: item)[property.name] ?? property.defaultValue
    }

    private func bumpEdits() { editRevision &+= 1 }

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let preview = item.previewURL, let image = NSImage(contentsOf: preview) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(item.title).font(.headline)
                    LabeledContent("Type", value: item.kind.label)
                    if let workshopId = item.workshopId {
                        LabeledContent("Workshop ID", value: workshopId)
                    }

                    Button("Set on All Displays") { controller.assignToAllDisplays(item) }
                        .buttonStyle(.borderedProminent)

                    if !editableProperties.isEmpty {
                        Divider()
                        HStack {
                            Text("Properties").font(.headline)
                            Spacer()
                            Button("Reset") { controller.resetProperties(for: item); bumpEdits() }
                                .buttonStyle(.link)
                                .disabled(controller.propertyEdits[item.id] == nil)
                        }
                        Text("Set by this wallpaper's author. Changes apply straight away.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(editableProperties) { property in
                            PropertyControl(property: property,
                                            value: value(of: property),
                                            onChange: { newValue in
                                                controller.setProperty(property.name, to: newValue, on: item)
                                                bumpEdits()
                                            })
                        }
                    }
                    Spacer()
                }
                .padding(16)
            }
            .task(id: item.id) { properties = DetailPanel.loadProperties(item) }
        } else {
            ContentUnavailableView("Select a Wallpaper", systemImage: "sidebar.right")
        }
    }

    static func loadProperties(_ item: WallpaperItem) -> [WEUserProperty] {
        guard let directory = item.projectDirectory, let project = try? WEProject.load(directory: directory) else { return [] }
        return project.properties.filter { !$0.displayLabel.isEmpty }
    }
}

/// One editable Wallpaper Engine property.
///
/// The control follows the property's declared type, which is what the author
/// designed the wallpaper around: a slider that carries `fraction` really is a
/// 0 to 1 value, and a combo's options are stored as strings even when they
/// look like numbers.
struct PropertyControl: View {
    let property: WEUserProperty
    let value: JSON
    let onChange: (JSON) -> Void

    var body: some View {
        switch property.kind {
        case .bool:
            Toggle(property.displayLabel, isOn: Binding(
                get: { value.bool ?? false },
                set: { onChange(.bool($0)) }))
                .toggleStyle(.switch)

        case .slider:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(property.displayLabel).lineLimit(1)
                    Spacer()
                    Text(formatted).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { value.double ?? property.defaultValue.double ?? 0 },
                    set: { onChange(.number($0)) }),
                       in: (property.min ?? 0)...(max(property.min ?? 0, property.max ?? 1)))
            }

        case .color:
            ColorPicker(property.displayLabel, selection: Binding(
                get: { Self.color(from: value) },
                set: { onChange(Self.json(from: $0)) }), supportsOpacity: false)

        case .combo:
            Picker(property.displayLabel, selection: Binding(
                get: { Self.comboKey(value) },
                set: { onChange(.string($0)) })) {
                    ForEach(property.options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }

        case .textinput, .text:
            VStack(alignment: .leading, spacing: 2) {
                Text(property.displayLabel).lineLimit(1)
                TextField("", text: Binding(
                    get: { value.string ?? "" },
                    set: { onChange(.string($0)) }))
                    .textFieldStyle(.roundedBorder)
            }

        default:
            EmptyView()
        }
    }

    private var formatted: String {
        let current = value.double ?? 0
        let digits = property.precision ?? (property.fraction ? 2 : 0)
        return String(format: "%.\(max(0, min(4, digits)))f", current)
    }

    /// Wallpaper Engine stores a colour as "r g b" in 0 to 1.
    private static func color(from json: JSON) -> Color {
        let parts = json.floats ?? [1, 1, 1]
        guard parts.count >= 3 else { return .white }
        return Color(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }

    private static func json(from color: Color) -> JSON {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return .string([rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { JSON.numberString(Double($0)) }
            .joined(separator: " "))
    }

    /// A combo's stored value may be a number or a string; its options are strings.
    private static func comboKey(_ json: JSON) -> String {
        if let text = json.string { return text }
        if let number = json.double { return JSON.numberString(number) }
        if let flag = json.bool { return flag ? "1" : "0" }
        return ""
    }
}
