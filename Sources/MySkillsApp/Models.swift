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
    case marketplace
    case git
    case local
    case unknown
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
        name
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
    var installedAt: Date
    var updatedAt: Date?

    var canUpdate: Bool {
        sourceKind == .marketplace || sourceKind == .git
    }

    var readerRequest: SkillReaderRequest {
        SkillReaderRequest(
            kind: .library,
            name: name,
            displayName: displayName,
            description: description,
            source: source,
            skillID: skillId,
            installs: nil,
            sourceURL: sourceWebURL?.absoluteString,
            )
    }

    var sourceWebURL: URL? {
        if let source, source.split(separator: "/").count == 2 {
            return URL(string: "https://github.com/\(source)")
        }

        guard let gitURL else {
            return nil
        }

        return SourceURL.webURL(from: gitURL, ref: ref, subpath: subpath)
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
        "\(skillName)|\(targetPath)"
    }

    var skillName: String
    var scope: SkillScope
    var targetID: String
    var targetName: String
    var projectPath: String?
    var targetPath: String
    var createdAt: Date
}

struct AgentTarget: Identifiable, Hashable {
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

    static let all: [AgentTarget] = [
        AgentTarget(
            id: "universal",
            name: "Universal",
            projectRelativePath: ".agents/skills",
            globalPath: "~/.agents/skills",
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
    var sourceKind: SourceKind = .marketplace
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
        case sourceKind
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
        sourceKind: SourceKind = .marketplace,
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
        self.sourceKind = sourceKind
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
        sourceKind = try container.decodeIfPresent(SourceKind.self, forKey: .sourceKind) ?? .marketplace
        sourceInput = try container.decodeIfPresent(String.self, forKey: .sourceInput)
        gitURL = try container.decodeIfPresent(String.self, forKey: .gitURL)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        subpath = try container.decodeIfPresent(String.self, forKey: .subpath)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown)
    }

    var resolvedSkillID: String {
        skillId ?? id.split(separator: "/").last.map(String.init) ?? name
    }

    var installsText: String {
        if installs >= 1_000_000 {
            return String(format: "%.1fM installs", Double(installs) / 1_000_000)
        }

        if installs >= 1000 {
            return String(format: "%.1fK installs", Double(installs) / 1000)
        }

        return installs == 1 ? "1 install" : "\(installs) installs"
    }

    var readerRequest: SkillReaderRequest {
        SkillReaderRequest(
            kind: sourceKind == .git ? .git : .marketplace,
            name: resolvedSkillID,
            displayName: name,
            description: "",
            source: source,
            skillID: resolvedSkillID,
            installs: installs,
            sourceURL: sourceWebURL?.absoluteString,
            sourceInput: sourceInput,
            gitURL: gitURL,
            ref: ref,
            subpath: subpath,
            markdown: markdown,
            )
    }

    var sourceWebURL: URL? {
        if sourceKind == .git, let gitURL {
            return SourceURL.webURL(from: gitURL, ref: ref, subpath: subpath)
        }

        return URL(string: "https://github.com/\(source)")
    }
}

struct StoredState: Codable {
    var skills: [SkillRecord] = []
    var projects: [ProjectRecord] = []
    var enablements: [EnablementRecord] = []
}

enum SkillReaderKind: String, Codable {
    case library
    case marketplace
    case git
}

struct SkillReaderRequest: Identifiable, Codable, Hashable {
    var kind: SkillReaderKind
    var name: String
    var displayName: String
    var description: String
    var source: String?
    var skillID: String?
    var installs: Int?
    var sourceURL: String?
    var sourceInput: String?
    var gitURL: String?
    var ref: String?
    var subpath: String?
    var markdown: String?

    var id: String {
        switch kind {
        case .library:
            "library:\(name)"
        case .marketplace:
            "marketplace:\(source ?? ""):\(skillID ?? name)"
        case .git:
            "git:\(gitURL ?? source ?? ""):\(subpath ?? skillID ?? name)"
        }
    }

    var searchResult: SkillSearchResult? {
        switch kind {
        case .library:
            return nil

        case .marketplace:
            guard let source else {
                return nil
            }

            return SkillSearchResult(
                id: "\(source)/\(skillID ?? name)",
                skillId: skillID ?? name,
                name: displayName,
                installs: installs ?? 0,
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
                installs: installs ?? 0,
                source: source ?? gitURL,
                sourceKind: .git,
                sourceInput: sourceInput,
                gitURL: gitURL,
                ref: ref,
                subpath: subpath,
                markdown: markdown,
                )
        }
    }

    var sourceWebURL: URL? {
        if let sourceURL {
            return URL(string: sourceURL)
        }

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
    static func serviceLabel(from gitURL: String) -> String {
        if gitURL.contains("github.com") {
            return "GitHub"
        }

        if gitURL.contains("gitlab.com") {
            return "GitLab"
        }

        return "Git"
    }

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
