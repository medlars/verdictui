import SwiftUI
import VerdictUICLICore
import VerdictUIKernel
import VerdictUIProbe

struct SettingsScenario: VerdictScenario, Sendable {
    let faulty: Bool
    var name: String { faulty ? "consumer-fault" : "consumer-settings" }

    func body(state: ScenarioState) -> some View {
        Button("Save") {}
            .buttonStyle(.plain)
            .frame(width: faulty ? 6 : 96, height: faulty ? 6 : 32)
            .verdictProbe("consumer-save", role: .button, text: "Save")
    }
}

@main
struct ConsumerMain {
    static func main() async {
        await VerdictUIRunner.main(
            registry: ScenarioRegistry([
                ScenarioEntry(viewport: Size(width: 320, height: 200)) { SettingsScenario(faulty: false) },
                ScenarioEntry(viewport: Size(width: 320, height: 200)) { SettingsScenario(faulty: true) },
            ]))
    }
}
