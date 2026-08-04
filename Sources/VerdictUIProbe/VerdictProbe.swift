// VerdictUIProbe — SwiftUI instrumentation runtime.
// Wave 2 replaces this seed with the Layout-protocol transparent probe and the
// full preference-key semantic-tree assembly (see docs/implementation-plan.md).
import SwiftUI
import VerdictUIKernel

/// Preference key carrying probed frames up the view tree. The oracle harness
/// reads this at the root to assemble the `SemanticNode` tree.
public struct VerdictFramesKey: PreferenceKey {
    public static let defaultValue: [String: Rect] = [:]

    public static func reduce(value: inout [String: Rect], nextValue: () -> [String: Rect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Tag a view so VerdictUI records its resolved frame in root coordinates.
    /// Non-invasive: hosted in a clear background, does not affect layout.
    public func verdictProbe(_ id: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: VerdictFramesKey.self,
                    value: [
                        id: Rect(
                            x: proxy.frame(in: .global).origin.x,
                            y: proxy.frame(in: .global).origin.y,
                            width: proxy.size.width,
                            height: proxy.size.height
                        )
                    ]
                )
            }
        )
    }
}
