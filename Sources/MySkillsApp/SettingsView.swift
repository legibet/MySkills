import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var store: AppStore
    @AppStorage("folderOpenMode") private var folderOpenModeRaw = FolderOpenMode.defaultFolderApp.rawValue
    @AppStorage("selectedOpenApplicationPath") private var selectedOpenApplicationPath = ""
    @State private var isAddingTarget = false
    @State private var isChoosingApplication = false

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
                            isChoosingApplication = true
                        }
                    }
                }
                .disabled(folderOpenMode != .selectedApplication)
            } header: {
                Text("Folders")
            } footer: {
                Text(modeDescription)
            }

            Section {
                if store.customTargets.isEmpty {
                    Text("No custom targets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.customTargets) { target in
                        CustomTargetRow(target: target) {
                            store.removeCustomTarget(target)
                        }
                    }
                }

                Button("Add Target…") {
                    isAddingTarget = true
                }
            } header: {
                Text("Custom Targets")
            } footer: {
                Text("Custom locations to enable skills into, alongside built-in agents.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
        .sheet(isPresented: $isAddingTarget) {
            AddTargetSheet(store: store)
        }
        .fileImporter(isPresented: $isChoosingApplication, allowedContentTypes: [.applicationBundle]) { result in
            if case let .success(url) = result {
                selectedOpenApplicationPath = url.path
                folderOpenModeRaw = FolderOpenMode.selectedApplication.rawValue
            }
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
        .fileDialogMessage("Choose an application for opening folders")
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
}

struct CustomTargetRow: View {
    var target: AgentTarget
    var onDelete: () -> Void

    private var pathSummary: String {
        [target.globalPath, target.projectRelativePath]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        LabeledContent {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove target")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                Text(pathSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AddTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore

    @State private var name = ""
    @State private var globalPath = ""
    @State private var projectRelativePath = ""
    @State private var errorMessage: String?
    @State private var isChoosingGlobalPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Target")
                    .font(.title3.weight(.semibold))
                Text("A folder that enabled skills are linked into. Fill at least one path.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            field("Name") {
                TextField("e.g. My Agent", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            field("Global path", hint: "absolute, optional") {
                HStack(spacing: 8) {
                    TextField("~/.myagent/skills", text: $globalPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        isChoosingGlobalPath = true
                    }
                }
            }

            field("Project path", hint: "relative to a project, optional") {
                TextField(".myagent/skills", text: $projectRelativePath)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    add()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fileImporter(isPresented: $isChoosingGlobalPath, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                globalPath = url.path
            }
        }
        .fileDialogMessage("Choose a global skills folder")
    }

    @ViewBuilder
    private func field(
        _ title: String,
        hint: String? = nil,
        @ViewBuilder content: () -> some View,
        ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    private func add() {
        do {
            try store.addCustomTarget(
                name: name,
                globalPath: globalPath,
                projectRelativePath: projectRelativePath,
                )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
