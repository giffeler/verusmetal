import Foundation
import VerusMetalCore

struct Arguments {
    let command: String
    private let values: [String: String]
    private let flags: Set<String>

    init(_ raw: [String]) throws(CLIError) {
        let leadingQuiet = raw.prefix(while: { $0 == "--quiet" }).count
        let raw = Array(raw.dropFirst(leadingQuiet)) + Array(repeating: "--quiet", count: leadingQuiet)
        guard let command = raw.first else { throw CLIError.usage }
        self.command = command
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 1
        while index < raw.count {
            let item = raw[index] == "-h" ? "--help" : raw[index]
            guard item.hasPrefix("--") else { throw CLIError.invalidArgument(item) }
            let name = String(item.dropFirst(2))
            let key = name == "batch" ? "batch-nonces" : name
            guard !key.isEmpty else { throw CLIError.invalidArgument(item) }
            guard values[key] == nil, !flags.contains(key) else {
                throw CLIError.invalidArgument("duplicate option --\(key)")
            }
            if key == "quiet" {
                flags.insert(key); index += 1
            } else if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
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
        let flagOptions = flagOptions.union(["quiet"])
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

let version = "0.2.3"

func commandUsage(_ command: String) -> String? {
    switch command {
    case "devices":
        return """
          verusmetal devices [--json]

        List Metal devices. JSON includes name, unifiedMemory and recommendedWorkingSetBytes.
        """
    case "benchmark":
        return """
          verusmetal benchmark [--duration 10] [--batch-nonces 32768] [--json]

        Measure full VerusHash v2.2 on a synthetic 1,487-byte input after warmup.
        Duration: 1...3600 seconds. Batch: 1...32768 nonces; --batch is an alias.
        JSON rates are hashes/second; text rates are MH/s. No pool connection is made.
        """
    case "verify":
        return """
          verusmetal verify --fixtures tests/v22-vectors.json

        Check independent reference digests on CPU and GPU with Metal validation.
        The fixture file is required and is not embedded in the executable.
        """
    case "mine":
        return """
          verusmetal mine --config Config/local.json [options]
          verusmetal mine --pool stratum+ssl://host:port --wallet address [options]

        Options:
          --pool URL                  Override the configured Stratum endpoint
          --wallet ADDRESS            Override the configured Verus transparent address
          --worker NAME               Optional ASCII alphanumeric name, 1...64 bytes; no default
          --password VALUE           Pool password; overrides environment (default: x)
          --batch-nonces N            Nonces per dispatch, 1...32768 (default: 32768)
          --batch N                   Compatibility alias for --batch-nonces
          --duration SECONDS          Stop after 1...604800 seconds (default: unlimited)
          --stop-after-shares N       Stop after 1...1000000 accepted shares
          --stats-file PATH           Append JSONL telemetry (default: disabled)
          --stats-interval SECONDS    Maximum statistics interval, 1...3600 (default: 10)
          --quiet                    Suppress stdout and stderr; exit codes are unchanged
          --telemetry-interval SECONDS  JSONL snapshots, 1...3600 (default: 30)
          --api-bind 127.0.0.1:4079   Enable the loopback status API (default: disabled)

        CLI pool, wallet and worker settings override the configuration file.
        Password order: --password, VERUSMETAL_POOL_PASSWORD, then "x".
        Passwords are not printed or written to telemetry.
        TLS uses system certificate validation. No automatic plaintext fallback.
        """
    default: return nil
    }
}

let usage = """
VerusMetal \(version) — Apple Silicon VerusHash v2.2 miner

Usage:
  verusmetal devices [--json]
  verusmetal benchmark [--duration 10] [--batch-nonces 32768] [--json]
  verusmetal verify --fixtures tests/v22-vectors.json
  verusmetal mine --config Config/local.json [options]
  verusmetal mine --pool stratum+ssl://host:port --wallet address [options]
  verusmetal --version

Use verusmetal COMMAND --help for command options; -h is also accepted.
--quiet is accepted before or after any command and suppresses stdout and stderr.
--batch remains an alias for --batch-nonces. Do not supply both names together.
Pool password: --password, VERUSMETAL_POOL_PASSWORD, then "x". No default worker name.
TLS uses system certificate validation. No automatic plaintext fallback.
"""
