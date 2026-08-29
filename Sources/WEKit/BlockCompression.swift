import Foundation

/// CPU decoders for BC1/BC2/BC3 (DXT1/3/5), used for thumbnails and as a
/// fallback when the GPU cannot sample compressed formats.
public enum BlockCompression {
    public static func decodeToRGBA8(_ data: Data, width: Int, height: Int, layout: WEPixelLayout) -> Data? {
        guard let outputCount = WEPixelLayout.rgba8.checkedByteCount(width: width, height: height),
              outputCount <= WEPixelLayout.maximumAllocationByteCount else { return nil }
        switch layout {
        case .bc1: return decode(data, width: width, height: height, blockSize: 8, hasAlphaBlock: false, alphaIsBC3: false)
        case .bc2: return decode(data, width: width, height: height, blockSize: 16, hasAlphaBlock: true, alphaIsBC3: false)
        case .bc3: return decode(data, width: width, height: height, blockSize: 16, hasAlphaBlock: true, alphaIsBC3: true)
        case .rgba8:
            guard data.count >= outputCount else { return nil }
            return Data(data.prefix(outputCount))
        case .rg8:
            guard let inputCount = layout.checkedByteCount(width: width, height: height), data.count >= inputCount else { return nil }
            let pixelCount = outputCount / 4
            var out = Data(count: outputCount)
            out.withUnsafeMutableBytes { o in
                data.withUnsafeBytes { s in
                    let sp = s.bindMemory(to: UInt8.self), op = o.bindMemory(to: UInt8.self)
                    for i in 0..<pixelCount {
                        op[i * 4] = sp[i * 2]; op[i * 4 + 1] = sp[i * 2]; op[i * 4 + 2] = sp[i * 2]; op[i * 4 + 3] = sp[i * 2 + 1]
                    }
                }
            }
            return out
        case .r8:
            guard let inputCount = layout.checkedByteCount(width: width, height: height), data.count >= inputCount else { return nil }
            let pixelCount = outputCount / 4
            var out = Data(count: outputCount)
            out.withUnsafeMutableBytes { o in
                data.withUnsafeBytes { s in
                    let sp = s.bindMemory(to: UInt8.self), op = o.bindMemory(to: UInt8.self)
                    for i in 0..<pixelCount {
                        op[i * 4] = 255; op[i * 4 + 1] = 255; op[i * 4 + 2] = 255; op[i * 4 + 3] = sp[i]
                    }
                }
            }
            return out
        case .bc7:
            return nil
        }
    }

    private static func decode(_ data: Data, width: Int, height: Int, blockSize: Int, hasAlphaBlock: Bool, alphaIsBC3: Bool) -> Data? {
        guard width > 0, height > 0,
              let inputCount = (blockSize == 8 ? WEPixelLayout.bc1 : WEPixelLayout.bc3).checkedByteCount(width: width, height: height),
              let outputCount = WEPixelLayout.rgba8.checkedByteCount(width: width, height: height),
              outputCount <= WEPixelLayout.maximumAllocationByteCount,
              data.count >= inputCount else { return nil }
        let bw = (width - 1) / 4 + 1, bh = (height - 1) / 4 + 1
        var out = Data(count: outputCount)
        out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { s in
                let sp = s.bindMemory(to: UInt8.self), op = o.bindMemory(to: UInt8.self)
                for by in 0..<bh {
                    for bx in 0..<bw {
                        let base = (by * bw + bx) * blockSize
                        var alpha = [UInt8](repeating: 255, count: 16)
                        var colorBase = base
                        if hasAlphaBlock {
                            colorBase = base + 8
                            if alphaIsBC3 {
                                let a0 = sp[base], a1 = sp[base + 1]
                                var table = [UInt8](repeating: 0, count: 8)
                                table[0] = a0; table[1] = a1
                                if a0 > a1 {
                                    for i in 1...6 { table[i + 1] = UInt8((Int(a0) * (7 - i) + Int(a1) * i) / 7) }
                                } else {
                                    for i in 1...4 { table[i + 1] = UInt8((Int(a0) * (5 - i) + Int(a1) * i) / 5) }
                                    table[6] = 0; table[7] = 255
                                }
                                var bits: UInt64 = 0
                                for i in 0..<6 { bits |= UInt64(sp[base + 2 + i]) << (8 * UInt64(i)) }
                                for i in 0..<16 { alpha[i] = table[Int((bits >> (3 * UInt64(i))) & 7)] }
                            } else {
                                for i in 0..<16 {
                                    let byte = sp[base + i / 2]
                                    let nib = (i % 2 == 0) ? (byte & 0xF) : (byte >> 4)
                                    alpha[i] = nib * 17
                                }
                            }
                        }
                        let c0 = UInt16(sp[colorBase]) | (UInt16(sp[colorBase + 1]) << 8)
                        let c1 = UInt16(sp[colorBase + 2]) | (UInt16(sp[colorBase + 3]) << 8)
                        func rgb(_ c: UInt16) -> (Int, Int, Int) {
                            let r = Int((c >> 11) & 31), g = Int((c >> 5) & 63), b = Int(c & 31)
                            return ((r * 255 + 15) / 31, (g * 255 + 31) / 63, (b * 255 + 15) / 31)
                        }
                        let (r0, g0, b0) = rgb(c0), (r1, g1, b1) = rgb(c1)
                        var palette = [(r0, g0, b0, 255), (r1, g1, b1, 255), (0, 0, 0, 255), (0, 0, 0, 255)]
                        if c0 > c1 || hasAlphaBlock {
                            palette[2] = ((2 * r0 + r1) / 3, (2 * g0 + g1) / 3, (2 * b0 + b1) / 3, 255)
                            palette[3] = ((r0 + 2 * r1) / 3, (g0 + 2 * g1) / 3, (b0 + 2 * b1) / 3, 255)
                        } else {
                            palette[2] = ((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2, 255)
                            palette[3] = (0, 0, 0, 0)
                        }
                        let indices = UInt32(sp[colorBase + 4]) | (UInt32(sp[colorBase + 5]) << 8) | (UInt32(sp[colorBase + 6]) << 16) | (UInt32(sp[colorBase + 7]) << 24)
                        for py in 0..<4 {
                            let y = by * 4 + py
                            guard y < height else { continue }
                            for px in 0..<4 {
                                let x = bx * 4 + px
                                guard x < width else { continue }
                                let i = py * 4 + px
                                let (r, g, b, a) = palette[Int((indices >> (2 * UInt32(i))) & 3)]
                                let o = (y * width + x) * 4
                                op[o] = UInt8(r); op[o + 1] = UInt8(g); op[o + 2] = UInt8(b)
                                op[o + 3] = hasAlphaBlock ? alpha[i] : UInt8(a)
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}
