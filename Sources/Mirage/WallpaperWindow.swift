import AppKit
import MetalKit
import AVFoundation
import simd
import WEKit
import MirageRender

/// A borderless window pinned behind the desktop icons on one screen.
///
/// `CGWindowLevelForKey(.desktopWindow)` puts it above the system wallpaper but
/// below the icons; `.canJoinAllSpaces` + `.stationary` keep it in place while
/// Spaces and Mission Control move around it.
final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        displaysWhenScreenProfileChanges = true
        // Desktop-level windows are not "visible" to the ordering the app uses for
        // its own windows, so keep it out of the window menu and cycling.
        isExcludedFromWindowsMenu = true
        setFrame(screen.frame, display: true)
    }

    func place(on screen: NSScreen) {
        setFrame(screen.frame, display: true)
        orderBack(nil)
    }
}

/// Draws a Wallpaper Engine *scene* wallpaper with Metal.
final class SceneWallpaperView: MTKView {
    private let renderer: SceneRenderer
    private var startTime = CACurrentMediaTime()
    private var accumulated: Double = 0
    private var pausedAt: Double?
    private var hasDrawnFrame = false
    private var pendingPause = false
    /// The scene's `sound` objects. Nil when it has none, which is most of them.
    private var sound: WallpaperSoundPlayer?

    init(renderer: SceneRenderer, context: RenderContext, muted: Bool, volume: Float) {
        self.renderer = renderer
        super.init(frame: .zero, device: context.device)
        buildSound(muted: muted, volume: volume)
        colorPixelFormat = .rgba8Unorm
        framebufferOnly = true
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 30
        layer?.isOpaque = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    /// Builds the sound player from the scene's `sound` objects.
    ///
    /// `WESceneObject` keeps the timing fields in `raw`, since only the volume
    /// is ever a binding, and the volume is resolved through the property store
    /// so a wallpaper whose volume is a user property starts at the right level.
    private func buildSound(muted: Bool, volume: Float) {
        let objects = renderer.scene.objects.filter { $0.kind == .sound }
        guard !objects.isEmpty else { return }
        let player = WallpaperSoundPlayer(locator: renderer.locator,
                                          workshopId: renderer.project.workshopId)
        for object in objects {
            player.add(paths: object.sounds,
                       mode: object.playbackMode ?? "loop",
                       volume: object.volume.resolveFloat(renderer.store, default: 1),
                       minTime: object.raw["mintime"].double ?? 0,
                       maxTime: object.raw["maxtime"].double ?? 0,
                       startSilent: object.raw["startsilent"].bool ?? false)
        }
        player.setVolume(volume, muted: muted)
        player.start()
        sound = player
    }

    /// Releases the audio players. The view is torn down with the wallpaper, and
    /// nothing else stops the sound.
    func stop() {
        sound?.stop()
        sound = nil
    }

    func setMuted(_ muted: Bool, volume: Float) {
        sound?.setVolume(volume, muted: muted)
    }

    var fpsCap: Int {
        get { preferredFramesPerSecond }
        set { preferredFramesPerSecond = max(1, newValue) }
    }

    /// Freezes animation without tearing down GPU resources.
    ///
    /// A pause request that arrives before the first frame is deferred: pausing an
    /// MTKView that has never drawn leaves a black window, which is what the user
    /// would see the moment the covering window moves away.
    func setPaused(_ paused: Bool) {
        guard hasDrawnFrame || !paused else { pendingPause = true; return }
        guard paused != isPaused else { return }
        if paused {
            accumulated = elapsed
            pausedAt = CACurrentMediaTime()
        } else {
            startTime = CACurrentMediaTime()
        }
        isPaused = paused
        sound?.setPaused(paused)
    }

    private var elapsed: Double {
        isPaused ? accumulated : accumulated + (CACurrentMediaTime() - startTime)
    }

    /// Normalised cursor position for `g_PointerPosition` / parallax (y grows down).
    func updatePointer(_ point: NSPoint, in frame: NSRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let x = (point.x - frame.minX) / frame.width
        let y = 1 - (point.y - frame.minY) / frame.height
        guard x.isFinite, y.isFinite else { return }
        renderer.pointerPosition = SIMD2(Float(min(1, max(0, x))), Float(min(1, max(0, y))))
    }

    override func draw(_ dirtyRect: NSRect) {
        if let window { updatePointer(NSEvent.mouseLocation, in: window.frame) }
        guard let drawable = currentDrawable,
              let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return }
        let time = elapsed
        sound?.update(time: time)
        renderer.render(into: drawable.texture, time: time, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        if !hasDrawnFrame {
            hasDrawnFrame = true
            if pendingPause {
                pendingPause = false
                setPaused(true)
            }
        }
    }
}

/// Plays a video wallpaper, gaplessly looped.
final class VideoWallpaperView: NSView {
    private let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private let playerLayer: AVPlayerLayer

    init(url: URL, muted: Bool, volume: Float) {
        player = AVQueuePlayer()
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)

        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = muted
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = false
        if #available(macOS 12.0, *) { player.preventsDisplaySleepDuringVideoPlayback = false }
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func setPaused(_ paused: Bool) {
        if paused { player.pause() } else { player.play() }
    }

    func setMuted(_ muted: Bool, volume: Float) {
        player.isMuted = muted
        player.volume = volume
    }

    func stop() {
        player.pause()
        player.removeAllItems()
        looper = nil
    }
}

/// A still image or animated GIF wallpaper.
final class ImageWallpaperView: NSView {
    private let imageView = NSImageView(frame: .zero)

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageView.image = NSImage(contentsOf: url)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        imageView.frame = bounds
    }

    /// Stops an animated GIF while the wallpaper is paused.
    func setPaused(_ paused: Bool) {
        imageView.animates = !paused
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}
