import AVFoundation
import CryptoKit
import Foundation
import WEKit

/// Plays the sound objects of one wallpaper.
///
/// Wallpaper Engine keeps its audio inside `scene.pkg` and `AVAudioPlayer` can only
/// read a file that exists on disk, so every clip is extracted once into a
/// per-wallpaper cache folder and reused on later launches.
///
/// Playback is driven from `update(time:)` with the wallpaper's own clock rather
/// than from a timer: the wallpaper clock stops when the wallpaper is paused, so
/// start delays and the silent fade-in stay in step with the visuals instead of
/// drifting ahead of them while nothing is being drawn.
public final class WallpaperSoundPlayer {

    /// Seconds the `startsilent` ramp takes to reach the object's own volume.
    private static let fadeInDuration: Double = 1

    /// A player that has just been asked to play can report `isPlaying == false`
    /// for a moment, so a clip only counts as finished after this much wallpaper
    /// time has passed. Without it a single frame of jitter would skip a file.
    private static let advanceGrace: Double = 0.25

    /// Diagnostics are shown in the UI, so keep the list bounded: a wallpaper with
    /// a broken sound list could otherwise append one line per frame.
    private static let maximumDiagnostics = 64

    /// Sound files are third-party input; refuse to copy an implausibly large one
    /// into the cache rather than filling the user's disk.
    private static let maximumFileByteCount = 64 * 1024 * 1024

    private enum Mode {
        case loop
        case random

        init(_ raw: String) {
            self = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "random" ? .random : .loop
        }
    }

    /// One `sound` object of the scene: its clips plus where in them it currently is.
    private final class SoundObject {
        let files: [URL]
        let mode: Mode
        var volume: Float
        let minTime: Double
        let maxTime: Double
        let startSilent: Bool

        var player: AVAudioPlayer?
        var index: Int = 0
        var failed: Set<Int> = []
        var disabled = false
        /// Wallpaper time the object's clock started at, set on the first update.
        var baseTime: Double?
        /// Delay before the first clip, redrawn from `minTime ... maxTime` on start.
        var delay: Double = 0
        /// Wallpaper time the current clip began at, for the fade and the finish check.
        var playbackStart: Double = 0
        /// Last computed fade factor, so an app volume change outside `update` can
        /// be applied without knowing the current wallpaper time.
        var fade: Float = 1

        init(files: [URL], mode: Mode, volume: Float, minTime: Double, maxTime: Double, startSilent: Bool) {
            self.files = files
            self.mode = mode
            self.volume = volume
            self.minTime = minTime
            self.maxTime = maxTime
            self.startSilent = startSilent
        }
    }

    private let locator: AssetLocator
    private let workshopId: String?
    private let lock = NSLock()

    private var objects: [SoundObject] = []
    private var isRunning = false
    private var isPaused = false
    private var appVolume: Float = 1
    private var isMuted = false
    private var lastUpdateTime: Double?
    /// Set on resume so the first update after a pause can absorb the time the
    /// wallpaper clock advanced while the audio was stopped.
    private var cachedDirectory: URL?
    private var didResolveDirectory = false

    public private(set) var diagnostics: [String] = []

    public init(locator: AssetLocator, workshopId: String?) {
        self.locator = locator
        self.workshopId = workshopId
    }

    deinit {
        // Never leave a player running past the wallpaper it belongs to.
        for object in objects {
            object.player?.stop()
            object.player = nil
        }
    }

    // MARK: Building

    /// `paths` are pkg-relative, e.g. "sounds/rain.mp3". `mode` is "loop" or "random".
    public func add(paths: [String], mode: String, volume: Float,
                    minTime: Double, maxTime: Double, startSilent: Bool) {
        lock.lock()
        defer { lock.unlock() }

        var files: [URL] = []
        for path in paths {
            guard let url = fileURL(for: path) else { continue }
            files.append(url)
        }
        guard !files.isEmpty else { return }

        let lo = max(0, minTime.isFinite ? minTime : 0)
        let hi = max(lo, maxTime.isFinite ? maxTime : lo)
        let object = SoundObject(files: files,
                                 mode: Mode(mode),
                                 volume: clamp01(volume),
                                 minTime: lo,
                                 maxTime: hi,
                                 startSilent: startSilent)
        object.delay = randomDelay(object)
        object.fade = startSilent ? 0 : 1
        objects.append(object)
        // A sound object added while the wallpaper is already playing should not
        // wait for the next start(), so let it pick up the current clock.
        if isRunning { object.baseTime = lastUpdateTime }
    }

    // MARK: Transport

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !objects.isEmpty else { return }
        isRunning = true
        isPaused = false
        lastUpdateTime = nil
        for object in objects {
            object.player?.stop()
            object.player = nil
            object.baseTime = nil
            object.index = 0
            object.failed = []
            object.disabled = false
            object.delay = randomDelay(object)
            object.fade = object.startSilent ? 0 : 1
        }
    }

    public func setPaused(_ paused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, paused != isPaused else { return }
        isPaused = paused
        for object in objects {
            guard let player = object.player else { continue }
            if paused { player.pause() } else if !player.play() { object.player = nil }
        }
    }

    /// App-level volume, multiplied into every object's own volume.
    public func setVolume(_ volume: Float, muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        appVolume = clamp01(volume)
        isMuted = muted
        for object in objects {
            object.player?.volume = storedVolume(object)
        }
    }

    /// Updates the per-object volumes, in the order they were added.
    ///
    /// A wallpaper's sound volume is a scene value like any other: it can be
    /// bound to a user property or driven by a script, so it is re-resolved
    /// every frame rather than read once at load.
    public func setObjectVolumes(_ volumes: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for (index, volume) in volumes.enumerated() where index < objects.count {
            let clamped = clamp01(volume)
            guard objects[index].volume != clamped else { continue }
            objects[index].volume = clamped
            objects[index].player?.volume = storedVolume(objects[index])
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
        isPaused = false
        lastUpdateTime = nil
        for object in objects {
            object.player?.stop()
            // AVAudioPlayer keeps a strong reference to nothing here: no delegate is
            // ever assigned, and dropping the player releases the decoder outright.
            object.player = nil
            object.baseTime = nil
            object.fade = object.startSilent ? 0 : 1
        }
    }

    /// Call once per frame with the elapsed wallpaper time: drives start delays,
    /// the silent fade-in and advancing to the next file.
    public func update(time: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, !isPaused, time.isFinite else { return }

        for object in objects { advance(object, time: time) }
        lastUpdateTime = time
    }

    // MARK: Playback

    private func advance(_ object: SoundObject, time: Double) {
        guard !object.disabled, !object.files.isEmpty else { return }
        guard let base = object.baseTime else {
            object.baseTime = time
            return
        }
        // A wallpaper reload restarts the clock; rebase instead of waiting forever.
        if time < base {
            object.baseTime = time
            object.playbackStart = time
            return
        }
        guard time - base >= object.delay else { return }

        if let player = object.player {
            player.volume = effectiveVolume(object, time: time)
            guard !player.isPlaying, time - object.playbackStart >= WallpaperSoundPlayer.advanceGrace else { return }
            object.player = nil
            object.index = nextIndex(object)
            beginPlayback(object, time: time)
        } else {
            beginPlayback(object, time: time)
        }
    }

    private func beginPlayback(_ object: SoundObject, time: Double) {
        for _ in 0..<object.files.count {
            let index = object.index
            guard index >= 0, index < object.files.count, !object.failed.contains(index) else {
                object.index = nextIndex(object)
                continue
            }
            let url = object.files[index]
            guard let player = try? AVAudioPlayer(contentsOf: url) else {
                note("sound could not be decoded: \(url.lastPathComponent)")
                object.failed.insert(index)
                object.index = nextIndex(object)
                continue
            }
            // A single looping clip loops inside AVAudioPlayer, which is gapless;
            // several clips are advanced by hand so the order (or randomness) holds.
            player.numberOfLoops = (object.mode == .loop && object.files.count == 1) ? -1 : 0
            object.playbackStart = time
            player.volume = effectiveVolume(object, time: time)
            player.prepareToPlay()
            guard player.play() else {
                note("sound could not be played: \(url.lastPathComponent)")
                object.failed.insert(index)
                object.index = nextIndex(object)
                continue
            }
            object.player = player
            return
        }
        object.disabled = true
        note("sound object has no playable file, silenced")
    }

    private func nextIndex(_ object: SoundObject) -> Int {
        let count = object.files.count
        guard count > 1 else { return 0 }
        switch object.mode {
        case .loop:
            return (object.index + 1) % count
        case .random:
            // Avoid repeating the clip that just ended; WE's random mode shuffles.
            var next = Int.random(in: 0..<(count - 1))
            if next >= object.index { next += 1 }
            return next
        }
    }

    private func effectiveVolume(_ object: SoundObject, time: Double) -> Float {
        if object.startSilent {
            let elapsed = time - object.playbackStart
            let progress = elapsed.isFinite && WallpaperSoundPlayer.fadeInDuration > 0
                ? elapsed / WallpaperSoundPlayer.fadeInDuration
                : 1
            object.fade = clamp01(Float(min(1, max(0, progress))))
        } else {
            object.fade = 1
        }
        return storedVolume(object)
    }

    private func storedVolume(_ object: SoundObject) -> Float {
        clamp01(object.volume * appVolume * (isMuted ? 0 : 1) * object.fade)
    }

    private func randomDelay(_ object: SoundObject) -> Double {
        guard object.maxTime > object.minTime else { return object.minTime }
        return Double.random(in: object.minTime...object.maxTime)
    }

    private func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    // MARK: Extraction

    /// Resolves one pkg-relative sound path to a file on disk, extracting it into
    /// the cache the first time it is seen.
    private func fileURL(for path: String) -> URL? {
        guard let relative = normalized(path) else {
            note("sound path rejected: \(path)")
            return nil
        }

        // A loose file in the project folder can be played where it lies.
        let loose = locator.projectDirectory.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: loose.path) { return loose }

        guard let directory = audioCacheDirectory() else { return nil }
        let target = directory.appendingPathComponent(cacheName(for: relative))
        if let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            return target
        }
        if let entry = locator.package?.entry(named: relative),
           entry.length > WallpaperSoundPlayer.maximumFileByteCount {
            note("sound too large to cache: \(relative)")
            return nil
        }
        guard let data = locator.data(relative), !data.isEmpty else {
            note("sound not found: \(relative)")
            return nil
        }
        guard data.count <= WallpaperSoundPlayer.maximumFileByteCount else {
            note("sound too large to cache: \(relative)")
            return nil
        }
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            note("could not cache sound \(relative): \(error.localizedDescription)")
            return nil
        }
        return target
    }

    /// `~/Library/Caches/Mirage/audio/<workshop id or path hash>/`, created lazily.
    private func audioCacheDirectory() -> URL? {
        if didResolveDirectory { return cachedDirectory }
        didResolveDirectory = true
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            note("no caches directory, sound is unavailable")
            return nil
        }
        let directory = caches
            .appendingPathComponent("Mirage/audio", isDirectory: true)
            .appendingPathComponent(wallpaperKey, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            note("could not create the sound cache: \(error.localizedDescription)")
            return nil
        }
        cachedDirectory = directory
        return directory
    }

    /// The workshop id when it is a safe folder name, otherwise a hash of the
    /// project path so two wallpapers never share a cache folder.
    private var wallpaperKey: String {
        if let id = workshopId, !id.isEmpty, id.count <= 32,
           id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            return id
        }
        return "path-" + hex(locator.projectDirectory.standardizedFileURL.path, characters: 16)
    }

    /// A collision-free, filesystem-safe name that keeps the original extension so
    /// AVFoundation can still sniff the format from it.
    private func cacheName(for relative: String) -> String {
        let prefix = hex(relative, characters: 16)
        let base = (relative as NSString).lastPathComponent
        var safe = String(base.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-" || c == "_") { return c }
            return "_"
        })
        if safe.count > 64 { safe = String(safe.suffix(64)) }
        if safe.isEmpty { safe = "sound" }
        return prefix + "-" + safe
    }

    private func hex(_ value: String, characters: Int) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(max(1, characters)))
    }

    /// Rejects the traversal and absolute forms a hostile pkg could carry.
    private func normalized(_ path: String) -> String? {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("/") { p.removeFirst() }
        guard !p.isEmpty else { return nil }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(".."), !parts.contains("") else { return nil }
        return p
    }

    private func note(_ message: String) {
        guard diagnostics.count < WallpaperSoundPlayer.maximumDiagnostics else { return }
        diagnostics.append(message)
    }
}
