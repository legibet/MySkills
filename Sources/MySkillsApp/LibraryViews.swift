import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var store: AppStore
    @AppStorage("folderOpenMode") private var folderOpenModeRaw = FolderOpenMode.defaultFolderApp.rawValue
    @AppStorage("selectedOpenApplicationPath") private var selectedOpenApplicationPath = ""
    @State private var selectedSkillName: String?
    @State private var skillToRemove: SkillRecord?

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
                folderOpenMode: folderOpenMode,
                selectedOpenApplicationPath: selectedOpenApplicationPath,
                openReader: { skill in
                    openWindow(id: "reader", value: skill.readerRequest)
                },
                requestRemove: { skillToRemove = $0 },
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
                        requestRemove: { skillToRemove = $0 },
                        )
                } else {
                    ContentUnavailableView(
                        "No Skill Selected",
                        systemImage: "sidebar.left",
                        description: Text("Select a skill from the list to see its details."),
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
        .confirmationDialog(
            skillToRemove.map { "Remove \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { skillToRemove != nil },
                set: { if !$0 { skillToRemove = nil } },
                ),
            titleVisibility: .visible,
            presenting: skillToRemove,
            ) { skill in
            Button("Remove", role: .destructive) {
                store.remove(skill)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Enabled symlinks managed by MySkills will be removed too.")
        }
    }
}

struct SkillListPanel: View {
    @Bindable var store: AppStore
    @Binding var selectedSkillName: String?
    var folderOpenMode: FolderOpenMode
    var selectedOpenApplicationPath: String
    var openReader: (SkillRecord) -> Void
    var requestRemove: (SkillRecord) -> Void

    @State private var searchText = ""
    @State private var highlighted: String?
    @State private var detailSyncTask: Task<Void, Never>?
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
                skill.sourceDisplayName
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
                ContentUnavailableView {
                    Label("No Skills", systemImage: "books.vertical")
                } description: {
                    Text("Install from Discover or import a local skill folder.")
                } actions: {
                    Button {
                        store.importLocalFolder()
                    } label: {
                        Label("Import Folder", systemImage: "folder.badge.plus")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredSkills) { skill in
                                SkillListRow(
                                    skill: skill,
                                    isSelected: highlighted == skill.name,
                                    select: {
                                        detailSyncTask?.cancel()
                                        highlighted = skill.name
                                        selectedSkillName = skill.name
                                        isListFocused = true
                                    },
                                    open: {
                                        detailSyncTask?.cancel()
                                        highlighted = skill.name
                                        selectedSkillName = skill.name
                                        openReader(skill)
                                    },
                                    )
                                .id(skill.name)
                                .contextMenu {
                                    Button("Read") {
                                        detailSyncTask?.cancel()
                                        highlighted = skill.name
                                        selectedSkillName = skill.name
                                        openReader(skill)
                                    }
                                    Button("Open") {
                                        store.openSkill(
                                            skill,
                                            mode: folderOpenMode,
                                            applicationPath: selectedOpenApplicationPath,
                                            )
                                    }
                                    if let url = skill.sourceWebURL {
                                        Button("Source") {
                                            store.openURL(url)
                                        }
                                    }

                                    Divider()

                                    Button("Remove", role: .destructive) {
                                        requestRemove(skill)
                                    }
                                }
                            }

                            if filteredSkills.isEmpty {
                                ContentUnavailableView.search(text: searchText)
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
                    .onChange(of: selectedSkillName) { _, newValue in
                        if highlighted != newValue {
                            highlighted = newValue
                        }
                    }
                    .onAppear {
                        highlighted = selectedSkillName
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

        let currentIndex = filteredSkills.firstIndex { $0.name == highlighted }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + direction, 0), filteredSkills.count - 1)
        } else {
            nextIndex = direction > 0 ? 0 : filteredSkills.count - 1
        }

        let skill = filteredSkills[nextIndex]
        highlighted = skill.name
        proxy.scrollTo(skill.name, anchor: .center)
        scheduleDetailSync(skill.name)
        return .handled
    }

    // Update the highlight instantly but debounce the detail pane refresh,
    // so holding an arrow key scrolls the list smoothly instead of rebuilding
    // SkillDetailView on every key repeat.
    private func scheduleDetailSync(_ name: String?) {
        detailSyncTask?.cancel()
        detailSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            selectedSkillName = name
        }
    }

    private func openSelectedSkill() -> KeyPress.Result {
        guard let skill = filteredSkills.first(where: { $0.name == highlighted }) else {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectableRowBackground(isSelected: isSelected, isHovering: isHovering)
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            open()
        })
    }

    private var subtitle: String {
        skill.sourceDisplayName
    }
}

struct SkillDetailView: View {
    @Bindable var store: AppStore
    var skill: SkillRecord
    var folderOpenMode: FolderOpenMode
    var selectedOpenApplicationPath: String
    var requestRemove: (SkillRecord) -> Void

    @State private var showingEnableSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                    showingEnableSheet = true
                } label: {
                    Label("Enable", systemImage: "checkmark.circle")
                }
                .keyboardShortcut("e", modifiers: [.command])
                .buttonStyle(.borderedProminent)

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
                    Task { await store.requestUpdate(skill) }
                } label: {
                    Label("Update", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut("u", modifiers: [.command])
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
                    requestRemove(skill)
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
                        .padding(12)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
                    }
                }
            }
        }
    }

    private var sourceText: String {
        skill.sourceDisplayName
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
    @State private var selectedTargetIDs: Set<String> = []

    private var availableTargets: [AgentTarget] {
        store.targets.filter { target in
            scope == .project ? target.supportsProject : target.supportsGlobal
        }
    }

    private var selectedTargets: Set<AgentTarget> {
        Set(availableTargets.filter { selectedTargetIDs.contains($0.id) && !isEnabled($0) })
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
                selectedTargetIDs = []
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
        .onChange(of: projectURL) { _, _ in
            selectedTargetIDs = []
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
                .disabled(isEnabled(target))
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
            get: { isEnabled(target) || selectedTargetIDs.contains(target.id) },
            set: { enabled in
                guard !isEnabled(target) else {
                    return
                }

                if enabled {
                    selectedTargetIDs.insert(target.id)
                } else {
                    selectedTargetIDs.remove(target.id)
                }
            },
            )
    }

    private func isEnabled(_ target: AgentTarget) -> Bool {
        store.enablements.contains { record in
            record.skillName == skill.name
                && record.scope == scope
                && record.targetID == target.id
                && (scope == .global || record.projectPath == projectURL?.path)
        }
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
