import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("folderOpenMode") private var folderOpenModeRaw = FolderOpenMode.defaultFolderApp.rawValue
    @AppStorage("selectedOpenApplicationPath") private var selectedOpenApplicationPath = ""

    private var folderOpenMode: FolderOpenMode {
        FolderOpenMode(rawValue: folderOpenModeRaw) ?? .defaultFolderApp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Folders")
                    .font(.title3.weight(.semibold))

                Text("Choose what the Open button uses for folders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Open folders with")
                    .font(.headline)

                Picker("Open folders with", selection: $folderOpenModeRaw) {
                    Text("Default App").tag(FolderOpenMode.defaultFolderApp.rawValue)
                    Text("Finder").tag(FolderOpenMode.finder.rawValue)
                    Text("Chosen App").tag(FolderOpenMode.selectedApplication.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)

                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 32, alignment: .topLeading)
            }

            if folderOpenMode == .selectedApplication {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected app")
                            .font(.headline)
                        Text(selectedApplicationName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Choose...") {
                        chooseApplication()
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 520, height: 260)
    }

    private var modeDescription: String {
        switch folderOpenMode {
        case .defaultFolderApp:
            "Uses macOS' current default app for folders. This also respects third-party file managers."
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
