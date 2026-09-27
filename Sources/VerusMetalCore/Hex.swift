import Foundation

public extension Array where Element == UInt8 {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self = []
        reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
