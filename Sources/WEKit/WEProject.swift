import Foundation

/// A user-facing property declared in `project.json → general.properties`.
public struct WEUserProperty: Identifiable, Hashable {
    public enum Kind: String {
        case bool, slider, color, combo, text, textinput, scenetexture, file, directory, group, usershortcut, unknown
    }

    public struct Option: Hashable {
        public let label: String
        public let value: String
    }

    public let name: String
    public let kind: Kind
    public let label: String
    public let defaultValue: JSON
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let fraction: Bool
    public let precision: Int?
    public let options: [Option]
    public let condition: String?
    public let order: Int
    /// Position in the file, used to break ties on `order`, which is not unique.
    public let index: Int

    public var id: String { name }

    /// A decorative heading rather than a value the user sets. Several corpus
    /// properties have no `type` at all and exist only to label a group.
    public var isHeading: Bool {
        kind == .group || (kind == .text && defaultValue.isNull) || (kind == .unknown && defaultValue.isNull)
    }

    /// Whether Mirage offers a control for it.
    public var isEditable: Bool {
        guard !isHeading else { return false }
        switch kind {
        case .bool, .slider, .color, .combo, .textinput: return true
        case .text: return !defaultValue.isNull
        default: return false
        }
    }

    public init(name: String, json: JSON, index: Int) {
        self.name = name
        let typeName = json["type"].string?.lowercased() ?? ""
        self.kind = Kind(rawValue: typeName) ?? .unknown
        self.label = json["text"].string ?? name
        self.defaultValue = json["value"]
        self.min = json["min"].double
        self.max = json["max"].double
        self.step = json["step"].double
        self.fraction = json["fraction"].bool ?? false
        self.precision = json["precision"].int
        self.options = (json["options"].array ?? []).compactMap { o in
            guard let label = o["label"].string else { return nil }
            let value: String
            switch o["value"] {
            case .string(let s): value = s
            case .number(let n): value = JSON.numberString(n)
            case .bool(let b): value = b ? "1" : "0"
            default: return nil
            }
            return Option(label: label, value: value)
        }
        self.condition = json["condition"].string
        self.order = json["order"].int ?? json["index"].int ?? index
        self.index = index
    }

    public static func == (a: WEUserProperty, b: WEUserProperty) -> Bool { a.name == b.name && a.defaultValue == b.defaultValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    /// Localised-ish label: WE uses `ui_*` keys for some built-in properties.
    public var displayLabel: String {
        switch label {
        case "ui_browse_properties_scheme_color": return "Scheme Color"
        default:
            // Strip simple HTML tags used for headings.
            var s = label.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? name : s
        }
    }
}

/// `project.json` of a wallpaper.
public struct WEProject {
    public enum Kind: String {
        case scene, video, web, application, unknown

        public init(typeString: String?) {
            switch typeString?.lowercased() {
            case "scene": self = .scene
            case "video": self = .video
            case "web": self = .web
            case "application": self = .application
            default: self = .unknown
            }
        }
    }

    public let directory: URL
    public let title: String
    public let kind: Kind
    public let file: String
    public let preview: String?
    public let description: String?
    public let tags: [String]
    public let workshopId: String?
    public let contentRating: String?
    public let properties: [WEUserProperty]
    public let supportsAudioProcessing: Bool
    public let raw: JSON

    public var fileURL: URL? { localURL(for: file) }
    public var previewURL: URL? {
        guard let preview, !preview.isEmpty, let url = localURL(for: preview) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    public var packageURL: URL? {
        let url = directory.appendingPathComponent("scene.pkg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func localURL(for path: String) -> URL? {
        let normalized = WEPackage.normalize(path)
        guard !normalized.isEmpty,
              !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        return directory.appendingPathComponent(normalized)
    }

    public init(directory: URL, json: JSON) {
        self.directory = directory
        self.raw = json
        self.title = json["title"].string ?? directory.lastPathComponent
        self.kind = Kind(typeString: json["type"].string)
        self.file = json["file"].string ?? (kind == .scene ? "scene.json" : "")
        self.preview = json["preview"].string
        self.description = json["description"].string
        self.tags = (json["tags"].array ?? []).compactMap(\.string)
        switch json["workshopid"] {
        case .string(let s): self.workshopId = s
        case .number(let n):
            self.workshopId = n.isFinite && n == n.rounded() ? Int64(exactly: n).map(String.init) : nil
        default:
            // Fall back to a trailing "[id]" in the folder name or an all-digit folder name.
            let name = directory.lastPathComponent
            if let open = name.lastIndex(of: "["), name.hasSuffix("]") {
                let id = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
                self.workshopId = id.allSatisfy(\.isNumber) ? id : nil
            } else if !name.isEmpty, name.allSatisfy(\.isNumber) {
                self.workshopId = name
            } else {
                self.workshopId = nil
            }
        }
        self.contentRating = json["contentrating"].string
        let general = json["general"]
        var props: [WEUserProperty] = []
        if let dict = general["properties"].object {
            for (i, key) in dict.keys.sorted().enumerated() {
                guard let value = dict[key] else { continue }
                props.append(WEUserProperty(name: key, json: value, index: i))
            }
        }
        // Swift's sort is not stable and `order` is not unique, so ties fall back
        // to the order the file lists them in.
        props.sort { $0.order != $1.order ? $0.order < $1.order : $0.index < $1.index }
        self.properties = props
        self.supportsAudioProcessing = general["supportsaudioprocessing"].bool ?? false
    }

    public static func load(directory: URL) throws -> WEProject {
        let url = directory.appendingPathComponent("project.json")
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > JSON.maximumDocumentByteCount {
            throw JSONParseError.documentTooLarge(size)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return WEProject(directory: directory, json: try JSON.parse(data))
    }
}
