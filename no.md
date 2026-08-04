# VerdictUI — Deliberate Non-Decisions (no.md)

Numbered list of things we deliberately did NOT do, so future sessions stop re-litigating them.

1. **No private SwiftUI API in the core path.** `_viewDebugData()` / `SWIFTUI_VIEW_DEBUG=287` / AttributeGraph interception are powerful but break across OS releases. They may ship later as an *optional* adapter target, never as a core dependency. Decided 2026-08-04 (three-option deliberation during product design; public-API instrumentation chosen as the spine).
2. **No external AX scraping as the primary channel.** `AXUIElement` trees depend on developer labeling and permissions; they are the *cross-validation* channel (middle loop), not the source of truth. Decided 2026-08-04.
3. **No web backend in Waves 1–9.** The contract (CLI/MCP verbs, verdict schema) is designed platform-agnostic from day one, but the web adapter is deferred until the SwiftUI backend is proven — web engines already exist free (CDP/Playwright); SwiftUI is the differentiated wedge. Decided 2026-08-04.
4. **No proprietary licensing for the engine.** Open-core: MIT engine for adoption, monetize the hosted workflow layer later. Decided 2026-08-04 after competitive research (all serious competitors are free; closed dev CLIs get zero adoption).
5. **No CoreGraphics types in the kernel.** `Rect` is hand-rolled so `VerdictUIKernel` compiles on Linux CI for pure-logic tests. Decided 2026-08-04.
