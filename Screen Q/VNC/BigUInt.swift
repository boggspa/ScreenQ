//
//  BigUInt.swift
//  Screen Q
//
//  Minimal arbitrary-precision unsigned integer for Diffie-Hellman key exchange.
//  Supports init from big-endian Data, modular exponentiation, and basic
//  arithmetic. Used exclusively by Apple DH authentication (type 30).
//

import Foundation

nonisolated struct BigUInt: Equatable, Comparable, Sendable {

    /// Little-endian UInt32 limbs (limbs[0] = least significant).
    var limbs: [UInt32]

    // MARK: - Init

    init() { limbs = [] }

    init(_ v: UInt64) {
        if v == 0 { limbs = [] }
        else if v <= UInt64(UInt32.max) { limbs = [UInt32(v)] }
        else { limbs = [UInt32(v & 0xFFFF_FFFF), UInt32(v >> 32)] }
    }

    /// Init from big-endian byte data.
    init(data: Data) {
        let count = data.count
        let limbCount = (count + 3) / 4
        limbs = [UInt32](repeating: 0, count: limbCount)
        for i in 0..<count {
            let byteIndex = count - 1 - i
            let limbIndex = i / 4
            let shift = (i % 4) * 8
            limbs[limbIndex] |= UInt32(data[data.startIndex + byteIndex]) << shift
        }
        trimLeadingZeros()
    }

    /// Export as big-endian byte data, zero-padded to `size` bytes.
    func toData(size: Int) -> Data {
        var result = Data(count: size)
        for i in 0..<size {
            let byteIndex = size - 1 - i
            let limbIndex = i / 4
            let shift = (i % 4) * 8
            if limbIndex < limbs.count {
                result[byteIndex] = UInt8((limbs[limbIndex] >> shift) & 0xFF)
            }
        }
        return result
    }

    // MARK: - Properties

    var isZero: Bool { limbs.isEmpty || limbs.allSatisfy { $0 == 0 } }

    var bitWidth: Int {
        guard let last = limbs.last, last != 0 else { return 0 }
        return (limbs.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool {
        let limbIdx = i / 32
        let bitIdx = i % 32
        guard limbIdx < limbs.count else { return false }
        return (limbs[limbIdx] >> bitIdx) & 1 == 1
    }

    mutating func trimLeadingZeros() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    // MARK: - Comparison

    nonisolated static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        let lc = lhs.limbs.count
        let rc = rhs.limbs.count
        if lc != rc { return lc < rc }
        if lc == 0 { return false }
        for i in stride(from: lc - 1, through: 0, by: -1) {
            if lhs.limbs[i] != rhs.limbs[i] { return lhs.limbs[i] < rhs.limbs[i] }
        }
        return false
    }

    nonisolated static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        lhs.limbs == rhs.limbs
    }

    // MARK: - Addition

    nonisolated static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let maxLen = max(lhs.limbs.count, rhs.limbs.count)
        var result = [UInt32](repeating: 0, count: maxLen + 1)
        var carry: UInt64 = 0
        for i in 0..<maxLen {
            let a = i < lhs.limbs.count ? UInt64(lhs.limbs[i]) : 0
            let b = i < rhs.limbs.count ? UInt64(rhs.limbs[i]) : 0
            let sum = a + b + carry
            result[i] = UInt32(sum & 0xFFFF_FFFF)
            carry = sum >> 32
        }
        result[maxLen] = UInt32(carry)
        var r = BigUInt()
        r.limbs = result
        r.trimLeadingZeros()
        return r
    }

    // MARK: - Subtraction (assumes lhs >= rhs)

    nonisolated static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt32](repeating: 0, count: lhs.limbs.count)
        var borrow: UInt64 = 0
        for i in 0..<lhs.limbs.count {
            let a = UInt64(lhs.limbs[i])
            let b = (i < rhs.limbs.count ? UInt64(rhs.limbs[i]) : 0) + borrow
            if a >= b {
                result[i] = UInt32(a - b)
                borrow = 0
            } else {
                result[i] = UInt32(0x1_0000_0000 + a - b)
                borrow = 1
            }
        }
        var r = BigUInt()
        r.limbs = result
        r.trimLeadingZeros()
        return r
    }

    // MARK: - Multiplication (schoolbook)

    nonisolated static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt() }
        let n = lhs.limbs.count + rhs.limbs.count
        var result = [UInt32](repeating: 0, count: n)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.limbs.count {
                let prod = UInt64(lhs.limbs[i]) * UInt64(rhs.limbs[j])
                             + UInt64(result[i + j]) + carry
                result[i + j] = UInt32(prod & 0xFFFF_FFFF)
                carry = prod >> 32
            }
            var k = rhs.limbs.count
            while carry > 0 && (i + k) < n {
                let sum = UInt64(result[i + k]) + carry
                result[i + k] = UInt32(sum & 0xFFFF_FFFF)
                carry = sum >> 32
                k += 1
            }
        }
        var r = BigUInt()
        r.limbs = result
        r.trimLeadingZeros()
        return r
    }

    // MARK: - Shift left by 1 bit

    func shiftedLeft1() -> BigUInt {
        guard !isZero else { return self }
        var result = [UInt32](repeating: 0, count: limbs.count + 1)
        var carry: UInt32 = 0
        for i in 0..<limbs.count {
            result[i] = (limbs[i] << 1) | carry
            carry = limbs[i] >> 31
        }
        result[limbs.count] = carry
        var r = BigUInt()
        r.limbs = result
        r.trimLeadingZeros()
        return r
    }

    // MARK: - Division / modulo (binary long division)

    func quotientAndRemainder(dividingBy d: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!d.isZero, "Division by zero")
        if self < d { return (BigUInt(), self) }
        if self == d { return (BigUInt(1), BigUInt()) }

        let bits = self.bitWidth
        var qLimbs = [UInt32](repeating: 0, count: (bits + 31) / 32)
        var r = BigUInt()

        for i in stride(from: bits - 1, through: 0, by: -1) {
            r = r.shiftedLeft1()
            if self.bit(i) {
                if r.limbs.isEmpty { r.limbs = [1] }
                else { r.limbs[0] |= 1 }
            }
            if !(r < d) {
                r = r - d
                qLimbs[i / 32] |= UInt32(1) << (i % 32)
            }
        }

        var q = BigUInt()
        q.limbs = qLimbs
        q.trimLeadingZeros()
        r.trimLeadingZeros()
        return (q, r)
    }

    nonisolated static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    // MARK: - Modular exponentiation

    nonisolated static func modpow(_ base: BigUInt, _ exp: BigUInt, _ mod: BigUInt) -> BigUInt {
        guard !mod.isZero else { return BigUInt() }
        if exp.isZero { return BigUInt(1) }
        if mod.limbs.first.map({ $0 & 1 == 1 }) == true {
            return MontgomeryContext(modulus: mod).pow(base: base, exponent: exp)
        }

        var result = BigUInt(1)
        var b = base % mod
        let bits = exp.bitWidth

        for i in 0..<bits {
            if exp.bit(i) {
                result = (result * b) % mod
            }
            b = (b * b) % mod
        }
        return result
    }

    private struct MontgomeryContext {
        let modulus: BigUInt
        let n: Int
        let modulusLimbs: [UInt32]
        let negInverse: UInt32
        let rMod: BigUInt
        let rSquaredMod: BigUInt

        init(modulus: BigUInt) {
            self.modulus = modulus
            self.n = max(1, modulus.limbs.count)
            self.modulusLimbs = modulus.limbs
            self.negInverse = 0 &- Self.inverseModWord(modulus.limbs.first ?? 1)
            self.rMod = Self.powerOfBaseModulo(limbCount: max(1, modulus.limbs.count), multiplier: 1, modulus: modulus)
            self.rSquaredMod = Self.powerOfBaseModulo(limbCount: max(1, modulus.limbs.count), multiplier: 2, modulus: modulus)
        }

        func pow(base: BigUInt, exponent: BigUInt) -> BigUInt {
            var result = rMod
            var b = toMontgomery(base < modulus ? base : base % modulus)
            let bits = exponent.bitWidth

            for i in 0..<bits {
                if exponent.bit(i) {
                    result = multiply(result, b)
                }
                b = multiply(b, b)
            }

            return fromMontgomery(result)
        }

        private func toMontgomery(_ value: BigUInt) -> BigUInt {
            multiply(value, rSquaredMod)
        }

        private func fromMontgomery(_ value: BigUInt) -> BigUInt {
            reduce(value.limbs)
        }

        private func multiply(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt {
            reduce((lhs * rhs).limbs)
        }

        private func reduce(_ input: [UInt32]) -> BigUInt {
            var t = input
            let minimumCount = (2 * n) + 2
            if t.count < minimumCount {
                t.append(contentsOf: repeatElement(0, count: minimumCount - t.count))
            } else {
                t.append(contentsOf: [0, 0])
            }

            for i in 0..<n {
                let u = t[i] &* negInverse
                var carry: UInt64 = 0

                for j in 0..<n {
                    let index = i + j
                    let product = UInt64(u) * UInt64(modulusLimbs[j])
                        + UInt64(t[index])
                        + carry
                    t[index] = UInt32(product & 0xFFFF_FFFF)
                    carry = product >> 32
                }

                var index = i + n
                var sum = UInt64(t[index]) + carry
                t[index] = UInt32(sum & 0xFFFF_FFFF)
                carry = sum >> 32
                index += 1

                while carry > 0 {
                    if index >= t.count {
                        t.append(0)
                    }
                    sum = UInt64(t[index]) + carry
                    t[index] = UInt32(sum & 0xFFFF_FFFF)
                    carry = sum >> 32
                    index += 1
                }
            }

            var result = BigUInt()
            result.limbs = Array(t.dropFirst(n))
            result.trimLeadingZeros()
            while !(result < modulus) {
                result = result - modulus
            }
            return result
        }

        private static func inverseModWord(_ value: UInt32) -> UInt32 {
            var inverse: UInt32 = 1
            for _ in 0..<5 {
                inverse = inverse &* (2 &- value &* inverse)
            }
            return inverse
        }

        private static func powerOfBaseModulo(limbCount: Int, multiplier: Int, modulus: BigUInt) -> BigUInt {
            var result = BigUInt(1)
            for _ in 0..<(32 * limbCount * multiplier) {
                result = result.shiftedLeft1()
                if !(result < modulus) {
                    result = result - modulus
                }
            }
            return result
        }
    }
}
