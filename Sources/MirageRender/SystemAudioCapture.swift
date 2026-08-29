import AudioToolbox
import CoreAudio
import Foundation
import os

/// Listens to what the Mac is playing, so audio reactive wallpapers can move
/// with it.
///
/// This uses a Core Audio **process tap** rather than ScreenCaptureKit. A tap
/// asks for the "Audio Capture" permission, which is what this actually is;
/// ScreenCaptureKit would make a wallpaper app ask to record the screen, run a
/// video pipeline whose frames are thrown away, and on newer systems re-prompt
/// periodically. Wallpaper Engine's own macOS port takes the same route.
///
/// Nothing is recorded: samples land in a fixed ring buffer, are turned into a
/// spectrum, and are overwritten.
@available(macOS 14.2, *)
final class SystemAudioCapture {

    enum Failure: Error, CustomStringConvertible {
        case tapRefused(OSStatus)
        case noOutputDevice
        case aggregateFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .tapRefused(let status):
                // The usual cause is a missing permission, since the tap is
                // refused before any audio flows.
                return "the system audio tap was refused (\(status)), which usually means Audio Capture permission"
            case .noOutputDevice: return "there is no default output device"
            case .aggregateFailed(let status): return "the aggregate device could not be created (\(status))"
            case .ioProcFailed(let status): return "the audio callback could not be installed (\(status))"
            case .startFailed(let status): return "the audio device would not start (\(status))"
            }
        }
    }

    /// How many samples of history each channel keeps. Two analysis windows, so
    /// a late reader still sees a full one.
    private static let ringSize = SpectrumAnalyzer.windowSize * 2

    private var tapID = AUAudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private let lock = OSAllocatedUnfairLock(initialState: RingState())
    private struct RingState {
        var left = [Float](repeating: 0, count: SystemAudioCapture.ringSize)
        var right = [Float](repeating: 0, count: SystemAudioCapture.ringSize)
        var writeIndex = 0
    }

    private(set) var sampleRate: Double = 48_000

    deinit { stop() }

    // MARK: Lifecycle

    func start() throws {
        stop()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Mirage"
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        // Keeps the tap out of other apps' device lists.
        description.isPrivate = true

        var tap = AUAudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else { throw Failure.tapRefused(tapStatus) }
        tapID = tap

        if let format = Self.tapFormat(tap), format.mSampleRate > 0 { sampleRate = format.mSampleRate }

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            stop()
            throw Failure.noOutputDevice
        }

        // An aggregate device is how a tap is read: it presents the tapped
        // stream as an input the process can run an IOProc against.
        let aggregateUID = UUID().uuidString
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mirage Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            stop()
            throw Failure.aggregateFailed(aggregateStatus)
        }
        aggregateID = aggregate

        // The callback runs on a real time thread: it copies and returns, with
        // no allocation, no logging and nothing that can block.
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard procStatus == noErr, let procID else {
            stop()
            throw Failure.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            stop()
            throw Failure.startFailed(startStatus)
        }

        observeOutputDeviceChanges()
    }

    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        removeOutputDeviceObserver()
    }

    // MARK: Samples

    /// The most recent analysis window for each channel, oldest sample first.
    func latestWindow() -> (left: [Float], right: [Float]) {
        let size = SpectrumAnalyzer.windowSize
        return lock.withLock { state in
            var left = [Float](repeating: 0, count: size)
            var right = [Float](repeating: 0, count: size)
            var index = (state.writeIndex - size + Self.ringSize) % Self.ringSize
            for i in 0..<size {
                left[i] = state.left[index]
                right[i] = state.right[index]
                index = (index + 1) % Self.ringSize
            }
            return (left, right)
        }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let raw = first.mData else { return }
        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(1, channels)
        guard frames > 0 else { return }
        let samples = raw.assumingMemoryBound(to: Float.self)

        // Either one interleaved stereo buffer or two mono ones, and a mono tap
        // feeds both channels.
        lock.withLock { state in
            var index = state.writeIndex
            for frame in 0..<frames {
                let l: Float
                let r: Float
                if channels >= 2 {
                    l = samples[frame * channels]
                    r = samples[frame * channels + 1]
                } else if buffers.count > 1, let other = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    l = samples[frame]
                    r = other[frame]
                } else {
                    l = samples[frame]
                    r = l
                }
                state.left[index] = l.isFinite ? l : 0
                state.right[index] = r.isFinite ? r : 0
                index = (index + 1) % Self.ringSize
            }
            state.writeIndex = index
        }
    }

    // MARK: Devices

    private static func tapFormat(_ tap: AUAudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { return nil }
        return uid as String
    }

    /// Switching to headphones destroys the aggregate's main device, so the tap
    /// is rebuilt when the default output changes. Without this the visualiser
    /// dies silently the first time the user plugs anything in.
    private func observeOutputDeviceChanges() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async { try? self.start() }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                            DispatchQueue.global(qos: .userInitiated), block)
    }

    private func removeOutputDeviceObserver() {
        guard let deviceListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                               DispatchQueue.global(qos: .userInitiated), deviceListener)
        self.deviceListener = nil
    }
}

/// One system audio tap for the whole app, shared by every display.
///
/// A renderer asks for audio while it needs it and lets go when it does not, so
/// the tap only runs while an audio reactive wallpaper is on screen. The
/// analysis runs on its own queue: never on the Core Audio thread, which must
/// return promptly, and never on the render thread.
public final class AudioSpectrumProvider {
    public enum State: Equatable {
        case off
        case running
        /// Refused, almost always for want of the Audio Capture permission.
        case unavailable(String)
    }

    public static let shared = AudioSpectrumProvider()

    private let queue = DispatchQueue(label: "com.mirage.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var consumers = 0
    private var timer: DispatchSourceTimer?
    private var analyzer = SpectrumAnalyzer()
    private var leftSmoother = SpectrumSmoother()
    private var rightSmoother = SpectrumSmoother()
    private var left = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var right = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var backing: AnyObject?
    private var currentState: State = .off

    private init() {}

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return currentState
    }

    /// The latest spectrum, 64 bands per channel, index 0 lowest.
    public func snapshot() -> (left: [Float], right: [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (left, right)
    }

    /// Says a wallpaper needs audio. Balanced by `release`.
    public func retain() {
        lock.lock()
        consumers += 1
        let shouldStart = consumers == 1
        lock.unlock()
        guard shouldStart else { return }
        queue.async { [weak self] in self?.startCapture() }
    }

    public func release() {
        lock.lock()
        consumers = max(0, consumers - 1)
        let shouldStop = consumers == 0
        lock.unlock()
        guard shouldStop else { return }
        queue.async { [weak self] in self?.stopCapture() }
    }

    private func startCapture() {
        guard #available(macOS 14.2, *) else {
            setState(.unavailable("system audio capture needs macOS 14.2 or later"))
            return
        }
        guard backing == nil else { return }
        let capture = SystemAudioCapture()
        do {
            try capture.start()
        } catch {
            setState(.unavailable(String(describing: error)))
            return
        }
        backing = capture
        analyzer = SpectrumAnalyzer(sampleRate: capture.sampleRate)
        setState(.running)

        // 60 Hz is enough for a bar to look continuous and is well under the
        // rate at which a new window of samples arrives.
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        source.setEventHandler { [weak self] in self?.analyze() }
        source.resume()
        timer = source
    }

    private func stopCapture() {
        timer?.cancel()
        timer = nil
        if #available(macOS 14.2, *), let capture = backing as? SystemAudioCapture { capture.stop() }
        backing = nil
        lock.lock()
        left = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        right = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        currentState = .off
        lock.unlock()
    }

    private func analyze() {
        guard #available(macOS 14.2, *), let capture = backing as? SystemAudioCapture else { return }
        let window = capture.latestWindow()
        let l = leftSmoother.smooth(analyzer.bands(window.left))
        let r = rightSmoother.smooth(analyzer.bands(window.right))
        lock.lock()
        left = l
        right = r
        lock.unlock()
    }

    private func setState(_ new: State) {
        lock.lock()
        currentState = new
        lock.unlock()
    }
}
