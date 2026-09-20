import Foundation

enum NotificationHTTPPolicy {
    static let maximumBodyBytes = 1_048_576
    static let maximumHeaderBytes = 16_384

    static func contentLength(of header: String) -> Int? {
        var length: Int?
        for line in header.components(separatedBy: "\r\n").dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { if !line.isEmpty { return nil }; continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "transfer-encoding" { return nil }
            if name == "content-length" {
                let raw = pair[1].trimmingCharacters(in: .whitespaces)
                guard length == nil, !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                      let value = Int(raw), value <= maximumBodyBytes else { return nil }
                length = value
            }
        }
        return length ?? 0
    }
}
