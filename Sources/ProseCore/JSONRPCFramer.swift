import Foundation

public struct JSONRPCFramer: Sendable {
    private var buffer = Data()
    public init() {}

    public enum FramingError: Error { case invalidHeader, oversizedMessage }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            guard let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8),
                  let lengthLine = header.components(separatedBy: "\r\n")
                  .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(lengthLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[1]
                      .trimmingCharacters(in: .whitespaces)), length >= 0
            else {
                throw FramingError.invalidHeader
            }
            guard length <= 64 * 1024 * 1024 else {
                throw FramingError.oversizedMessage
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.count - bodyStart >= length else {
                return messages
            }
            messages.append(Data(buffer[bodyStart ..< (bodyStart + length)]))
            buffer = Data(buffer.dropFirst(bodyStart + length))
        }
        if buffer.count > 8192 {
            throw FramingError.invalidHeader
        }
        return messages
    }

    public static func encode(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var result = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        result.append(payload)
        return result
    }
}
