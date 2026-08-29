import Foundation
import Metal
import simd
import WEKit

/// Named colour render targets (`_rt_*`) with their sizes, shared for the
/// lifetime of a wallpaper. Wallpaper Engine addresses framebuffers by name, so
/// this is a name → texture map rather than a transient pool.
public final class RenderTargetPool {
    public let context: RenderContext
    public let pixelFormat: MTLPixelFormat

    private var targets: [String: MTLTexture] = [:]
    private var cleared: Set<String> = []
    private var wrappers: [String: GPUTexture] = [:]

    public init(context: RenderContext, pixelFormat: MTLPixelFormat = .rgba8Unorm) {
        self.context = context
        self.pixelFormat = pixelFormat
    }

    public func existing(_ name: String) -> MTLTexture? { targets[name] }

    /// Returns the named target, creating (or re-creating on size change) as needed.
    @discardableResult
    public func target(_ name: String, width: Int, height: Int, mipmapped: Bool = false) -> MTLTexture? {
        let w = max(1, width), h = max(1, height)
        guard w <= 16_384, h <= 16_384 else { return nil }
        if let existing = targets[name], existing.width == w, existing.height == h,
           (existing.mipmapLevelCount > 1) == mipmapped {
            return existing
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: mipmapped)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: desc) else { return nil }
        texture.label = name
        targets[name] = texture
        wrappers.removeValue(forKey: name)
        cleared.remove(name)
        return texture
    }

    /// True the first time a target is used in a frame, so callers know to clear it.
    public func takeNeedsClear(_ name: String) -> Bool {
        if cleared.contains(name) { return false }
        cleared.insert(name)
        return true
    }

    public func beginFrame() { cleared.removeAll(keepingCapacity: true) }

    public func removeAll() {
        targets.removeAll()
        cleared.removeAll()
        wrappers.removeAll()
    }

    public var allNames: [String] { Array(targets.keys).sorted() }

    /// Wraps a target as a bindable `GPUTexture`.
    public func gpuTexture(_ name: String) -> GPUTexture? {
        if let wrapper = wrappers[name] { return wrapper }
        guard let texture = targets[name] else { return nil }
        let wrapper = GPUTexture(name: name, texture: texture,
                                 samplerKey: SamplerKey(nearest: false, clamp: true, hasMips: texture.mipmapLevelCount > 1),
                                 resolution: SIMD4(Float(texture.width), Float(texture.height), Float(texture.width), Float(texture.height)),
                                 weFormat: .argb8888, source: nil, isRenderTarget: true)
        wrappers[name] = wrapper
        return wrapper
    }
}

public extension MTLRenderPassDescriptor {
    /// A single-colour-attachment pass.
    static func color(_ texture: MTLTexture, clear: SIMD4<Double>?) -> MTLRenderPassDescriptor {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = texture
        if let clear {
            desc.colorAttachments[0].loadAction = .clear
            desc.colorAttachments[0].clearColor = MTLClearColor(red: clear.x, green: clear.y, blue: clear.z, alpha: clear.w)
        } else {
            desc.colorAttachments[0].loadAction = .load
        }
        desc.colorAttachments[0].storeAction = .store
        return desc
    }
}
