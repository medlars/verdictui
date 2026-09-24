import Foundation

/// The web session's wall-clock budgets, scaled for hosts slower than the
/// developer hardware they were set on.
///
/// The budgets bound a capture so a hung page refuses instead of hanging the
/// caller. Hosted CI runners run these captures ~2x slower than a developer Mac,
/// so heavy pages ran out of budget there and refused with "deadline exceeded"
/// instead of the verdict under test (CIS-4ADF5658). `VERDICTUI_WEB_TIMEOUT_SCALE`
/// stretches every budget together; it can never shrink them below the defaults.
struct WebTiming: Sendable, Equatable {
    static let scaleVariable = "VERDICTUI_WEB_TIMEOUT_SCALE"
    static let maximumScale = 10.0
    static let current = WebTiming(scale: scale(from: ProcessInfo.processInfo.environment))

    let scale: Double

    /// Page settle plus capture, including every frame-coherence retry.
    var captureDeadline: Duration { .seconds(10 * scale) }
    /// One CDP request inside a capture, and one session command.
    var requestCap: Duration { .seconds(5 * scale) }
    var captureDeadlineDescription: String { String(format: "%g seconds", 10 * scale) }

    static func scale(from environment: [String: String]) -> Double {
        guard let raw = environment[scaleVariable], let value = Double(raw), value.isFinite, value >= 1
        else { return 1 }
        return min(value, maximumScale)
    }
}
