import Foundation

/// Reader for Wallpaper Engine `scene.pkg` containers.
///
/// Layout (little endian):
/// ```
/// u32 len, char[len]   version string, e.g. "PKGV0020"
/// u32 fileCount
/// fileCount × { u32 len, char[len] name; u32 offset; u32 length }
/// <file data>          offsets are relative to the end of the header
/// ```
public final class WEPackage {
    private static let maximumNameByteCount = 1024 * 1024
    private static let maximumHeaderStringByteCount = 64 * 1024 * 1024
    private static let maximumEntryCount = 262_144
    private static let maximumEntryByteCount = 256 * 1024 * 1024
    public struct Entry: Hashable {
        public let name: String
        public let offset: Int
        public let length: Int
    }

    public enum PackageError: Error, CustomStringConvertible {
        case truncated
        case badMagic(String)
        public var description: String {
            switch self {
            case .truncated: return "package file is truncated"
            case .badMagic(let m): return "not a Wallpaper Engine package (magic \(m))"
            }
        }
    }

    public let url: URL
    public let version: String
    public let entries: [Entry]
    private let index: [String: Entry]
    private let lowercaseIndex: [String: Entry]
    private let data: Data
    private let base: Int

    public init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        self.data = data
        var cursor = 0
        var headerStringByteCount = 0

        func readU32() throws -> Int {
            guard 4 <= data.count - cursor else { throw PackageError.truncated }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
            cursor += 4
            return Int(UInt32(littleEndian: v))
        }
        func readString() throws -> String {
            let len = try readU32()
            guard len <= WEPackage.maximumNameByteCount,
                  headerStringByteCount <= WEPackage.maximumHeaderStringByteCount - len,
                  len <= data.count - cursor else {
                throw PackageError.truncated
            }
            let s = String(decoding: data[(data.startIndex + cursor)..<(data.startIndex + cursor + len)], as: UTF8.self)
            cursor += len
            headerStringByteCount += len
            return s
        }

        let version = try readString()
        guard version.hasPrefix("PKGV") else { throw PackageError.badMagic(version) }
        self.version = version
        let count = try readU32()
        // Even an empty name needs a length field plus offset and length.
        guard count <= WEPackage.maximumEntryCount,
              count <= (data.count - cursor) / 12 else { throw PackageError.truncated }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let name = try readString()
            let offset = try readU32()
            let length = try readU32()
            entries.append(Entry(name: name, offset: offset, length: length))
        }
        self.base = cursor
        let payloadSize = data.count - cursor
        guard entries.allSatisfy({ $0.offset <= payloadSize && $0.length <= payloadSize - $0.offset }) else {
            throw PackageError.truncated
        }
        self.entries = entries
        var index: [String: Entry] = [:]
        var lower: [String: Entry] = [:]
        for e in entries {
            index[e.name] = e
            lower[e.name.lowercased()] = e
        }
        self.index = index
        self.lowercaseIndex = lower
    }

    public var fileNames: [String] { entries.map(\.name) }

    public func entry(named name: String) -> Entry? {
        let n = WEPackage.normalize(name)
        return index[n] ?? lowercaseIndex[n.lowercased()]
    }

    public func contains(_ name: String) -> Bool { entry(named: name) != nil }

    public func data(named name: String) -> Data? {
        guard let e = entry(named: name) else { return nil }
        guard e.length <= WEPackage.maximumEntryByteCount else { return nil }
        guard base <= data.count, e.offset <= data.count - base else { return nil }
        let start = data.startIndex + base + e.offset
        guard e.length <= data.endIndex - start else { return nil }
        let end = start + e.length
        return data.subdata(in: start..<end)
    }

    static func normalize(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "\\", with: "/")
        while n.hasPrefix("/") { n.removeFirst() }
        return n
    }
}
