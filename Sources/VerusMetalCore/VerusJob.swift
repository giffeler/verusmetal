import Foundation
import CryptoKit

public enum VerusError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let reason): return reason } }
}

public struct VerusStratumJob: Sendable {
    public let generation: UInt64
    public let id: String
    public let target: UInt256
    public let cleanJobs: Bool
    public let extraNoncePrefix: [UInt8]
    public let timeHex: String
    public let header: [UInt8]
    public let solution: [UInt8]
    public let hashInput: [UInt8]
    public let nonceOffset: Int
    public let nonceBytes: Int
    public let receivedAt: Date

    public var maximumNonce: UInt64 { nonceBytes == 8 ? .max : (UInt64(1) << (nonceBytes * 8)) - 1 }

    public static func decode(_ params: [Any], generation: UInt64, prefix: [UInt8], target: UInt256) throws -> Self {
        guard params.count == 9, let id = params[0] as? String, !id.isEmpty, id.utf8.count <= 256,
              let clean = params[7] as? Bool, !prefix.isEmpty, prefix.count <= 14, target != .zero
        else { throw VerusError.invalid("Unsupported Verus notify layout") }
        let sizes = [4, 32, 32, 32, 4, 4]
        var header: [UInt8] = []
        for (index, size) in sizes.enumerated() {
            guard let text = params[index+1] as? String, let bytes = [UInt8](hex: text), bytes.count == size
            else { throw VerusError.invalid("Invalid block header field \(index+1)") }
            header += bytes
        }
        guard header.prefix(4).elementsEqual([4,0,1,0]),
              let text = params[8] as? String, let reserved = [UInt8](hex: text),
              !reserved.isEmpty, reserved.count <= 1329
        else { throw VerusError.invalid("Unsupported block version or solution size") }
        let versionBytes = Array((reserved + [0,0,0,0]).prefix(4))
        let version = UInt32(versionBytes[0]) | UInt32(versionBytes[1]) << 8 | UInt32(versionBytes[2]) << 16 | UInt32(versionBytes[3]) << 24
        // Solution v8 hardens PBaaS proofs; the v2.2 hash and header layout are unchanged.
        guard (4...8).contains(version) else { throw VerusError.invalid("Unsupported solution version \(version)") }
        // Preserve the pool's reserved solution; only the last 15 bytes are nonce space.
        var solution = reserved + [UInt8](repeating: 0, count: 1344-reserved.count)
        solution.replaceSubrange(1329..<1329+prefix.count, with: prefix)
        header += prefix + [UInt8](repeating: 0, count: 32-prefix.count)
        var input = header + [0xfd,0x40,0x05] + solution
        if version >= 7 {
            let chains = Int(solution[5])
            let extraDataSize = Int(solution[6]) | Int(solution[7]) << 8
            // The descriptor counts extra payload bytes, not free nonce space.
            // Reserved bytes may omit trailing zeros; padding restores that payload.
            guard chains > 0, 72 + chains*52 <= reserved.count,
                  72 + chains*52 + extraDataSize <= 1329
            else { throw VerusError.invalid("Unsupported PBaaS solution descriptor") }
            // PBaaS commitments stay intact; only the non-canonical hash view is cleared.
            for range in [4..<100, 104..<140, 151..<215] {
                input.replaceSubrange(range, with: repeatElement(UInt8(0), count: range.count))
            }
        }
        return Self(generation: generation, id: id, target: target, cleanJobs: clean,
                    extraNoncePrefix: prefix, timeHex: (params[5] as! String).lowercased(),
                    header: header, solution: solution, hashInput: input,
                    nonceOffset: 143+1329+prefix.count, nonceBytes: min(8,15-prefix.count), receivedAt: Date())
    }

    public func input(nonce: UInt64) throws -> [UInt8] {
        guard nonce <= maximumNonce else { throw VerusError.invalid("Nonce space exhausted") }
        var bytes = hashInput
        for i in 0..<nonceBytes { bytes[nonceOffset+i] = UInt8(truncatingIfNeeded: nonce >> (8*i)) }
        return bytes
    }

    public func submission(user: String, nonce: UInt64) throws -> [String] {
        guard nonce <= maximumNonce else { throw VerusError.invalid("Nonce space exhausted") }
        var bytes = solution
        for i in 0..<nonceBytes { bytes[nonceOffset-143+i] = UInt8(truncatingIfNeeded: nonce >> (8*i)) }
        return [user, id, timeHex, Array(header[108+extraNoncePrefix.count..<140]).hex,
                ([0xfd,0x40,0x05]+bytes).hex]
    }
}

public enum VerusAddress {
    public static func isValid(_ text: String) -> Bool {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        guard (26...36).contains(text.count) else { return false }
        var bytes = [UInt8](repeating: 0, count: 1)
        for character in text {
            guard let digit = alphabet.firstIndex(of: character) else { return false }
            var carry = digit
            for i in bytes.indices.reversed() {
                carry += Int(bytes[i])*58; bytes[i] = UInt8(carry & 255); carry >>= 8
            }
            while carry > 0 { bytes.insert(UInt8(carry & 255), at: 0); carry >>= 8 }
        }
        bytes = [UInt8](repeating: 0, count: text.prefix(while: {$0 == "1"}).count) + bytes
        guard bytes.count == 25, bytes[0] == 60 || bytes[0] == 102 else { return false }
        let checksum = SHA256.hash(data: Data(SHA256.hash(data: Data(bytes.prefix(21)))))
        return bytes.suffix(4).elementsEqual(checksum.prefix(4))
    }
}
