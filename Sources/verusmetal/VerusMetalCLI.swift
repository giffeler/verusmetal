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
            switch args.command {
            case "help", "--help", "-h": print(usage)
            case "devices":
                try args.validate()
                for d in MetalVerusSolver.devices() { print("\(d.name) unified=\(d.unifiedMemory)") }
            case "verify": try verify(args)
            case "benchmark": try benchmark(args)
            case "mine": try mine(args)
            default: throw CLIError.invalidArgument(args.command)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1)
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
            guard VerusHash.digest(input) == expected, result.candidates.first?.digest == expected else { throw CLIError.fixture("digest mismatch") }
        }
        print("Verified \(file.vectors.count) independent CPU/GPU reference vectors with Metal validation.")
    }
    private static func benchmark(_ args: Arguments) throws {
        try args.validate(valueOptions:["duration","batch"])
        let duration = try args.int("duration",default:10,in:1...3600)
        let solver = try MetalVerusSolver(batchSize:args.int("batch",default:4096,in:1...32768))
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
        print(String(format:"GPU %.3f MH/s | dispatch/wait %.3f MH/s | whole loop %.3f MH/s",
                     Double(s.nonces)/s.gpuSeconds/1e6,s.averageHashrate/1e6,
                     Double(s.nonces)/(ProcessInfo.processInfo.systemUptime-start)/1e6))
    }
    private static func mine(_ args: Arguments) throws {
        try args.validate(valueOptions:["config","pool","wallet","worker","batch","duration","stats-file","stats-interval","api-bind","stop-after-shares"])
        var config: Configuration?
        if let path = args.string("config") { config = try JSONDecoder().decode(Configuration.self,from:Data(contentsOf:URL(fileURLWithPath:path))) }
        guard let pool = args.string("pool",default:config?.pool), let wallet = args.string("wallet",default:config?.wallet),
              VerusAddress.isValid(wallet) else { throw CLIError.invalidAddress }
        let worker = args.string("worker",default:config?.worker ?? "m4")!
        guard !worker.isEmpty, worker.utf8.count <= 64, worker.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw CLIError.invalidArgument("worker must be ASCII alphanumeric") }
        let duration = try args.optionalInt("duration",in:1...604800)
        let shareLimit = try args.optionalInt("stop-after-shares",in:1...1_000_000)
        let interval = try args.int("stats-interval",default:10,in:1...3600)
        let solver = try MetalVerusSolver(batchSize:args.int("batch",default:4096,in:1...32768))
        let stats = StatisticsStore(); stats.update { $0.device = solver.device.name }
        let writer = JSONLEventWriter(path:args.string("stats-file"))
        if let error = writer.failure { throw error }
        let coordinator = MiningCoordinator(stats:stats,writer:writer)
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
        // A session-wide counter avoids reusing search space when a target changes.
        var nonceSequence: NonceSequence?
        var noncePrefix: [UInt8]?
        var accumulator = SearchStatisticsAccumulator()
        coordinator.start()
        print("Mining on \(client.redactedHost), worker \(worker), device \(solver.device.name)")
        do {
            while !coordinator.isStopped {
                let now = ProcessInfo.processInfo.systemUptime
                if let duration, now-start >= Double(duration) { break }
                if let shareLimit, stats.snapshot().accepted >= UInt64(shareLimit) { break }
                if now-lastStatus >= Double(interval) {
                    print(MinerStatusLineFormatter.format(stats.snapshot())); lastStatus = now
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
            print(MinerStatusLineFormatter.format(stats.snapshot()))
            if let duration, stats.snapshot().accepted == 0 {
                print("Timed run (\(duration)s) ended without an accepted share.")
            }
        } catch {
            accumulator.flush()?.record(in:stats); stats.update { $0.lastError = error.localizedDescription }
            coordinator.finish(failed:true); throw error
        }
    }
}
