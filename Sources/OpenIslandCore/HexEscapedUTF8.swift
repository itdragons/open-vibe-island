import Foundation

/// Decodes C/Python-style `\xHH` byte escapes into UTF-8 text.
///
/// Some session sources surface non-ASCII path segments as hex escapes
/// (e.g. `\xe8\xa8\xba\xe7\x99\x82...` instead of `診療...`). When those
/// sequences are present, reassemble the bytes and decode as UTF-8 so
/// island titles stay human-readable.
public enum HexEscapedUTF8 {
    /// Returns `input` with `\xHH` sequences decoded when possible; otherwise
    /// returns `input` unchanged.
    public static func decodeIfNeeded(_ input: String) -> String {
        let trimmed = stripPythonBytesLiteral(input)
        guard trimmed.contains("\\x") || trimmed.contains("\\X") else {
            return input
        }
        guard let decoded = decodeHexEscapes(trimmed), !decoded.isEmpty else {
            return input
        }
        return decoded
    }

    private static func stripPythonBytesLiteral(_ input: String) -> String {
        if input.count >= 3,
           input.hasPrefix("b'"),
           input.hasSuffix("'") {
            return String(input.dropFirst(2).dropLast())
        }
        if input.count >= 3,
           input.hasPrefix("b\""),
           input.hasSuffix("\"") {
            return String(input.dropFirst(2).dropLast())
        }
        return input
    }

    private static func decodeHexEscapes(_ input: String) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(input.utf8.count)

        var index = input.startIndex
        var sawEscape = false

        while index < input.endIndex {
            if input[index] == "\\",
               input.distance(from: index, to: input.endIndex) >= 4 {
                let xIndex = input.index(after: index)
                if input[xIndex] == "x" || input[xIndex] == "X" {
                    let firstHex = input.index(after: xIndex)
                    let secondHex = input.index(after: firstHex)
                    let hex = String(input[firstHex...secondHex])
                    if let byte = UInt8(hex, radix: 16) {
                        bytes.append(byte)
                        sawEscape = true
                        index = input.index(after: secondHex)
                        continue
                    }
                }
            }

            let next = input.index(after: index)
            bytes.append(contentsOf: input[index..<next].utf8)
            index = next
        }

        guard sawEscape else {
            return nil
        }

        return String(bytes: bytes, encoding: .utf8)
    }
}
