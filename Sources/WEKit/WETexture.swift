import Foundation
import Compression
import CoreGraphics
import ImageIO
import Accelerate
import simd

/// Pixel format enum stored in the TEX header.
public enum WETextureFormat: UInt32 {
    case argb8888 = 0
    case rgb888 = 1
    case rgb565 = 2
    case dxt5 = 4
    case dxt3 = 6
    case dxt1 = 7
    case rg88 = 8
    case r8 = 9
    case rg1616f = 10
    case r16f = 11
    case bc7 = 12
    case rgba1010102 = 13
    case rgba16161616f = 14
    case rgb161616f = 15
    case unknown = 0xFFFF_FFFF
}

public struct WETextureFlags: OptionSet, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let noInterpolation = WETextureFlags(rawValue: 1)
    public static let clampUVs = WETextureFlags(rawValue: 2)
    public static let isGif = WETextureFlags(rawValue: 4)
    public static let clampUVsBorder = WETextureFlags(rawValue: 8)
    public static let video = WETextureFlags(rawValue: 32)
    public static let alphaChannelPriority = WETextureFlags(rawValue: 0x80000)
}

/// Layout of the bytes stored in a decoded mip level.
public enum WEPixelLayout: Hashable {
    case rgba8        // 4 bytes per pixel, straight (non-premultiplied) alpha
    case rg8          // 2 bytes per pixel
    case r8           // 1 byte per pixel
    case bc1          // DXT1, 8 bytes per 4x4 block
    case bc2          // DXT3, 16 bytes per 4x4 block
    case bc3          // DXT5, 16 bytes per 4x4 block
    case bc7          // 16 bytes per 4x4 block

    /// Keeps hostile dimensions from requesting impractically large temporary buffers.
    public static let maximumAllocationByteCount = 256 * 1024 * 1024

    public var isBlockCompressed: Bool {
        switch self {
        case .bc1, .bc2, .bc3, .bc7: return true
        default: return false
        }
    }

    public var bytesPerPixel: Int {
        switch self {
        case .rgba8: return 4
        case .rg8: return 2
        case .r8: return 1
        default: return 0
        }
    }

    public var bytesPerBlock: Int {
        switch self {
        case .bc1: return 8
        case .bc2, .bc3, .bc7: return 16
        default: return 0
        }
    }

    /// Number of bytes a `width × height` image occupies in this layout.
    public func byteCount(width: Int, height: Int) -> Int {
        checkedByteCount(width: width, height: height) ?? 0
    }

    public func checkedByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        if isBlockCompressed {
            let bw = (width - 1) / 4 + 1, bh = (height - 1) / 4 + 1
            let (blocks, overflow1) = bw.multipliedReportingOverflow(by: bh)
            let (bytes, overflow2) = blocks.multipliedReportingOverflow(by: bytesPerBlock)
            return overflow1 || overflow2 ? nil : bytes
        }
        let (pixels, overflow1) = width.multipliedReportingOverflow(by: height)
        let (bytes, overflow2) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        return overflow1 || overflow2 ? nil : bytes
    }

    /// Bytes per row as expected by Metal's `replace(region:...)`.
    public func bytesPerRow(width: Int) -> Int {
        checkedBytesPerRow(width: width) ?? 0
    }

    public func checkedBytesPerRow(width: Int) -> Int? {
        guard width > 0 else { return nil }
        let units = isBlockCompressed ? (width - 1) / 4 + 1 : width
        let bytes = isBlockCompressed ? bytesPerBlock : bytesPerPixel
        let (result, overflow) = units.multipliedReportingOverflow(by: bytes)
        return overflow ? nil : result
    }
}

public struct WEMipLevel {
    public let width: Int
    public let height: Int
    public let data: Data
    public init(width: Int, height: Int, data: Data) {
        self.width = width; self.height = height; self.data = data
    }
}

/// One frame of an animated (sprite sheet) texture. Coordinates are pixels in
/// the mip-0 image; `xAxis`/`yAxis` are the frame's axis vectors (rotated
/// frames have e.g. `xAxis = (0, h)`).
public struct WESpriteFrame {
    public let imageIndex: Int
    public let frameTime: Float
    public let x: Float
    public let y: Float
    public let xAxis: SIMD2<Float>
    public let yAxis: SIMD2<Float>
    public var width: Float { simd_length(xAxis) }
    public var height: Float { simd_length(yAxis) }
}

public enum WETextureError: Error, CustomStringConvertible {
    case truncated
    case badMagic(String)
    case unsupportedFormat(UInt32)
    case unsupportedContainer(String)
    case decompressionFailed
    case imageDecodeFailed
    case invalidDimensions(Int, Int)
    case allocationTooLarge(Int)
    case payloadTooSmall(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .truncated: return "texture data is truncated"
        case .badMagic(let m): return "not a Wallpaper Engine texture (\(m))"
        case .unsupportedFormat(let f): return "unsupported texture format \(f)"
        case .unsupportedContainer(let c): return "unsupported texture container \(c)"
        case .decompressionFailed: return "LZ4 decompression failed"
        case .imageDecodeFailed: return "embedded image could not be decoded"
        case .invalidDimensions(let w, let h): return "invalid texture dimensions \(w)×\(h)"
        case .allocationTooLarge(let count): return "texture allocation is too large (\(count) bytes)"
        case .payloadTooSmall(let e, let a): return "texture payload too small (expected \(e), got \(a))"
        }
    }
}

/// A decoded Wallpaper Engine `.tex` texture.
public final class WETexture {
    public let format: WETextureFormat
    public let flags: WETextureFlags
    /// Storage size from the header (usually power-of-two padded).
    public let headerTextureWidth: Int
    public let headerTextureHeight: Int
    /// Real ("mapped") image size from the header.
    public let imageWidth: Int
    public let imageHeight: Int
    public let containerVersion: String
    public let freeImageFormat: Int32
    public let layout: WEPixelLayout
    /// `images[imageIndex][mipLevel]`. Multi-image textures are old-style GIFs.
    public let images: [[WEMipLevel]]
    public let frames: [WESpriteFrame]
    /// Logical size of one animation frame (TEXS0003) if animated.
    public let spriteWidth: Int?
    public let spriteHeight: Int?
    /// Raw MP4 bytes for video textures.
    public let videoData: Data?

    public var isAnimated: Bool { !frames.isEmpty }
    public var isVideo: Bool { videoData != nil }
    public var mip0: WEMipLevel { images[0][0] }
    /// Actual GPU texture size (decoded mip 0).
    public var width: Int { images.first?.first?.width ?? headerTextureWidth }
    public var height: Int { images.first?.first?.height ?? headerTextureHeight }
    public var mipCount: Int { images.first?.count ?? 0 }
    public var animationDuration: Float { frames.reduce(0) { $0 + $1.frameTime } }

    /// `g_TextureNResolution`: (texture w, texture h, mapped w, mapped h).
    public var resolution: SIMD4<Float> {
        if isAnimated, let sw = spriteWidth, let sh = spriteHeight {
            return SIMD4(Float(width), Float(height), Float(sw), Float(sh))
        }
        return SIMD4(Float(width), Float(height), Float(imageWidth), Float(imageHeight))
    }

    init(format: WETextureFormat, flags: WETextureFlags, headerTextureWidth: Int, headerTextureHeight: Int,
         imageWidth: Int, imageHeight: Int, containerVersion: String, freeImageFormat: Int32,
         layout: WEPixelLayout, images: [[WEMipLevel]], frames: [WESpriteFrame],
         spriteWidth: Int?, spriteHeight: Int?, videoData: Data?) {
        self.format = format; self.flags = flags
        self.headerTextureWidth = headerTextureWidth; self.headerTextureHeight = headerTextureHeight
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.containerVersion = containerVersion; self.freeImageFormat = freeImageFormat
        self.layout = layout; self.images = images; self.frames = frames
        self.spriteWidth = spriteWidth; self.spriteHeight = spriteHeight; self.videoData = videoData
    }

    /// Frame active at `time` (seconds), looping.
    public func frame(at time: Double) -> WESpriteFrame? {
        guard !frames.isEmpty else { return nil }
        let total = Double(animationDuration)
        guard total > 0 else { return frames[0] }
        var t = time.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }
        for f in frames {
            t -= Double(f.frameTime)
            if t <= 0 { return f }
        }
        return frames[frames.count - 1]
    }
}

// MARK: - Decoding

private struct ByteReader {
    private static let maximumStringByteCount = 1024 * 1024
    let data: Data
    var cursor: Int = 0
    init(_ data: Data) { self.data = data }

    mutating func u32() throws -> UInt32 {
        guard 4 <= data.count - cursor else { throw WETextureError.truncated }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
        cursor += 4
        return UInt32(littleEndian: v)
    }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, n <= data.count - cursor else { throw WETextureError.truncated }
        let d = data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + cursor + n))
        cursor += n
        return d
    }
    /// Fixed-size NUL-terminated string field.
    mutating func cString(_ n: Int) throws -> String {
        let d = try bytes(n)
        let end = d.firstIndex(of: 0) ?? d.endIndex
        return String(decoding: d[d.startIndex..<end], as: UTF8.self)
    }
    mutating func cStringUnbounded() throws -> String {
        let count = min(data.count - cursor, ByteReader.maximumStringByteCount + 1)
        let start = data.startIndex + cursor
        let end = start + count
        guard let terminator = data[start..<end].firstIndex(of: 0), terminator - start <= ByteReader.maximumStringByteCount else {
            throw WETextureError.truncated
        }
        cursor += terminator - start + 1
        return String(decoding: data[start..<terminator], as: UTF8.self)
    }
    var remaining: Int { data.count - cursor }
}

public extension WETexture {
    static func decode(_ data: Data) throws -> WETexture {
        var r = ByteReader(data)
        let magic = try r.cString(9)
        guard magic.hasPrefix("TEXV") else { throw WETextureError.badMagic(magic) }
        _ = try r.cString(9) // "TEXI0001"
        let formatRaw = try r.u32()
        let flags = WETextureFlags(rawValue: try r.u32())
        let texW = Int(try r.u32()), texH = Int(try r.u32())
        let imgW = Int(try r.u32()), imgH = Int(try r.u32())
        _ = try r.u32() // unknown
        let container = try r.cString(9)
        guard container.hasPrefix("TEXB") else { throw WETextureError.unsupportedContainer(container) }
        let imageCount = Int(try r.u32())
        var fif: Int32 = -1
        var extra: UInt32 = 0
        if container == "TEXB0003" || container >= "TEXB0004" { fif = try r.i32() }
        if container >= "TEXB0004" { extra = try r.u32() }
        let hasCompressionFields = container != "TEXB0001"
        guard imageCount > 0, imageCount <= 16_384, imageCount <= r.remaining / 4 else {
            throw WETextureError.truncated
        }

        struct RawMip { let w: Int; let h: Int; let payload: Data }
        var rawImages: [[RawMip]] = []
        var totalPayloadByteCount = 0
        for _ in 0..<imageCount {
            let mipCount = Int(try r.u32())
            let minimumMipBytes = hasCompressionFields ? 20 : 12
            guard mipCount > 0, mipCount <= 32, mipCount <= r.remaining / minimumMipBytes else {
                throw WETextureError.truncated
            }
            var mips: [RawMip] = []
            for _ in 0..<mipCount {
                if container >= "TEXB0004" && extra == 1 {
                    _ = try r.u32(); _ = try r.u32(); _ = try r.cStringUnbounded(); _ = try r.u32()
                }
                let mw = Int(try r.u32()), mh = Int(try r.u32())
                guard mw > 0, mh > 0 else { throw WETextureError.invalidDimensions(mw, mh) }
                var compression: UInt32 = 0
                var uncompressedSize = 0
                if hasCompressionFields {
                    compression = try r.u32()
                    uncompressedSize = Int(try r.i32())
                }
                guard compression == 0 || compression == 1 else { throw WETextureError.decompressionFailed }
                let size = Int(try r.i32())
                let storedSize = compression == 1 ? uncompressedSize : size
                guard size >= 0, size <= WEPixelLayout.maximumAllocationByteCount,
                      storedSize > 0, storedSize <= WEPixelLayout.maximumAllocationByteCount,
                      totalPayloadByteCount <= WEPixelLayout.maximumAllocationByteCount - storedSize else {
                    throw WETextureError.allocationTooLarge(max(size, storedSize))
                }
                var payload = try r.bytes(size)
                if compression == 1 {
                    payload = try lz4DecompressRaw(payload, expectedSize: uncompressedSize)
                }
                totalPayloadByteCount += storedSize
                mips.append(RawMip(w: mw, h: mh, payload: payload))
            }
            rawImages.append(mips)
        }

        // Sprite sheet / animation frames.
        var frames: [WESpriteFrame] = []
        var spriteW: Int? = nil, spriteH: Int? = nil
        if flags.contains(.isGif) && r.remaining >= 13 {
            let smagic = try r.cString(9)
            let frameCount = Int(try r.u32())
            if smagic == "TEXS0003" {
                let w = Int(try r.u32()), h = Int(try r.u32())
                if w > 0, h > 0 { spriteW = w; spriteH = h }
            }
            guard frameCount <= 65_536, frameCount <= r.remaining / 32 else { throw WETextureError.truncated }
            for _ in 0..<frameCount {
                if smagic == "TEXS0001" {
                    let idx = Int(try r.u32()); let ft = try r.f32()
                    let x = Float(try r.u32()), y = Float(try r.u32())
                    let w1 = Float(try r.u32()); _ = try r.u32(); _ = try r.u32()
                    let h1 = Float(try r.u32())
                    guard ft.isFinite, ft >= 0 else { throw WETextureError.truncated }
                    frames.append(WESpriteFrame(imageIndex: idx, frameTime: ft, x: x, y: y,
                                                xAxis: SIMD2(w1, 0), yAxis: SIMD2(0, h1)))
                } else {
                    let idx = Int(try r.u32()); let ft = try r.f32()
                    let x = try r.f32(), y = try r.f32()
                    let w1 = try r.f32(), w2 = try r.f32(), h2 = try r.f32(), h1 = try r.f32()
                    guard ft >= 0, [ft, x, y, w1, w2, h1, h2].allSatisfy(\.isFinite) else {
                        throw WETextureError.truncated
                    }
                    frames.append(WESpriteFrame(imageIndex: idx, frameTime: ft, x: x, y: y,
                                                xAxis: SIMD2(w1, w2), yAxis: SIMD2(h2, h1)))
                }
            }
            if spriteW == nil, let f0 = frames.first {
                if let w = Int(exactly: f0.width.rounded()), let h = Int(exactly: f0.height.rounded()), w > 0, h > 0 {
                    spriteW = w; spriteH = h
                }
            }
        }

        let format = WETextureFormat(rawValue: formatRaw) ?? .unknown

        // Video texture: the payload is an MP4 container.
        if let first = rawImages.first?.first {
            let p = first.payload
            let looksLikeMP4 = p.count > 12 && p[p.startIndex + 4] == 0x66 && p[p.startIndex + 5] == 0x74 && p[p.startIndex + 6] == 0x79 && p[p.startIndex + 7] == 0x70
            if flags.contains(.video) || looksLikeMP4 {
                let mip = WEMipLevel(width: first.w, height: first.h, data: Data())
                return WETexture(format: format, flags: flags, headerTextureWidth: texW, headerTextureHeight: texH,
                                 imageWidth: imgW, imageHeight: imgH, containerVersion: container, freeImageFormat: fif,
                                 layout: .rgba8, images: [[mip]], frames: [], spriteWidth: nil, spriteHeight: nil,
                                 videoData: p)
            }
        }

        var layout: WEPixelLayout
        var images: [[WEMipLevel]] = []
        var decodedImageByteCount = 0
        func accountDecodedImage(_ byteCount: Int) throws {
            guard byteCount > 0, byteCount <= WEPixelLayout.maximumAllocationByteCount,
                  decodedImageByteCount <= WEPixelLayout.maximumAllocationByteCount - byteCount else {
                throw WETextureError.allocationTooLarge(byteCount)
            }
            decodedImageByteCount += byteCount
        }
        if fif != -1 {
            // Payload is an image file (PNG/JPEG/...).
            layout = .rgba8
            for mips in rawImages {
                var decoded: [WEMipLevel] = []
                for m in mips {
                    guard let (w, h, pixels) = decodeImageFile(m.payload) else { throw WETextureError.imageDecodeFailed }
                    try accountDecodedImage(pixels.count)
                    decoded.append(WEMipLevel(width: w, height: h, data: pixels))
                }
                images.append(decoded)
            }
        } else {
            switch format {
            case .argb8888: layout = .rgba8
            case .rg88: layout = .rg8
            case .r8: layout = .r8
            case .dxt5: layout = .bc3
            case .dxt3: layout = .bc2
            case .dxt1: layout = .bc1
            case .bc7: layout = .bc7
            case .rgb888:
                // Expand to RGBA8.
                layout = .rgba8
                for mips in rawImages {
                    images.append(try mips.map { m in
                        let pixels = try expandRGB(m.payload, width: m.w, height: m.h)
                        try accountDecodedImage(pixels.count)
                        return WEMipLevel(width: m.w, height: m.h, data: pixels)
                    })
                }
            default:
                throw WETextureError.unsupportedFormat(formatRaw)
            }
            if images.isEmpty {
                for mips in rawImages {
                    var decoded: [WEMipLevel] = []
                    for m in mips {
                        guard let expected = layout.checkedByteCount(width: m.w, height: m.h) else {
                            throw WETextureError.invalidDimensions(m.w, m.h)
                        }
                        guard expected <= WEPixelLayout.maximumAllocationByteCount else {
                            throw WETextureError.allocationTooLarge(expected)
                        }
                        guard m.payload.count >= expected else {
                            throw WETextureError.payloadTooSmall(expected: expected, actual: m.payload.count)
                        }
                        decoded.append(WEMipLevel(width: m.w, height: m.h, data: m.payload))
                    }
                    images.append(decoded)
                }
            }
        }
        guard let firstImage = images.first, !firstImage.isEmpty else { throw WETextureError.truncated }

        return WETexture(format: format, flags: flags, headerTextureWidth: texW, headerTextureHeight: texH,
                         imageWidth: imgW, imageHeight: imgH, containerVersion: container, freeImageFormat: fif,
                         layout: layout, images: images, frames: frames, spriteWidth: spriteW, spriteHeight: spriteH,
                         videoData: nil)
    }

    /// Decode a raw LZ4 block (no frame header).
    static func lz4DecompressRaw(_ src: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { throw WETextureError.decompressionFailed }
        guard expectedSize <= WEPixelLayout.maximumAllocationByteCount else {
            throw WETextureError.allocationTooLarge(expectedSize)
        }
        var dst = Data(count: expectedSize)
        let produced = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                guard let dp = d.baseAddress, let sp = s.baseAddress else { return 0 }
                return compression_decode_buffer(dp.assumingMemoryBound(to: UInt8.self), expectedSize,
                                                 sp.assumingMemoryBound(to: UInt8.self), src.count,
                                                 nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard produced == expectedSize else { throw WETextureError.decompressionFailed }
        return dst
    }

    private static func expandRGB(_ src: Data, width: Int, height: Int) throws -> Data {
        guard let outputCount = WEPixelLayout.rgba8.checkedByteCount(width: width, height: height) else {
            throw WETextureError.invalidDimensions(width, height)
        }
        guard outputCount <= WEPixelLayout.maximumAllocationByteCount else {
            throw WETextureError.allocationTooLarge(outputCount)
        }
        let pixelCount = outputCount / 4
        let (inputCount, overflow) = pixelCount.multipliedReportingOverflow(by: 3)
        guard !overflow, src.count >= inputCount else {
            throw WETextureError.payloadTooSmall(expected: overflow ? Int.max : inputCount, actual: src.count)
        }
        var out = Data(count: outputCount)
        out.withUnsafeMutableBytes { o in
            src.withUnsafeBytes { s in
                let sp = s.bindMemory(to: UInt8.self), op = o.bindMemory(to: UInt8.self)
                for i in 0..<pixelCount {
                    op[i * 4] = sp[i * 3]; op[i * 4 + 1] = sp[i * 3 + 1]; op[i * 4 + 2] = sp[i * 3 + 2]; op[i * 4 + 3] = 255
                }
            }
        }
        return out
    }

    /// Decode an image file (PNG/JPEG/…) to straight-alpha RGBA8.
    static func decodeImageFile(_ data: Data) -> (Int, Int, Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              let byteCount = WEPixelLayout.rgba8.checkedByteCount(width: width, height: height),
              byteCount <= WEPixelLayout.maximumAllocationByteCount,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return rgba8(from: image)
    }

    static func rgba8(from image: CGImage) -> (Int, Int, Data)? {
        let w = image.width, h = image.height
        guard let outputCount = WEPixelLayout.rgba8.checkedByteCount(width: w, height: h),
              outputCount <= WEPixelLayout.maximumAllocationByteCount else { return nil }
        let rowByteCount = outputCount / h
        // Fast path: already 8-bit RGBA/RGBX, byte order R,G,B,A.
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        let alpha = image.alphaInfo
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           byteOrder == [] || byteOrder == .byteOrder32Big,
           alpha == .last || alpha == .noneSkipLast || alpha == .premultipliedLast,
           let provider = image.dataProvider, let cfData = provider.data {
            let src = cfData as Data
            let bpr = image.bytesPerRow
            let (lastRowOffset, rowOverflow) = bpr.multipliedReportingOverflow(by: h - 1)
            guard bpr >= rowByteCount, !rowOverflow, lastRowOffset <= src.count,
                  rowByteCount <= src.count - lastRowOffset else { return nil }
            var out = Data(count: outputCount)
            out.withUnsafeMutableBytes { o in
                src.withUnsafeBytes { s in
                    let sp = s.bindMemory(to: UInt8.self), op = o.bindMemory(to: UInt8.self)
                    for y in 0..<h {
                        let srcRow = y * bpr
                        for x in 0..<rowByteCount { op[y * rowByteCount + x] = sp[srcRow + x] }
                    }
                }
            }
            if alpha == .noneSkipLast {
                out.withUnsafeMutableBytes { o in
                    let op = o.bindMemory(to: UInt8.self)
                    var i = 3
                    while i < op.count { op[i] = 255; i += 4 }
                }
            } else if alpha == .premultipliedLast {
                unpremultiply(&out, width: w, height: h)
            }
            return (w, h, out)
        }
        // General path: draw through CoreGraphics (premultiplied) then unpremultiply.
        var out = Data(count: outputCount)
        let ok: Bool = out.withUnsafeMutableBytes { o in
            guard let ctx = CGContext(data: o.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowByteCount,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        if image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst {
            unpremultiply(&out, width: w, height: h)
        }
        // CoreGraphics draws bottom-up relative to the buffer origin; the context has row 0 at the top
        // of the image because CGContext(data:) uses a flipped coordinate system when drawing CGImages.
        return (w, h, out)
    }

    static func unpremultiply(_ data: inout Data, width: Int, height: Int) {
        data.withUnsafeMutableBytes { o in
            guard let base = o.baseAddress else { return }
            var buffer = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            _ = vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        }
    }
}
