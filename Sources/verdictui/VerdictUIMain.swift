// The `verdictui` binary.
//
// Deliberately tiny. Nothing inside an executable target is reachable from any
// test in the same package, so every line here is a line no test can execute —
// the whole command surface lives in `VerdictUICLICore`, which the test target
// imports and drives directly.
//
// The file is NOT called `main.swift`, and that is load-bearing: Swift gives a
// file with that name top-level-code semantics and then refuses `@main` in the
// same module. Going the other way — a `main.swift` calling `VerdictUITool.main()`
// — selects the SYNCHRONOUS overload on an async root command, which builds
// cleanly, passes every library test, and then fails at RUN time with
// "Asynchronous root command needs availability annotation". Measured: the CLI
// suite was 8/8 green against a binary that could not execute a single command.
import VerdictUICLICore

@main
struct VerdictUIBinary {
    static func main() async {
        await VerdictUITool.main()
    }
}
