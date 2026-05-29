import SwiftUI

struct SkillReaderView: View {
    @Bindable var store: AppStore
    var request: SkillReaderRequest

    @AppStorage("folderOpenMode") private var folderOpenModeRaw = FolderOpenMode.defaultFolderApp.rawValue
    @AppStorage("selectedOpenApplicationPath") private var selectedOpenApplicationPath = ""
    @State private var markdown = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showingEnableSheet = false

    private var installedSkill: SkillRecord? {
        store.skills.first { $0.name == request.name }
    }

    private var folderOpenMode: FolderOpenMode {
        FolderOpenMode(rawValue: folderOpenModeRaw) ?? .defaultFolderApp
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if isLoading {
                ProgressView("Loading SKILL.md")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                EmptyStateView(title: "Preview unavailable", message: errorMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    MarkdownDocumentView(markdown: markdown)
                }
            }
        }
        .task(id: request.id) {
            await loadMarkdown()
        }
        .navigationTitle(request.displayName)
        .sheet(isPresented: $showingEnableSheet) {
            if let installedSkill {
                EnableSheet(store: store, skill: installedSkill)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let installedSkill {
                Button {
                    store.openSkill(
                        installedSkill,
                        mode: folderOpenMode,
                        applicationPath: selectedOpenApplicationPath,
                    )
                } label: {
                    Label("Open", systemImage: "folder")
                }

                Button {
                    showingEnableSheet = true
                } label: {
                    Label("Enable", systemImage: "checkmark.circle")
                }
            } else if let result = request.searchResult {
                Button {
                    Task { await store.install(result) }
                } label: {
                    Label(store.installed(result) ? "Installed" : "Install", systemImage: "arrow.down.circle")
                }
                .disabled(store.installed(result) || store.isInstalling)
            }

            if let url = request.sourceWebURL {
                Button {
                    store.openURL(url)
                } label: {
                    Label("Source", systemImage: "arrow.up.right.square")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        switch request.kind {
        case .library:
            return installedSkill.map { PathResolver.skillURL($0.name).path } ?? "Installed skill"
        case .marketplace:
            if let source = request.source, let installs = request.installs {
                return "GitHub · \(source) · \(formatInstalls(installs))"
            }
            return request.source ?? "GitHub skill"
        case .git:
            if let source = request.source, let subpath = request.subpath, !subpath.isEmpty {
                return "\(source) · \(subpath)"
            }
            return request.source ?? "Git source"
        }
    }

    private func formatInstalls(_ installs: Int) -> String {
        if installs >= 1_000_000 {
            return String(format: "%.1fM installs", Double(installs) / 1_000_000)
        }

        if installs >= 1000 {
            return String(format: "%.1fK installs", Double(installs) / 1000)
        }

        return installs == 1 ? "1 install" : "\(installs) installs"
    }

    @MainActor
    private func loadMarkdown() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            switch request.kind {
            case .library:
                markdown = try SkillLibrary.skillMarkdown(request.name)

            case .marketplace:
                guard let source = request.source, let skillID = request.skillID else {
                    throw AppError.message("This GitHub result is missing source metadata.")
                }
                markdown = try await SkillsSearchClient.skillMarkdown(source: source, skillID: skillID)

            case .git:
                guard let value = request.markdown else {
                    throw AppError.message("This Git result is missing SKILL.md content.")
                }
                markdown = value
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
