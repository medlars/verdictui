import VerdictUICLICore
import VerdictUIDemoScenarios

@main
struct VerdictUIProjectRunner {
    static func main() async {
        await VerdictUIRunner.main(registry: DemoScenarios.registry)
    }
}
