import Foundation
import CoreGraphics
import CoreText
import Metal
import simd
import WEKit

// MARK: - Layer description

/// Everything a text layer needs from `scene.json`, already resolved through
/// `DynamicValue` so the rasteriser never has to look at raw JSON.
///
/// `color`, `alpha` and `verticalAlign` are carried here for the caller's
/// convenience: they never change the coverage bitmap. Colour and opacity reach
/// the GPU as `g_Color4 = vec4(color, alpha)` in `materials/fonts/basefont.json`,
/// and the vertical alignment positions the quad, not the glyphs inside it.
public struct TextLayerSpec {
    public var string: String
    /// `"fonts/x.ttf"`, `"fonts/workshop/<id>/y.otf"` or `"systemfont_arial"`.
    public var fontPath: String?
    /// Wallpaper Engine `pointsize`. Pixels are `pointsize * 25/6`, see `TextRasterizer.pixelsPerPoint`.
    public var pointSize: Float
    public var color: SIMD3<Float>
    public var alpha: Float
    /// `"left"`, `"center"` or `"right"`; anything else is treated as `"center"`.
    public var horizontalAlign: String
    /// `"top"`, `"center"` or `"bottom"`; used by the caller when placing the quad.
    public var verticalAlign: String
    /// Wrap width in scene pixels, honoured only when `limitWidth`.
    public var maxWidth: Float
    /// Row cap, honoured only when `limitRows`.
    public var maxRows: Int
    public var limitWidth: Bool
    public var limitRows: Bool
    /// Append U+2026 to the last kept row when `limitRows` dropped something.
    public var useEllipsis: Bool

    public init(string: String,
                fontPath: String? = nil,
                pointSize: Float = 32,
                color: SIMD3<Float> = SIMD3(1, 1, 1),
                alpha: Float = 1,
                horizontalAlign: String = "center",
                verticalAlign: String = "center",
                maxWidth: Float = 500,
                maxRows: Int = 1,
                limitWidth: Bool = false,
                limitRows: Bool = false,
                useEllipsis: Bool = false) {
        self.string = string
        self.fontPath = fontPath
        self.pointSize = pointSize
        self.color = color
        self.alpha = alpha
        self.horizontalAlign = horizontalAlign
        self.verticalAlign = verticalAlign
        self.maxWidth = maxWidth
        self.maxRows = maxRows
        self.limitWidth = limitWidth
        self.limitRows = limitRows
        self.useEllipsis = useEllipsis
    }
}

/// A glyph coverage bitmap on the GPU. `width` and `height` are the block size in
/// scene pixels at `scale == 1`, which is exactly what the quad must measure
/// before the object's `scale.xy` is applied, and also what
/// `g_Texture0Resolution = (w, h, w, h)` wants.
public struct RasterizedText {
    /// `.r8Unorm`, row 0 is the top row, red channel is coverage, matching
    /// `ConvertSampleR8` in WE's `font.frag`.
    public let texture: MTLTexture
    public let width: Int
    public let height: Int

    public init(texture: MTLTexture, width: Int, height: Int) {
        self.texture = texture
        self.width = width
        self.height = height
    }
}

// MARK: - Rasteriser

/// Turns a text layer into a single-channel Metal texture the normal image pass
/// chain can draw, so `effects`, `colorBlendMode` and the composite targets all
/// keep working on text.
///
/// The font metrics deliberately do not come from CoreText. CoreText reports
/// `OS/2 usWin*` values for some faces, and Wallpaper Engine lays out from
/// `hhea` at 300 DPI (`25/6` pixels per point). Measuring the corpus against the
/// `size` the WE editor cached shows `hhea` matching to under a pixel and the
/// `OS/2` values missing by a third, so the tables are parsed out of the font
/// bytes and CoreText is used only for shaping and advances.
public final class TextRasterizer {
    /// Wallpaper Engine rasterises text at 300 DPI regardless of scene resolution.
    public static let pixelsPerPoint: Float = 25.0 / 6.0

    private let device: MTLDevice
    private let locator: AssetLocator
    private let queue: MTLCommandQueue?
    private let lock = NSLock()

    private var fonts: [String: LoadedFont] = [:]
    private var cache: [CacheKey: RasterizedText] = [:]
    private var order: [CacheKey] = []

    /// A clock layer only ever holds a handful of distinct strings, but a
    /// countdown or a scripted ticker mints a new one every second, so the cache
    /// is bounded rather than grow-forever.
    private static let cacheLimit = 64
    /// Guards against hostile input: a single layer must not be able to ask for
    /// a gigabyte of coverage bitmap.
    private static let maximumDimension = 8192
    private static let maximumPixelCount = 16_777_216
    private static let maximumCharacters = 4096
    private static let maximumLines = 512

    public init(device: MTLDevice, locator: AssetLocator) {
        self.device = device
        self.locator = locator
        self.queue = device.makeCommandQueue()
    }

    /// Returns nil for an empty or whitespace-only string, for a point size that
    /// is not a positive finite number, and for anything that fails to load or
    /// upload. Wallpaper files are third-party input, so every failure is silent.
    public func rasterize(_ spec: TextLayerSpec) -> RasterizedText? {
        guard !spec.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard spec.pointSize.isFinite, spec.pointSize > 0 else { return nil }

        let pixelSize = Double(spec.pointSize) * Double(Self.pixelsPerPoint)
        guard pixelSize.isFinite, pixelSize >= 0.5, pixelSize <= 4096 else { return nil }

        let fontKey = spec.fontPath ?? ""
        let wrapWidth = self.wrapWidth(for: spec)
        let rowLimit = spec.limitRows ? max(1, min(spec.maxRows, Self.maximumLines)) : 0
        let text = clipped(spec.string)
        let align = Alignment(spec.horizontalAlign)

        let key = CacheKey(font: fontKey,
                           pixelSize: (pixelSize * 64).rounded(),
                           string: text,
                           wrapWidth: (wrapWidth * 64).rounded(),
                           rowLimit: rowLimit,
                           align: align,
                           ellipsis: spec.useEllipsis)

        lock.lock()
        if let hit = cache[key] {
            touch(key)
            lock.unlock()
            return hit
        }
        let font = fonts[fontKey]
        lock.unlock()

        let loaded: LoadedFont
        if let font {
            loaded = font
        } else {
            guard let built = LoadedFont.load(path: spec.fontPath, locator: locator) else { return nil }
            loaded = built
            lock.lock(); fonts[fontKey] = built; lock.unlock()
        }

        guard let result = render(text: text, font: loaded, pixelSize: pixelSize,
                                  wrapWidth: wrapWidth, rowLimit: rowLimit,
                                  ellipsis: spec.useEllipsis, align: align) else { return nil }

        lock.lock()
        cache[key] = result
        touch(key)
        while order.count > Self.cacheLimit, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return result
    }

    /// Drops every cached bitmap and font. Call it when a wallpaper is torn down;
    /// the retained font `Data` blocks are the expensive part.
    public func purge() {
        lock.lock()
        cache.removeAll()
        order.removeAll()
        fonts.removeAll()
        lock.unlock()
    }

    // MARK: Cache bookkeeping

    private struct CacheKey: Hashable {
        let font: String
        let pixelSize: Double
        let string: String
        let wrapWidth: Double
        let rowLimit: Int
        let align: Alignment
        let ellipsis: Bool
    }

    /// Caller holds `lock`.
    private func touch(_ key: CacheKey) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private enum Alignment: Hashable {
        case left, center, right

        init(_ name: String) {
            switch name.lowercased() {
            case "left": self = .left
            case "right": self = .right
            default: self = .center
            }
        }

        /// Where a line of `lineWidth` starts inside a block of `blockWidth`.
        func originX(lineWidth: Double, blockWidth: Double) -> Double {
            switch self {
            case .left: return 0
            case .center: return (blockWidth - lineWidth) * 0.5
            case .right: return blockWidth - lineWidth
            }
        }
    }

    private func wrapWidth(for spec: TextLayerSpec) -> Double {
        guard spec.limitWidth, spec.maxWidth.isFinite, spec.maxWidth > 0 else { return 0 }
        return min(Double(spec.maxWidth), 65536)
    }

    private func clipped(_ string: String) -> String {
        guard string.utf16.count > Self.maximumCharacters else { return string }
        return String(string.prefix(Self.maximumCharacters))
    }

    // MARK: Layout

    private struct LaidOutLine {
        var line: CTLine?          // nil for a blank paragraph, which still takes a row
        var width: Double
        var paragraph: Int
        var start: CFIndex
    }

    private func render(text: String, font: LoadedFont, pixelSize: Double,
                        wrapWidth: Double, rowLimit: Int, ellipsis: Bool,
                        align: Alignment) -> RasterizedText? {
        let lineHeight = pixelSize * font.lineHeightEm
        let ascent = pixelSize * font.ascentEm
        guard lineHeight.isFinite, lineHeight > 0, ascent.isFinite else { return nil }

        let ctFont = font.font(pixelSize: CGFloat(pixelSize))
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: ctFont,
            // The context's fill colour is the coverage value; without this CoreText
            // would paint opaque black, which happens to work in an alpha-only
            // context but stops working the moment the context gains channels.
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ]

        let paragraphs = Self.paragraphs(of: text)
        var attributed: [NSAttributedString] = []
        var lines: [LaidOutLine] = []

        for (index, paragraph) in paragraphs.enumerated() {
            let string = NSAttributedString(string: paragraph, attributes: attributes)
            attributed.append(string)
            guard string.length > 0 else {
                lines.append(LaidOutLine(line: nil, width: 0, paragraph: index, start: 0))
                continue
            }
            if wrapWidth > 0 {
                let typesetter = CTTypesetterCreateWithAttributedString(string)
                var start: CFIndex = 0
                while start < string.length, lines.count < Self.maximumLines {
                    var count = CTTypesetterSuggestLineBreak(typesetter, start, wrapWidth)
                    // A width narrower than one glyph makes CoreText suggest nothing;
                    // take the rest of the paragraph rather than spin forever.
                    if count <= 0 { count = string.length - start }
                    let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                    lines.append(LaidOutLine(line: line, width: CTLineGetTypographicBounds(line, nil, nil, nil),
                                             paragraph: index, start: start))
                    start += count
                }
            } else {
                let line = CTLineCreateWithAttributedString(string)
                lines.append(LaidOutLine(line: line, width: CTLineGetTypographicBounds(line, nil, nil, nil),
                                         paragraph: index, start: 0))
            }
            if lines.count >= Self.maximumLines { break }
        }

        guard !lines.isEmpty else { return nil }

        var truncated = false
        if rowLimit > 0, lines.count > rowLimit {
            lines.removeSubrange(rowLimit...)
            truncated = true
        }

        var blockWidth = lines.reduce(0.0) { max($0, $1.width.isFinite ? $1.width : 0) }

        if truncated, ellipsis, let last = lines.last, last.line != nil {
            let limit = wrapWidth > 0 ? wrapWidth : blockWidth
            if limit > 0, last.paragraph < attributed.count {
                let source = attributed[last.paragraph]
                let start = max(0, min(Int(last.start), source.length))
                let remainder = source.attributedSubstring(from: NSRange(location: start, length: source.length - start))
                let full = CTLineCreateWithAttributedString(remainder)
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
                if let cut = CTLineCreateTruncatedLine(full, limit, .end, token) {
                    lines[lines.count - 1].line = cut
                    lines[lines.count - 1].width = CTLineGetTypographicBounds(cut, nil, nil, nil)
                    blockWidth = lines.reduce(0.0) { max($0, $1.width.isFinite ? $1.width : 0) }
                }
            }
        }

        guard let width = Self.pixels(blockWidth, limit: Self.maximumDimension),
              let height = Self.pixels(lineHeight * Double(lines.count), limit: Self.maximumDimension),
              width * height <= Self.maximumPixelCount else { return nil }

        return draw(lines: lines, width: width, height: height,
                    blockWidth: Double(width), lineHeight: lineHeight, ascent: ascent, align: align)
    }

    /// Splits on `\n` after normalising `\r\n` and lone `\r`, keeping blank rows:
    /// a blank line in a text layer still advances the block by one line height.
    private static func paragraphs(of text: String) -> [String] {
        var normalised = text
        if normalised.contains("\r") {
            normalised = normalised.replacingOccurrences(of: "\r\n", with: "\n")
            normalised = normalised.replacingOccurrences(of: "\r", with: "\n")
        }
        return normalised.components(separatedBy: "\n")
    }

    /// Rounds a block dimension to whole pixels the way Wallpaper Engine's editor
    /// did when it cached `size` (57.51 becomes 58, 153.36 becomes 153), so the
    /// quad measures what the wallpaper was authored against. `Int(someDouble)`
    /// traps on NaN and infinity, so the range is checked first.
    private static func pixels(_ value: Double, limit: Int) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        if rounded < 1 { return 1 }
        if rounded > Double(limit) { return limit }
        return Int(rounded)
    }

    // MARK: Rasterisation

    private func draw(lines: [LaidOutLine], width: Int, height: Int, blockWidth: Double,
                      lineHeight: Double, ascent: Double, align: Alignment) -> RasterizedText? {
        // Alpha-only over device gray: one byte per pixel holding coverage, which
        // is exactly what `font.frag` reads back through `ConvertSampleR8`.
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        // Subpixel smoothing would bake an RGB fringe into a single channel.
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.setFillColor(gray: 1, alpha: 1)

        for (index, entry) in lines.enumerated() {
            guard let line = entry.line else { continue }
            // A `CGBitmapContext` is y-up while its memory row 0 is the top row, so
            // measuring the baseline down from the block top gives row 0 = first
            // line with no CTM flip.
            let baseline = Double(height) - (Double(index) * lineHeight + ascent)
            guard baseline.isFinite else { continue }
            let x = align.originX(lineWidth: entry.width.isFinite ? entry.width : 0, blockWidth: blockWidth)
            guard x.isFinite else { continue }
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
        }

        guard let texture = upload(context: context, width: width, height: height) else { return nil }
        return RasterizedText(texture: texture, width: width, height: height)
    }

    /// Private-storage upload through a shared staging buffer and a blit, the same
    /// path `TextureStore.uploadLevels` uses for wallpaper textures.
    private func upload(context: CGContext, width: Int, height: Int) -> MTLTexture? {
        guard let queue, let pixels = context.data else { return nil }
        let bytesPerRow = width
        let byteCount = bytesPerRow * height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let staging = device.makeBuffer(bytes: pixels, length: byteCount, options: .storageModeShared),
              let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return nil }
        texture.label = "mirage.text"

        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
                  sourceBytesPerImage: byteCount,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        command.commit()
        // This queue is not the renderer's, so nothing else orders the blit ahead
        // of the first draw that samples the texture. Text changes at most a few
        // times a second, so the wait is cheaper than plumbing a shared queue.
        command.waitUntilCompleted()
        return texture
    }
}

// MARK: - Font loading

/// A resolved face plus the two metrics Wallpaper Engine lays out from, expressed
/// per em so one load serves every point size.
private final class LoadedFont {
    /// Retained for the lifetime of the face: `CGFont` does not copy the bytes a
    /// `CGDataProvider` hands it, and fonts inside `scene.pkg` have no file to
    /// fall back on.
    private let source: Data?
    private let template: CTFont
    let ascentEm: Double
    let lineHeightEm: Double

    private init(source: Data?, template: CTFont, ascentEm: Double, lineHeightEm: Double) {
        self.source = source
        self.template = template
        self.ascentEm = ascentEm
        self.lineHeightEm = lineHeightEm
    }

    func font(pixelSize: CGFloat) -> CTFont {
        CTFontCreateCopyWithAttributes(template, pixelSize, nil, nil)
    }

    static func load(path: String?, locator: AssetLocator) -> LoadedFont? {
        guard let path, !path.isEmpty else { return system(named: nil) }
        let lowered = path.lowercased()
        if lowered.hasPrefix("systemfont_") {
            return system(named: String(path.dropFirst("systemfont_".count)))
        }
        // `AssetLocator.data` already walks pkg, then the project folder, then the
        // WE assets folder, which is where the 15 bundled faces live.
        var candidates = [path]
        let leaf = (path as NSString).lastPathComponent
        if !leaf.isEmpty, leaf != path { candidates.append("fonts/\(leaf)") }
        for candidate in candidates {
            guard let data = locator.data(candidate), !data.isEmpty else { continue }
            if let font = fromData(data) { return font }
        }
        return system(named: nil)
    }

    private static func fromData(_ data: Data) -> LoadedFont? {
        var template: CTFont?
        if let provider = CGDataProvider(data: data as CFData), let cgFont = CGFont(provider) {
            template = CTFontCreateWithGraphicsFont(cgFont, 1, nil, nil)
        }
        if template == nil {
            // `.ttc` collections and some `.otf` files only come back through the
            // font manager.
            let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]
            if let first = descriptors?.first {
                template = CTFontCreateWithFontDescriptor(first, 1, nil)
            }
        }
        guard let template else { return nil }
        let metrics = SFNTMetrics.parse(data) ?? SFNTMetrics.parse(template) ?? SFNTMetrics.coreText(template)
        return LoadedFont(source: data, template: template,
                          ascentEm: metrics.ascentEm, lineHeightEm: metrics.lineHeightEm)
    }

    /// `systemfont_<name>` names Windows faces; map them onto what a Mac has.
    private static func system(named name: String?) -> LoadedFont? {
        var candidates: [String] = []
        if let name, !name.isEmpty {
            switch name.lowercased() {
            case "arial": candidates = ["Arial", "Helvetica Neue", "Helvetica"]
            case "consolas": candidates = ["Consolas", "Menlo", "SF Mono"]
            case "comicsans", "comicsansms": candidates = ["Comic Sans MS", "Chalkboard SE"]
            case "times", "timesnewroman": candidates = ["Times New Roman", "Times"]
            case "courier", "couriernew": candidates = ["Courier New", "Courier"]
            case "verdana": candidates = ["Verdana"]
            case "tahoma": candidates = ["Tahoma"]
            case "segoeui": candidates = ["SF Pro Text", "Helvetica Neue"]
            case "georgia": candidates = ["Georgia"]
            case "impact": candidates = ["Impact"]
            default: candidates = [name]
            }
        }

        var template: CTFont?
        for candidate in candidates {
            let font = CTFontCreateWithName(candidate as CFString, 1, nil)
            // `CTFontCreateWithName` never fails; it silently substitutes, so
            // compare the family back to know whether the face really exists.
            let family = CTFontCopyFamilyName(font) as String
            if family.compare(candidate, options: .caseInsensitive) == .orderedSame {
                template = font
                break
            }
        }
        if template == nil {
            template = CTFontCreateUIFontForLanguage(.system, 1, nil)
        }
        guard let template else { return nil }
        let metrics = SFNTMetrics.parse(template) ?? SFNTMetrics.coreText(template)
        return LoadedFont(source: nil, template: template,
                          ascentEm: metrics.ascentEm, lineHeightEm: metrics.lineHeightEm)
    }
}

// MARK: - sfnt metrics

/// `head.unitsPerEm` and `hhea.{ascender, descender, lineGap}`, normalised per em.
///
/// CoreText is not asked for these: it reports `OS/2 usWin*` for some faces, and
/// Wallpaper Engine's cached block sizes only reproduce from `hhea`.
private struct SFNTMetrics {
    var ascentEm: Double
    var lineHeightEm: Double

    private static let headTag: UInt32 = 0x68656164   // 'head'
    private static let hheaTag: UInt32 = 0x68686561   // 'hhea'

    /// Parses the tables straight out of the font file bytes.
    static func parse(_ data: Data) -> SFNTMetrics? {
        guard let head = table(headTag, in: data), let hhea = table(hheaTag, in: data) else { return nil }
        return metrics(head: head, hhea: hhea)
    }

    /// Same tables, fetched through CoreText for a face we have no bytes for.
    static func parse(_ font: CTFont) -> SFNTMetrics? {
        let options = CTFontTableOptions(rawValue: 0)
        guard let head = CTFontCopyTable(font, CTFontTableTag(headTag), options) as Data?,
              let hhea = CTFontCopyTable(font, CTFontTableTag(hheaTag), options) as Data? else { return nil }
        return metrics(head: head, hhea: hhea)
    }

    /// Last resort when the tables are missing or nonsense.
    static func coreText(_ font: CTFont) -> SFNTMetrics {
        // The template is built at size 1, so these already are em fractions.
        let ascent = Double(CTFontGetAscent(font))
        let descent = Double(CTFontGetDescent(font))
        let leading = Double(CTFontGetLeading(font))
        let height = ascent + descent + leading
        guard ascent.isFinite, height.isFinite, height > 0 else {
            return SFNTMetrics(ascentEm: 0.8, lineHeightEm: 1.2)
        }
        return SFNTMetrics(ascentEm: ascent, lineHeightEm: height)
    }

    private static func metrics(head: Data, hhea: Data) -> SFNTMetrics? {
        // head: unitsPerEm is a uint16 at offset 18 (two Fixed, two uint32, uint16 flags).
        guard let upem = readUInt16(head, at: 18), upem >= 16, upem <= 16384 else { return nil }
        // hhea: ascender, descender and lineGap are consecutive int16 after the Fixed version.
        guard let ascender = readInt16(hhea, at: 4),
              let descender = readInt16(hhea, at: 6),
              let lineGap = readInt16(hhea, at: 8) else { return nil }
        let units = Double(upem)
        let ascentEm = Double(ascender) / units
        let lineHeightEm = (Double(ascender) - Double(descender) + Double(lineGap)) / units
        guard ascentEm.isFinite, lineHeightEm.isFinite, lineHeightEm > 0, lineHeightEm <= 16 else { return nil }
        return SFNTMetrics(ascentEm: ascentEm, lineHeightEm: lineHeightEm)
    }

    // MARK: sfnt table directory

    /// Walks the sfnt table directory, stepping into the first face of a `ttcf`
    /// collection, and returns the bytes of one table.
    private static func table(_ tag: UInt32, in data: Data) -> Data? {
        guard let magic = readUInt32(data, at: 0) else { return nil }
        var base = 0
        if magic == 0x74746366 {                       // 'ttcf'
            guard let count = readUInt32(data, at: 8), count > 0,
                  let first = readUInt32(data, at: 12) else { return nil }
            base = Int(first)
            guard let inner = readUInt32(data, at: base), isSFNT(inner) else { return nil }
        } else {
            guard isSFNT(magic) else { return nil }
        }

        guard let tableCount = readUInt16(data, at: base + 4), tableCount > 0 else { return nil }
        let directory = base + 12
        for index in 0..<Int(tableCount) {
            let entry = directory + index * 16
            guard let entryTag = readUInt32(data, at: entry) else { return nil }
            guard entryTag == tag else { continue }
            guard let offset = readUInt32(data, at: entry + 8),
                  let length = readUInt32(data, at: entry + 12) else { return nil }
            // A `UInt32` always fits an `Int` on the 64-bit targets this ships to.
            let start = Int(offset), size = Int(length)
            guard size > 0, start >= 0, start <= data.count, data.count - start >= size else { return nil }
            return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + size))
        }
        return nil
    }

    private static func isSFNT(_ magic: UInt32) -> Bool {
        magic == 0x00010000            // TrueType outlines
            || magic == 0x4F54544F     // 'OTTO', CFF outlines
            || magic == 0x74727565     // 'true'
            || magic == 0x74797031     // 'typ1'
    }

    // MARK: Big-endian readers, bounds checked

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, data.count >= offset + 2 else { return nil }
        let base = data.startIndex + offset
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }

    private static func readInt16(_ data: Data, at offset: Int) -> Int16? {
        guard let raw = readUInt16(data, at: offset) else { return nil }
        return Int16(bitPattern: raw)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, data.count >= offset + 4 else { return nil }
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }
}
