import XCTest
@testable import MirageRender

/// The spectrum feeds shaders that expect Wallpaper Engine's contract: 64 bands
/// per channel, index 0 lowest, roughly 0 to 1.
final class SpectrumTests: XCTestCase {

    private func tone(hertz: Float, sampleRate: Float = 48_000, amplitude: Float = 1) -> [Float] {
        (0..<SpectrumAnalyzer.windowSize).map { i in
            amplitude * sin(2 * .pi * hertz * Float(i) / sampleRate)
        }
    }

    func testSilenceIsSilent() {
        let analyzer = SpectrumAnalyzer()
        let bands = analyzer.bands([Float](repeating: 0, count: SpectrumAnalyzer.windowSize))
        XCTAssertEqual(bands.count, SpectrumAnalyzer.bandCount)
        XCTAssertEqual(bands.max() ?? 1, 0, accuracy: 1e-6)
    }

    func testAToneLandsInOneBandAndTheRestStayQuiet() {
        let analyzer = SpectrumAnalyzer()
        let bands = analyzer.bands(tone(hertz: 1000))
        guard let peak = bands.firstIndex(of: bands.max() ?? 0) else { return XCTFail("no peak") }
        // 1 kHz sits above the middle of a 30 Hz to 16 kHz log sweep.
        XCTAssertTrue((30...45).contains(peak), "1 kHz landed in band \(peak)")
        let elsewhere = bands.enumerated().filter { abs($0.offset - peak) > 2 }.map(\.element).max() ?? 0
        XCTAssertLessThan(elsewhere, bands[peak] * 0.5)
    }

    func testLowAndHighTonesOrderCorrectly() {
        let analyzer = SpectrumAnalyzer()
        let low = analyzer.bands(tone(hertz: 60))
        let high = analyzer.bands(tone(hertz: 8000))
        let lowPeak = low.firstIndex(of: low.max() ?? 0) ?? 0
        let highPeak = high.firstIndex(of: high.max() ?? 0) ?? 0
        XCTAssertLessThan(lowPeak, highPeak, "band 0 must be the lowest frequency")
    }

    func testAFullScaleToneReachesRoughlyOne() {
        let analyzer = SpectrumAnalyzer()
        let bands = analyzer.bands(tone(hertz: 1000, amplitude: 1))
        XCTAssertGreaterThan(bands.max() ?? 0, 0.3)
        XCTAssertLessThanOrEqual(bands.max() ?? 0, 1.0)
    }

    func testHostileInputIsRefusedRatherThanRead() {
        let analyzer = SpectrumAnalyzer()
        XCTAssertEqual(analyzer.bands([]).count, SpectrumAnalyzer.bandCount)
        XCTAssertEqual(analyzer.bands([1, 2, 3]).max() ?? 1, 0)
        let nan = [Float](repeating: .nan, count: SpectrumAnalyzer.windowSize)
        XCTAssertTrue(analyzer.bands(nan).allSatisfy { $0.isFinite })
    }

    func testSmootherRisesAtOnceAndFallsGradually() {
        var smoother = SpectrumSmoother()
        let loud = [Float](repeating: 1, count: SpectrumAnalyzer.bandCount)
        let quiet = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        XCTAssertEqual(smoother.smooth(loud).first ?? 0, 1, accuracy: 1e-6)
        let afterOne = smoother.smooth(quiet).first ?? 0
        XCTAssertGreaterThan(afterOne, 0.5, "a bar must not snap to zero")
        XCTAssertLessThan(afterOne, 1)
        for _ in 0..<200 { _ = smoother.smooth(quiet) }
        XCTAssertEqual(smoother.smooth(quiet).first ?? 1, 0, accuracy: 1e-3)
    }
}
