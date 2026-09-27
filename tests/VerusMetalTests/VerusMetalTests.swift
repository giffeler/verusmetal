import XCTest
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

final class HashTests: XCTestCase {
    func testIndependentFixtures() throws {
        struct Vector: Decodable { let input: String; let digest: String }
        struct File: Decodable { let vectors: [Vector] }
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"v22-vectors",withExtension:"json"))
        let file = try JSONDecoder().decode(File.self,from:Data(contentsOf:url))
        XCTAssertEqual(file.vectors.count,148)
        let solver = try MetalVerusSolver(batchSize:1,validation:true)
        for f in file.vectors {
            let bytes = try XCTUnwrap([UInt8](hex:f.input))
            XCTAssertEqual(VerusHash.digest(bytes).hex,f.digest)
            let result = try solver.search(input:bytes,nonceOffset:0,nonceBytes:0,target:.max)
            XCTAssertEqual(result.candidates.first?.digest.hex,f.digest)
        }
    }
    func testPartialGroupsNonceMappingAndReuse() throws {
        let solver = try MetalVerusSolver(batchSize:129,validation:true)
        let job = try makeJob()
        for count in [1,31,32,33,127,128,129] {
            let result = try solver.search(job:job,firstNonce:0x0102030405060708,count:count)
            XCTAssertEqual(result.candidates.count,count)
            for (i,candidate) in result.candidates.enumerated() {
                XCTAssertEqual(candidate.nonce,0x0102030405060708+UInt64(i))
                XCTAssertEqual(candidate.digest,VerusHash.digest(try job.input(nonce:candidate.nonce)))
            }
        }
    }
    func testTargetEqualityAndLittleEndianOrder() throws {
        let solver = try MetalVerusSolver(batchSize:1,validation:true)
        let bytes = Array((0..<64).map(UInt8.init))
        let digest = VerusHash.digest(bytes)
        let equal = UInt256(bigEndian:Array(digest.reversed()))
        XCTAssertEqual(try solver.search(input:bytes,nonceOffset:0,nonceBytes:0,target:equal).candidates.count,1)
        var lower = equal.limbs
        for i in lower.indices.reversed() {
            if lower[i] > 0 { lower[i] -= 1; break }
            lower[i] = .max
        }
        XCTAssertTrue(try solver.search(input:bytes,nonceOffset:0,nonceBytes:0,target:UInt256(limbs:lower)).candidates.isEmpty)
        XCTAssertFalse(VerusHash.meetsTarget(digest,UInt256(limbs:lower)))
    }
    func testNonceBoundsAndPreparationModeChange() throws {
        let solver = try MetalVerusSolver(batchSize:2,validation:true)
        let bytes = [UInt8](repeating:0,count:64)
        XCTAssertThrowsError(try solver.search(input:bytes,nonceOffset:56,nonceBytes:8,target:.max,firstNonce:.max))
        XCTAssertThrowsError(try solver.search(input:bytes,nonceOffset:63,nonceBytes:2,target:.max))
        XCTAssertThrowsError(try solver.search(input:bytes,nonceOffset:56,nonceBytes:1,target:.max,firstNonce:255))
        let max = try solver.search(input:bytes,nonceOffset:56,nonceBytes:8,target:.max,firstNonce:.max,count:1)
        XCTAssertEqual(max.candidates.count,1)
        let plain = try solver.search(input:bytes,nonceOffset:0,nonceBytes:0,target:.max,count:1)
        XCTAssertEqual(plain.candidates[0].digest,VerusHash.digest(bytes))
    }
}

final class ProtocolTests: XCTestCase {
    func testPBaaSCanonicalViewAndSubmission() throws {
        let job = try makeJob()
        XCTAssertEqual(job.hashInput.count,1487)
        XCTAssertEqual(job.nonceOffset,1476)
        XCTAssertEqual(job.nonceBytes,8)
        for r in [4..<100,104..<140,151..<215] { XCTAssertTrue(job.hashInput[r].allSatisfy {$0==0}) }
        XCTAssertEqual(Array(job.hashInput[100..<104]),[0x12,0x34,0x56,0x78])
        XCTAssertEqual(Array(job.hashInput[215..<267]),Array(job.solution[72..<124]))
        XCTAssertEqual(Array(job.header[4..<36]),[UInt8](repeating:0x11,count:32))
        let params = try job.submission(user:"wallet.m4",nonce:0x0102030405060708)
        XCTAssertEqual(params.count,5); XCTAssertEqual(params[2],"12345678")
        XCTAssertEqual(params[3].count,56)
        let submitted = try XCTUnwrap([UInt8](hex:params[4]))
        XCTAssertEqual(submitted.count,1347); XCTAssertEqual(Array(submitted.prefix(3)),[0xfd,0x40,0x05])
        XCTAssertEqual(Array(submitted[3..<1329+3]),Array(job.solution[..<1329]))
        XCTAssertEqual(Array(submitted[(1329+3)..<(1329+7)]),[1,2,3,4])
        XCTAssertEqual(Array(submitted[(1333+3)..<(1341+3)]),[8,7,6,5,4,3,2,1])
    }
    func testVersion8PBaaSViewAndGPUHash() throws {
        let job = try VerusStratumJob.decode(makeParams(version:8),generation:1,prefix:[1,2,3,4],target:.max)
        let old = try makeJob()
        var expected = old.hashInput
        expected[143] = 8
        XCTAssertEqual(job.hashInput,expected)
        let nonce: UInt64 = 0x0102030405060708
        let submitted = try XCTUnwrap([UInt8](hex:job.submission(user:"wallet.m4",nonce:nonce)[4]))
        XCTAssertEqual(submitted[3],8)
        XCTAssertEqual(Array(submitted[3..<1332]),Array(job.solution[..<1329]))
        let solver = try MetalVerusSolver(batchSize:1,validation:true)
        let batch = try solver.search(input:job.hashInput,nonceOffset:job.nonceOffset,nonceBytes:job.nonceBytes,
                                     target:.max,firstNonce:nonce,count:1)
        XCTAssertEqual(batch.candidates.first?.digest,VerusHash.digest(try job.input(nonce:nonce)))
        XCTAssertThrowsError(try VerusStratumJob.decode(makeParams(version:9),generation:1,prefix:[1],target:.max))
    }
    func testCompactPBaaSDescriptorAndNonceBoundary() throws {
        var params = makeParams(version:8)
        var reserved = [UInt8](repeating:0,count:229)
        reserved[0] = 8; reserved[5] = 3; reserved[6] = 4
        reserved[228] = 1
        params[8] = reserved.hex
        let job = try VerusStratumJob.decode(params,generation:1,prefix:[1,2,3,4],target:.max)
        XCTAssertEqual(Array(job.solution[228..<232]),[1,0,0,0])
        XCTAssertEqual(Array(job.solution[1329..<1333]),[1,2,3,4])
        // Three headers consume 228 bytes; payload must end before the nonce tail.
        reserved[6] = 0x4d; reserved[7] = 4 // 1101 bytes: ends exactly at 1329.
        params[8] = reserved.hex
        XCTAssertNoThrow(try VerusStratumJob.decode(params,generation:1,prefix:[1],target:.max))
        reserved[6] = 0x4e; params[8] = reserved.hex
        XCTAssertThrowsError(try VerusStratumJob.decode(params,generation:1,prefix:[1],target:.max))
    }
    func testLegacySolutionAndRejectUnsupportedLayouts() throws {
        var p = makeParams(version:4); p[8] = "04"
        let job = try VerusStratumJob.decode(p,generation:1,prefix:[1],target:.max)
        XCTAssertEqual(job.hashInput[4],0x11)
        p[8] = "03"; XCTAssertThrowsError(try VerusStratumJob.decode(p,generation:1,prefix:[1],target:.max))
        p[8] = "08"; XCTAssertThrowsError(try VerusStratumJob.decode(p,generation:1,prefix:[1],target:.max))
        p = makeParams(); p[2] = "00"; XCTAssertThrowsError(try VerusStratumJob.decode(p,generation:1,prefix:[1],target:.max))
        XCTAssertThrowsError(try VerusStratumJob.decode(makeParams(),generation:1,prefix:[],target:.max))
        XCTAssertThrowsError(try VerusStratumJob.decode(makeParams(),generation:1,prefix:[1],target:.zero))
    }
    func testSubscriptionAddressAndURLValidation() throws {
        XCTAssertEqual(try VerusStratumClient.decodeSubscription([NSNull(),"01020304"]),[1,2,3,4])
        XCTAssertThrowsError(try VerusStratumClient.decodeSubscription([NSNull(),"zz"]))
        XCTAssertTrue(VerusAddress.isValid("R9HDHYTuwAr3PyRkXrhYgwycrxC7Xja8zs"))
        XCTAssertFalse(VerusAddress.isValid("R9HDHYTuwAr3PyRkXrhYgwycrxC7Xja8z1"))
        XCTAssertThrowsError(try VerusStratumClient(url:"https://example.com:1",user:"u") {_ in})
        XCTAssertThrowsError(try VerusStratumClient(url:"stratum+ssl://u:p@example.com:1",user:"u") {_ in})
        XCTAssertEqual(VerusStratumClient.shareRejectionDiagnostic([23,"secret",NSNull()]),"pool rejected share (code 23)")
    }
}

final class FakeClient: MiningStratumClient, Sendable {
    let calls = Mutex((connect:0,disconnect:0,submit:0))
    func connect() { calls.withLock { $0.connect += 1 } }
    func disconnect() { calls.withLock { $0.disconnect += 1 } }
    func submit(job: VerusStratumJob, nonce: UInt64) throws -> Int { calls.withLock { $0.submit += 1; return $0.submit } }
}
final class LifecycleTests: XCTestCase {
    func testStaleJobAndCPUVerification() throws {
        let stats = StatisticsStore(), client = FakeClient()
        let coordinator = MiningCoordinator(stats:stats,writer:JSONLEventWriter(path:nil))
        coordinator.configure(client:client); coordinator.start(); coordinator.handle(.authorized)
        let old = try makeJob(), new = try makeJob(generation:2)
        coordinator.handle(.job(old)); XCTAssertTrue(coordinator.isCurrent(old))
        let digest = VerusHash.digest(try old.input(nonce:1))
        coordinator.handle(.job(new)); XCTAssertFalse(coordinator.isCurrent(old))
        try coordinator.submit(Candidate(nonce:1,digest:digest),for:old)
        XCTAssertEqual(stats.snapshot().stale,1); XCTAssertEqual(client.calls.withLock {$0.submit},0)
        XCTAssertThrowsError(try coordinator.submit(Candidate(nonce:1,digest:[UInt8](repeating:0,count:32)),for:new))
        try coordinator.submit(Candidate(nonce:1,digest:digest),for:new)
        XCTAssertEqual(client.calls.withLock {$0.submit},1)
        coordinator.stop(); XCTAssertTrue(coordinator.isStopped); XCTAssertNil(coordinator.nextWork())
    }
    func testReconnectCancellationAndNonceExhaustion() throws {
        let client = FakeClient(), coordinator = MiningCoordinator(stats:StatisticsStore(),writer:JSONLEventWriter(path:nil),reconnectDelay:0.05)
        coordinator.configure(client:client); coordinator.start(); coordinator.handle(.disconnected("test")); coordinator.stop()
        Thread.sleep(forTimeInterval:0.1)
        XCTAssertEqual(client.calls.withLock {$0.connect},1)
        var sequence = NonceSequence(start:UInt64.max-2,maximum:.max)
        XCTAssertEqual(try sequence.take(2),UInt64.max-2)
        XCTAssertEqual(try sequence.take(1),UInt64.max)
        XCTAssertThrowsError(try sequence.take(1))
        var narrow = NonceSequence(start:254,maximum:255)
        XCTAssertThrowsError(try narrow.take(3)); XCTAssertEqual(try narrow.take(2),254)
    }
    func testArgumentsAndAPIExposure() throws {
        XCTAssertThrowsError(try Arguments(["mine","--pool","a","--pool","b"]))
        let args = try Arguments(["mine","--batch","0"])
        XCTAssertThrowsError(try args.int("batch",default:4096,in:1...32768))
        XCTAssertThrowsError(try StatisticsHTTPServer(store:StatisticsStore()).start(bind:"0.0.0.0:4079"))
    }
}
