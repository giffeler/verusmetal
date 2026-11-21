import Testing
import Foundation
import Synchronization
@testable import VerusMetalCore

func makeParams(version: UInt8 = 7, id: String = "job1") -> [Any] {
    var solution = [UInt8](repeating:0,count:124)
    solution[0] = version; solution[5] = 1; solution[6] = 4; solution[7] = 0
    for i in 8..<124 { solution[i] = UInt8(i) }
    return [id,"04000100",String(repeating:"11",count:32),String(repeating:"22",count:32),
            String(repeating:"33",count:32),"12345678","ffff071f",true,solution.hex]
}
func makeJob(generation: UInt64 = 1, target: UInt256 = .max) throws -> VerusStratumJob {
    try VerusStratumJob.decode(makeParams(),generation:generation,prefix:[1,2,3,4],target:target)
}

final class HashTests {
    @Test func testIndependentFixtures() throws {
        struct Vector: Decodable { let input: String; let digest: String }
        struct File: Decodable { let vectors: [Vector] }
        let url = try #require(Bundle(for: Self.self).url(forResource: "v22-vectors", withExtension: "json"))
        let file = try JSONDecoder().decode(File.self,from:Data(contentsOf:url))
        #expect(file.vectors.count == 148)
        let solver = try MetalVerusSolver(batchSize:1,validation:true)
        for f in file.vectors {
            let bytes = try #require([UInt8](hex:f.input))
            #expect(VerusHash.digest(bytes).hex == f.digest)
            #expect(try PreparedVerusHash(input:bytes,nonceOffset:0,nonceBytes:0).digest().hex == f.digest)
            let result = try solver.search(input:bytes,nonceOffset:0,nonceBytes:0,target:.max)
            #expect(result.candidates.first?.digest.hex == f.digest)
            #expect(solver.usesCachedHash)
        }
    }
    @Test func testPartialGroupsNonceMappingAndReuse() throws {
        let solver = try MetalVerusSolver(batchSize:129,validation:true)
        let job = try makeJob()
        for count in [1,31,32,33,127,128,129] {
            let result = try solver.search(job:job,firstNonce:0x0102030405060708,count:count)
            #expect(result.candidates.count == count)
            for (i,candidate) in result.candidates.enumerated() {
                #expect(candidate.nonce == 0x0102030405060708+UInt64(i))
                #expect(candidate.digest == VerusHash.digest(try job.input(nonce:candidate.nonce)))
            }
        }
    }
    @Test func testCachedPrefixesRandomNoncesAndJobChanges() throws {
        let solver = try MetalVerusSolver(batchSize:129,validation:true)
        var random: UInt64 = 0x938aa746bc92
        func next() -> UInt64 {
            random ^= random << 13; random ^= random >> 7; random ^= random << 17
            return random
        }
        for version: UInt8 in [7,8] {
            for prefixLength in 1...14 {
                let prefix = (0..<prefixLength).map { _ in UInt8(truncatingIfNeeded:next()) }
                let job = try VerusStratumJob.decode(makeParams(version:version),generation:1,prefix:prefix,target:.max)
                let cpu = try PreparedVerusHash(input:job.hashInput,nonceOffset:job.nonceOffset,nonceBytes:job.nonceBytes)
                #expect(cpu.usesCachedHash)
                let limit: UInt64 = job.nonceBytes == 8 ? .max : (UInt64(1) << (8*job.nonceBytes))-1
                // Repeat each range to detect stale masks, and change strides for partial groups.
                for count in [129,33] {
                    let first = next() % (limit-UInt64(count))
                    for _ in 0..<2 {
                        let batch = try solver.search(job:job,firstNonce:first,count:count)
                        #expect(solver.usesCachedHash)
                        #expect(batch.candidates.count == count)
                        for candidate in batch.candidates {
                            let expected = VerusHash.digest(try job.input(nonce:candidate.nonce))
                            #expect(candidate.digest == expected)
                            #expect(try cpu.digest(nonce:candidate.nonce) == expected)
                        }
                    }
                }
            }
        }
    }

    @Test func testFullBlockOverlapFallbackAndModeTransitions() throws {
        let solver = try MetalVerusSolver(batchSize:33,validation:true)
        let input = (0..<79).map { UInt8(truncatingIfNeeded:$0*37) }
        for offset in [63,64,31,68,0] {
            let cpu = try PreparedVerusHash(input:input,nonceOffset:offset,nonceBytes:8)
            for first: UInt64 in [0,0x8192837465564321] {
                let batch = try solver.search(input:input,nonceOffset:offset,nonceBytes:8,target:.max,firstNonce:first)
                #expect(solver.usesCachedHash == (offset >= 64))
                #expect(cpu.usesCachedHash == (offset >= 64))
                for candidate in batch.candidates {
                    var bytes = input
                    for i in 0..<8 { bytes[offset+i] = UInt8(truncatingIfNeeded:candidate.nonce >> (8*i)) }
                    let expected = VerusHash.digest(bytes)
                    #expect(candidate.digest == expected)
                    #expect(try cpu.digest(nonce:candidate.nonce) == expected)
                }
            }
        }
    }

    @Test func testTargetEqualityAndLittleEndianOrder() throws {
        let solver = try MetalVerusSolver(batchSize:1,validation:true)
        let bytes = Array((0..<64).map(UInt8.init))
        let digest = VerusHash.digest(bytes)
        let equal = UInt256(bigEndian:Array(digest.reversed()))
        #expect(try solver.search(input:bytes,nonceOffset:0,nonceBytes:0,target:equal).candidates.count == 1)
        var lower = equal.limbs
        for i in lower.indices.reversed() {
            if lower[i] > 0 { lower[i] -= 1; break }
            lower[i] = .max
        }
        #expect(try solver.search(input:bytes,nonceOffset:0,nonceBytes:0,target:UInt256(limbs:lower)).candidates.isEmpty)
        #expect(!VerusHash.meetsTarget(digest,UInt256(limbs:lower)))
    }
    @Test func testNonceBoundsAndPreparationModeChange() throws {
        let solver = try MetalVerusSolver(batchSize:2,validation:true)
        let bytes = [UInt8](repeating:0,count:64)
        #expect(throws: (any Error).self) {
            try solver.search(input:bytes,nonceOffset:Int.max,nonceBytes:8,target:.max)
        }
        #expect(throws: (any Error).self) {
            try PreparedVerusHash(input:bytes,nonceOffset:Int.max,nonceBytes:8)
        }
        #expect(throws: (any Error).self) {
            try solver.search(input:bytes,nonceOffset:56,nonceBytes:8,target:.max,firstNonce:.max)
        }
        #expect(throws: (any Error).self) {
            try solver.search(input:bytes,nonceOffset:63,nonceBytes:2,target:.max)
        }
        #expect(throws: (any Error).self) {
            try solver.search(input:bytes,nonceOffset:56,nonceBytes:1,target:.max,firstNonce:255)
        }
        let max = try solver.search(input:bytes,nonceOffset:56,nonceBytes:8,target:.max,firstNonce:.max,count:1)
        #expect(max.candidates.count == 1)
        let plain = try solver.search(input:bytes,nonceOffset:0,nonceBytes:0,target:.max,count:1)
        #expect(plain.candidates[0].digest == VerusHash.digest(bytes))
    }
}

struct ProtocolTests {
    @Test func testPBaaSCanonicalViewAndSubmission() throws {
        let job = try makeJob()
        #expect(job.hashInput.count == 1487)
        #expect(job.nonceOffset == 1476)
        #expect(job.nonceBytes == 8)
        for r in [4..<100,104..<140,151..<215] { #expect(job.hashInput[r].allSatisfy {$0==0}) }
        #expect(Array(job.hashInput[100..<104]) == [0x12,0x34,0x56,0x78])
        #expect(Array(job.hashInput[215..<267]) == Array(job.solution[72..<124]))
        #expect(Array(job.header[4..<36]) == [UInt8](repeating:0x11,count:32))
        let params = try job.submission(user:"wallet.m4",nonce:0x0102030405060708)
        #expect(params.count == 5)
        #expect(params[2] == "12345678")
        #expect(params[3].count == 56)
        let submitted = try #require([UInt8](hex:params[4]))
        #expect(submitted.count == 1347)
        #expect(Array(submitted.prefix(3)) == [0xfd,0x40,0x05])
        #expect(Array(submitted[3..<1329+3]) == Array(job.solution[..<1329]))
        #expect(Array(submitted[(1329+3)..<(1329+7)]) == [1,2,3,4])
        #expect(Array(submitted[(1333+3)..<(1341+3)]) == [8,7,6,5,4,3,2,1])
    }
    @Test func testVersion8PBaaSViewAndGPUHash() throws {
        let job = try VerusStratumJob.decode(makeParams(version:8),generation:1,prefix:[1,2,3,4],target:.max)
        let old = try makeJob()
        var expected = old.hashInput
        expected[143] = 8
        #expect(job.hashInput == expected)
        let nonce: UInt64 = 0x0102030405060708
        let submitted = try #require([UInt8](hex:job.submission(user:"wallet.m4",nonce:nonce)[4]))
        #expect(submitted[3] == 8)
        #expect(Array(submitted[3..<1332]) == Array(job.solution[..<1329]))
        let solver = try MetalVerusSolver(batchSize:1,validation:true)
        let batch = try solver.search(input:job.hashInput,nonceOffset:job.nonceOffset,nonceBytes:job.nonceBytes,
                                     target:.max,firstNonce:nonce,count:1)
        #expect(batch.candidates.first?.digest == VerusHash.digest(try job.input(nonce:nonce)))
        #expect(throws: (any Error).self) {
            try VerusStratumJob.decode(makeParams(version:9),generation:1,prefix:[1],target:.max)
        }
    }
    @Test func testCompactPBaaSDescriptorAndNonceBoundary() throws {
        var params = makeParams(version:8)
        var reserved = [UInt8](repeating:0,count:229)
        reserved[0] = 8; reserved[5] = 3; reserved[6] = 4
        reserved[228] = 1
        params[8] = reserved.hex
        let job = try VerusStratumJob.decode(params,generation:1,prefix:[1,2,3,4],target:.max)
        #expect(Array(job.solution[228..<232]) == [1,0,0,0])
        #expect(Array(job.solution[1329..<1333]) == [1,2,3,4])
        // Three headers consume 228 bytes; payload must end before the nonce tail.
        reserved[6] = 0x4d; reserved[7] = 4 // 1101 bytes: ends exactly at 1329.
        params[8] = reserved.hex
        _ = try VerusStratumJob.decode(params,generation:1,prefix:[1],target:.max)
        reserved[6] = 0x4e; params[8] = reserved.hex
        #expect(throws: (any Error).self) {
            try VerusStratumJob.decode(params,generation:1,prefix:[1],target:.max)
        }
    }
    @Test func testLegacySolutionAndRejectUnsupportedLayouts() throws {
        var p = makeParams(version:4); p[8] = "04"
        let job = try VerusStratumJob.decode(p,generation:1,prefix:[1],target:.max)
        #expect(job.hashInput[4] == 0x11)
        p[8] = "03"
        #expect(throws: (any Error).self) {
            try VerusStratumJob.decode(p,generation:1,prefix:[1],target:.max)
        }
        p[8] = "08"
        #expect(throws: (any Error).self) {
            try VerusStratumJob.decode(p,generation:1,prefix:[1],target:.max)
        }
        p = makeParams(); p[2] = "00"
        #expect(throws: (any Error).self) {
            try VerusStratumJob.decode(p,generation:1,prefix:[1],target:.max)
        }
        #expect(throws: (any Error).self) {
            try VerusStratumJob.decode(makeParams(),generation:1,prefix:[],target:.max)
        }
        #expect(throws: (any Error).self) {
            try VerusStratumJob.decode(makeParams(),generation:1,prefix:[1],target:.zero)
        }
    }
    @Test func testSubscriptionAddressAndURLValidation() throws {
        #expect(try VerusStratumClient.decodeSubscription([NSNull(),"01020304"]) == [1,2,3,4])
        #expect(throws: (any Error).self) { try VerusStratumClient.decodeSubscription([NSNull(),"zz"]) }
        #expect(VerusAddress.isValid("R9HDHYTuwAr3PyRkXrhYgwycrxC7Xja8zs"))
        #expect(!VerusAddress.isValid("R9HDHYTuwAr3PyRkXrhYgwycrxC7Xja8z1"))
        #expect(throws: (any Error).self) {
            try VerusStratumClient(url:"https://example.com:1",user:"u") {_ in}
        }
        #expect(throws: (any Error).self) {
            try VerusStratumClient(url:"stratum+ssl://u:p@example.com:1",user:"u") {_ in}
        }
        #expect(VerusStratumClient.shareRejectionDiagnostic([23,"secret",NSNull()]) == "pool rejected share (code 23)")
    }
}

final class FakeClient: MiningStratumClient, Sendable {
    let calls = Mutex((connect:0,disconnect:0,submit:0))
    func connect() { calls.withLock { $0.connect += 1 } }
    func disconnect() { calls.withLock { $0.disconnect += 1 } }
    func submit(job: VerusStratumJob, nonce: UInt64) throws -> Int { calls.withLock { $0.submit += 1; return $0.submit } }
}
struct LifecycleTests {
    @Test func testStaleJobAndCPUVerification() throws {
        let stats = StatisticsStore(), client = FakeClient()
        let coordinator = MiningCoordinator(stats:stats,writer:JSONLEventWriter(path:nil))
        coordinator.configure(client:client); coordinator.start(); coordinator.handle(.authorized)
        let old = try makeJob(), new = try makeJob(generation:2)
        coordinator.handle(.job(old))
        #expect(coordinator.isCurrent(old))
        let digest = VerusHash.digest(try old.input(nonce:1))
        coordinator.handle(.job(new))
        #expect(!coordinator.isCurrent(old))
        try coordinator.submit(Candidate(nonce:1,digest:digest),for:old)
        #expect(stats.snapshot().stale == 1)
        #expect(client.calls.withLock {$0.submit} == 0)
        #expect(throws: (any Error).self) {
            try coordinator.submit(Candidate(nonce:1,digest:[UInt8](repeating:0,count:32)),for:new)
        }
        try coordinator.submit(Candidate(nonce:1,digest:digest),for:new)
        #expect(client.calls.withLock {$0.submit} == 1)
        coordinator.stop()
        #expect(coordinator.isStopped)
        #expect(coordinator.nextWork() == nil)
    }
    @Test func testReconnectCancellationAndNonceExhaustion() throws {
        let client = FakeClient(), coordinator = MiningCoordinator(stats:StatisticsStore(),writer:JSONLEventWriter(path:nil),reconnectDelay:0.05)
        coordinator.configure(client:client); coordinator.start(); coordinator.handle(.disconnected("test")); coordinator.stop()
        Thread.sleep(forTimeInterval:0.1)
        #expect(client.calls.withLock {$0.connect} == 1)
        var sequence = NonceSequence(start:UInt64.max-2,maximum:.max)
        #expect(try sequence.take(2) == UInt64.max-2)
        #expect(try sequence.take(1) == UInt64.max)
        #expect(throws: (any Error).self) { try sequence.take(1) }
        var narrow = NonceSequence(start:254,maximum:255)
        #expect(throws: (any Error).self) { try narrow.take(3) }
        #expect(try narrow.take(2) == 254)
    }
    @Test func testArgumentsAndAPIExposure() throws {
        #expect(throws: (any Error).self) { try Arguments(["mine","--pool","a","--pool","b"]) }
        let args = try Arguments(["mine","--batch","0"])
        #expect(throws: (any Error).self) { try args.int("batch-nonces",default:4096,in:1...32768) }
        #expect(throws: (any Error).self) {
            try StatisticsHTTPServer(store:StatisticsStore()).start(bind:"0.0.0.0:4079")
        }
    }

    @Test func testBatchAliasAndStrictOptions() throws {
        for command in ["mine", "benchmark"] {
            for option in ["--batch", "--batch-nonces"] {
                let args = try Arguments([command, option, "8192"])
                try args.validate(valueOptions: ["batch-nonces"])
                #expect(try args.int("batch-nonces",default:4096,in:1...32768) == 8192)
                for invalid in ["0", "32769", "invalid"] {
                    let bad = try Arguments([command, option, invalid])
                    #expect(throws: (any Error).self) {
                        try bad.int("batch-nonces",default:4096,in:1...32768)
                    }
                }
                #expect(throws: (any Error).self) {
                    try Arguments([command, option]).validate(valueOptions:["batch-nonces"])
                }
            }
            for pair in [["--batch", "--batch-nonces"], ["--batch-nonces", "--batch"], ["--batch-nonces", "--batch-nonces"]] {
                #expect(throws: (any Error).self) {
                    try Arguments([command, pair[0], "4096", pair[1], "8192"])
                }
            }
        }
        #expect(throws: (any Error).self) {
            try Arguments(["devices", "--json", "true"]).validate(flagOptions:["json"])
        }
        #expect(throws: (any Error).self) {
            try Arguments(["devices", "--unknown"]).validate(flagOptions:["json"])
        }
        let help = try Arguments(["mine", "-h"])
        try help.validate(flagOptions:["help"])
        #expect(help.has("help"))
    }
}

struct TelemetryTests {
    @Test func testStartupStatusScheduleAndReconnect() {
        var schedule = MiningStatusSchedule(maximumInterval: 240)
        let beforeStart = schedule.consumeIfDue(at: 100)
        #expect(!beforeStart)
        schedule.start(at: 0)
        for time in [1.0, 3, 7, 15, 31, 63, 127, 255, 495, 735] {
            let beforeDeadline = schedule.consumeIfDue(at: time - 0.01)
            #expect(!beforeDeadline)
            let atDeadline = schedule.consumeIfDue(at: time)
            #expect(atDeadline)
        }
        schedule.stop()
        let afterStop = schedule.consumeIfDue(at: 1000)
        #expect(!afterStop)
        schedule.start(at: 1000)
        let afterRestart = schedule.consumeIfDue(at: 1001)
        #expect(afterRestart)
        var frequent = MiningStatusSchedule(maximumInterval: 1)
        frequent.start(at: 0)
        for time in 1...3 {
            let atInterval = frequent.consumeIfDue(at: Double(time))
            #expect(atInterval)
        }
    }

    @Test func testIntervalRatesAndIdleTime() throws {
        var before = MinerSnapshot()
        before.nonces = 100; before.dispatches = 1; before.gpuSeconds = 1
        before.activeSeconds = 2; before.uptimeSeconds = 3
        var after = before
        after.nonces = 2100; after.dispatches = 3; after.gpuSeconds = 3
        after.activeSeconds = 6; after.uptimeSeconds = 13
        let fields = after.telemetryFields(since:before,batchSize:1000)
        #expect(fields["interval_nonces"] == "2000")
        #expect(fields["interval_dispatches"] == "2")
        #expect(fields["interval_hashrate"] == "200.0")
        #expect(fields["interval_gpu_hashrate"] == "1000.0")
        #expect(fields["interval_command_hashrate"] == "500.0")
        #expect(fields["interval_command_overhead_seconds"] == "2.0")
        #expect(fields["interval_outside_commands_seconds"] == "6.0")
        var idle = after; idle.uptimeSeconds += 30
        let idleFields = idle.telemetryFields(since:after,batchSize:1000)
        #expect(idleFields["interval_hashrate"] == "0.0")
        #expect(idleFields["interval_gpu_hashrate"] == "0.0")
        #expect(idleFields["interval_outside_commands_seconds"] == "30.0")
    }

    @Test func testDispatchAccountingAcrossFlushes() throws {
        var accumulator = SearchStatisticsAccumulator()
        let stats = StatisticsStore()
        for i in 0..<17 {
            let batch = SearchBatch(nonceCount:64,gpuSeconds:0.001,
                                    wallStartTime:Double(i),wallEndTime:Double(i)+0.002,candidates:[])
            accumulator.append(batch)?.record(in:stats)
        }
        #expect(stats.snapshot().dispatches == 16)
        accumulator.flush()?.record(in:stats)
        #expect(stats.snapshot().dispatches == 17)
        #expect(stats.snapshot().nonces == 1088)
        #expect(accumulator.flush() == nil)
    }

    @Test func testShareContextSurvivesTargetChangeAndLogAppends() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("events.jsonl")
        let historical = "{\"schemaVersion\":1,\"timestamp\":\"2026-09-27T00:00:00Z\"}\n"
        try Data(historical.utf8).write(to:file)
        let writer = JSONLEventWriter(path:file.path), stats = StatisticsStore()
        let coordinator = MiningCoordinator(stats:stats,writer:writer,onMessage:{ _ in })
        coordinator.start()
        let old = try makeJob(), newer = try makeJob(generation:2,target:UInt256(bigEndian:[1]))
        coordinator.handle(.target(old.target)); coordinator.handle(.job(old))
        let share = ShareMetadata(id:10,job:old)
        coordinator.handle(.shareSubmitted(share))
        coordinator.handle(.target(newer.target)); coordinator.handle(.job(newer))
        coordinator.handle(.shareResult(share:share,accepted:false,message:"pool rejected share (code 23)",responseMilliseconds:123.5))
        coordinator.finish()
        #expect(writer.failure == nil)
        let raw = try String(contentsOf:file,encoding:.utf8)
        #expect(raw.hasPrefix(historical))
        let events = try raw.split(separator:"\n").dropFirst().map {
            try #require(JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any])
        }
        #expect(events.allSatisfy { ($0["schemaVersion"] as? Int) == 2 })
        let stamps = try events.map { try #require($0["monotonicNanoseconds"] as? UInt64) }
        #expect(stamps == stamps.sorted())
        let timestamp = try #require(events.first?["timestamp"] as? String)
        #expect(timestamp.range(of:#"\.\d{3}Z$"#,options:.regularExpression) != nil)
        let rejected = try #require(events.first { ($0["type"] as? String) == "share_rejected" })
        let fields = try #require(rejected["fields"] as? [String:String])
        #expect(fields["generation"] == "1")
        #expect(fields["target_hex"] == old.target.bigEndianBytes.hex)
        #expect(fields["response_ms"] == "123.5")
        #expect(stats.snapshot().submitted == 1)
        #expect(stats.snapshot().rejected == 1)
    }
}
