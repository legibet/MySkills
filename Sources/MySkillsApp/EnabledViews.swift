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
                ContentUnavailableView(
                    "No Enabled Skills",
                    systemImage: "checkmark.circle",
                    description: Text("Global and project enablements appear here."),
                    )
                .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    if !globalEnablements.isEmpty {
                        EnabledSectionTitle("Global")
                        GlobalEnablements(store: store, records: globalEnablements)
                    }

                    if !projectSections.isEmpty {
                        EnabledSectionTitle("Projects")

                        VStack(spacing: 12) {
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
                .frame(maxWidth: 860, alignment: .leading)
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

struct GlobalEnablements: View {
    @Bindable var store: AppStore
    var records: [EnablementRecord]

    private var groups: [GlobalTargetGroup] {
        GlobalTargetGroup.groups(from: records)
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(groups) { group in
                GlobalTargetCard(store: store, group: group)
            }
        }
    }
}

struct GlobalTargetGroup: Identifiable {
    var targetID: String
    var targetName: String
    var targetPath: String
    var records: [EnablementRecord]

    var id: String {
        targetID
    }

    static func groups(from records: [EnablementRecord]) -> [GlobalTargetGroup] {
        Dictionary(grouping: records, by: \.targetID)
            .map { _, records in
                let sortedRecords = records.sorted { $0.skillName < $1.skillName }
                let first = sortedRecords[0]
                return GlobalTargetGroup(
                    targetID: first.targetID,
                    targetName: first.targetName,
                    targetPath: URL(fileURLWithPath: first.targetPath).deletingLastPathComponent().path,
                    records: sortedRecords,
                    )
            }
            .sorted { $0.targetName < $1.targetName }
    }
}

struct GlobalTargetCard: View {
    @Bindable var store: AppStore
    var group: GlobalTargetGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EnablementCardHeader(title: group.targetName, subtitle: group.targetPath)

            ForEach(group.records) { record in
                Divider()
                EnablementRecordLine(store: store, record: record)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
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
            EnablementCardHeader(title: project.name, subtitle: project.path) {
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

            ForEach(EnablementGroup.groups(from: records)) { group in
                Divider()
                ProjectEnablementLine(store: store, group: group)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
    }
}

struct EnablementCardHeader<Accessory: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var accessory: () -> Accessory

    init(
        title: String,
        subtitle: String,
        @ViewBuilder accessory: @escaping () -> Accessory,
        ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

extension EnablementCardHeader where Accessory == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct EnablementGroup: Identifiable {
    var skillName: String
    var records: [EnablementRecord]

    var id: String {
        skillName
    }

    var targetNames: String {
        records.map(\.targetName).joined(separator: " · ")
    }

    static func groups(from records: [EnablementRecord]) -> [EnablementGroup] {
        Dictionary(grouping: records, by: \.skillName)
            .map { skillName, records in
                EnablementGroup(
                    skillName: skillName,
                    records: records.sorted { $0.targetName < $1.targetName },
                    )
            }
            .sorted { $0.skillName < $1.skillName }
    }
}

struct EnablementRecordLine: View {
    @Bindable var store: AppStore
    var record: EnablementRecord

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(record.skillName)
                .font(.body.weight(.medium))
                .lineLimit(1)

            Spacer()

            DisableEnablementControl(store: store, records: [record])
        }
        .padding(.vertical, 8)
        .padding(.leading, 24)
        .padding(.trailing, 12)
    }
}

struct ProjectEnablementLine: View {
    @Bindable var store: AppStore
    var group: EnablementGroup

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                Text(group.skillName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(group.targetNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            DisableEnablementControl(store: store, records: group.records)
        }
        .padding(.vertical, 8)
        .padding(.leading, 24)
        .padding(.trailing, 12)
    }
}

struct DisableEnablementControl: View {
    @Bindable var store: AppStore
    var records: [EnablementRecord]

    var body: some View {
        if records.count == 1, let record = records.first {
            Button {
                store.disable(record)
            } label: {
                Label("Disable", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Disable")
            .accessibilityLabel("Disable \(record.skillName)")
        } else {
            Menu {
                ForEach(records) { record in
                    Button("Disable \(record.targetName)") {
                        store.disable(record)
                    }
                }
            } label: {
                Label("Disable", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
            .help("Disable")
            .accessibilityLabel("Disable \(records.first?.skillName ?? "skill")")
        }
    }
}
