import CryptoKit
import Foundation

/// scrypt (RFC 7914), the passphrase function of the age file format. PBKDF2-HMAC-SHA256 with one iteration around
/// ROMix with Salsa20/8, written here so the export needs no new dependency. Checked against the RFC's test vectors.
public enum Scrypt {
    public enum Failure: Error, Equatable {
        case parameters
    }

    /// The derived key. `logN` is log2 of the cost N; memory use is 128 · r · 2^logN bytes (256 MiB at logN 18, r 8).
    public static func derive(password: [UInt8], salt: [UInt8], logN: Int, r: Int, p: Int, length: Int) throws -> [UInt8] {
        guard (1...30).contains(logN), r > 0, p > 0, length > 0, r * p < 1 << 30 else { throw Failure.parameters }
        let n = 1 << logN
        let words = 32 * r   // 128·r bytes per block, as 32-bit words
        var b = pbkdf2(password: password, salt: salt, length: p * 128 * r)
        var x = [UInt32](repeating: 0, count: words)
        var y = [UInt32](repeating: 0, count: words)
        var v = [UInt32](repeating: 0, count: words * n)
        for i in 0..<p {
            let offset = i * 128 * r
            for k in 0..<words {
                let o = offset + 4 * k
                x[k] = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
            }
            x.withUnsafeMutableBufferPointer { xp in
                y.withUnsafeMutableBufferPointer { yp in
                    v.withUnsafeMutableBufferPointer { vp in
                        roMix(xp, yp, vp, n: n, r: r)
                    }
                }
            }
            for k in 0..<words {
                let o = offset + 4 * k
                b[o] = UInt8(truncatingIfNeeded: x[k])
                b[o + 1] = UInt8(truncatingIfNeeded: x[k] >> 8)
                b[o + 2] = UInt8(truncatingIfNeeded: x[k] >> 16)
                b[o + 3] = UInt8(truncatingIfNeeded: x[k] >> 24)
            }
        }
        return pbkdf2(password: password, salt: b, length: length)
    }

    /// PBKDF2-HMAC-SHA256 with one iteration (all scrypt uses).
    static func pbkdf2(password: [UInt8], salt: [UInt8], length: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var out: [UInt8] = []
        out.reserveCapacity(length + 32)
        var block: UInt32 = 1
        while out.count < length {
            var message = salt
            message += [UInt8(block >> 24), UInt8(truncatingIfNeeded: block >> 16), UInt8(truncatingIfNeeded: block >> 8), UInt8(truncatingIfNeeded: block)]
            out += Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
            block += 1
        }
        return Array(out.prefix(length))
    }

    private static func roMix(_ x: UnsafeMutableBufferPointer<UInt32>, _ y: UnsafeMutableBufferPointer<UInt32>,
                              _ v: UnsafeMutableBufferPointer<UInt32>, n: Int, r: Int) {
        let words = 32 * r
        for i in 0..<n {
            (v.baseAddress! + i * words).update(from: x.baseAddress!, count: words)
            blockMix(x, y, r: r)
        }
        for _ in 0..<n {
            let j = Int(x[(2 * r - 1) * 16] & UInt32(n - 1))
            let vj = v.baseAddress! + j * words
            for k in 0..<words { x[k] ^= vj[k] }
            blockMix(x, y, r: r)
        }
    }

    /// BlockMix: Y_i = Salsa20/8(Y_{i-1} ⊕ B_i), output the even Y's then the odd ones.
    private static func blockMix(_ b: UnsafeMutableBufferPointer<UInt32>, _ y: UnsafeMutableBufferPointer<UInt32>, r: Int) {
        var t = (UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0),
                 UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0))
        withUnsafeMutableBytes(of: &t) { raw in
            let x = raw.bindMemory(to: UInt32.self)
            let last = (2 * r - 1) * 16
            for k in 0..<16 { x[k] = b[last + k] }
            for i in 0..<(2 * r) {
                for k in 0..<16 { x[k] ^= b[i * 16 + k] }
                salsa20_8(x)
                // Even blocks to the first half, odd ones to the second.
                let to = (i / 2 + (i % 2) * r) * 16
                for k in 0..<16 { y[to + k] = x[k] }
            }
        }
        b.baseAddress!.update(from: y.baseAddress!, count: 32 * r)
    }

    @inline(__always)
    private static func rotl(_ v: UInt32, _ c: UInt32) -> UInt32 { (v << c) | (v >> (32 - c)) }

    private static func salsa20_8(_ b: UnsafeMutableBufferPointer<UInt32>) {
        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]
        for _ in 0..<4 {
            x4 ^= rotl(x0 &+ x12, 7); x8 ^= rotl(x4 &+ x0, 9); x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7); x13 ^= rotl(x9 &+ x5, 9); x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9); x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9); x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            x1 ^= rotl(x0 &+ x3, 7); x2 ^= rotl(x1 &+ x0, 9); x3 ^= rotl(x2 &+ x1, 13); x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7); x7 ^= rotl(x6 &+ x5, 9); x4 ^= rotl(x7 &+ x6, 13); x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9); x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9); x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
        }
        b[0] = b[0] &+ x0; b[1] = b[1] &+ x1; b[2] = b[2] &+ x2; b[3] = b[3] &+ x3
        b[4] = b[4] &+ x4; b[5] = b[5] &+ x5; b[6] = b[6] &+ x6; b[7] = b[7] &+ x7
        b[8] = b[8] &+ x8; b[9] = b[9] &+ x9; b[10] = b[10] &+ x10; b[11] = b[11] &+ x11
        b[12] = b[12] &+ x12; b[13] = b[13] &+ x13; b[14] = b[14] &+ x14; b[15] = b[15] &+ x15
    }
}
