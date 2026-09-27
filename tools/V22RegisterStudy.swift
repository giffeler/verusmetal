// Appended to the frozen benchmark's shared types by v22_register_study.py.
struct StudyReport: Codable {
    let count: Int
    let inputBytes: Int
    let device: String
    let os: String
    let groupSize: Int
    let pipelineThreadLimit: Int
    let pairCount: Int
    let queueMode: String
    let lowPowerMode: Bool
    let librarySHA256: [String: String]
    let cpuObjectSHA256: String
    let samples: [Sample]
}

func pressureCases(_ engine: Engine, name: String) throws {
    let bytes = 512 * 556 * 16
    let scratch = try engine.buffer(bytes + 64, "Directed mix cases")
    let expected = try engine.buffer(bytes, "Frozen CPU mix oracle")
    let output = try engine.buffer(512*32 + 64, "Directed case results")
    let expectedOutput = try engine.buffer(512*32, "Frozen CPU primitive oracle")
    memset(scratch.contents(), 0xa5, scratch.length)
    memset(output.contents(), 0xa5, output.length)
    vm_pressure_cases(scratch.contents(), expected.contents(), expectedOutput.contents())
    let library = try engine.device.makeLibrary(URL: URL(filePath: "build/v22/register-study/\(name)/kernel.metallib"))
    let descriptor = MTLComputePipelineDescriptor()
    descriptor.computeFunction = try unwrap(library.makeFunction(name: "pressure_cases"), "Test kernel unavailable")
    descriptor.maxTotalThreadsPerThreadgroup = 128
    descriptor.shaderValidation = engine.validation ? .enabled : .disabled
    let pipeline = try engine.device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
    let command = try unwrap(engine.queue.makeCommandBuffer(), "Test command unavailable")
    let encoder = try unwrap(command.makeComputeCommandEncoder(), "Test encoder unavailable")
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(scratch, offset: 0, index: 0)
    encoder.setBuffer(output, offset: 0, index: 1)
    encoder.dispatchThreadgroups(MTLSize(width: 4, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    try require(command.status == .completed, "Directed test failed: \(String(describing: command.error))")
    try require(memcmp(scratch.contents(), expected.contents(), bytes) == 0, "Directed mix workspace mismatch")
    try require(memcmp(output.contents(), expectedOutput.contents(), 512*32) == 0, "Directed mix/primitive mismatch")
    for (buffer, offset) in [(scratch, bytes), (output, 512*32)] {
        for i in offset..<offset+64 {
            try require(buffer.contents().load(fromByteOffset: i, as: UInt8.self) == 0xa5, "Directed case guard overwritten")
        }
    }
    print("Verified 512 directed mix cases: all operations, aliasing, lane, loop endpoints, selector signs and rounded-product extrema.")
}

func instructionCases(_ engine: Engine, name: String) throws {
    let bytes = 8192 * 32
    let input = try engine.buffer(bytes, "Primitive inputs")
    let expected = try engine.buffer(bytes, "ARM primitive oracle")
    let output = try engine.buffer(bytes+64, "GPU primitive results and guard")
    memset(output.contents(), 0xa5, output.length)
    if name.hasPrefix("i3_cross") {
        vm_cross_cases(input.contents(), expected.contents())
    } else {
        vm_instruction_cases(input.contents(), expected.contents())
    }
    let library = try engine.device.makeLibrary(URL: URL(filePath: "build/v22/register-study/\(name)/kernel.metallib"))
    let descriptor = MTLComputePipelineDescriptor()
    descriptor.computeFunction = try unwrap(library.makeFunction(name: "instruction_cases"), "Primitive test kernel unavailable")
    descriptor.maxTotalThreadsPerThreadgroup = 128
    descriptor.shaderValidation = engine.validation ? .enabled : .disabled
    let pipeline = try engine.device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
    let command = try unwrap(engine.queue.makeCommandBuffer(), "Primitive test command unavailable")
    let encoder = try unwrap(command.makeComputeCommandEncoder(), "Primitive test encoder unavailable")
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(input, offset: 0, index: 0)
    encoder.setBuffer(output, offset: 0, index: 1)
    encoder.dispatchThreadgroups(MTLSize(width: 64, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    try require(command.status == .completed, "Primitive GPU test failed")
    try require(memcmp(output.contents(), expected.contents(), bytes) == 0, "Primitive CPU/GPU mismatch")
    for i in bytes..<bytes+64 {
        try require(output.contents().load(fromByteOffset: i, as: UInt8.self) == 0xa5, "Primitive guard overwritten")
    }
    print("Verified 8,192 product/\(name.hasPrefix("i3_cross") ? "cross-XOR" : "AES") cases against ARM primitives, including all 4,096 single-bit product pairs.")
}

func runStudy() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    try require(args.count >= 3, "Usage: study test|bench|capture INPUT_BYTES VARIANT...")
    let mode = args[0]
    try require(["test", "bench", "capture"].contains(mode), "Invalid mode")
    let size = try unwrap(Int(args[1]), "Invalid input size")
    try require((0...4096).contains(size), "Invalid input size")
    let names = Array(args.dropFirst(2))
    try require(mode != "bench" || names.count == 2, "Benchmark exactly one A/B pair")
    let pairText = ProcessInfo.processInfo.environment["VERUS_STUDY_PAIRS"] ?? "5"
    let pairCount = try unwrap(Int(pairText), "Invalid VERUS_STUDY_PAIRS")
    try require((2...100).contains(pairCount), "VERUS_STUDY_PAIRS must be 2...100")
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
    let queueMode = ProcessInfo.processInfo.environment["VERUS_STUDY_QUEUE"] ?? "separate"
    try require(["separate", "shared"].contains(queueMode), "Invalid VERUS_STUDY_QUEUE")
    var sharedQueue: (any MTLCommandQueue)?
    if queueMode == "shared" {
        let device = try unwrap(MTLCreateSystemDefaultDevice(), "Metal device unavailable")
        sharedQueue = try unwrap(device.makeCommandQueue(), "Shared command queue unavailable")
    }
    let engines = try names.map { try Engine(validation: mode == "test", name: $0, sharedQueue: sharedQueue) }
    for (name, engine) in zip(names, engines) {
        print("Checking \(name)")
        _ = try validate(engine)
        try pressureCases(engine, name: name)
        if name.hasPrefix("i") { try instructionCases(engine, name: name) }
    }
    if mode == "test" { return }
    let count = 4096
    var random: UInt64 = 0x220927
    let inputs = (0..<count).map { _ in (0..<size).map { _ -> UInt8 in
        random ^= random << 13; random ^= random >> 7; random ^= random << 17
        return UInt8(truncatingIfNeeded: random)
    } }
    let batch = try Batch(engine: engines[0], inputs: inputs)
    _ = engines[0].cpu(batch)
    for engine in engines {
        _ = try engine.gpu(batch); try batch.compare(); try batch.checkGuards(engine: engine)
    }
    let directory = URL(filePath: "build/v22/register-study/run-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if mode == "capture" {
        let manager = MTLCaptureManager.shared()
        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = engines[0].device
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = directory.appending(path: "register-study.gputrace")
        try manager.startCapture(with: descriptor)
        for engine in engines { _ = try engine.gpu(batch) }
        manager.stopCapture()
        print("Capture: \(descriptor.outputURL!.path)")
        return
    }
    let warmup = ContinuousClock.now
    repeat { for engine in engines { _ = try engine.gpu(batch) } }
    while seconds(warmup.duration(to: .now)) < 0.75
    var samples = [Sample]()
    for pair in 0..<pairCount {
        let order = pair % 2 == 0 ? [0, 1] : [1, 0]
        for i in order {
            let (gpu, wall) = try engines[i].gpu(batch)
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            samples.append(Sample(path: "\(names[i])/gpu", seconds: gpu,
                                  mhs: Double(count)/gpu/1e6, thermalState: thermal))
            samples.append(Sample(path: "\(names[i])/endToEnd", seconds: wall,
                                  mhs: Double(count)/wall/1e6, thermalState: thermal))
            try batch.compare(); try batch.checkGuards(engine: engines[i])
        }
    }
    let report = StudyReport(count: count, inputBytes: size, device: engines[0].device.name,
        os: ProcessInfo.processInfo.operatingSystemVersionString, groupSize: engines[0].groupSize,
        pipelineThreadLimit: engines[0].pipeline.maxTotalThreadsPerThreadgroup, pairCount: pairCount,
        queueMode: queueMode,
        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
        librarySHA256: try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try fileSHA256("build/v22/register-study/\(name)/kernel.metallib"))
        }), cpuObjectSHA256: try fileSHA256("build/v22/register-study/baseline/cpu.o"), samples: samples)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let destination = directory.appending(path: "timings.json")
    try encoder.encode(report).write(to: destination, options: .atomic)
    for name in names {
        for path in ["gpu", "endToEnd"] {
            let values = samples.filter { $0.path == "\(name)/\(path)" }.map(\.mhs).sorted()
            let middle = values.count / 2
            let median = values.count % 2 == 0 ? (values[middle-1]+values[middle])/2 : values[middle]
            print(String(format: "%@ %@ median %.6f MH/s [%.6f, %.6f]", name, path, median, values[0], values[values.count-1]))
        }
    }
    print("Results: \(destination.path)")
}

do { try runStudy() }
catch { FileHandle.standardError.write(Data("Error: \(error)\n".utf8)); exit(1) }
