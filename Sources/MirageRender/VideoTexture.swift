import AVFoundation
import CoreVideo
import Foundation
import Metal
import simd
import WEKit

/// Decodes a video into Metal textures, looping, driven by the render clock.
///
/// Two things feed this: a `TEXB0004` `.tex` whose payload is an MP4 (see
/// `WETexture.videoData`) and plain video files used as wallpapers. Both end up
/// as an `MTLTexture` the renderer binds like any other layer texture.
///
/// `AVPlayer` is deliberately not used. A player owns its own clock, and the
/// renderer already has one (scene time, which pauses with the wallpaper and can
/// be scrubbed offscreen by `wetool render`). An `AVAssetReader` decoding ahead
/// into a small ring buffer lets `texture(at:)` stay a pure lookup: it picks the
/// newest frame whose presentation time has passed and never blocks the render
/// thread, however slow the decoder is.
public final class VideoTexture {
    /// One decoded frame. The `CVMetalTexture` must outlive the `MTLTexture`
    /// derived from it, so they travel together and are released together.
    private struct Frame {
        /// Seconds on a monotonic timeline that keeps counting across loops, so
        /// comparisons never break at the wrap point.
        let time: Double
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
        let width: Int
        let height: Int
    }

    /// Frames decoded ahead. Small: this exists to absorb decode jitter, not to
    /// buffer the video, and every entry pins an IOSurface.
    private static let ringCapacity = 6
    /// How many replaced frames stay retained. The renderer may still be holding
    /// the previously returned texture while the GPU reads it, and dropping the
    /// last reference would hand the surface back to the decoder for reuse.
    private static let retiredCapacity = 3
    /// A clock step larger than this reads as a seek or a resume, not playback.
    private static let maximumStep: Double = 0.5

    private let device: MTLDevice
    private let label: String
    private let url: URL
    /// Set only when this instance wrote the file itself, and then removed in `deinit`.
    private let temporaryFile: URL?
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let textureCache: CVMetalTextureCache
    private let frameInterval: Double
    private let queue: DispatchQueue

    /// Guards everything the render thread and the decode queue share. Held for
    /// pointer shuffling only, never across a decode.
    private let lock = NSLock()
    private var ring: [Frame] = []
    private var retired: [Frame] = []
    private var current: Frame?
    private var pixelSize: SIMD2<Float>
    private var playhead: Double = 0
    private var lastClock: Double?
    private var paused = false
    private var stopped = false

    /// Guards the reader pair. Separate from `lock` because the decode queue
    /// reads through it while `texture(at:)` must never wait on a decode.
    private let readerLock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    /// Decode-queue only.
    private var loopBase: Double = 0
    private var passFirstPresentation: Double?
    private var lastPresentation: Double = 0

    // MARK: Construction

    /// `data` is an in-memory MP4 (from a TEXB0004 .tex). It is written to a temporary
    /// file because AVAsset cannot read from memory.
    public convenience init?(data: Data, device: MTLDevice, label: String) {
        guard !data.isEmpty else { return nil }
        let name = "mirage-video-\(UUID().uuidString).mp4"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        self.init(url: file, device: device, label: label, temporaryFile: file)
    }

    public convenience init?(url: URL, device: MTLDevice, label: String) {
        self.init(url: url, device: device, label: label, temporaryFile: nil)
    }

    /// Convenience for a `TEXB0004` texture, whose payload is already in memory.
    public convenience init?(texture: WETexture, device: MTLDevice, label: String) {
        guard let data = texture.videoData else { return nil }
        self.init(data: data, device: device, label: label)
    }

    private init?(url: URL, device: MTLDevice, label: String, temporaryFile: URL?) {
        // Any failure here must still clean up a temporary file we wrote: a
        // failed initialiser of a class only runs `deinit` once every stored
        // property is set, which is not the case on these paths.
        func giveUp() {
            if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard let loaded = Self.loadVideoTrack(from: asset) else { giveUp(); return nil }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            giveUp()
            return nil
        }

        self.device = device
        self.label = label
        self.url = url
        self.temporaryFile = temporaryFile
        self.asset = asset
        self.track = loaded.track
        self.textureCache = cache
        self.pixelSize = loaded.size
        self.frameInterval = loaded.frameInterval
        self.queue = DispatchQueue(label: "com.mirage.video-texture", qos: .userInitiated)

        guard startReader() else { giveUp(); return nil }
        queue.async { [weak self] in self?.pump() }
    }

    deinit {
        lock.lock()
        stopped = true
        ring.removeAll()
        retired.removeAll()
        current = nil
        lock.unlock()

        readerLock.lock()
        reader?.cancelReading()
        reader = nil
        output = nil
        readerLock.unlock()

        CVMetalTextureCacheFlush(textureCache, 0)
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
    }

    // MARK: Public surface

    /// Pixel size of the decoded frames. Before the first frame arrives this is
    /// the track's natural size with its preferred transform applied, so a
    /// rotated video still reports the size it will present at.
    public var size: SIMD2<Float> {
        lock.lock(); defer { lock.unlock() }
        return pixelSize
    }

    /// Advances to the frame for `time` (seconds, looping) and returns the texture to
    /// bind. Returns the previous frame when the next one is not ready yet, and nil
    /// before the first frame has decoded.
    public func texture(at time: Double) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return current?.texture }

        if paused {
            // Drop the reference point so resuming does not replay the gap.
            lastClock = nil
            return current?.texture
        }

        // The caller's clock is only used for its deltas. Its origin, its
        // absolute value and its own looping (if any) are irrelevant, which
        // keeps the wrap between loops from ever looking like a rewind.
        if let last = lastClock {
            let step = time - last
            if step.isFinite, step > 0, step < Self.maximumStep { playhead += step }
        }
        lastClock = time.isFinite ? time : nil

        var picked: Frame?
        while let first = ring.first, first.time <= playhead {
            picked = first
            ring.removeFirst()
        }
        if let picked {
            if let previous = current {
                retired.append(previous)
                if retired.count > Self.retiredCapacity { retired.removeFirst(retired.count - Self.retiredCapacity) }
            }
            current = picked
            pixelSize = SIMD2(Float(picked.width), Float(picked.height))
        } else if ring.isEmpty, let current, playhead > current.time + Self.maximumStep {
            // Starved: the decoder fell behind. Hold the playhead at the frame
            // on screen instead of running up a debt that would be paid off by
            // discarding a burst of frames the moment decoding catches up.
            playhead = current.time
        }
        return current?.texture
    }

    public func pause() {
        lock.lock()
        paused = true
        lastClock = nil
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        paused = false
        lastClock = nil
        lock.unlock()
    }

    // MARK: Decoding

    /// Fills the ring, then reschedules itself. Self-rescheduling rather than a
    /// blocking loop so a paused wallpaper costs one wakeup every 100 ms.
    private func pump() {
        lock.lock()
        if stopped { lock.unlock(); return }
        let isPaused = paused
        let wanted = max(0, Self.ringCapacity - ring.count)
        lock.unlock()

        var produced = 0
        if !isPaused {
            while produced < wanted {
                guard let frame = decodeNextFrame() else { break }
                lock.lock()
                if stopped { lock.unlock(); return }
                ring.append(frame)
                lock.unlock()
                produced += 1
            }
        }

        let delay: Double
        if isPaused {
            delay = 0.1
        } else if produced < wanted {
            // Decoding stalled or the asset went away. Back off rather than spin.
            delay = 0.05
        } else {
            delay = max(0.005, frameInterval * 0.5)
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pump() }
    }

    /// Next decodable frame, restarting the reader at the end of the file so the
    /// loop is seamless. A finished `AVAssetReader` cannot be rewound, so this
    /// builds a fresh one.
    private func decodeNextFrame(allowRestart: Bool = true) -> Frame? {
        readerLock.lock()
        let reader = self.reader
        let output = self.output
        readerLock.unlock()
        guard let reader, let output else { return nil }

        // A sample without an image buffer (or one the texture cache rejects) is
        // skipped rather than treated as the end of the stream.
        var skipped = 0
        while reader.status == .reading, skipped < 8 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            if let frame = makeFrame(from: sample) { return frame }
            skipped += 1
        }
        guard allowRestart, !isStopped else { return nil }
        guard restartReader() else { return nil }
        return decodeNextFrame(allowRestart: false)
    }

    private func makeFrame(from sample: CMSampleBuffer) -> Frame? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }

        // Presentation times come from the file and can be invalid or absurd, so
        // an unusable one just inherits the previous frame's slot.
        let stamp = CMSampleBufferGetPresentationTimeStamp(sample)
        var seconds = lastPresentation - loopBase + frameInterval
        if stamp.isNumeric {
            let value = stamp.seconds
            if value.isFinite, value >= 0 { seconds = value }
        }
        if passFirstPresentation == nil { passFirstPresentation = seconds }
        let time = loopBase + max(0, seconds - (passFirstPresentation ?? 0))
        guard time.isFinite else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        texture.label = "mirage.video.\(label)"

        lastPresentation = time
        return Frame(time: time, cvTexture: cvTexture, texture: texture, width: width, height: height)
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    // MARK: Reader lifecycle

    @discardableResult
    private func startReader() -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        let settings: [String: Any] = [
            // Single plane, so one CVMetalTexture is the whole frame and the
            // renderer can bind it like any other .bgra8Unorm layer texture.
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }

        readerLock.lock()
        self.reader?.cancelReading()
        self.reader = reader
        self.output = output
        readerLock.unlock()
        passFirstPresentation = nil
        return true
    }

    /// Rewinds by rebuilding the reader, and pushes the frame timeline forward
    /// by one loop so frame times stay monotonic for `texture(at:)`.
    private func restartReader() -> Bool {
        let next = lastPresentation + frameInterval
        guard next.isFinite else { return false }
        guard startReader() else { return false }
        loopBase = next
        return true
    }

    // MARK: Track loading

    private struct TrackInfo {
        let track: AVAssetTrack
        let size: SIMD2<Float>
        let frameInterval: Double
    }

    /// Box for carrying the result of the async load back to the caller. The
    /// initialiser has to be synchronous (it either produces a usable texture or
    /// returns nil), and for a local file this resolves in microseconds.
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    private static func loadVideoTrack(from asset: AVURLAsset, timeout: TimeInterval = 10) -> TrackInfo? {
        let box = Box<TrackInfo>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }
                let (natural, transform, rate) = try await track.load(
                    .naturalSize, .preferredTransform, .nominalFrameRate)
                let presented = natural.applying(transform)
                let width = abs(Float(presented.width)), height = abs(Float(presented.height))
                guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return }
                var interval = 1.0 / 30.0
                if rate.isFinite, rate > 0 { interval = 1.0 / Double(rate) }
                interval = min(max(interval, 1.0 / 240.0), 1.0)
                box.value = TrackInfo(track: track, size: SIMD2(width, height), frameInterval: interval)
            } catch {
                // Corrupt or unreadable: the caller turns a nil into a nil init.
            }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }
}
