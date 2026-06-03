import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("folderOpenMode") private var folderOpenModeRaw = FolderOpenMode.defaultFolderApp.rawValue
    @AppStorage("selectedOpenApplicationPath") private var selectedOpenApplicationPath = ""

    private var folderOpenMode: FolderOpenMode {
        FolderOpenMode(rawValue: folderOpenModeRaw) ?? .defaultFolderApp
    }

    var body: some View {
        Form {
            Section {
                Picker("Open folders with", selection: $folderOpenModeRaw) {
                    Text("Default App").tag(FolderOpenMode.defaultFolderApp.rawValue)
                    Text("Finder").tag(FolderOpenMode.finder.rawValue)
                    Text("Chosen App").tag(FolderOpenMode.selectedApplication.rawValue)
                }

                LabeledContent("Application") {
                    HStack(spacing: 8) {
                        if folderOpenMode == .selectedApplication {
                            Text(selectedApplicationName)
                                .foregroundStyle(.secondary)
                        }

                        Button("Choose…") {
                            chooseApplication()
                        }
                    }
                }
                .disabled(folderOpenMode != .selectedApplication)
            } header: {
                Text("Folders")
            } footer: {
                Text(modeDescription)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 260)
    }

    private var modeDescription: String {
        switch folderOpenMode {
        case .defaultFolderApp:
            "Uses macOS' current default app for folders."
        case .finder:
            "Always opens folders in Finder."
        case .selectedApplication:
            "Opens folders with the application you choose below."
        }
    }

    private var selectedApplicationName: String {
        guard !selectedOpenApplicationPath.isEmpty else {
            return "None"
        }
        return URL(fileURLWithPath: selectedOpenApplicationPath)
            .deletingPathExtension()
            .lastPathComponent
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.message = "Choose an application for opening folders"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        selectedOpenApplicationPath = url.path
        folderOpenModeRaw = FolderOpenMode.selectedApplication.rawValue
    }
}
