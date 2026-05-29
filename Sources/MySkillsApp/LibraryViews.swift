import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var store: AppStore
    @AppStorage("folderOpenMode") private var folderOpenModeRaw = FolderOpenMode.defaultFolderApp.rawValue
    @AppStorage("selectedOpenApplicationPath") private var selectedOpenApplicationPath = ""
    @State private var selectedSkillName: String?

    private var selectedSkill: SkillRecord? {
        guard let selectedSkillName else {
            return store.skills.first
        }
        return store.skills.first { $0.name == selectedSkillName }
    }

    private var folderOpenMode: FolderOpenMode {
        FolderOpenMode(rawValue: folderOpenModeRaw) ?? .defaultFolderApp
    }

    var body: some View {
        HStack(spacing: 0) {
            SkillListPanel(
                store: store,
                selectedSkillName: $selectedSkillName,
                openReader: { skill in
                    openWindow(id: "reader", value: skill.readerRequest)
                },
            )
            .frame(width: 320)

            Divider()

            Group {
                if let selectedSkill {
                    SkillDetailView(
                        store: store,
                        skill: selectedSkill,
                        folderOpenMode: folderOpenMode,
                        selectedOpenApplicationPath: selectedOpenApplicationPath,
                    )
                } else {
                    EmptyStateView(
                        title: "Select a skill",
                        message: "Installed skills appear on the left.",
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Library")
        .onChange(of: store.skills, initial: true) { _, skills in
            if selectedSkillName == nil || !skills.contains(where: { $0.name == selectedSkillName }) {
                selectedSkillName = skills.first?.name
            }
        }
    }
}

struct SkillListPanel: View {
    @Bindable var store: AppStore
    @Binding var selectedSkillName: String?
    var openReader: (SkillRecord) -> Void

    @State private var searchText = ""
    @FocusState private var isListFocused: Bool

    private var filteredSkills: [SkillRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return store.skills
        }

        return store.skills.filter { skill in
            let values = [
                skill.displayName,
                skill.name,
                skill.source ?? "",
                skill.sourceInput ?? "",
                skill.gitURL ?? ""
            ]
            return values.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search Library", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                Button {
                    store.importLocalFolder()
                } label: {
                    Label("Import Folder", systemImage: "folder.badge.plus")
                }
                .labelStyle(.iconOnly)
                .help("Import folder")
                .accessibilityLabel("Import folder")

                Button {
                    store.load()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Reload")
                .accessibilityLabel("Reload library")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if store.skills.isEmpty {
                EmptyStateView(
                    title: "No skills",
                    message: "Install from Discover or import a local skill folder.",
                ) {
                    Button {
                        store.importLocalFolder()
                    } label: {
                        Label("Import Folder", systemImage: "folder.badge.plus")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredSkills) { skill in
                                SkillListRow(
                                    skill: skill,
                                    isSelected: selectedSkillName == skill.name,
                                    select: {
                                        selectedSkillName = skill.name
                                        isListFocused = true
                                    },
                                    open: {
                                        selectedSkillName = skill.name
                                        openReader(skill)
                                    },
                                )
                                .id(skill.name)
                                .contextMenu {
                                    Button("Read") {
                                        selectedSkillName = skill.name
                                        openReader(skill)
                                    }
                                }
                            }

                            if filteredSkills.isEmpty {
                                EmptyStateView(
                                    title: "No matches",
                                    message: "Try another search.",
                                )
                                .padding(.top, 80)
                            }
                        }
                        .padding(10)
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
                        openSelectedSkill()
                    }
                }
            }
        }
        .background(.background)
    }

    private func moveSelection(_ direction: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !filteredSkills.isEmpty else {
            return .ignored
        }

        let currentIndex = filteredSkills.firstIndex { $0.name == selectedSkillName }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + direction, 0), filteredSkills.count - 1)
        } else {
            nextIndex = direction > 0 ? 0 : filteredSkills.count - 1
        }

        let skill = filteredSkills[nextIndex]
        selectedSkillName = skill.name
        proxy.scrollTo(skill.name, anchor: .center)
        return .handled
    }

    private func openSelectedSkill() -> KeyPress.Result {
        guard let skill = filteredSkills.first(where: { $0.name == selectedSkillName }) else {
            return .ignored
        }

        openReader(skill)
        return .handled
    }
}

struct SkillListRow: View {
    var skill: SkillRecord
    var isSelected: Bool
    var select: () -> Void
    var open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            open()
        })
    }

    private var subtitle: String {
        switch skill.sourceKind {
        case .marketplace:
            if let source = skill.source {
                return "GitHub · \(source)"
            }
            return "GitHub"

        case .git:
            guard let gitURL = skill.gitURL else {
                return "Git"
            }
            return "\(SourceURL.serviceLabel(from: gitURL)) · \(SourceURL.repositoryLabel(from: gitURL))"

        case .local:
            return "Local"

        case .unknown:
            return "Unknown"
        }
    }

    private var rowBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.16))
        }

        if isHovering {
            return AnyShapeStyle(Color.primary.opacity(0.06))
        }

        return AnyShapeStyle(Color.clear)
    }
}

struct SkillDetailView: View {
    @Bindable var store: AppStore
    var skill: SkillRecord
    var folderOpenMode: FolderOpenMode
    var selectedOpenApplicationPath: String

    @State private var showingEnableSheet = false
    @State private var showingRemoveConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                metadata
                enablements
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingEnableSheet) {
            EnableSheet(store: store, skill: skill)
        }
        .confirmationDialog(
            "Remove \(skill.displayName)?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible,
        ) {
            Button("Remove", role: .destructive) {
                store.remove(skill)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enabled symlinks managed by MySkills will be removed too.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(skill.displayName)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button {
                    store.openSkill(
                        skill,
                        mode: folderOpenMode,
                        applicationPath: selectedOpenApplicationPath,
                    )
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button {
                    showingEnableSheet = true
                } label: {
                    Label("Enable", systemImage: "checkmark.circle")
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button {
                    Task { await store.requestUpdate(skill) }
                } label: {
                    Label("Update", systemImage: "arrow.down.circle")
                }
                .disabled(!skill.canUpdate)

                Button {
                    if let url = skill.sourceWebURL {
                        store.openURL(url)
                    }
                } label: {
                    Label("Source", systemImage: "arrow.up.right.square")
                }
                .disabled(skill.sourceWebURL == nil)

                Button(role: .destructive) {
                    showingRemoveConfirmation = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    private var description: String? {
        let value = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == ">" || value == "|" ? nil : value
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details")
                .font(.headline)

            DetailRow(label: "Folder", value: PathResolver.skillURL(skill.name).path)
            DetailRow(label: "Source", value: sourceText)

            if let updatedAt = skill.updatedAt {
                DetailRow(label: "Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var enablements: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enabled Paths")
                .font(.headline)

            let records = store.enablements(for: skill)
            if records.isEmpty {
                Text("Not enabled anywhere.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(records) { record in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(record.scope.title) · \(record.targetName)")
                                    .font(.body.weight(.medium))
                                Text(record.targetPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            Spacer()

                            Button {
                                store.disable(record)
                            } label: {
                                Label("Disable", systemImage: "xmark.circle")
                            }
                            .labelStyle(.iconOnly)
                            .help("Disable")
                            .accessibilityLabel("Disable \(record.skillName)")
                        }
                        .padding(10)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var sourceText: String {
        switch skill.sourceKind {
        case .marketplace:
            if let source = skill.source {
                return "GitHub · \(source)"
            }
            return "GitHub"
        case .git:
            return skill.sourceInput ?? skill.gitURL ?? "Git"
        case .local:
            return "Local"
        case .unknown:
            return "Unknown"
        }
    }
}

struct DetailRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

struct EnableSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    var skill: SkillRecord

    @State private var scope = SkillScope.project
    @State private var projectURL: URL?
    @State private var selectedTargetIDs: Set<String> = ["universal"]

    private var availableTargets: [AgentTarget] {
        AgentTarget.all.filter { target in
            scope == .project ? target.supportsProject : target.supportsGlobal
        }
    }

    private var selectedTargets: Set<AgentTarget> {
        Set(availableTargets.filter { selectedTargetIDs.contains($0.id) })
    }

    private var canEnable: Bool {
        !selectedTargets.isEmpty && (scope == .global || projectURL != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Enable \(skill.displayName)")
                .font(.title3.weight(.semibold))

            Picker("Scope", selection: $scope) {
                ForEach(SkillScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: scope) { _, _ in
                selectedTargetIDs = ["universal"]
            }

            if scope == .project {
                projectPicker
            }

            targetPicker

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Enable") {
                    store.enable(
                        skill: skill,
                        scope: scope,
                        targets: selectedTargets,
                        projectURL: projectURL,
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canEnable)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            projectURL = store.projects.first.map { URL(fileURLWithPath: $0.path) }
        }
    }

    private var projectPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project")
                .font(.headline)

            HStack(spacing: 8) {
                Text(projectURL?.path ?? "No project selected")
                    .foregroundStyle(projectURL == nil ? .secondary : .primary)
                    .lineLimit(1)

                Spacer()

                Button {
                    chooseProject()
                } label: {
                    Label("Choose", systemImage: "folder.badge.plus")
                }
            }

            if !store.projects.isEmpty {
                Picker("Recent", selection: recentProjectBinding) {
                    Text("Choose recent project").tag("")
                    ForEach(store.projects) { project in
                        Text(project.name).tag(project.path)
                    }
                }
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Targets")
                .font(.headline)

            ForEach(availableTargets) { target in
                Toggle(isOn: binding(for: target)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name)
                        Text(pathHint(for: target))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var recentProjectBinding: Binding<String> {
        Binding(
            get: { projectURL?.path ?? "" },
            set: { path in
                projectURL = path.isEmpty ? nil : URL(fileURLWithPath: path)
            },
        )
    }

    private func binding(for target: AgentTarget) -> Binding<Bool> {
        Binding(
            get: { selectedTargetIDs.contains(target.id) },
            set: { enabled in
                if enabled {
                    selectedTargetIDs.insert(target.id)
                } else {
                    selectedTargetIDs.remove(target.id)
                }
            },
        )
    }

    private func pathHint(for target: AgentTarget) -> String {
        switch scope {
        case .project:
            target.projectRelativePath ?? ""
        case .global:
            target.globalPath ?? ""
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder"

        if panel.runModal() == .OK {
            projectURL = panel.url
        }
    }
}
