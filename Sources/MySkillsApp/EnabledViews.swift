import SwiftUI

struct EnabledView: View {
    @Bindable var store: AppStore
    @AppStorage("folderOpenMode") private var folderOpenModeRaw = FolderOpenMode.defaultFolderApp.rawValue
    @AppStorage("selectedOpenApplicationPath") private var selectedOpenApplicationPath = ""

    private var globalEnablements: [EnablementRecord] {
        store.globalEnablements()
    }

    private var projectSections: [(ProjectRecord, [EnablementRecord])] {
        store.projects.compactMap { project in
            let records = store.enablements(for: project)
            return records.isEmpty ? nil : (project, records)
        }
    }

    private var isEmpty: Bool {
        globalEnablements.isEmpty && projectSections.isEmpty
    }

    private var folderOpenMode: FolderOpenMode {
        FolderOpenMode(rawValue: folderOpenModeRaw) ?? .defaultFolderApp
    }

    var body: some View {
        ScrollView {
            if isEmpty {
                EmptyStateView(
                    title: "No enabled skills",
                    message: "Global and project enablements appear here.",
                )
                .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if !globalEnablements.isEmpty {
                        EnabledSectionTitle("Global")
                        EnablementList(store: store, records: globalEnablements, showsPath: true)
                    }

                    if !projectSections.isEmpty {
                        EnabledSectionTitle("Projects")

                        VStack(spacing: 18) {
                            ForEach(projectSections, id: \.0.id) { project, records in
                                ProjectEnablementGroup(
                                    store: store,
                                    project: project,
                                    records: records,
                                    folderOpenMode: folderOpenMode,
                                    selectedOpenApplicationPath: selectedOpenApplicationPath,
                                )
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .navigationTitle("Enabled")
        .toolbar {
            Button {
                store.load()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        }
    }
}

struct EnabledSectionTitle: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
    }
}

struct EnablementList: View {
    @Bindable var store: AppStore
    var records: [EnablementRecord]
    var showsPath: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(records) { record in
                EnablementLine(store: store, record: record, showsPath: showsPath)
                if record.id != records.last?.id {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ProjectEnablementGroup: View {
    @Bindable var store: AppStore
    var project: ProjectRecord
    var records: [EnablementRecord]
    var folderOpenMode: FolderOpenMode
    var selectedOpenApplicationPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.title3.weight(.semibold))
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Button {
                    store.openProject(
                        project,
                        mode: folderOpenMode,
                        applicationPath: selectedOpenApplicationPath,
                    )
                } label: {
                    Label("Open", systemImage: "folder")
                }
            }
            .padding(.bottom, 10)

            ForEach(records) { record in
                Divider()
                EnablementLine(store: store, record: record, showsPath: false)
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct EnablementLine: View {
    @Bindable var store: AppStore
    var record: EnablementRecord
    var showsPath: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(record.skillName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(record.targetName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if showsPath {
                    Text(record.targetPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            Button {
                store.disable(record)
            } label: {
                Label("Disable", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Disable")
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
    }
}
