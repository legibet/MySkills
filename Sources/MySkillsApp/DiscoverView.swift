import SwiftUI

struct DiscoverView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var store: AppStore
    @State private var selectedResultID: String?
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if store.isSearching {
                ProgressView("Searching")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.searchResults.isEmpty {
                EmptyStateView(
                    title: "Find skills",
                    message: "Search GitHub skills or browse a Git repository.",
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(store.searchResults) { result in
                                SearchResultRow(
                                    store: store,
                                    result: result,
                                    isSelected: selectedResultID == result.id,
                                    select: {
                                        selectedResultID = result.id
                                        isListFocused = true
                                    },
                                    open: {
                                        selectedResultID = result.id
                                        openWindow(id: "reader", value: result.readerRequest)
                                    },
                                )
                                .id(result.id)
                                .contextMenu {
                                    Button("Read") {
                                        selectedResultID = result.id
                                        openWindow(id: "reader", value: result.readerRequest)
                                    }

                                    if !store.installed(result) {
                                        Button("Install") {
                                            Task { await store.install(result) }
                                        }
                                    }

                                    if let url = result.sourceWebURL {
                                        Button("Source") {
                                            store.openURL(url)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isListFocused)
                    .onKeyPress(.upArrow) {
                        moveSelection(-1, proxy: proxy)
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(1, proxy: proxy)
                    }
                    .onKeyPress(.return) {
                        openSelectedResult()
                    }
                }
            }
        }
        .navigationTitle("Discover")
    }

    private func moveSelection(_ direction: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !store.searchResults.isEmpty else {
            return .ignored
        }

        let currentIndex = store.searchResults.firstIndex { $0.id == selectedResultID }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + direction, 0), store.searchResults.count - 1)
        } else {
            nextIndex = direction > 0 ? 0 : store.searchResults.count - 1
        }

        let result = store.searchResults[nextIndex]
        selectedResultID = result.id
        proxy.scrollTo(result.id, anchor: .center)
        return .handled
    }

    private func openSelectedResult() -> KeyPress.Result {
        guard let result = store.searchResults.first(where: { $0.id == selectedResultID }) else {
            return .ignored
        }

        openWindow(id: "reader", value: result.readerRequest)
        return .handled
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search GitHub skills", text: $store.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await store.search() }
                    }

                Button {
                    Task { await store.search() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                TextField("GitHub, GitLab, or Git URL", text: $store.sourceInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await store.browseSource() }
                    }

                Button {
                    Task { await store.browseSource() }
                } label: {
                    Label("Browse", systemImage: "list.bullet")
                }
                .disabled(store.sourceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSearching)
            }
        }
        .padding(16)
    }
}

struct SearchResultRow: View {
    @Bindable var store: AppStore
    var result: SkillSearchResult
    var isSelected: Bool
    var select: () -> Void
    var open: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                open()
            })

            if store.installed(result) {
                Text("Installed")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .center)
            } else {
                Button {
                    Task { await store.install(result) }
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .disabled(store.isInstalling)
            }

            if let url = result.sourceWebURL {
                Button {
                    store.openURL(url)
                } label: {
                    Label("Source", systemImage: "arrow.up.right.square")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var subtitle: String {
        if result.sourceKind == .git {
            let service = result.gitURL.map(SourceURL.serviceLabel) ?? "Git"
            let repository = result.gitURL.map(SourceURL.repositoryLabel) ?? result.source
            if let subpath = result.subpath, !subpath.isEmpty {
                return "\(service) · \(repository) · \(subpath)"
            }
            return "\(service) · \(repository)"
        }

        return "GitHub · \(result.source) · \(result.installsText)"
    }

    private var rowBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.14))
        }

        if isHovering {
            return AnyShapeStyle(Color.primary.opacity(0.05))
        }

        return AnyShapeStyle(Color.clear)
    }
}
