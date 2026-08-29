import Foundation
import simd

/// Perlin noise and the curl of a Perlin vector field, plus a tiny seeded PRNG.
///
/// These live in WEKit rather than the renderer because the particle system is
/// pure CPU simulation: the `turbulence` operator asks for the curl of a noise
/// field and every initializer asks for random numbers, and both have to match
/// the reference renderers exactly or the motion looks wrong even though no
/// single frame is obviously broken. The table, the fade curve, the three
/// decorrelation offsets and the curl epsilon below are all reproduced from the
/// reference implementations for that reason, do not "improve" them.
public enum Noise {

    // MARK: - Permutation table

    /// Ken Perlin's original 256-entry permutation, duplicated to 512 so the
    /// hash lookups never have to wrap an index by hand.
    private static let permutation: [Int] = {
        let base: [Int] = [
            151, 160, 137,  91,  90,  15, 131,  13, 201,  95,  96,  53, 194, 233,   7, 225,
            140,  36, 103,  30,  69, 142,   8,  99,  37, 240,  21,  10,  23, 190,   6, 148,
            247, 120, 234,  75,   0,  26, 197,  62,  94, 252, 219, 203, 117,  35,  11,  32,
             57, 177,  33,  88, 237, 149,  56,  87, 174,  20, 125, 136, 171, 168,  68, 175,
             74, 165,  71, 134, 139,  48,  27, 166,  77, 146, 158, 231,  83, 111, 229, 122,
             60, 211, 133, 230, 220, 105,  92,  41,  55,  46, 245,  40, 244, 102, 143,  54,
             65,  25,  63, 161,   1, 216,  80,  73, 209,  76, 132, 187, 208,  89,  18, 169,
            200, 196, 135, 130, 116, 188, 159,  86, 164, 100, 109, 198, 173, 186,   3,  64,
             52, 217, 226, 250, 124, 123,   5, 202,  38, 147, 118, 126, 255,  82,  85, 212,
            207, 206,  59, 227,  47,  16,  58,  17, 182, 189,  28,  42, 223, 183, 170, 213,
            119, 248, 152,   2,  44, 154, 163,  70, 221, 153, 101, 155, 167,  43, 172,   9,
            129,  22,  39, 253,  19,  98, 108, 110,  79, 113, 224, 232, 178, 185, 112, 104,
            218, 246,  97, 228, 251,  34, 242, 193, 238, 210, 144,  12, 191, 179, 162, 241,
             81,  51, 145, 235, 249,  14, 239, 107,  49, 192, 214,  31, 181, 199, 106, 157,
            184,  84, 204, 176, 115, 121,  50,  45, 127,   4, 150, 254, 138, 236, 205,  93,
            222, 114,  67,  29,  24,  72, 243, 141, 128, 195,  78,  66, 215,  61, 156, 180,
        ]
        return base + base
    }()

    // MARK: - Perlin

    /// Classic 3D Perlin noise. The result is bounded by [-1, 1], in practice
    /// it stays inside about +/- 0.96, and it is exactly 0 at every integer
    /// lattice point.
    ///
    /// Returns 0 for any non-finite coordinate: the inputs are derived from
    /// wallpaper JSON and from accumulated particle positions, either of which
    /// can go NaN, and a noise field that quietly flattens is far better than a
    /// trap in the middle of a frame.
    public static func perlin(_ x: Double, _ y: Double, _ z: Double) -> Double {
        guard x.isFinite, y.isFinite, z.isFinite else { return 0 }

        let xi = latticeIndex(x)
        let yi = latticeIndex(y)
        let zi = latticeIndex(z)

        // Fractional position inside the cell. For coordinates so large that a
        // Double has no fractional bits left this is 0, which is still a valid
        // (if boring) sample rather than a special case.
        let xf = x - floor(x)
        let yf = y - floor(y)
        let zf = z - floor(z)

        let u = fade(xf)
        let v = fade(yf)
        let w = fade(zf)

        let p = permutation
        let a = p[xi] + yi
        let aa = p[a] + zi
        let ab = p[a + 1] + zi
        let b = p[xi + 1] + yi
        let ba = p[b] + zi
        let bb = p[b + 1] + zi

        let x1 = lerp(u, grad(p[aa], xf, yf, zf),
                         grad(p[ba], xf - 1, yf, zf))
        let x2 = lerp(u, grad(p[ab], xf, yf - 1, zf),
                         grad(p[bb], xf - 1, yf - 1, zf))
        let y1 = lerp(v, x1, x2)

        let x3 = lerp(u, grad(p[aa + 1], xf, yf, zf - 1),
                         grad(p[ba + 1], xf - 1, yf, zf - 1))
        let x4 = lerp(u, grad(p[ab + 1], xf, yf - 1, zf - 1),
                         grad(p[bb + 1], xf - 1, yf - 1, zf - 1))
        let y2 = lerp(v, x3, x4)

        return lerp(w, y1, y2)
    }

    /// Three decorrelated Perlin samples forming a vector field. The offsets
    /// are the ones the reference renderers use; without them the three
    /// components would be identical and the curl below would be zero.
    public static func perlinVec3(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let x = Double(p.x), y = Double(p.y), z = Double(p.z)
        let a = perlin(x, y, z)
        let b = perlin(x + 89.2, y + 33.1, z + 57.3)
        let c = perlin(x + 100.3, y + 120.1, z + 142.2)
        return SIMD3<Float>(Float(a), Float(b), Float(c))
    }

    /// Curl of `perlinVec3`, sampled with central differences at epsilon 1e-4.
    ///
    /// The curl of any field is divergence free, which is what makes particles
    /// driven by it swirl and never pile up in sinks. The result is not
    /// normalised here because the `turbulence` operator normalises it itself
    /// before scaling by its speed.
    public static func curl(_ p: SIMD3<Float>) -> SIMD3<Float> {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return SIMD3<Float>(repeating: 0) }

        let e: Float = 1e-4
        let dx = SIMD3<Float>(e, 0, 0)
        let dy = SIMD3<Float>(0, e, 0)
        let dz = SIMD3<Float>(0, 0, e)

        let x0 = perlinVec3(p - dx), x1 = perlinVec3(p + dx)
        let y0 = perlinVec3(p - dy), y1 = perlinVec3(p + dy)
        let z0 = perlinVec3(p - dz), z1 = perlinVec3(p + dz)

        let cx = (y1.z - y0.z) - (z1.y - z0.y)
        let cy = (z1.x - z0.x) - (x1.z - x0.z)
        let cz = (x1.y - x0.y) - (y1.x - y0.x)

        let scale: Float = 1 / (2 * e)
        let out = SIMD3<Float>(cx, cy, cz) * scale
        guard out.x.isFinite, out.y.isFinite, out.z.isFinite else { return SIMD3<Float>(repeating: 0) }
        return out
    }

    // MARK: - Helpers

    /// Perlin's fade curve, t*t*t*(t*(t*6 - 15) + 10). Its first and second
    /// derivatives vanish at 0 and 1, which is why the lattice seams are
    /// invisible.
    private static func fade(_ t: Double) -> Double {
        t * t * t * (t * (t * 6 - 15) + 10)
    }

    private static func lerp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        a + t * (b - a)
    }

    /// The standard 16-case gradient: hash the corner, then dot the distance
    /// vector with one of the twelve cube-edge directions (four repeat, which
    /// is Perlin's own cheap way of keeping the case count a power of two).
    private static func grad(_ hash: Int, _ x: Double, _ y: Double, _ z: Double) -> Double {
        let h = hash & 15
        let u = h < 8 ? x : y
        let v = h < 4 ? y : (h == 12 || h == 14 ? x : z)
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
    }

    /// `Int(floor(v)) & 255`, computed so it cannot trap. `Int(_: Double)`
    /// traps on values outside Int's range, and particle positions can run
    /// away, so fold the coordinate into the table's period first: the noise
    /// is 256-periodic anyway, so this changes nothing for sane inputs.
    private static func latticeIndex(_ v: Double) -> Int {
        let folded = floor(v).truncatingRemainder(dividingBy: 256)
        guard folded.isFinite else { return 0 }
        return Int(folded) & 255
    }
}

/// A small seeded PRNG for the particle system.
///
/// Particle simulations draw several random numbers per spawned particle and
/// there can be twenty thousand of them, so `SystemRandomNumberGenerator` (a
/// syscall-backed CSPRNG) is both too slow and non-reproducible. This is
/// xorshift64* seeded through SplitMix64: a handful of ALU ops per draw, and
/// the same seed always replays the same simulation, which is what makes a
/// misbehaving wallpaper debuggable.
public struct FastRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        // SplitMix64 the seed so that adjacent seeds (0, 1, 2 ... which is how
        // per-emitter seeds tend to be handed out) do not produce correlated
        // streams. xorshift dies on a zero state, so refuse that one value.
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        state = z == 0 ? 0x9E37_79B9_7F4A_7C15 : z
    }

    /// Raw 64 bits. Public so `Int.random(in:using:)` and friends can be driven
    /// from this generator when a caller needs a distribution we do not have.
    public mutating func next() -> UInt64 {
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        return x &* 0x2545_F491_4F6C_DD1D
    }

    /// Uniform in [0, 1). Built from the top 24 bits, which is exactly the
    /// mantissa width of a Float, so every result is representable and the
    /// value 1.0 can never appear.
    public mutating func float() -> Float {
        Float(next() >> 40) * 0x1p-24
    }

    /// Uniform in [lo, hi). Order does not matter, and a non-finite bound
    /// yields the other bound (or 0) rather than a NaN that would spread
    /// through the whole particle's state.
    public mutating func float(_ lo: Float, _ hi: Float) -> Float {
        let t = float()
        switch (lo.isFinite, hi.isFinite) {
        case (true, true): return lo + (hi - lo) * t
        case (true, false): return lo
        case (false, true): return hi
        case (false, false): return 0
        }
    }

    /// Per-component `float(lo, hi)`, drawn x then y then z so the stream order
    /// matches the reference renderers' component-wise loops.
    public mutating func vector(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> SIMD3<Float> {
        let x = float(lo.x, hi.x)
        let y = float(lo.y, hi.y)
        let z = float(lo.z, hi.z)
        return SIMD3<Float>(x, y, z)
    }

    /// Normally distributed value via the Box-Muller transform. One of the two
    /// values the transform produces is used and the other discarded: keeping a
    /// spare would make the stream depend on how many draws came before, which
    /// costs more in reproducibility than it saves in arithmetic.
    public mutating func gaussian(mean: Float, deviation: Float) -> Float {
        // u1 must be strictly positive for the log.
        var u1 = float()
        if u1 <= 0 { u1 = Float.leastNormalMagnitude }
        let u2 = float()
        let radius = (-2 * Foundation.log(u1)).squareRoot()
        let angle = 2 * Float.pi * u2
        let z = radius * Foundation.cos(angle)
        let out = mean + deviation * z
        return out.isFinite ? out : mean
    }

    /// -1 or +1 with equal probability, for the "random sign per axis" rule the
    /// box emitter and several initializers use.
    public mutating func sign() -> Float {
        (next() & 1) == 0 ? -1 : 1
    }
}

// What a caller may rely on:
//
// * `Noise.perlin` is deterministic, has no state, and is safe to call from
//   several threads at once. Its range is [-1, 1], with observed extremes near
//   +/- 0.96; it is exactly 0 at integer lattice points, continuous with
//   continuous first and second derivatives, and 256-periodic on each axis.
// * `Noise.perlinVec3` and `Noise.curl` are likewise pure. `perlinVec3` has the
//   same per-component range as `perlin`. `curl` is a finite difference, so its
//   magnitude depends on how fast the field varies and it is NOT normalised or
//   bounded by 1; normalise it at the call site if you need a direction.
// * Any non-finite input to any of the three returns zero instead of trapping
//   or propagating NaN, and no input value can crash them.
// * `FastRandom` is fully deterministic: two instances built with the same seed
//   return identical sequences from every method, forever, and the sequence
//   depends only on the order and kind of calls made. It is a value type, so
//   copying one forks the stream rather than sharing it. It is NOT
//   cryptographically secure and must not be used for anything but simulation.
// * `float()` is in [0, 1), never 1. `float(lo, hi)` is in [lo, hi) for finite
//   bounds and never returns NaN. `sign()` returns exactly -1 or +1.
