import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// The compiler-plugin entry point: the list the toolchain consults to resolve
/// every `@Verifiable` / `#VerdictScenario` spelling in a consumer's source.
///
/// A macro that is implemented but absent from this array fails at *use* site
/// with "external macro implementation type could not be found", which reads
/// like a toolchain fault rather than a missing registration — so the registry
/// is asserted against the implementations by `MacroPluginTests` rather than
/// maintained by memory.
@main
struct VerdictUIMacroPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        VerifiableMacro.self,
        VerdictScenarioMacro.self,
    ]
}
