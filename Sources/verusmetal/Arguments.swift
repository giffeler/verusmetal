import Foundation
import VerusMetalCore

struct Arguments {
    let command: String
    private let values: [String: String]
    private let flags: Set<String>

    init(_ raw: [String]) throws(CLIError) {
        guard let command = raw.first else { throw CLIError.usage }
        self.command = command
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 1
        while index < raw.count {
            let item = raw[index]
            guard item.hasPrefix("--") else { throw CLIError.invalidArgument(item) }
            let key = String(item.dropFirst(2))
            guard !key.isEmpty else { throw CLIError.invalidArgument(item) }
            guard values[key] == nil, !flags.contains(key) else {
                throw CLIError.invalidArgument("duplicate option --\(key)")
            }
            if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                values[key] = raw[index + 1]; index += 2
            } else {
                flags.insert(key); index += 1
            }
        }
        self.values = values; self.flags = flags
    }

    func string(_ key: String, default fallback: String? = nil) -> String? { values[key] ?? fallback }
    func require(_ key: String) throws(CLIError) -> String {
        guard let value = values[key], !value.isEmpty else { throw CLIError.missing("--\(key)") }
        return value
    }
    func int(_ key: String, default fallback: Int) throws(CLIError) -> Int {
        guard let raw = values[key] else { return fallback }
        guard let value = Int(raw) else { throw CLIError.invalidArgument("--\(key) \(raw)") }
        return value
    }

    func int(
        _ key: String,
        default fallback: Int,
        in range: ClosedRange<Int>
    ) throws(CLIError) -> Int {
        let value = try int(key, default: fallback)
        guard range.contains(value) else {
            throw CLIError.invalidArgument("--\(key) must be in \(range.lowerBound)...\(range.upperBound)")
        }
        return value
    }

    func optionalInt(
        _ key: String,
        in range: ClosedRange<Int>
    ) throws(CLIError) -> Int? {
        guard let raw = values[key] else { return nil }
        guard let value = Int(raw), range.contains(value) else {
            throw CLIError.invalidArgument("--\(key) must be in \(range.lowerBound)...\(range.upperBound)")
        }
        return value
    }

    func has(_ key: String) -> Bool { flags.contains(key) }

    func validate(
        valueOptions: Set<String> = [],
        flagOptions: Set<String> = []
    ) throws(CLIError) {
        for key in flags.sorted() {
            if valueOptions.contains(key) { throw CLIError.missing("--\(key) value") }
            guard flagOptions.contains(key) else { throw CLIError.invalidArgument("--\(key)") }
        }
        for key in values.keys.sorted() {
            if flagOptions.contains(key) {
                throw CLIError.invalidArgument("--\(key) does not take a value")
            }
            guard valueOptions.contains(key) else { throw CLIError.invalidArgument("--\(key)") }
        }
    }
}

enum CLIError: Error, LocalizedError {
    case usage
    case invalidArgument(String)
    case missing(String)
    case invalidAddress
    case fixture(String)

    var errorDescription: String? {
        switch self {
        case .usage: return "missing command"
        case .invalidArgument(let value): return "invalid argument: \(value)"
        case .missing(let value): return "missing required option \(value)"
        case .invalidAddress: return "wallet is not a valid Verus transparent address"
        case .fixture(let value): return "invalid replay fixture: \(value)"
        }
    }
}

let usage = """
VerusMetal 0.1.0 — Apple Silicon VerusHash v2.2 miner

  verusmetal devices
  verusmetal benchmark [--duration 10] [--batch 4096]
  verusmetal verify --fixtures tests/v22-vectors.json
  verusmetal mine --config Config/local.json [--duration SECONDS]
  verusmetal mine --pool stratum+ssl://host:port --wallet address [--worker m4]
                 [--batch 4096] [--stats-file path] [--stats-interval 10]
                 [--telemetry-interval 30]
                 [--api-bind 127.0.0.1:4079] [--stop-after-shares N]

The password is VERUSMETAL_POOL_PASSWORD or "x" and is never logged.
TLS uses system certificate validation. No automatic plaintext fallback.
"""
