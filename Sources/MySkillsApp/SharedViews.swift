import MarkdownUI
import SwiftUI

/// Shared layout metrics for a consistent 8pt grid.
enum Metrics {
    static let rowCornerRadius: CGFloat = 6
    static let cardCornerRadius: CGFloat = 10
}

/// Selection and hover background for the hand-built list rows,
/// with a subtle transition that respects Reduce Motion.
private struct SelectableRowBackground: ViewModifier {
    var isSelected: Bool
    var isHovering: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }

    private var fill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }

        if isHovering {
            return AnyShapeStyle(Color.primary.opacity(0.06))
        }

        return AnyShapeStyle(Color.clear)
    }
}

extension View {
    func selectableRowBackground(isSelected: Bool, isHovering: Bool) -> some View {
        modifier(SelectableRowBackground(isSelected: isSelected, isHovering: isHovering))
    }
}

struct MarkdownDocumentView: View {
    var markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(.gitHub)
            .textSelection(.enabled)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
