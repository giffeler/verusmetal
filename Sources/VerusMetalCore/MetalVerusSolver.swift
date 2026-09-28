import Foundation
import Metal

public enum VerusHash {
    public static func digest(_ bytes: [UInt8]) -> [UInt8] {
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: 8896, alignment: 16)
        let output = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 16)
        defer { scratch.deallocate(); output.deallocate() }
        var length = UInt32(bytes.count)
        let storage = bytes.isEmpty ? [UInt8(0)] : bytes
        storage.withUnsafeBufferPointer { raw in
            vm_cpu_hashes(raw.baseAddress!, &length, max(1,length), 1,
                          output.assumingMemoryBound(to: UInt8.self), scratch)
        }
        return Array(UnsafeBufferPointer(start: output.assumingMemoryBound(to: UInt8.self), count: 32))
    }
    public static func meetsTarget(_ digest: [UInt8], _ target: UInt256) -> Bool {
        digest.count == 32 && UInt256(bigEndian: Array(digest.reversed())) <= target
    }
}

public struct GPUDeviceInfo: Codable, Sendable {
    public let name: String
    public let unifiedMemory: Bool
    public let recommendedWorkingSetBytes: UInt64
}
public struct Candidate: Sendable { public let nonce: UInt64; public let digest: [UInt8] }
public struct SearchBatch: Sendable {
    public let nonceCount: Int
    public let gpuSeconds: Double
    public let wallStartTime: Double
    public let wallEndTime: Double
    public let candidates: [Candidate]
}
private struct SearchParameters {
    var firstNonce: UInt64
    var count: UInt32
    var stride: UInt32
    var inputSize: UInt32
    var nonceOffset: UInt32
    var nonceBytes: UInt32
}

/// One synchronous command at a time; owned by the mining thread.
public final class MetalVerusSolver {
    public let device: any MTLDevice
    public let batchSize: Int
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let cachedPipeline: any MTLComputePipelineState
    private let prepared: any MTLBuffer
    public private(set) var usesCachedHash = false
    private var input: (any MTLBuffer)?
    private let output: any MTLBuffer
    private var scratch: (any MTLBuffer)?
    private let matches: any MTLBuffer
    private let target: any MTLBuffer
    private var preparedGeneration: UInt64?
    private var preparedInput: [UInt8] = []
    private var inputStride = 0
    private var preparedNonceOffset = -1
    private var preparedNonceBytes = -1

    public static func devices() -> [GPUDeviceInfo] {
        MTLCopyAllDevices().map { GPUDeviceInfo(name: $0.name, unifiedMemory: $0.hasUnifiedMemory,
                                               recommendedWorkingSetBytes: $0.recommendedMaxWorkingSetSize) }
    }
    public init(batchSize: Int = 32768, validation: Bool = false) throws {
        guard (1...32768).contains(batchSize), let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw VerusError.invalid("Invalid batch size or Metal unavailable") }
        self.device = device; self.queue = queue; self.batchSize = batchSize
        let library: any MTLLibrary
        if let embedded = embeddedMetalLibraryData() { library = try device.makeLibrary(data: embedded) }
        else { throw VerusError.invalid("Embedded Metal library missing") }
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = library.makeFunction(name: "verus_search")
        descriptor.maxTotalThreadsPerThreadgroup = 128
        descriptor.shaderValidation = validation ? .enabled : .disabled
        pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        descriptor.computeFunction = library.makeFunction(name: "verus_search_cached")
        cachedPipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        func buffer(_ size: Int) throws -> any MTLBuffer {
            guard let b = device.makeBuffer(length: size, options: .storageModeShared)
            else { throw VerusError.invalid("Metal buffer allocation failed") }
            return b
        }
        output = try buffer(batchSize*32); prepared = try buffer(8896)
        matches = try buffer(batchSize*4); target = try buffer(32)
    }

    public func search(job: VerusStratumJob, firstNonce: UInt64, count: Int? = nil) throws -> SearchBatch {
        try search(input: job.hashInput, nonceOffset: job.nonceOffset, nonceBytes: job.nonceBytes,
                   target: job.target, generation: job.generation, firstNonce: firstNonce, count: count)
    }

    public func search(input bytes: [UInt8], nonceOffset: Int, nonceBytes: Int, target threshold: UInt256,
                       generation: UInt64 = 0, firstNonce: UInt64 = 0, count requested: Int? = nil) throws -> SearchBatch {
        let count = requested ?? batchSize
        guard (1...batchSize).contains(count), bytes.count <= 4096, (0...8).contains(nonceBytes),
              nonceOffset >= 0, nonceOffset <= bytes.count, nonceBytes <= bytes.count-nonceOffset,
              firstNonce <= UInt64.max-UInt64(count-1)
        else { throw VerusError.invalid("Invalid search range") }
        if nonceBytes > 0 && nonceBytes < 8 {
            guard firstNonce+UInt64(count-1) < UInt64(1) << (8*nonceBytes)
            else { throw VerusError.invalid("Nonce range exceeds solution space") }
        }
        if preparedGeneration != generation || preparedInput != bytes || preparedNonceOffset != nonceOffset || preparedNonceBytes != nonceBytes {
            let cached = nonceBytes == 0 || nonceOffset >= (bytes.count/32)*32
            let requiredScratch = batchSize * (cached ? 8192 : 8896)
            var nextScratch = scratch
            if nextScratch?.length != requiredScratch {
                guard let buffer = device.makeBuffer(length: requiredScratch, options: .storageModeShared)
                else { throw VerusError.invalid("Workspace allocation failed") }
                nextScratch = buffer
            }
            let nextInput: (any MTLBuffer)?
            let nextStride: Int
            if cached {
                let storage = bytes.isEmpty ? [UInt8(0)] : bytes
                storage.withUnsafeBufferPointer {
                    vm_cpu_prepare($0.baseAddress!, UInt32(bytes.count), prepared.contents())
                }
                nextInput = nil
                nextStride = 0
            } else {
                // A nonce in a full block changes the absorbed seed and key.
                // Keep the complete reference path; expose the mode to callers.
                nextStride = max(16,(bytes.count+15) & ~15)
                guard let buffer = device.makeBuffer(length: nextStride*batchSize, options: .storageModeShared)
                else { throw VerusError.invalid("Input buffer allocation failed") }
                memset(buffer.contents(), 0, buffer.length)
                bytes.withUnsafeBytes { raw in
                    if let base = raw.baseAddress, !bytes.isEmpty {
                        for i in 0..<batchSize { memcpy(buffer.contents()+i*nextStride, base, bytes.count) }
                    }
                }
                nextInput = buffer
            }
            // Commit preparation only after every allocation succeeds.
            input = nextInput; inputStride = nextStride; scratch = nextScratch
            usesCachedHash = cached
            preparedInput = bytes; preparedGeneration = generation
            preparedNonceOffset = nonceOffset; preparedNonceBytes = nonceBytes
        }
        let targetBytes = Array(threshold.bigEndianBytes.reversed())
        targetBytes.withUnsafeBytes { _ = memcpy(target.contents(), $0.baseAddress!, 32) }
        var parameters = SearchParameters(firstNonce: firstNonce, count: UInt32(count), stride: UInt32(inputStride),
                                          inputSize: UInt32(bytes.count), nonceOffset: UInt32(nonceOffset), nonceBytes: UInt32(nonceBytes))
        let start = ProcessInfo.processInfo.systemUptime
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { throw VerusError.invalid("Metal command allocation failed") }
        encoder.setComputePipelineState(usesCachedHash ? cachedPipeline : pipeline)
        for (i,b) in [usesCachedHash ? prepared : input!,output,scratch!,matches,target].enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        encoder.setBytes(&parameters, length: MemoryLayout<SearchParameters>.stride, index: 5)
        encoder.dispatchThreadgroups(MTLSize(width: (count+127)/128, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        let end = ProcessInfo.processInfo.systemUptime
        guard command.status == .completed else { throw VerusError.invalid("Metal execution failed: \(String(describing: command.error))") }
        var candidates: [Candidate] = []
        let flags = matches.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<count where flags[i] != 0 {
            let bytes = output.contents().advanced(by:i*32).assumingMemoryBound(to: UInt8.self)
            candidates.append(Candidate(nonce: firstNonce+UInt64(i), digest: Array(UnsafeBufferPointer(start: bytes, count: 32))))
        }
        return SearchBatch(nonceCount: count, gpuSeconds: command.gpuEndTime-command.gpuStartTime,
                           wallStartTime: start, wallEndTime: end, candidates: candidates)
    }
}
