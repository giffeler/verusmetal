import Foundation

/// Reusable CPU hash state for tests and callers that own one serial worker.
/// Share the input value between workers; create a separate instance per worker.
public final class PreparedVerusHash {
    public let usesCachedHash: Bool
    private let input: [UInt8]
    private let nonceOffset: Int
    private let nonceBytes: Int
    private let prepared: UnsafeMutableRawPointer
    private let scratch: UnsafeMutableRawPointer
    private let output: UnsafeMutableRawPointer
    private let size: Int

    public init(input: [UInt8], nonceOffset: Int, nonceBytes: Int) throws {
        guard input.count <= 4096, (0...8).contains(nonceBytes), nonceOffset >= 0,
              nonceOffset <= input.count, nonceBytes <= input.count-nonceOffset
        else { throw VerusError.invalid("Invalid prepared hash layout") }
        prepared = .allocate(byteCount: 8896, alignment: 16)
        scratch = .allocate(byteCount: 8896, alignment: 16)
        output = .allocate(byteCount: 32, alignment: 16)
        self.input = input.isEmpty ? [0] : input
        self.size = input.count
        self.nonceOffset = nonceOffset; self.nonceBytes = nonceBytes
        usesCachedHash = nonceBytes == 0 || nonceOffset >= (input.count/32)*32
        self.input.withUnsafeBufferPointer {
            vm_cpu_prepare($0.baseAddress!, UInt32(input.count), prepared)
        }
    }
    deinit { prepared.deallocate(); scratch.deallocate(); output.deallocate() }

    public func digest(nonce: UInt64 = 0) throws -> [UInt8] {
        if nonceBytes > 0 && nonceBytes < 8 && nonce >= UInt64(1) << (8*nonceBytes) {
            throw VerusError.invalid("Nonce exceeds solution space")
        }
        let mode = input.withUnsafeBufferPointer {
            vm_cpu_finish_nonce($0.baseAddress!, UInt32(size), UInt32(nonceOffset),
                                UInt32(nonceBytes), nonce, prepared, scratch,
                                output.assumingMemoryBound(to: UInt8.self))
        }
        guard mode >= 0 else { throw VerusError.invalid("Invalid prepared hash layout") }
        return Array(UnsafeBufferPointer(start: output.assumingMemoryBound(to: UInt8.self), count: 32))
    }
}
