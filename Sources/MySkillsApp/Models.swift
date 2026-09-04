import Foundation

enum MainSection: String, CaseIterable, Identifiable, Codable {
    case library
    case discover
    case enabled

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .library: "Library"
        case .discover: "Discover"
        case .enabled: "Enabled"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .discover: "magnifyingglass"
        case .enabled: "checkmark.circle"
        }
    }
}

enum SourceKind: String, Codable {
    case skillsSh
    case git
    case local
}

enum SkillAvailabilityIssue: String, Codable, Hashable {
    case missingLinkTarget
    case invalidSkill

    var label: String {
        switch self {
        case .missingLinkTarget: "Linked folder is unavailable."
        case .invalidSkill: "This folder does not contain a valid SKILL.md."
        }
    }
}

enum SearchSource: String, Codable, Hashable {
    case skillsSh
    case git
}

enum SkillScope: String, Codable, CaseIterable, Identifiable {
    case project
    case global

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .project: "Project"
        case .global: "Global"
        }
    }
}

enum FolderOpenMode: String, CaseIterable, Identifiable {
    case defaultFolderApp
    case finder
    case selectedApplication

    var id: String {
        rawValue
    }
}

struct SkillRecord: Identifiable, Codable, Hashable {
    var id: String {
        libraryRelativePath
    }

    var name: String
    var displayName: String
    var description: String
    var sourceKind: SourceKind
    var source: String?
    var skillId: String?
    var sourceInput: String?
    var gitURL: String?
    var ref: String?
    var subpath: String?
    var importedHash: String?
    var libraryPath: String?
    var owningLinkPath: String?
    var installedAt: Date
    var updatedAt: Date?
    var availabilityIssue: SkillAvailabilityIssue?
    var availabilityMessage: String?

    var isAvailable: Bool {
        availabilityIssue == nil
    }

    var unavailableMessage: String? {
        availabilityMessage ?? availabilityIssue?.label
    }

    var canUpdate: Bool {
        sourceKind != .local && isAvailable
    }

    var libraryRelativePath: String {
        libraryPath ?? name
    }

    var collectionName: String? {
        guard let separator = libraryRelativePath.firstIndex(of: "/") else {
            return nil
        }
        return String(libraryRelativePath[..<separator])
    }

    var linkedCollectionPath: String? {
        guard let owningLinkPath, owningLinkPath != libraryRelativePath else {
            return nil
        }
        return owningLinkPath
    }

    var readerRequest: SkillReaderRequest {
        SkillReaderRequest(
            kind: .library,
            name: name,
            displayName: displayName,
            libraryPath: libraryRelativePath,
            )
    }

    var sourceWebURL: URL? {
        switch sourceKind {
        case .skillsSh:
            guard let source else {
                return nil
            }
            return URL(string: "https://github.com/\(source)")
        case .git:
            guard let gitURL else {
                return nil
            }
            return SourceURL.webURL(from: gitURL, ref: ref, subpath: subpath)
        case .local:
            return nil
        }
    }

    var sourceDisplayName: String {
        switch sourceKind {
        case .skillsSh:
            return [source, skillId].compactMap { $0 }.joined(separator: "/")
        case .git:
            guard let gitURL else {
                return "Local"
            }
            return [SourceURL.repositoryLabel(from: gitURL), subpath]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        case .local:
            return collectionName.map { "Local · \($0)" } ?? "Local"
        }
    }
}

struct ProjectRecord: Identifiable, Codable, Hashable {
    var id: String {
        path
    }

    var path: String
    var lastUsedAt: Date

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

struct EnablementRecord: Identifiable, Codable, Hashable {
    var id: String {
        targetPath
    }

    var skillName: String
    var scope: SkillScope
    var targetID: String
    var targetName: String
    var projectPath: String?
    var targetPath: String
    var sourcePath: String?
    var createdAt: Date
}

struct AgentTarget: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var projectRelativePath: String?
    var globalPath: String?

    var supportsProject: Bool {
        projectRelativePath != nil
    }

    var supportsGlobal: Bool {
        globalPath != nil
    }

    static let builtins: [AgentTarget] = [
        AgentTarget(
            id: "universal",
            name: "Universal",
            projectRelativePath: ".agents/skills",
            globalPath: "~/.agents/skills",
            ),
        AgentTarget(
            id: "antigravity",
            name: "Antigravity",
            projectRelativePath: nil,
            globalPath: "~/.gemini/config/skills",
            ),
        AgentTarget(
            id: "claude-code",
            name: "Claude Code",
            projectRelativePath: ".claude/skills",
            globalPath: "~/.claude/skills",
            ),
        AgentTarget(
            id: "codex",
            name: "Codex",
            projectRelativePath: nil,
            globalPath: "~/.codex/skills",
            ),
        AgentTarget(
            id: "opencode",
            name: "OpenCode",
            projectRelativePath: nil,
            globalPath: "~/.config/opencode/skills",
            ),
        AgentTarget(
            id: "cursor",
            name: "Cursor",
            projectRelativePath: nil,
            globalPath: "~/.cursor/skills",
            )
    ]
}

struct SkillSearchResult: Identifiable, Decodable, Hashable {
    var id: String
    var skillId: String?
    var name: String
    var installs: Int
    var source: String
    var searchSource: SearchSource = .skillsSh
    var sourceInput: String?
    var gitURL: String?
    var ref: String?
    var subpath: String?
    var markdown: String?

    enum CodingKeys: String, CodingKey {
        case id
        case skillId
        case name
        case installs
        case source
        case searchSource
        case sourceInput
        case gitURL
        case ref
        case subpath
        case markdown
    }

    init(
        id: String,
        skillId: String? = nil,
        name: String,
        installs: Int,
        source: String,
        searchSource: SearchSource = .skillsSh,
        sourceInput: String? = nil,
        gitURL: String? = nil,
        ref: String? = nil,
        subpath: String? = nil,
        markdown: String? = nil,
        ) {
        self.id = id
        self.skillId = skillId
        self.name = name
        self.installs = installs
        self.source = source
        self.searchSource = searchSource
        self.sourceInput = sourceInput
        self.gitURL = gitURL
        self.ref = ref
        self.subpath = subpath
        self.markdown = markdown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        skillId = try container.decodeIfPresent(String.self, forKey: .skillId)
        name = try container.decode(String.self, forKey: .name)
        installs = try container.decodeIfPresent(Int.self, forKey: .installs) ?? 0
        source = try container.decode(String.self, forKey: .source)
        searchSource = try container.decodeIfPresent(SearchSource.self, forKey: .searchSource) ?? .skillsSh
        sourceInput = try container.decodeIfPresent(String.self, forKey: .sourceInput)
        gitURL = try container.decodeIfPresent(String.self, forKey: .gitURL)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        subpath = try container.decodeIfPresent(String.self, forKey: .subpath)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown)
    }

    var resolvedSkillID: String {
        skillId ?? id.split(separator: "/").last.map(String.init) ?? name
    }

    var readerRequest: SkillReaderRequest {
        SkillReaderRequest(
            kind: searchSource == .git ? .git : .skillsSh,
            name: resolvedSkillID,
            displayName: name,
            source: source,
            skillID: resolvedSkillID,
            sourceInput: sourceInput,
            gitURL: gitURL,
            ref: ref,
            subpath: subpath,
            markdown: markdown,
            )
    }

    var sourceWebURL: URL? {
        if searchSource == .git, let gitURL {
            return SourceURL.webURL(from: gitURL, ref: ref, subpath: subpath)
        }

        return URL(string: "https://github.com/\(source)")
    }
}

struct StoredState: Codable {
    var skills: [SkillRecord] = []
    var projects: [ProjectRecord] = []
    var enablements: [EnablementRecord] = []
    var customTargets: [AgentTarget] = []
}

extension StoredState {
    private enum CodingKeys: String, CodingKey {
        case skills, projects, enablements, customTargets
    }

    // Decode tolerantly so adding new fields never invalidates an existing state file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skills = try container.decodeIfPresent([SkillRecord].self, forKey: .skills) ?? []
        projects = try container.decodeIfPresent([ProjectRecord].self, forKey: .projects) ?? []
        enablements = try container.decodeIfPresent([EnablementRecord].self, forKey: .enablements) ?? []
        customTargets = try container.decodeIfPresent([AgentTarget].self, forKey: .customTargets) ?? []
    }
}

enum SkillReaderKind: String, Codable {
    case library
    case skillsSh
    case git
}

struct SkillReaderRequest: Identifiable, Codable, Hashable {
    var kind: SkillReaderKind
    var name: String
    var displayName: String
    var libraryPath: String?
    var source: String?
    var skillID: String?
    var sourceInput: String?
    var gitURL: String?
    var ref: String?
    var subpath: String?
    var markdown: String?

    var id: String {
        switch kind {
        case .library:
            "library:\(libraryPath ?? name)"
        case .skillsSh:
            "skillsSh:\(source ?? ""):\(skillID ?? name)"
        case .git:
            "git:\(gitURL ?? source ?? ""):\(subpath ?? skillID ?? name)"
        }
    }

    var searchResult: SkillSearchResult? {
        switch kind {
        case .library:
            return nil

        case .skillsSh:
            guard let source else {
                return nil
            }

            return SkillSearchResult(
                id: "\(source)/\(skillID ?? name)",
                skillId: skillID ?? name,
                name: displayName,
                installs: 0,
                source: source,
                )

        case .git:
            guard let gitURL else {
                return nil
            }

            return SkillSearchResult(
                id: id,
                skillId: skillID ?? name,
                name: displayName,
                installs: 0,
                source: source ?? gitURL,
                searchSource: .git,
                sourceInput: sourceInput,
                gitURL: gitURL,
                ref: ref,
                subpath: subpath,
                markdown: markdown,
                )
        }
    }

    var sourceWebURL: URL? {
        if kind == .git, let gitURL {
            return SourceURL.webURL(from: gitURL, ref: ref, subpath: subpath)
        }

        guard let source else {
            return nil
        }
        return URL(string: "https://github.com/\(source)")
    }
}

enum SourceURL {
    static func repositoryLabel(from gitURL: String) -> String {
        if gitURL.hasPrefix("git@github.com:") {
            return gitURL
                .replacingOccurrences(of: "git@github.com:", with: "")
                .replacingOccurrences(of: ".git", with: "")
        }

        guard let url = URL(string: gitURL) else {
            return gitURL.replacingOccurrences(of: ".git", with: "")
        }

        let path = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "")
        guard url.host == "github.com" else {
            return path.isEmpty ? gitURL : path
        }

        let parts = path.split(separator: "/").map(String.init)
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : path
    }

    static func webURL(from gitURL: String, ref: String? = nil, subpath: String? = nil) -> URL? {
        func appendGitHubPath(to base: String) -> URL? {
            guard let ref, let subpath, !subpath.isEmpty else {
                return URL(string: base)
            }
            return URL(string: "\(base)/tree/\(ref)/\(subpath)")
        }

        func appendGitLabPath(to base: String) -> URL? {
            guard let ref, let subpath, !subpath.isEmpty else {
                return URL(string: base)
            }
            return URL(string: "\(base)/-/tree/\(ref)/\(subpath)")
        }

        if gitURL.hasPrefix("git@github.com:") {
            let path = gitURL
                .replacingOccurrences(of: "git@github.com:", with: "")
                .replacingOccurrences(of: ".git", with: "")
            return appendGitHubPath(to: "https://github.com/\(path)")
        }

        if gitURL.hasPrefix("https://github.com/") {
            return appendGitHubPath(to: gitURL.replacingOccurrences(of: ".git", with: ""))
        }

        if gitURL.hasPrefix("https://gitlab.com/") {
            return appendGitLabPath(to: gitURL.replacingOccurrences(of: ".git", with: ""))
        }

        return nil
    }
}
