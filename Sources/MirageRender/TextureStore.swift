import Foundation
import Metal
import simd
import WEKit

/// A texture bound to a shader sampler slot, plus everything the renderer must
/// know about it: `g_TextureNResolution`, the sampler state, the `TEX<n>FORMAT`
/// combo value and any sprite-sheet animation.
public final class GPUTexture {
    public let name: String
    /// A video texture swaps this for the decoded frame each time the scene advances,
    /// so it is the one property that is not fixed for the texture's lifetime.
    public internal(set) var texture: MTLTexture
    public let samplerKey: SamplerKey
    /// (gpu width, gpu height, mapped/image width, mapped/image height)
    public let resolution: SIMD4<Float>
    public let weFormat: WETextureFormat
    public let source: WETexture?
    public let isRenderTarget: Bool
    /// Set when the texture's pixels come from an embedded video rather than a bitmap.
    var video: VideoTexture?

    /// Pulls the frame for `time` from the backing video, if there is one.
    func advance(to time: Double) {
        guard let video, let frame = video.texture(at: time) else { return }
        texture = frame
    }

    public init(name: String, texture: MTLTexture, samplerKey: SamplerKey, resolution: SIMD4<Float>,
                weFormat: WETextureFormat, source: WETexture?, isRenderTarget: Bool) {
        self.name = name; self.texture = texture; self.samplerKey = samplerKey
        self.resolution = resolution; self.weFormat = weFormat; self.source = source
        self.isRenderTarget = isRenderTarget
    }

    public var isAnimated: Bool { source?.isAnimated ?? false }

    /// UV fraction of the texture actually covered by image content (POT padding).
    public var contentRatio: SIMD2<Float> {
        let w = resolution.x, h = resolution.y
        guard w > 0, h > 0 else { return SIMD2(1, 1) }
        return SIMD2(min(1, resolution.z / w), min(1, resolution.w / h))
    }

    /// `g_TextureNRotation` / `g_TextureNTranslation` for an animated texture at `time`.
    public func spriteTransform(at time: Double) -> (rotation: SIMD4<Float>, translation: SIMD2<Float>)? {
        guard let source, let frame = source.frame(at: time) else { return nil }
        let tw = Float(source.width), th = Float(source.height)
        guard tw > 0, th > 0 else { return nil }
        return (SIMD4(frame.xAxis.x / tw, frame.xAxis.y / th, frame.yAxis.x / tw, frame.yAxis.y / th),
                SIMD2(frame.x / tw, frame.y / th))
    }

    /// Which of the texture's images the current frame comes from (multi-image GIFs).
    public func imageIndex(at time: Double) -> Int { source?.frame(at: time)?.imageIndex ?? 0 }
}

/// Loads and caches the textures of one wallpaper.
public final class TextureStore {
    public let context: RenderContext
    public let locator: AssetLocator
    private var cache: [String: GPUTexture] = [:]
    /// Extra images of multi-image animated textures, keyed by "name#index".
    private var lock = NSLock()
    private var failureSet: Set<String> = []
    private var videoTextureNames: Set<String> = []
    public private(set) var failures: [String] = []
    private var videoBacked: [GPUTexture] = []

    public init(context: RenderContext, locator: AssetLocator) {
        self.context = context
        self.locator = locator
    }

    // MARK: Lookup

    /// `name` is a WE texture name such as `bg`, `util/white`, `workshop/123/foo`.
    public func texture(named name: String) -> GPUTexture? {
        lock.lock()
        if let cached = cache[name] { lock.unlock(); return cached }
        if failureSet.contains(name) { lock.unlock(); return nil }
        lock.unlock()
        let result = load(name)
        lock.lock()
        if let result { cache[name] = result }
        else if failureSet.insert(name).inserted { failures.append(name) }
        lock.unlock()
        return result
    }

    private func load(_ name: String) -> GPUTexture? {
        guard let data = locator.textureData(named: name) else { return nil }
        guard let we = try? WETexture.decode(data) else { return nil }
        if we.isVideo {
            lock.lock(); videoTextureNames.insert(name); lock.unlock()
            return uploadVideo(we, name: name)
        }
        return upload(we, name: name)
    }

    public func isVideoTexture(named name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return videoTextureNames.contains(name)
    }

    // MARK: Fallbacks

    private var solidCache: [UInt32: GPUTexture] = [:]

    /// 1×1 texture of a constant colour, for unbound slots.
    public func solid(_ rgba: SIMD4<UInt8>, name: String) -> GPUTexture? {
        let key = (UInt32(rgba.x) << 24) | (UInt32(rgba.y) << 16) | (UInt32(rgba.z) << 8) | UInt32(rgba.w)
        lock.lock()
        if let t = solidCache[key] { lock.unlock(); return t }
        lock.unlock()
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .managed
        guard let tex = context.device.makeTexture(descriptor: desc) else { return nil }
        var bytes = [rgba.x, rgba.y, rgba.z, rgba.w]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
        tex.label = "mirage.solid.\(name)"
        let gpu = GPUTexture(name: name, texture: tex, samplerKey: SamplerKey(nearest: false, clamp: true, hasMips: false),
                             resolution: SIMD4(1, 1, 1, 1), weFormat: .argb8888, source: nil, isRenderTarget: false)
        lock.lock(); solidCache[key] = gpu; lock.unlock()
        return gpu
    }

    public var white: GPUTexture? { solid(SIMD4(255, 255, 255, 255), name: "util/white") }
    public var black: GPUTexture? { solid(SIMD4(0, 0, 0, 255), name: "util/black") }
    public var transparent: GPUTexture? { solid(SIMD4(0, 0, 0, 0), name: "util/transparent") }

    /// A texture for a sampler annotation's `default` value, falling back to white.
    public func defaultTexture(_ name: String?) -> GPUTexture? {
        guard let name, !name.isEmpty, !name.isRenderTargetName else { return white }
        return texture(named: name) ?? white
    }

    // MARK: Upload

    /// A `TEXB0004` texture carries an MP4 in place of pixels. It is decoded on a
    /// background queue and the current frame is swapped in as the scene advances.
    private func uploadVideo(_ we: WETexture, name: String) -> GPUTexture? {
        guard let data = we.videoData,
              let video = VideoTexture(data: data, device: context.device, label: "video.\(name)") else { return nil }
        // Start with a 1x1 placeholder so the first frames before the decoder catches up
        // draw nothing rather than garbage.
        guard let placeholder = solid(SIMD4(0, 0, 0, 0), name: "video.placeholder")?.texture else { return nil }
        let size = video.size
        let gpu = GPUTexture(name: name, texture: placeholder,
                             samplerKey: SamplerKey(nearest: false, clamp: true, hasMips: false),
                             resolution: SIMD4(size.x, size.y, size.x, size.y),
                             weFormat: .argb8888, source: nil, isRenderTarget: false)
        gpu.video = video
        lock.lock(); videoBacked.append(gpu); lock.unlock()
        return gpu
    }

    /// Every texture whose pixels come from a video, so the renderer can advance them.
    public func advanceVideoTextures(to time: Double) {
        lock.lock()
        let backed = videoBacked
        lock.unlock()
        for texture in backed { texture.advance(to: time) }
    }

    public func upload(_ we: WETexture, name: String) -> GPUTexture? {
        guard !we.isVideo else { return nil }   // handled by the video path
        let images = we.images
        guard let first = images.first, let mip0 = first.first else { return nil }
        guard (1...16_384).contains(mip0.width), (1...16_384).contains(mip0.height) else { return nil }

        var layout = we.layout
        var mips = first
        var pixelFormat: MTLPixelFormat

        func cpuDecode() -> Bool {
            guard let rgba = BlockCompression.decodeToRGBA8(mip0.data, width: mip0.width, height: mip0.height, layout: layout) else { return false }
            mips = [WEMipLevel(width: mip0.width, height: mip0.height, data: rgba)]
            layout = .rgba8
            return true
        }

        switch layout {
        case .rgba8: pixelFormat = .rgba8Unorm
        case .rg8: pixelFormat = .rg8Unorm
        case .r8: pixelFormat = .r8Unorm
        case .bc1, .bc2, .bc3, .bc7:
            if context.supportsBC {
                switch layout {
                case .bc1: pixelFormat = .bc1_rgba
                case .bc2: pixelFormat = .bc2_rgba
                case .bc3: pixelFormat = .bc3_rgba
                default: pixelFormat = .bc7_rgbaUnorm
                }
            } else {
                guard cpuDecode() else { return nil }
                pixelFormat = .rgba8Unorm
            }
        }

        // Only keep a mip chain that actually halves; some workshop textures lie.
        var levels = 1
        var maximumLevels = 1
        var maximumDimension = max(mips[0].width, mips[0].height)
        while maximumDimension > 1 { maximumDimension >>= 1; maximumLevels += 1 }
        for i in 1..<min(mips.count, maximumLevels) {
            let expectedW = max(1, mips[0].width >> i), expectedH = max(1, mips[0].height >> i)
            guard mips[i].width == expectedW, mips[i].height == expectedH else { break }
            levels = i + 1
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: mips[0].width,
                                                            height: mips[0].height, mipmapped: levels > 1)
        desc.mipmapLevelCount = levels
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: desc) else { return nil }
        texture.label = "we.\(name)"

        guard uploadLevels(mips, levels: levels, layout: layout, into: texture) else { return nil }

        let clamp = we.flags.contains(.clampUVs)
        let sampler = SamplerKey(nearest: we.flags.contains(.noInterpolation),
                                 clamp: clamp,
                                 border: !clamp && we.flags.contains(.clampUVsBorder),
                                 hasMips: levels > 1)
        return GPUTexture(name: name, texture: texture, samplerKey: sampler, resolution: we.resolution,
                          weFormat: we.format, source: we, isRenderTarget: false)
    }

    /// Staging upload: private-storage textures need a blit from a shared buffer.
    private func uploadLevels(_ mips: [WEMipLevel], levels: Int, layout: WEPixelLayout, into texture: MTLTexture) -> Bool {
        var staging: [(buffer: MTLBuffer, bytesPerRow: Int, byteCount: Int, mip: WEMipLevel)] = []
        for level in 0..<levels {
            let mip = mips[level]
            guard let bytesPerRow = layout.checkedBytesPerRow(width: mip.width),
                  let expected = layout.checkedByteCount(width: mip.width, height: mip.height),
                  expected <= WEPixelLayout.maximumAllocationByteCount,
                  mip.data.count >= expected else { return false }
            guard let buffer = mip.data.withUnsafeBytes({ raw -> MTLBuffer? in
                guard let base = raw.baseAddress else { return nil }
                return context.device.makeBuffer(bytes: base, length: expected, options: .storageModeShared)
            }) else { return false }
            staging.append((buffer, bytesPerRow, expected, mip))
        }
        guard staging.count == levels,
              let command = context.commandQueue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return false }
        for (level, item) in staging.enumerated() {
            blit.copy(from: item.buffer, sourceOffset: 0, sourceBytesPerRow: item.bytesPerRow,
                      sourceBytesPerImage: item.byteCount,
                      sourceSize: MTLSize(width: item.mip.width, height: item.mip.height, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: level,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        command.commit()
        return true
    }
}
