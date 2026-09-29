import SwiftUI

@main
struct MySkillsApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("MySkills", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 920, minHeight: 620)
                .task {
                    store.load()
                }
        }
        .defaultSize(width: 1040, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            LibraryCommands(store: store)
        }

        WindowGroup("Skill Reader", id: "reader", for: SkillReaderRequest.self) { $request in
            if let request {
                SkillReaderView(store: store, request: request)
                    .frame(minWidth: 720, minHeight: 560)
            } else {
                Text("No skill selected.")
                    .frame(minWidth: 720, minHeight: 560)
            }
        }
        .defaultSize(width: 880, height: 680)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(store: store)
        }
    }
}

extension FocusedValues {
    /// Presents the folder importer of the focused main window.
    @Entry var isImportingFolder: Binding<Bool>?
}

struct LibraryCommands: Commands {
    var store: AppStore
    @FocusedBinding(\.isImportingFolder) private var isImportingFolder

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Folder…") {
                isImportingFolder = true
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(isImportingFolder == nil)

            Button("Reload") {
                store.load()
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
