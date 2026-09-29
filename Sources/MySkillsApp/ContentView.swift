import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @SceneStorage("selectedSection") private var selectedSection = MainSection.library.rawValue
    @State private var isImportingFolder = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedSection) {
                    ForEach(MainSection.allCases) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section.rawValue)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("MySkills")
        } detail: {
            detailView
        }
        .fileImporter(isPresented: $isImportingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                store.importLocalFolder(url)
            }
        }
        .fileDialogMessage("Choose a skill folder that contains SKILL.md")
        .focusedSceneValue(\.isImportingFolder, $isImportingFolder)
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "This skill has local changes. Updating will replace them.",
            isPresented: pendingUpdateBinding,
            titleVisibility: .visible,
            ) {
            Button("Replace") {
                Task { await store.replacePendingUpdate() }
            }
            Button("Detach") {
                store.detachPendingUpdate()
            }
            Button("Cancel", role: .cancel) {
                store.pendingUpdate = nil
            }
        }
        .onAppear {
            if selectedSection == "projects" {
                selectedSection = MainSection.enabled.rawValue
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch MainSection(rawValue: selectedSection) ?? .library {
        case .library:
            LibraryView(store: store, importFolder: { isImportingFolder = true })
        case .discover:
            DiscoverView(store: store)
        case .enabled:
            EnabledView(store: store)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } },
            )
    }

    private var pendingUpdateBinding: Binding<Bool> {
        Binding(
            get: { store.pendingUpdate != nil },
            set: { if !$0 { store.pendingUpdate = nil } },
            )
    }
}
