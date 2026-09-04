import Accelerate
import Foundation

/// Turns a window of audio samples into the 64 band spectrum Wallpaper Engine
/// shaders expect.
///
/// The contract comes from Wallpaper Engine's own documentation: 64 values per
/// channel, index 0 the lowest frequency, "generally 0.00 to 1.00" where 1.00
/// means that band is at maximum. Bands are spaced logarithmically, because
/// that is how the ear hears and how every visualiser in the corpus draws its
/// bars: linear bins would crowd all the music into the bottom fifth.
public struct SpectrumAnalyzer {
    /// 2048 samples is 42.7 ms at 48 kHz and 23.4 Hz per bin. Halving it would
    /// make the bottom bands, which the stock `pulse.vert` reads, too coarse to
    /// separate a kick drum from a bass note.
    public static let windowSize = 2048
    public static let bandCount = 64

    private static let lowestFrequency: Float = 30
    private static let highestFrequency: Float = 16_000

    /// `vDSP_create_fftsetup` hands back a manually managed object, so it lives
    /// in a small class whose deinit destroys it; the struct itself has none.
    private final class Setup {
        let handle: FFTSetup?
        init(log2n: vDSP_Length) { handle = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) }
        deinit { if let handle { vDSP_destroy_fftsetup(handle) } }
    }

    private let setup: Setup
    private let window: [Float]
    private let windowSum: Float
    /// The first bin of each band, plus one past the end of the last.
    private let bandEdges: [Int]

    public init(sampleRate: Double = 48_000) {
        let log2n = vDSP_Length(log2(Float(SpectrumAnalyzer.windowSize)).rounded())
        setup = Setup(log2n: log2n)

        var hann = [Float](repeating: 0, count: SpectrumAnalyzer.windowSize)
        vDSP_hann_window(&hann, vDSP_Length(SpectrumAnalyzer.windowSize), Int32(vDSP_HANN_DENORM))
        window = hann
        windowSum = hann.reduce(0, +)

        // Logarithmic edges, clamped so that no band is empty at the bottom
        // where the bins are wider apart than the bands are.
        let binCount = SpectrumAnalyzer.windowSize / 2
        let hertzPerBin = Float(sampleRate) / Float(SpectrumAnalyzer.windowSize)
        var edges: [Int] = []
        edges.reserveCapacity(SpectrumAnalyzer.bandCount + 1)
        let ratio = SpectrumAnalyzer.highestFrequency / SpectrumAnalyzer.lowestFrequency
        for band in 0...SpectrumAnalyzer.bandCount {
            let fraction = Float(band) / Float(SpectrumAnalyzer.bandCount)
            let frequency = SpectrumAnalyzer.lowestFrequency * pow(ratio, fraction)
            var bin = Int((frequency / hertzPerBin).rounded())
            bin = min(binCount, max(1, bin))
            if let last = edges.last, bin <= last { bin = min(binCount, last + 1) }
            edges.append(bin)
        }
        bandEdges = edges
    }

    /// Magnitudes for one channel, already smoothed by the caller if it wants.
    ///
    /// `samples` must hold `windowSize` values; anything else returns silence
    /// rather than reading out of bounds.
    public func bands(_ samples: [Float]) -> [Float] {
        let n = SpectrumAnalyzer.windowSize
        guard samples.count == n, let setup = setup.handle else {
            return [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        }

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Float(n)).rounded()), FFTDirection(FFT_FORWARD))
                // zrip packs Nyquist into imagp[0]; it is not the partner of DC,
                // and leaving it there would put a phantom peak in band 0.
                split.imagp[0] = 0
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // zrip's output is twice the mathematical transform, and a Hann window
        // removes about half the energy, so this scaling makes a full-scale sine
        // read 1.0 in the band that contains it.
        var scale = 1 / windowSum
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

        var out = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        for band in 0..<SpectrumAnalyzer.bandCount {
            let start = bandEdges[band]
            let end = max(start + 1, bandEdges[band + 1])
            guard start < half else { break }
            var peak: Float = 0
            // The peak, not the mean: a narrow tone in a wide high band would
            // otherwise be averaged away to nothing.
            vDSP_maxv(Array(magnitudes[start..<min(end, half)]), 1, &peak,
                      vDSP_Length(min(end, half) - start))
            out[band] = peak.isFinite ? min(1, max(0, peak)) : 0
        }
        return out
    }
}

/// Keeps a spectrum steady enough to look at.
///
/// Raw FFT frames flicker badly at 60 Hz. Wallpaper Engine's own visualisers
/// look smooth because the values fall gradually, so this rises instantly to a
/// louder value and decays towards a quieter one.
public struct SpectrumSmoother {
    private var previous = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    /// Fraction of the gap closed per frame when falling.
    private let fall: Float

    public init(fall: Float = 0.22) { self.fall = min(1, max(0.01, fall)) }

    public mutating func smooth(_ incoming: [Float]) -> [Float] {
        guard incoming.count == previous.count else { return previous }
        for index in 0..<previous.count {
            let value = incoming[index].isFinite ? incoming[index] : 0
            previous[index] = value > previous[index]
                ? value
                : previous[index] + (value - previous[index]) * fall
        }
        return previous
    }
}
