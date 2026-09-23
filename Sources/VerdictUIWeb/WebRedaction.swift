import Foundation

/// Only allowlisted DOM metadata leaves the browser boundary. This second
/// boundary masks known credentials reflected by a page and URL auth material.
public enum WebRedaction {
    public static func clean(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
            let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: unreserved), encoded != secret {
                result = result.replacingOccurrences(of: encoded, with: "[REDACTED]", options: .caseInsensitive)
            }
        }
        guard let pattern = try? NSRegularExpression(pattern: "(?:https?|file)://[^\\s<>\\\"']+") else { return result }
        for match in pattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result), let url = URL(string: String(result[range])) else { continue }
            result.replaceSubrange(range, with: safeURL(url))
        }
        return result
    }

    public static func safeURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "[URL]" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? "[URL]"
    }
}
