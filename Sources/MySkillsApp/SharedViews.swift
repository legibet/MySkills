import MarkdownUI
import SwiftUI

struct EmptyStateView<Actions: View>: View {
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            actions
                .padding(.top, 4)
        }
    }
}

struct MarkdownDocumentView: View {
    var markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(.gitHub)
            .textSelection(.enabled)
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, message: String) {
        self.title = title
        self.message = message
        actions = EmptyView()
    }
}
