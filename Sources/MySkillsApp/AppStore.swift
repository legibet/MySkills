import AppKit
import Foundation
import Observation
import SwiftUI

enum UpdateOutcome {
    case updated
    case upToDate

    var label: String {
        switch self {
        case .updated: "Updated"
        case .upToDate: "Already up to date"
        }
    }
}

@MainActor
@Observable
final class AppStore {
    var skills: [SkillRecord] = []
    var projects: [ProjectRecord] = []
    var enablements: [EnablementRecord] = []
    var customTargets: [AgentTarget] = []
    var searchQuery = ""
    var searchResults: [SkillSearchResult] = []
    var sourceInput = ""
    var errorMessage: String?
    var isSearching = false
    var isInstalling = false
    var pendingUpdate: SkillRecord?
    var updatingSkillNames: Set<String> = []
    var updateOutcomes: [String: UpdateOutcome] = [:]

    var targets: [AgentTarget] {
        AgentTarget.builtins + customTargets
    }

    func load() {
        do {
            let result = try StateFile.load()
            let state = result.state
            skills = try SkillLibrary.scan(knownSkills: state.skills)
            projects = state.projects.sorted { $0.lastUsedAt > $1.lastUsedAt }
            enablements = SymlinkService.validEnablements(state.enablements)
            customTargets = state.customTargets
            try save()
            errorMessage = result.recoveryMessage
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
                    )

            case .git:
                skill = try await Task.detached {
                    try GitInstaller.install(result)
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

    func addCustomTarget(name: String, globalPath: String, projectRelativePath: String) throws {
        let target = try makeCustomTarget(
            name: name,
            globalPath: globalPath,
            projectRelativePath: projectRelativePath,
            )
        customTargets.append(target)
        try save()
    }

    func removeCustomTarget(_ target: AgentTarget) {
        customTargets.removeAll { $0.id == target.id }
        do {
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

            try await update(skill)
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
            try await update(skill)
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
        skills.contains { skill in
            switch result.searchSource {
            case .skillsSh:
                skill.sourceKind == .skillsSh
                    && skill.source == result.source
                    && skill.skillId == result.resolvedSkillID
            case .git:
                skill.sourceKind == .git
                    && skill.gitURL == result.gitURL
                    && skill.subpath == result.subpath
            }
        }
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

    private func update(_ skill: SkillRecord) async throws {
        withAnimation { updateOutcomes[skill.name] = nil }
        updatingSkillNames.insert(skill.name)
        defer { updatingSkillNames.remove(skill.name) }

        // Hash the on-disk folder (not importedHash) so replacing local edits
        // with identical upstream content still reads as an update.
        let previousHash = try? FolderHash.hash(PathResolver.skillURL(skill.name))

        var updated: SkillRecord
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
            updated = try SkillLibrary.installDownloadedSkill(
                result: result,
                response: response,
                replacing: skill.name,
                )

        case .git:
            guard let gitURL = skill.gitURL else {
                throw AppError.message("This skill is missing source metadata.")
            }
            // Reinstall from the exact stored location (gitURL + subpath) so a repo
            // containing multiple skills with the same name doesn't get remapped.
            let result = SkillSearchResult(
                id: "git:\(gitURL):\(skill.subpath ?? ".")",
                skillId: skill.name,
                name: skill.displayName,
                installs: 0,
                source: SourceURL.repositoryLabel(from: gitURL),
                searchSource: .git,
                sourceInput: skill.sourceInput,
                gitURL: gitURL,
                ref: skill.ref,
                subpath: skill.subpath,
                )
            updated = try await Task.detached {
                try GitInstaller.install(result, replacing: skill.name)
            }.value

        case .local:
            throw AppError.message("This skill cannot be updated automatically.")
        }

        let outcome: UpdateOutcome
        if updated.importedHash == previousHash {
            outcome = .upToDate
        } else {
            updated.installedAt = skill.installedAt
            upsert(updated)
            try save()
            outcome = .updated
        }

        withAnimation { updateOutcomes[skill.name] = outcome }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { updateOutcomes[skill.name] = nil }
        }
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

    private func makeCustomTarget(
        name: String,
        globalPath: String,
        projectRelativePath: String,
        ) throws -> AgentTarget {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AppError.message("Enter a target name.")
        }
        guard !targets.contains(where: {
            $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            throw AppError.message("A target named \(trimmedName) already exists.")
        }

        let global = globalPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = projectRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !global.isEmpty || !project.isEmpty else {
            throw AppError.message("Fill at least one path.")
        }

        if !global.isEmpty {
            let isAbsolute = global.hasPrefix("/") || global == "~" || global.hasPrefix("~/")
            guard isAbsolute else {
                throw AppError.message("Global path must be absolute or start with ~/.")
            }
        }
        if !project.isEmpty {
            let isRelative = !project.hasPrefix("/") && !project.hasPrefix("~")
                && !project.split(separator: "/").contains("..")
            guard isRelative else {
                throw AppError.message("Project path must be relative to a project folder.")
            }
        }

        return AgentTarget(
            id: UUID().uuidString,
            name: trimmedName,
            projectRelativePath: project.isEmpty ? nil : project,
            globalPath: global.isEmpty ? nil : global,
            )
    }

    private func save() throws {
        try StateFile.save(
            StoredState(
                skills: skills,
                projects: projects,
                enablements: enablements,
                customTargets: customTargets,
                ),
            )
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription.isEmpty
            ? String(describing: error)
            : error.localizedDescription
    }
}
