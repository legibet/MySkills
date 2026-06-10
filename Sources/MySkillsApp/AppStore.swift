import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    var skills: [SkillRecord] = []
    var projects: [ProjectRecord] = []
    var enablements: [EnablementRecord] = []
    var searchQuery = ""
    var searchResults: [SkillSearchResult] = []
    var sourceInput = ""
    var errorMessage: String?
    var isSearching = false
    var isInstalling = false
    var pendingUpdate: SkillRecord?

    func load() {
        do {
            let state = StateFile.load()
            skills = try SkillLibrary.scan(knownSkills: state.skills)
            projects = state.projects.sorted { $0.lastUsedAt > $1.lastUsedAt }
            enablements = SymlinkService.validEnablements(state.enablements)
            try save()
        } catch {
            report(error)
        }
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            searchResults = try await SkillsSearchClient.search(query)
        } catch {
            report(error)
        }
    }

    func install(_ result: SkillSearchResult) async {
        isInstalling = true
        defer { isInstalling = false }

        do {
            let skill: SkillRecord
            switch result.searchSource {
            case .skillsSh:
                let response = try await SkillsSearchClient.download(
                    source: result.source,
                    skillID: result.resolvedSkillID,
                    )
                skill = try SkillLibrary.installDownloadedSkill(
                    result: result,
                    response: response,
                    replacing: false,
                    )

            case .git:
                skill = try await Task.detached {
                    try GitInstaller.install(result, replacing: false)
                }.value
            }

            upsert(skill)
            try save()
        } catch {
            report(error)
        }
    }

    func browseSource() async {
        let input = sourceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            searchResults = try await Task.detached {
                try GitInstaller.browse(input)
            }.value
        } catch {
            report(error)
        }
    }

    func importLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a skill folder that contains SKILL.md"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let skill = try SkillLibrary.importLocalFolder(url)
            upsert(skill)
            try save()
        } catch {
            report(error)
        }
    }

    func enable(skill: SkillRecord, scope: SkillScope, targets: Set<AgentTarget>, projectURL: URL?) {
        do {
            let scopedProjectURL = scope == .project ? projectURL : nil
            var created: [EnablementRecord] = []
            for target in targets {
                let record = try SymlinkService.enable(
                    skill: skill,
                    scope: scope,
                    target: target,
                    projectURL: scopedProjectURL,
                    )
                created.append(record)
            }

            for record in created {
                upsert(record)
            }

            if let projectURL = scopedProjectURL {
                upsert(ProjectRecord(path: projectURL.path, lastUsedAt: Date()))
            }

            try save()
        } catch {
            report(error)
        }
    }

    func disable(_ enablement: EnablementRecord) {
        do {
            try SymlinkService.disable(enablement)
            enablements.removeAll { $0.id == enablement.id }
            try save()
        } catch {
            report(error)
        }
    }

    func remove(_ skill: SkillRecord) {
        do {
            let records = enablements.filter { $0.skillName == skill.name }
            for record in records {
                try SymlinkService.disable(record)
            }
            enablements.removeAll { $0.skillName == skill.name }
            try SkillLibrary.removeSkill(skill)
            skills.removeAll { $0.name == skill.name }
            try save()
        } catch {
            report(error)
        }
    }

    func requestUpdate(_ skill: SkillRecord) async {
        do {
            if let importedHash = skill.importedHash {
                let currentHash = try FolderHash.hash(PathResolver.skillURL(skill.name))
                if currentHash != importedHash {
                    pendingUpdate = skill
                    return
                }
            }

            try await update(skill, replacingLocalChanges: true)
        } catch {
            report(error)
        }
    }

    func replacePendingUpdate() async {
        guard let skill = pendingUpdate else {
            return
        }

        pendingUpdate = nil

        do {
            try await update(skill, replacingLocalChanges: true)
        } catch {
            report(error)
        }
    }

    func detachPendingUpdate() {
        guard var skill = pendingUpdate else {
            return
        }

        pendingUpdate = nil
        skill.sourceKind = .local
        skill.importedHash = nil
        skill.updatedAt = Date()
        upsert(skill)

        do {
            try save()
        } catch {
            report(error)
        }
    }

    func openSkill(_ skill: SkillRecord, mode: FolderOpenMode, applicationPath: String) {
        openFolder(PathResolver.skillURL(skill.name), mode: mode, applicationPath: applicationPath)
    }

    func openProject(_ project: ProjectRecord, mode: FolderOpenMode, applicationPath: String) {
        openFolder(URL(fileURLWithPath: project.path), mode: mode, applicationPath: applicationPath)
    }

    func openURL(_ url: URL) {
        do {
            try OpenActionService.openURL(url)
        } catch {
            report(error)
        }
    }

    func installed(_ result: SkillSearchResult) -> Bool {
        skills.contains { $0.name == SkillLibrary.sanitizeSkillName(result.resolvedSkillID) }
    }

    func enablements(for skill: SkillRecord) -> [EnablementRecord] {
        enablements
            .filter { $0.skillName == skill.name }
            .sorted { $0.targetPath < $1.targetPath }
    }

    func enablements(for project: ProjectRecord) -> [EnablementRecord] {
        enablements
            .filter { $0.scope == .project && $0.projectPath == project.path }
            .sorted { $0.skillName < $1.skillName }
    }

    func globalEnablements() -> [EnablementRecord] {
        enablements
            .filter { $0.scope == .global }
            .sorted { $0.skillName < $1.skillName }
    }

    private func update(_ skill: SkillRecord, replacingLocalChanges: Bool) async throws {
        switch skill.sourceKind {
        case .skillsSh:
            guard let source = skill.source, let skillID = skill.skillId else {
                throw AppError.message("This skill is missing source metadata.")
            }
            let result = SkillSearchResult(
                id: "\(source)/\(skillID)",
                skillId: skillID,
                name: skill.displayName,
                installs: 0,
                source: source,
                )
            let response = try await SkillsSearchClient.download(source: source, skillID: skillID)
            var updated = try SkillLibrary.installDownloadedSkill(
                result: result,
                response: response,
                replacing: replacingLocalChanges,
                )
            updated.installedAt = skill.installedAt
            upsert(updated)

        case .git:
            guard let input = skill.sourceInput else {
                throw AppError.message("This skill is missing source metadata.")
            }
            let installed = try await Task.detached {
                try GitInstaller.install(input, replacing: replacingLocalChanges, wantedName: skill.name)
            }.value
            guard var updated = installed.first else {
                throw AppError.message("No matching skill was found while updating.")
            }
            updated.installedAt = skill.installedAt
            upsert(updated)

        case .local:
            throw AppError.message("This skill cannot be updated automatically.")
        }

        try save()
    }

    private func openFolder(_ url: URL, mode: FolderOpenMode, applicationPath: String) {
        do {
            try OpenActionService.openFolder(url, mode: mode, applicationPath: applicationPath)
        } catch {
            report(error)
        }
    }

    private func upsert(_ skill: SkillRecord) {
        skills.removeAll { $0.name == skill.name }
        skills.append(skill)
        skills.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func upsert(_ project: ProjectRecord) {
        projects.removeAll { $0.path == project.path }
        projects.insert(project, at: 0)
    }

    private func upsert(_ enablement: EnablementRecord) {
        enablements.removeAll { $0.id == enablement.id }
        enablements.append(enablement)
    }

    private func save() throws {
        try StateFile.save(
            StoredState(
                skills: skills,
                projects: projects,
                enablements: enablements,
                ),
            )
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription.isEmpty
            ? String(describing: error)
            : error.localizedDescription
    }
}
