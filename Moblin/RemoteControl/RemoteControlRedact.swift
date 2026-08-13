import Foundation

// Keys whose values must never reach a log. A stream key is enough to hijack
// somebody's broadcast, and a full RTMP url usually has the key in its path.
private let sensitiveJsonKeys = [
    "streamKey",
    "stream_key",
    "url",
    "authentication",
    "accessToken",
    "access_token",
    "password",
    "token",
    "controlToken",
    "control_token",
]

private let sensitiveJsonValue = try! NSRegularExpression(
    pattern: "\"(\(sensitiveJsonKeys.joined(separator: "|")))\"\\s*:\\s*\"(\\\\.|[^\"\\\\])*\"",
    options: [.caseInsensitive]
)

// Replaces the values of known sensitive keys with a placeholder, leaving the
// rest of the message readable for debugging.
func redactSensitiveJsonValues(_ json: String) -> String {
    let range = NSRange(json.startIndex ..< json.endIndex, in: json)
    return sensitiveJsonValue.stringByReplacingMatches(in: json,
                                                       range: range,
                                                       withTemplate: "\"$1\":\"<redacted>\"")
}
