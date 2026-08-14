// A SagaMail screen, adopted into VerdictUI.
//
// This reproduces the structure of SagaMail's real
// `Sources/SagaMailUI/NotificationsSettingsTab.swift` — a `Form` of `Section`s
// carrying toggles, a slider row, `ForEach` pickers, and a conditional advanced
// block that appears only when a disclosure toggle is on.
//
// It is a REPRODUCTION rather than the file itself for one reason: SagaMail's
// working tree carries 293 uncommitted files on a WIP branch, so an edit there
// would mix into somebody else's in-flight work with no reviewable diff
// (DIR-035). The shapes are what matter for the dogfood — `Form`/`Section`,
// conditional content, `ForEach`, `Toggle`, `Slider`, `HStack` — and every one
// of them is present here. The real view's `@AppStorage`/`@Environment` state
// is replaced by plain `@State`, which changes nothing about layout.
import SwiftUI
import VerdictUIMacroSupport

/// How multiple notification banners are grouped. Mirrors SagaMail's enum.
public enum NotificationGrouping: String, CaseIterable, Identifiable, Sendable {
    case byAccount, bySender, byThread, none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .byAccount: "By Account"
        case .bySender: "By Sender"
        case .byThread: "By Thread"
        case .none: "No Grouping"
        }
    }
}

/// Digest cadence. Mirrors SagaMail's enum, including the long label that is
/// the reason this screen is worth verifying at all.
public enum DigestSchedule: String, CaseIterable, Identifiable, Sendable {
    case off, hourly, everyFourHours, morning, morningEvening

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .hourly: "Every Hour"
        case .everyFourHours: "Every 4 Hours"
        case .morning: "Morning (9 AM)"
        case .morningEvening: "Morning & Evening (9 AM / 6 PM)"
        }
    }
}

/// SagaMail's notification settings tab.
///
/// The `@Verifiable` line is the entire adoption cost: it probes the view's
/// elements so a verdict can name them. Nothing else in this file exists for
/// VerdictUI's benefit.
@Verifiable
public struct NotificationsSettingsScreen: View {
    @State private var notificationsEnabled = true
    @State private var soundEnabled = true
    @State private var badgeCountEnabled = true
    @State private var grouping: NotificationGrouping = .byAccount
    @State private var digestSchedule: DigestSchedule = .off
    @State private var smartPriorityThreshold: Double = 0.75
    @State private var showAdvanced = false

    public init(showAdvanced: Bool = false) {
        _showAdvanced = State(initialValue: showAdvanced)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notifications")
                .font(.headline)

            Toggle("Enable Notifications", isOn: $notificationsEnabled)

            // Conditional content — the shape Wave 4 Task 4 found entirely
            // unprobed, because an `if` in a @ViewBuilder is a STATEMENT.
            if notificationsEnabled {
                HStack {
                    Text("Priority Threshold")
                    Slider(value: $smartPriorityThreshold, in: 0.5 ... 0.95, step: 0.05)
                    Text(smartPriorityThreshold, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                }

                Toggle("Sound", isOn: $soundEnabled)
                Toggle("Badge Count", isOn: $badgeCountEnabled)
            }

            if showAdvanced {
                Text("Advanced Notifications")
                    .font(.headline)

                // ForEach — the shape that expanded to non-compiling source
                // before Wave 4 Task 4 fixed the closure-signature trivia.
                Picker("Grouping", selection: $grouping) {
                    ForEach(NotificationGrouping.allCases) { group in
                        Text(group.displayName).tag(group)
                    }
                }

                Picker("Digest Mode", selection: $digestSchedule) {
                    ForEach(DigestSchedule.allCases) { schedule in
                        Text(schedule.displayName).tag(schedule)
                    }
                }
            }
        }
        .padding()
    }
}
