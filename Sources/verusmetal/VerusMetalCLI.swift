import Foundation
import VerusMetalCore
import Darwin

private struct Configuration: Decodable {
    var pool: String
    var wallet: String
    var worker: String?
}

@main enum VerusMetalCLI {
    static func main() {
        do {
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if args.has("help"), let help = commandUsage(args.command) {
                try args.validate(flagOptions: ["help"])
                print(help)
                return
            }
            switch args.command {
            case "help", "--help", "-h":
                try args.validate()
                print(usage)
            case "version", "--version":
                try args.validate()
                print("VerusMetal \(version)")
            case "devices": try devices(args)
            case "verify": try verify(args)
            case "benchmark": try benchmark(args)
            case "mine": try mine(args)
            default: throw CLIError.invalidArgument(args.command)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\nUse 'verusmetal --help' for usage.\n".utf8)); exit(2)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        print()
    }

    private static func devices(_ args: Arguments) throws {
        try args.validate(flagOptions: ["json"])
        let devices = MetalVerusSolver.devices()
        if args.has("json") { try printJSON(devices) }
        else if devices.isEmpty { print("No Metal devices found") }
        else {
            for device in devices {
                print("\(device.name) unified=\(device.unifiedMemory) working-set=\(device.recommendedWorkingSetBytes) bytes")
            }
        }
    }

    private static func verify(_ args: Arguments) throws {
        try args.validate(valueOptions:["fixtures"])
        struct Fixture: Decodable { let input: String; let digest: String }
        struct File: Decodable { let vectors: [Fixture] }
        let file = try JSONDecoder().decode(File.self,from: Data(contentsOf: URL(fileURLWithPath:args.require("fixtures"))))
        let solver = try MetalVerusSolver(batchSize: 1,validation: true)
        for fixture in file.vectors {
            guard let input = [UInt8](hex:fixture.input), let expected = [UInt8](hex:fixture.digest) else { throw CLIError.fixture("hex") }
            let result = try solver.search(input: input,nonceOffset:0,nonceBytes:0,target:.max)
            guard VerusHash.digest(input) == expected,
                  try PreparedVerusHash(input:input,nonceOffset:0,nonceBytes:0).digest() == expected,
                  result.candidates.first?.digest == expected else { throw CLIError.fixture("digest mismatch") }
        }
        print("Verified \(file.vectors.count) independent CPU/GPU reference vectors with Metal validation.")
    }
    private static func benchmark(_ args: Arguments) throws {
        try args.validate(valueOptions:["duration","batch-nonces"],flagOptions:["json"])
        let duration = try args.int("duration",default:10,in:1...3600)
        let solver = try MetalVerusSolver(batchSize:args.int("batch-nonces",default:32768,in:1...32768))
        let stats = StatisticsStore(); var accumulator = SearchStatisticsAccumulator()
        let input = [UInt8](repeating:0,count:1487)
        let warmup = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime-warmup < 0.75 {
            _ = try solver.search(input:input,nonceOffset:1479,nonceBytes:8,target:.zero)
        }
        let start = ProcessInfo.processInfo.systemUptime; var nonce: UInt64 = 0
        while ProcessInfo.processInfo.systemUptime-start < Double(duration) {
            let batch = try solver.search(input:input,nonceOffset:1479,nonceBytes:8,target:.zero,firstNonce:nonce)
            nonce += UInt64(batch.nonceCount)
            accumulator.append(batch)?.record(in:stats)
        }
        accumulator.flush()?.record(in:stats)
        let s = stats.snapshot()
        let elapsed = ProcessInfo.processInfo.systemUptime-start
        let gpuHashrate = s.gpuSeconds > 0 ? Double(s.nonces)/s.gpuSeconds : 0
        let effectiveHashrate = elapsed > 0 ? Double(s.nonces)/elapsed : 0
        if args.has("json") {
            struct Report: Encodable {
                let schemaVersion: Int
                let version: String
                let device: String
                let batchNonces: Int
                let requestedDurationSeconds: Int
                let durationSeconds: Double
                let nonces: UInt64
                let dispatches: UInt64
                let gpuSeconds: Double
                let commandWallSeconds: Double
                let gpuHashrate: Double
                let averageHashrate: Double
                let effectiveHashrate: Double
            }
            try printJSON(Report(schemaVersion:1,version:version,device:solver.device.name,
                                 batchNonces:solver.batchSize,requestedDurationSeconds:duration,
                                 durationSeconds:elapsed,nonces:s.nonces,dispatches:s.dispatches,
                                 gpuSeconds:s.gpuSeconds,commandWallSeconds:s.activeSeconds,
                                 gpuHashrate:gpuHashrate,averageHashrate:s.averageHashrate,
                                 effectiveHashrate:effectiveHashrate))
        } else {
            print(String(format:"GPU %.3f MH/s | dispatch/wait %.3f MH/s | whole loop %.3f MH/s",
                         gpuHashrate/1e6,s.averageHashrate/1e6,effectiveHashrate/1e6))
        }
    }
    private static func mine(_ args: Arguments) throws {
        try args.validate(valueOptions:["config","pool","wallet","worker","batch-nonces","duration","stats-file","stats-interval","telemetry-interval","api-bind","stop-after-shares"])
        var config: Configuration?
        if let path = args.string("config") { config = try JSONDecoder().decode(Configuration.self,from:Data(contentsOf:URL(fileURLWithPath:path))) }
        guard let pool = args.string("pool",default:config?.pool) else { throw CLIError.missing("--pool or --config") }
        guard let wallet = args.string("wallet",default:config?.wallet) else { throw CLIError.missing("--wallet or --config") }
        guard VerusAddress.isValid(wallet) else { throw CLIError.invalidAddress }
        let worker = args.string("worker",default:config?.worker ?? "m4")!
        guard !worker.isEmpty, worker.utf8.count <= 64, worker.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw CLIError.invalidArgument("worker must be ASCII alphanumeric") }
        let duration = try args.optionalInt("duration",in:1...604800)
        let shareLimit = try args.optionalInt("stop-after-shares",in:1...1_000_000)
        let interval = try args.int("stats-interval",default:10,in:1...3600)
        let telemetryInterval = try args.int("telemetry-interval",default:30,in:1...3600)
        let solver = try MetalVerusSolver(batchSize:args.int("batch-nonces",default:32768,in:1...32768))
        let stats = StatisticsStore(); stats.update { $0.device = solver.device.name }
        let writer = JSONLEventWriter(path:args.string("stats-file"))
        if let error = writer.failure { throw error }
        let console = MiningConsole()
        defer { console.finish() }
        let coordinator = MiningCoordinator(stats:stats,writer:writer,batchSize:solver.batchSize,telemetryInterval:telemetryInterval,onMessage: { console.message($0) })
        let client = try VerusStratumClient(url:pool,user:wallet+"."+worker,
                                           password:ProcessInfo.processInfo.environment["VERUSMETAL_POOL_PASSWORD"] ?? "x") { [weak coordinator] event in coordinator?.handle(event) }
        coordinator.configure(client:client)
        let server = StatisticsHTTPServer(store:stats)
        if let bind = args.string("api-bind") { try server.start(bind:bind) }
        defer { server.stop() }
        signal(SIGINT,SIG_IGN); signal(SIGTERM,SIG_IGN)
        let signals = [SIGINT,SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal:number,queue:.global())
            source.setEventHandler { coordinator.stop() }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        let start = ProcessInfo.processInfo.systemUptime
        var lastStatus = start
        var lastTelemetry = start
        // A session-wide counter avoids reusing search space when a target changes.
        var nonceSequence: NonceSequence?
        var noncePrefix: [UInt8]?
        var accumulator = SearchStatisticsAccumulator()
        coordinator.start()
        console.message("Mining on \(client.redactedHost), worker \(worker), device \(solver.device.name)")
        console.status(stats.snapshot())
        do {
            while !coordinator.isStopped {
                let now = ProcessInfo.processInfo.systemUptime
                if let duration, now-start >= Double(duration) { break }
                if let shareLimit, stats.snapshot().accepted >= UInt64(shareLimit) { break }
                if now-lastTelemetry >= Double(telemetryInterval) {
                    accumulator.flush()?.record(in:stats)
                    coordinator.recordTelemetry(); lastTelemetry = now
                }
                if now-lastStatus >= Double(interval) {
                    console.status(stats.snapshot()); lastStatus = now
                }
                guard let job = coordinator.nextWork() else { continue }
                if noncePrefix != job.extraNoncePrefix {
                    nonceSequence = NonceSequence(start: UInt64.random(in:0...job.maximumNonce/2), maximum: job.maximumNonce)
                    noncePrefix = job.extraNoncePrefix
                }
                let nonce = try nonceSequence!.take(solver.batchSize)
                let batch = try solver.search(job:job,firstNonce:nonce)
                accumulator.append(batch)?.record(in:stats)
                for candidate in batch.candidates { try coordinator.submit(candidate,for:job) }
            }
            accumulator.flush()?.record(in:stats)
            if duration != nil && stats.snapshot().nonces == 0 && !coordinator.isStopped {
                throw VerusError.invalid("No mining work completed: \(stats.snapshot().lastError ?? "no job received")")
            }
            coordinator.finish()
            console.status(stats.snapshot())
            console.finish()
            if let duration, stats.snapshot().accepted == 0 {
                print("Timed run (\(duration)s) ended without an accepted share.")
            }
        } catch {
            accumulator.flush()?.record(in:stats); stats.update { $0.lastError = error.localizedDescription }
            coordinator.finish(failed:true); console.status(stats.snapshot()); throw error
        }
    }
}
