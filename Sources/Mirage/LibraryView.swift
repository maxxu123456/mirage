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

                    if !properties.isEmpty {
                        Divider()
                        Text("Properties").font(.headline)
                        Text("\(properties.count) options defined by this wallpaper.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(properties) { property in
                            HStack {
                                Text(property.displayLabel).lineLimit(1)
                                Spacer()
                                Text(String(describing: property.kind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
        return project.properties.filter { $0.kind != .group && !$0.displayLabel.isEmpty }
    }
}
