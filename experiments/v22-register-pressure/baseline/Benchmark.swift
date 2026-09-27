import Foundation
import Metal
import Darwin

enum BenchError: Error, CustomStringConvertible {
    case failure(String)
    var description: String { switch self { case .failure(let text): text } }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw BenchError.failure(message) }
}
func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw BenchError.failure(message) }
    return value
}

struct Fixture: Decodable { let input: String; let digest: String }
struct FixtureFile: Decodable { let algorithm: String; let revision: String; let vectors: [Fixture] }
struct Sample: Codable {
    let path: String
    let seconds: Double
    let mhs: Double
    let thermalState: Int
}
struct Report: Codable {
    let algorithm: String
    let device: String
    let os: String
    let count: Int
    let inputBytes: Int
    let scratchBytesPerHash: Int
    let threadgroupSize: Int
    let pipelineThreadLimit: Int
    let executionWidth: Int
    let lowPowerMode: Bool
    let validatedFixtures: Int
    let referenceRevision: String
    let medianCPU: Double
    let medianGPU: Double
    let medianEndToEnd: Double
    let samples: [Sample]
}

func decodeHex(_ text: String) throws -> [UInt8] {
    let digits = Array(text.utf8)
    try require(digits.count % 2 == 0, "Odd hexadecimal length")
    func nibble(_ byte: UInt8) throws -> UInt8 {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 87
        default: throw BenchError.failure("Invalid hexadecimal fixture")
        }
    }
    var result = [UInt8](); result.reserveCapacity(digits.count/2)
    for i in stride(from: 0, to: digits.count, by: 2) {
        result.append(try nibble(digits[i]) << 4 | nibble(digits[i+1]))
    }
    return result
}

// Swift 6.4 RawSpan loads keep digest inspection bounds checked. The only unsafe
// boundary is the Metal buffer mapping, whose owner outlives this call.
func digestHex(_ buffer: any MTLBuffer, at index: Int) -> String {
    let raw = UnsafeRawBufferPointer(start: buffer.contents()+index*32, count: 32)
    let bytes = RawSpan(_unsafeBytes: raw)
    var result = ""
    for offset in 0..<32 { result += String(format: "%02x", bytes.load(fromByteOffset: offset, as: UInt8.self)) }
    return result
}

final class Engine {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLComputePipelineState
    let groupSize = 128
    let scratchPerHash = 556 * 16
    let validation: Bool

    init(validation: Bool) throws {
        self.validation = validation
        device = try unwrap(MTLCreateSystemDefaultDevice(), "Metal device unavailable")
        queue = try unwrap(device.makeCommandQueue(), "Command queue unavailable")
        queue.label = "Sequential VerusHash benchmark"
        let library = try device.makeLibrary(URL: URL(filePath: "build/v22/verus.metallib"))
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = try unwrap(library.makeFunction(name: "verus_v22"), "Kernel unavailable")
        descriptor.label = "VerusHash v2.2 / full hash per thread"
        descriptor.maxTotalThreadsPerThreadgroup = groupSize
        descriptor.shaderValidation = validation ? .enabled : .disabled
        pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        try require(pipeline.maxTotalThreadsPerThreadgroup >= groupSize, "Unsupported threadgroup size")
    }

    func buffer(_ size: Int, _ label: String) throws -> any MTLBuffer {
        let b = try unwrap(device.makeBuffer(length: max(size, 16), options: .storageModeShared), "Allocation failed: \(label)")
        b.label = label
        return b
    }

    func gpu(_ batch: Batch) throws -> (Double, Double) {
        let start = ContinuousClock.now
        let command = try unwrap(queue.makeCommandBuffer(), "Command buffer unavailable")
        command.label = "Complete input-to-digest batch"
        let encoder = try unwrap(command.makeComputeCommandEncoder(), "Encoder unavailable")
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(batch.input, offset: 0, index: 0)
        encoder.setBuffer(batch.lengths, offset: 0, index: 1)
        encoder.setBuffer(batch.output, offset: 0, index: 2)
        encoder.setBuffer(batch.scratch, offset: 0, index: 3)
        var parameters: InlineArray<2, UInt32> = [UInt32(batch.count), UInt32(batch.stride)]
        withUnsafeBytes(of: &parameters) { encoder.setBytes($0.baseAddress!, length: $0.count, index: 4) }
        encoder.dispatchThreadgroups(MTLSize(width: (batch.count+groupSize-1)/groupSize, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let wall = seconds(start.duration(to: .now))
        try require(command.status == .completed, "GPU failure: \(String(describing: command.error))")
        let gpu = command.gpuEndTime - command.gpuStartTime
        try require(gpu > 0, "GPU timestamps unavailable")
        return (gpu, wall)
    }
    func cpu(_ batch: Batch) -> Double {
        let start = ContinuousClock.now
        vm_cpu_hashes(batch.input.contents().assumingMemoryBound(to: UInt8.self),
                      batch.lengths.contents().assumingMemoryBound(to: UInt32.self),
                      UInt32(batch.stride), UInt32(batch.count),
                      batch.cpuOutput.contents().assumingMemoryBound(to: UInt8.self), batch.cpuScratch.contents())
        return seconds(start.duration(to: .now))
    }
}
func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds)*1e-18
}

final class Batch {
    let count: Int
    let stride: Int
    let input: any MTLBuffer
    let lengths: any MTLBuffer
    let output: any MTLBuffer
    let cpuOutput: any MTLBuffer
    let scratch: any MTLBuffer
    let cpuScratch: any MTLBuffer
    let scratchBytes: Int

    init(engine: Engine, inputs: [[UInt8]]) throws {
        count = inputs.count
        stride = max(inputs.map(\.count).max() ?? 0, 1)
        try require(count > 0 && count <= 32768 && stride <= 4096, "Batch exceeds benchmark limits")
        input = try engine.buffer(count*stride, "Input bytes")
        lengths = try engine.buffer(count*4, "Input lengths")
        output = try engine.buffer(count*32+64, "GPU digests and guard")
        cpuOutput = try engine.buffer(count*32+64, "CPU digests and guard")
        scratchBytes = count*engine.scratchPerHash
        scratch = try engine.buffer(scratchBytes+64, "Transposed per-hash workspace and guard")
        cpuScratch = try engine.buffer(engine.scratchPerHash+64, "Single CPU thread workspace and guard")
        memset(input.contents(), 0, count*stride)
        memset(output.contents(), 0xa5, output.length)
        memset(cpuOutput.contents(), 0xa5, cpuOutput.length)
        memset(scratch.contents(), 0xa5, scratch.length)
        memset(cpuScratch.contents(), 0xa5, cpuScratch.length)
        for (i, bytes) in inputs.enumerated() {
            bytes.withUnsafeBytes { raw in
                if !raw.isEmpty { input.contents().advanced(by: i*stride).copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
            }
            lengths.contents().assumingMemoryBound(to: UInt32.self)[i] = UInt32(bytes.count)
        }
    }

    func checkGuards(engine: Engine) throws {
        for (buffer, offset) in [(output,count*32),(cpuOutput,count*32),
                                  (scratch,scratchBytes),(cpuScratch,engine.scratchPerHash)] {
            let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
            for i in offset..<offset+64 { try require(bytes[i] == 0xa5, "Guard overwritten: \(buffer.label ?? "buffer")") }
        }
    }
    func compare() throws {
        try require(memcmp(output.contents(), cpuOutput.contents(), count*32) == 0, "CPU/GPU digest mismatch")
    }
}

func validate(_ engine: Engine) throws -> FixtureFile {
    try require(vm_primitive_test() == 0, "CPU primitive known-answer test failed")
    let fixtures = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: URL(filePath: "tests/v22-vectors.json")))
    try require(fixtures.algorithm == "VerusHash v2.2", "Wrong fixture algorithm")
    let inputs = try fixtures.vectors.map { try decodeHex($0.input) }
    let batch = try Batch(engine: engine, inputs: inputs)
    _ = engine.cpu(batch); _ = try engine.gpu(batch)
    for (i, fixture) in fixtures.vectors.enumerated() {
        try require(digestHex(batch.cpuOutput, at: i) == fixture.digest, "CPU reference mismatch at fixture \(i)")
        try require(digestHex(batch.output, at: i) == fixture.digest, "GPU reference mismatch at fixture \(i)")
    }
    try batch.checkGuards(engine: engine)
    // Partial threadgroups, repeated invocation and dirty scratch reuse.
    for count in [1, 31, 32, 33, 127, 128, 129] {
        let subset = try Batch(engine: engine, inputs: Array(inputs.prefix(count)))
        _ = engine.cpu(subset)
        for _ in 0..<2 { _ = try engine.gpu(subset); try subset.compare(); try subset.checkGuards(engine: engine) }
    }
    print("Verified \(inputs.count) independent reference vectors, partial groups and workspace reuse.")
    return fixtures
}

func run() throws {
    var count = 4096, size = 64, repetitions = 5
    var testOnly = false, capture = false, validation = false
    let arguments = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < arguments.count {
        let option = arguments[index]; index += 1
        switch option {
        case "--test": testOnly = true
        case "--capture": capture = true
        case "--validate": validation = true
        case "--batch", "--input-size", "--samples":
            try require(index < arguments.count, "Missing value for \(option)")
            let value = try unwrap(Int(arguments[index]), "Invalid integer for \(option)"); index += 1
            if option == "--batch" { count = value }
            else if option == "--input-size" { size = value }
            else { repetitions = value }
        default: throw BenchError.failure("Unknown argument: \(option)")
        }
    }
    try require((1...32768).contains(count) && (0...4096).contains(size) && (1...25).contains(repetitions), "Invalid benchmark range")
    try require(!validation || testOnly, "Use --validate with --test; validation timings are not benchmark results")
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
    let engine = try Engine(validation: validation)
    let fixtures = try validate(engine)
    if testOnly { return }
    var random: UInt64 = 0x220927
    let inputs = (0..<count).map { _ in
        (0..<size).map { _ -> UInt8 in
            random ^= random << 13; random ^= random >> 7; random ^= random << 17
            return UInt8(truncatingIfNeeded: random)
        }
    }
    let batch = try Batch(engine: engine, inputs: inputs)
    _ = engine.cpu(batch); _ = try engine.gpu(batch)
    try batch.compare(); try batch.checkGuards(engine: engine)
    let directory = URL(filePath: "build/v22/run-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if capture {
        let manager = MTLCaptureManager.shared()
        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = engine.queue
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = directory.appending(path: "verus-v22.gputrace")
        try manager.startCapture(with: descriptor)
        defer { manager.stopCapture() }
        _ = try engine.gpu(batch)
        print("Capture: \(descriptor.outputURL!.path)")
        return
    }
    let warmup = ContinuousClock.now
    repeat { _ = engine.cpu(batch); _ = try engine.gpu(batch) }
    while seconds(warmup.duration(to: .now)) < 0.75
    // UniqueArray (Swift 6.4) avoids copy-on-write storage for recorded samples.
    var samples = UniqueArray<Sample>()
    samples.reserveCapacity(repetitions*3)
    func sample(_ path: String, _ elapsed: Double) -> Sample {
        Sample(path: path, seconds: elapsed, mhs: Double(count)/elapsed/1e6,
               thermalState: ProcessInfo.processInfo.thermalState.rawValue)
    }
    for repetition in 0..<repetitions {
        if repetition % 2 == 0 { samples.append(sample("cpu", engine.cpu(batch))) }
        let (gpu, wall) = try engine.gpu(batch)
        samples.append(sample("gpu", gpu)); samples.append(sample("endToEnd", wall))
        if repetition % 2 != 0 { samples.append(sample("cpu", engine.cpu(batch))) }
    }
    try batch.compare(); try batch.checkGuards(engine: engine)
    var records = [Sample]()
    for i in 0..<samples.count { records.append(samples.span[i]) }
    func median(_ path: String) -> Double {
        let values = records.filter { $0.path == path }.map(\.mhs).sorted()
        let middle = values.count/2
        return values.count % 2 == 0 ? (values[middle-1]+values[middle])/2 : values[middle]
    }
    let report = Report(algorithm: "VerusHash v2.2, fresh key for every hash", device: engine.device.name,
        os: ProcessInfo.processInfo.operatingSystemVersionString, count: count, inputBytes: size,
        scratchBytesPerHash: engine.scratchPerHash, threadgroupSize: engine.groupSize,
        pipelineThreadLimit: engine.pipeline.maxTotalThreadsPerThreadgroup,
        executionWidth: engine.pipeline.threadExecutionWidth, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
        validatedFixtures: fixtures.vectors.count, referenceRevision: fixtures.revision,
        medianCPU: median("cpu"), medianGPU: median("gpu"), medianEndToEnd: median("endToEnd"), samples: records)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let destination = directory.appending(path: "timings.json")
    try encoder.encode(report).write(to: destination, options: .atomic)
    print(String(format: "CPU %.4f | GPU %.4f | GPU end-to-end %.4f MH/s", report.medianCPU, report.medianGPU, report.medianEndToEnd))
    print("Results: \(destination.path)")
}

do { try run() }
catch { FileHandle.standardError.write(Data("Error: \(error)\n".utf8)); exit(1) }
