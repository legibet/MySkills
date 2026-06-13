import CryptoKit
import Foundation

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

enum PathResolver {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var root: URL {
        home.appendingPathComponent(".myskills", isDirectory: true)
    }

    static var skillsDirectory: URL {
        root.appendingPathComponent("skills", isDirectory: true)
    }

    static var stateFile: URL {
        root.appendingPathComponent("state.json")
    }

    static func skillURL(_ name: String) -> URL {
        skillsDirectory.appendingPathComponent(name, isDirectory: true)
    }

    static func expandedPath(_ path: String) -> URL {
        if path == "~" {
            return home
        }

        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)))
        }

        return URL(fileURLWithPath: path)
    }

    static func targetDirectory(scope: SkillScope, target: AgentTarget, projectURL: URL?) throws
    -> URL {
        switch scope {
        case .project:
            guard let relativePath = target.projectRelativePath else {
                throw AppError.message(
                    "\(target.name) does not have a project-specific skills path.",
                    )
            }
            guard let projectURL else {
                throw AppError.message("Choose a project folder first.")
            }
            return projectURL.appendingPathComponent(relativePath, isDirectory: true)

        case .global:
            guard let globalPath = target.globalPath else {
                throw AppError.message("\(target.name) does not have a global skills path.")
            }
            return expandedPath(globalPath)
        }
    }
}

enum StateFile {
    static func load() -> StoredState {
        do {
            let data = try Data(contentsOf: PathResolver.stateFile)
            return try JSONDecoder().decode(StoredState.self, from: data)
        } catch {
            return StoredState()
        }
    }

    static func save(_ state: StoredState) throws {
        try SkillLibrary.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: PathResolver.stateFile, options: [.atomic])
    }
}

enum SkillsSearchClient {
    struct SearchEnvelope: Decodable {
        var skills: [SkillSearchResult]
    }

    struct DownloadResponse: Decodable {
        var files: [DownloadedFile]
        var hash: String
    }

    struct DownloadedFile: Decodable {
        var path: String
        var contents: String
    }

    static func search(_ query: String) async throws -> [SkillSearchResult] {
        var components = URLComponents(string: "https://skills.sh/api/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "20")
        ]

        guard let url = components.url else {
            throw AppError.message("Invalid search URL.")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            throw AppError.message("GitHub skill search failed.")
        }

        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        return envelope.skills.sorted { $0.installs > $1.installs }
    }

    static func download(source: String, skillID: String) async throws -> DownloadResponse {
        let parts = source.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw AppError.message("Invalid GitHub source: \(source)")
        }

        let encodedOwner =
            parts[0].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parts[0]
        let encodedRepo =
            parts[1].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parts[1]
        let encodedSkill =
            skillID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? skillID
        let url = URL(
            string: "https://skills.sh/api/download/\(encodedOwner)/\(encodedRepo)/\(encodedSkill)",
            )!

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            throw AppError.message("GitHub skill download failed.")
        }

        return try JSONDecoder().decode(DownloadResponse.self, from: data)
    }

    static func skillMarkdown(source: String, skillID: String) async throws -> String {
        let response = try await download(source: source, skillID: skillID)
        guard let file = response.files.first(where: { $0.path == "SKILL.md" || $0.path.hasSuffix("/SKILL.md") }) else {
            throw AppError.message("This skill snapshot does not contain SKILL.md.")
        }
        return MarkdownCleaner.stripFrontmatter(file.contents)
    }
}

enum SkillLibrary {
    static func prepare() throws {
        try FileManager.default.createDirectory(
            at: PathResolver.skillsDirectory,
            withIntermediateDirectories: true,
            )
    }

    static func scan(knownSkills: [SkillRecord]) throws -> [SkillRecord] {
        try prepare()

        var known: [String: SkillRecord] = [:]
        for skill in knownSkills {
            known[skill.name] = skill
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: PathResolver.skillsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            )

        return entries.compactMap { url in
            guard isDirectoryOrSymlink(url) else {
                return nil
            }

            let skillName = url.lastPathComponent
            let skillFile = url.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else {
                return nil
            }

            let metadata = parseSkillMetadata(at: skillFile)
            var record =
                known[skillName]
                ?? SkillRecord(
                    name: skillName,
                    displayName: metadata.name ?? skillName,
                    description: metadata.description ?? "",
                    sourceKind: .local,
                    installedAt: Date(),
                    )

            record.displayName = metadata.name ?? record.displayName
            record.description = metadata.description ?? record.description
            return record
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func installDownloadedSkill(
        result: SkillSearchResult,
        response: SkillsSearchClient.DownloadResponse,
        replacing: Bool,
        ) throws -> SkillRecord {
        let name = sanitizeSkillName(result.resolvedSkillID)
        let destination = PathResolver.skillURL(name)

        try writeFiles(response.files, to: destination, replacing: replacing)
        let hash = try FolderHash.hash(destination)

        let metadata = parseSkillMetadata(at: destination.appendingPathComponent("SKILL.md"))
        return SkillRecord(
            name: name,
            displayName: metadata.name ?? result.name,
            description: metadata.description ?? "",
            sourceKind: .skillsSh,
            source: result.source,
            skillId: result.resolvedSkillID,
            importedHash: hash,
            installedAt: Date(),
            updatedAt: Date(),
            )
    }

    static func importLocalFolder(_ folder: URL) throws -> SkillRecord {
        let skillFile = folder.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillFile.path) else {
            throw AppError.message("The selected folder does not contain SKILL.md.")
        }

        let metadata = parseSkillMetadata(at: skillFile)
        let name = sanitizeSkillName(metadata.name ?? folder.lastPathComponent)
        let destination = PathResolver.skillURL(name)

        try prepare()
        try copySkillDirectory(from: folder, to: destination, replacing: false)

        return SkillRecord(
            name: name,
            displayName: metadata.name ?? name,
            description: metadata.description ?? "",
            sourceKind: .local,
            installedAt: Date(),
            )
    }

    static func removeSkill(_ skill: SkillRecord) throws {
        let url = PathResolver.skillURL(skill.name)
        if FileManager.default.fileExists(atPath: url.path) || isSymlink(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func skillMarkdown(_ skillName: String) throws -> String {
        let skillFile = PathResolver.skillURL(skillName).appendingPathComponent("SKILL.md")
        return try MarkdownCleaner.stripFrontmatter(String(contentsOf: skillFile, encoding: .utf8))
    }

    static func copySkillDirectory(
        from source: URL,
        to destination: URL,
        replacing: Bool,
        ) throws {
        if FileManager.default.fileExists(atPath: destination.path) || isSymlink(destination) {
            if replacing {
                try FileManager.default.removeItem(at: destination)
            } else {
                throw AppError.message(
                    "The name \(destination.lastPathComponent) is already in use.",
                    )
            }
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyContents(from: source, to: destination)
    }

    static func sanitizeSkillName(_ raw: String) -> String {
        let lowercased = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = lowercased.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression,
            )
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func parseSkillMetadata(at url: URL) -> (name: String?, description: String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (nil, nil)
        }

        var lines = text.components(separatedBy: .newlines)
        guard lines.first == "---" else {
            return (nil, nil)
        }
        lines.removeFirst()

        var name: String?
        var description: String?
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1

            if line == "---" {
                break
            }

            if line.hasPrefix("name:") {
                name = cleanFrontmatterValue(String(line.dropFirst("name:".count)))
            }

            if line.hasPrefix("description:") {
                description = parseFrontmatterFieldValue(
                    String(line.dropFirst("description:".count)),
                    lines: lines,
                    index: &index,
                    )
            }
        }

        return (name, description)
    }

    private static func writeFiles(
        _ files: [SkillsSearchClient.DownloadedFile],
        to destination: URL,
        replacing: Bool,
        ) throws {
        if FileManager.default.fileExists(atPath: destination.path) || isSymlink(destination) {
            if replacing {
                try FileManager.default.removeItem(at: destination)
            } else {
                throw AppError.message(
                    "The name \(destination.lastPathComponent) is already in use.",
                    )
            }
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for file in files {
            let relative = try safeRelativePath(file.path)
            let fileURL = destination.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                )
            try Data(file.contents.utf8).write(to: fileURL)
        }
    }

    private static func copyContents(from source: URL, to destination: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            )

        for entry in entries where entry.lastPathComponent != ".git" {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

            if values.isDirectory == true, values.isSymbolicLink != true {
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: true,
                    )
                try copyContents(from: entry, to: target)
            } else {
                try FileManager.default.copyItem(at: entry, to: target)
            }
        }
    }

    private static func isDirectoryOrSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else {
            return false
        }
        return values.isDirectory == true || values.isSymbolicLink == true
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func cleanFrontmatterValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func parseFrontmatterFieldValue(
        _ value: String,
        lines: [String],
        index: inout Int,
        ) -> String {
        let cleaned = cleanFrontmatterValue(value)
        guard cleaned == ">" || cleaned == "|" else {
            return cleaned
        }

        var blockLines: [String] = []

        while index < lines.count {
            let line = lines[index]
            if line == "---" || (!line.isEmpty && !line.first!.isWhitespace) {
                break
            }
            blockLines.append(line)
            index += 1
        }

        let indent = blockLines
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.prefix { $0.isWhitespace }.count }
            .min() ?? 0
        let normalizedLines = blockLines.map { String($0.dropFirst(min(indent, $0.count))) }

        if cleaned == ">" {
            return normalizedLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        return normalizedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeRelativePath(_ path: String) throws -> String {
        guard !path.hasPrefix("/") else {
            throw AppError.message("Unsafe file path in skill snapshot: \(path)")
        }

        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains("..") else {
            throw AppError.message("Unsafe file path in skill snapshot: \(path)")
        }

        return parts.joined(separator: "/")
    }
}

enum MarkdownCleaner {
    static func stripFrontmatter(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first == "---" else {
            return markdown
        }

        guard let endIndex = lines.dropFirst().firstIndex(of: "---") else {
            return markdown
        }

        return lines.dropFirst(endIndex + 1).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FolderHash {
    static func hash(_ folder: URL) throws -> String {
        var hasher = SHA256()
        try updateHash(folder, base: folder, hasher: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func updateHash(_ folder: URL, base: URL, hasher: inout SHA256) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            )
        .filter { $0.lastPathComponent != ".git" }
        .sorted { $0.path < $1.path }

        for entry in entries {
            let relative = entry.path.replacingOccurrences(of: base.path + "/", with: "")
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
                hasher.update(data: Data("L\(relative)\0\(target)".utf8))
            } else if values.isDirectory == true {
                hasher.update(data: Data("D\(relative)\0".utf8))
                try updateHash(entry, base: base, hasher: &hasher)
            } else {
                hasher.update(data: Data("F\(relative)\0".utf8))
                try hasher.update(data: Data(contentsOf: entry))
            }
        }
    }
}

enum ProcessRunner {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], workingDirectory: URL? = nil)
    throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = workingDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw AppError.message(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }

    static func runDetached(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
    }
}

struct ParsedGitSource {
    var input: String
    var gitURL: String
    var ref: String?
    var subpath: String?
    var skillFilter: String?
}

enum GitInstaller {
    static func browse(_ input: String) throws -> [SkillSearchResult] {
        let parsed = try parse(input)
        let cloneURL = try clone(parsed)
        defer {
            try? FileManager.default.removeItem(at: cloneURL)
        }

        let searchRoot =
            parsed.subpath.map {
                cloneURL.appendingPathComponent($0, isDirectory: true)
            } ?? cloneURL

        let skillFolders = try findSkillFolders(in: searchRoot)
        let selectedFolders = filterSkillFolders(skillFolders, parsed: parsed, wantedName: nil)

        guard !selectedFolders.isEmpty else {
            throw AppError.message("No matching skill was found in this source.")
        }

        return try selectedFolders.map { folder in
            let skillFile = folder.appendingPathComponent("SKILL.md")
            let metadata = SkillLibrary.parseSkillMetadata(at: skillFile)
            let skillName = SkillLibrary.sanitizeSkillName(metadata.name ?? folder.lastPathComponent)
            let relativePath = relativePath(from: cloneURL, to: folder)
            let markdown = try String(contentsOf: skillFile, encoding: .utf8)

            return SkillSearchResult(
                id: "git:\(parsed.gitURL):\(relativePath ?? ".")",
                skillId: skillName,
                name: metadata.name ?? folder.lastPathComponent,
                installs: 0,
                source: SourceURL.repositoryLabel(from: parsed.gitURL),
                searchSource: .git,
                sourceInput: parsed.input,
                gitURL: parsed.gitURL,
                ref: parsed.ref,
                subpath: relativePath,
                markdown: MarkdownCleaner.stripFrontmatter(markdown),
                )
        }
    }

    static func install(_ result: SkillSearchResult, replacing: Bool) throws -> SkillRecord {
        guard result.searchSource == .git, let gitURL = result.gitURL else {
            throw AppError.message("This result is missing Git source metadata.")
        }

        let parsed = ParsedGitSource(
            input: result.sourceInput ?? gitURL,
            gitURL: gitURL,
            ref: result.ref,
            subpath: nil,
            skillFilter: nil,
            )
        let cloneURL = try clone(parsed)
        defer {
            try? FileManager.default.removeItem(at: cloneURL)
        }

        let folder = result.subpath.map {
            cloneURL.appendingPathComponent($0, isDirectory: true)
        } ?? cloneURL
        let skillFile = folder.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillFile.path) else {
            throw AppError.message("No matching skill was found in this source.")
        }

        let metadata = SkillLibrary.parseSkillMetadata(at: skillFile)
        let name = SkillLibrary.sanitizeSkillName(
            result.skillId ?? metadata.name ?? folder.lastPathComponent,
            )
        let destination = PathResolver.skillURL(name)

        try SkillLibrary.copySkillDirectory(from: folder, to: destination, replacing: replacing)
        let hash = try FolderHash.hash(destination)

        return SkillRecord(
            name: name,
            displayName: metadata.name ?? result.name,
            description: metadata.description ?? "",
            sourceKind: .git,
            sourceInput: result.sourceInput ?? gitURL,
            gitURL: gitURL,
            ref: result.ref,
            subpath: result.subpath,
            importedHash: hash,
            installedAt: Date(),
            updatedAt: Date(),
            )
    }

    static func install(_ input: String, replacing: Bool, wantedName: String? = nil) throws
    -> [SkillRecord] {
        let parsed = try parse(input)
        let cloneURL = try clone(parsed)
        defer {
            try? FileManager.default.removeItem(at: cloneURL)
        }

        let searchRoot =
            parsed.subpath.map {
                cloneURL.appendingPathComponent($0, isDirectory: true)
            } ?? cloneURL

        let skillFolders = try findSkillFolders(in: searchRoot)
        let selectedFolders = filterSkillFolders(
            skillFolders,
            parsed: parsed,
            wantedName: wantedName,
            )

        guard !selectedFolders.isEmpty else {
            throw AppError.message("No matching skill was found in this source.")
        }

        return try selectedFolders.map { folder in
            let metadata = SkillLibrary.parseSkillMetadata(
                at: folder.appendingPathComponent("SKILL.md"),
                )
            let name = SkillLibrary.sanitizeSkillName(
                wantedName ?? metadata.name ?? folder.lastPathComponent,
                )
            let destination = PathResolver.skillURL(name)

            try SkillLibrary.copySkillDirectory(from: folder, to: destination, replacing: replacing)
            let hash = try FolderHash.hash(destination)

            return SkillRecord(
                name: name,
                displayName: metadata.name ?? name,
                description: metadata.description ?? "",
                sourceKind: .git,
                sourceInput: parsed.input,
                gitURL: parsed.gitURL,
                ref: parsed.ref,
                subpath: relativePath(from: cloneURL, to: folder),
                importedHash: hash,
                installedAt: Date(),
                updatedAt: Date(),
                )
        }
    }

    static func parse(_ input: String) throws -> ParsedGitSource {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AppError.message("Enter a GitHub, GitLab, or Git URL.")
        }

        var ref: String?
        var skillFilter: String?

        if let hashRange = text.range(of: "#") {
            let fragment = String(text[hashRange.upperBound...])
            text = String(text[..<hashRange.lowerBound])

            if let atRange = fragment.range(of: "@") {
                ref = String(fragment[..<atRange.lowerBound])
                skillFilter = String(fragment[atRange.upperBound...])
            } else {
                ref = fragment
            }
        }

        if !text.contains("://"), !text.hasPrefix("git@"), let atRange = text.range(of: "@") {
            skillFilter = skillFilter ?? String(text[atRange.upperBound...])
            text = String(text[..<atRange.lowerBound])
        }

        if let parsed = parseGitHubURL(text, ref: ref, skillFilter: skillFilter, input: input) {
            return parsed
        }

        if let parsed = parseGitLabURL(text, ref: ref, skillFilter: skillFilter, input: input) {
            return parsed
        }

        if text.hasPrefix("git@") || text.hasSuffix(".git") || text.hasPrefix("ssh://") {
            return ParsedGitSource(
                input: input,
                gitURL: text,
                ref: ref,
                skillFilter: skillFilter,
                )
        }

        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            throw AppError.message("Unsupported source format.")
        }

        let owner = parts[0]
        let repo = parts[1].replacingOccurrences(of: ".git", with: "")
        let subpath = parts.count > 2 ? parts.dropFirst(2).joined(separator: "/") : nil

        return ParsedGitSource(
            input: input,
            gitURL: "https://github.com/\(owner)/\(repo).git",
            ref: ref,
            subpath: subpath,
            skillFilter: skillFilter,
            )
    }

    private static func parseGitHubURL(
        _ text: String,
        ref: String?,
        skillFilter: String?,
        input: String,
        ) -> ParsedGitSource? {
        guard let url = URL(string: text), url.host == "github.com" else {
            return nil
        }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else {
            return nil
        }

        let owner = parts[0]
        let repo = parts[1].replacingOccurrences(of: ".git", with: "")

        if parts.count >= 4, parts[2] == "tree" {
            let treeRef = ref ?? parts[3]
            let subpath = parts.count > 4 ? parts.dropFirst(4).joined(separator: "/") : nil
            return ParsedGitSource(
                input: input,
                gitURL: "https://github.com/\(owner)/\(repo).git",
                ref: treeRef,
                subpath: subpath,
                skillFilter: skillFilter,
                )
        }

        return ParsedGitSource(
            input: input,
            gitURL: "https://github.com/\(owner)/\(repo).git",
            ref: ref,
            skillFilter: skillFilter,
            )
    }

    private static func parseGitLabURL(
        _ text: String,
        ref: String?,
        skillFilter: String?,
        input: String,
        ) -> ParsedGitSource? {
        guard let url = URL(string: text), url.host == "gitlab.com" else {
            return nil
        }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard let marker = parts.firstIndex(of: "-"), parts.indices.contains(marker + 2),
              parts[marker + 1] == "tree"
        else {
            let repoPath = parts.joined(separator: "/").replacingOccurrences(of: ".git", with: "")
            guard repoPath.contains("/") else {
                return nil
            }
            return ParsedGitSource(
                input: input,
                gitURL: "https://gitlab.com/\(repoPath).git",
                ref: ref,
                skillFilter: skillFilter,
                )
        }

        let repoPath = parts[..<marker].joined(separator: "/").replacingOccurrences(
            of: ".git", with: "",
            )
        let treeRef = ref ?? parts[marker + 2]
        let subpath =
            parts.count > marker + 3 ? parts.dropFirst(marker + 3).joined(separator: "/") : nil

        return ParsedGitSource(
            input: input,
            gitURL: "https://gitlab.com/\(repoPath).git",
            ref: treeRef,
            subpath: subpath,
            skillFilter: skillFilter,
            )
    }

    private static func clone(_ parsed: ParsedGitSource) throws -> URL {
        let cloneURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("myskills-\(UUID().uuidString)", isDirectory: true)

        var arguments = ["clone", "--depth", "1"]
        if let ref = parsed.ref, !ref.isEmpty {
            arguments += ["--branch", ref]
        }
        arguments += [parsed.gitURL, cloneURL.path]
        try ProcessRunner.run("git", arguments)
        return cloneURL
    }

    private static func filterSkillFolders(
        _ folders: [URL],
        parsed: ParsedGitSource,
        wantedName: String?,
        ) -> [URL] {
        folders.filter { folder in
            guard let filter = wantedName ?? parsed.skillFilter else {
                return true
            }

            let metadata = SkillLibrary.parseSkillMetadata(
                at: folder.appendingPathComponent("SKILL.md"),
                )
            let folderName = SkillLibrary.sanitizeSkillName(folder.lastPathComponent)
            let metadataName = metadata.name.map(SkillLibrary.sanitizeSkillName)
            let cleanFilter = SkillLibrary.sanitizeSkillName(filter)
            return folderName == cleanFilter || metadataName == cleanFilter
        }
    }

    private static func relativePath(from root: URL, to folder: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path

        if rootPath == folderPath {
            return nil
        }

        guard folderPath.hasPrefix(rootPath + "/") else {
            return folder.lastPathComponent
        }

        return String(folderPath.dropFirst(rootPath.count + 1))
    }

    private static func findSkillFolders(in root: URL) throws -> [URL] {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) {
            return [root]
        }

        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                )
        else {
            return []
        }

        var folders: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }

            if url.lastPathComponent == "SKILL.md" {
                folders.append(url.deletingLastPathComponent())
                enumerator.skipDescendants()
            }
        }

        return folders.sorted { $0.path < $1.path }
    }
}

enum SymlinkService {
    static func enable(skill: SkillRecord, scope: SkillScope, target: AgentTarget, projectURL: URL?)
    throws -> EnablementRecord {
        let source = PathResolver.skillURL(skill.name)
        let directory = try PathResolver.targetDirectory(
            scope: scope, target: target, projectURL: projectURL,
            )
        let destination = directory.appendingPathComponent(skill.name)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destination.path) || isSymlink(destination) {
            if try symlink(destination, pointsTo: source) {
                return makeRecord(
                    skill: skill, scope: scope, target: target, projectURL: projectURL,
                    destination: destination,
                    )
            }
            throw AppError.message("\(destination.path) already exists.")
        }

        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        return makeRecord(
            skill: skill, scope: scope, target: target, projectURL: projectURL,
            destination: destination,
            )
    }

    static func disable(_ enablement: EnablementRecord) throws {
        let destination = URL(fileURLWithPath: enablement.targetPath)
        guard isSymlink(destination) else {
            return
        }
        try FileManager.default.removeItem(at: destination)
    }

    static func validEnablements(_ enablements: [EnablementRecord]) -> [EnablementRecord] {
        enablements.compactMap { enablement in
            let destination = URL(fileURLWithPath: enablement.targetPath)
            let source = PathResolver.skillURL(enablement.skillName)
            guard (try? symlink(destination, pointsTo: source)) == true else {
                return nil
            }

            var record = enablement
            if record.scope == .global {
                record.projectPath = nil
            }
            return record
        }
    }

    private static func makeRecord(
        skill: SkillRecord,
        scope: SkillScope,
        target: AgentTarget,
        projectURL: URL?,
        destination: URL,
        ) -> EnablementRecord {
        EnablementRecord(
            skillName: skill.name,
            scope: scope,
            targetID: target.id,
            targetName: target.name,
            projectPath: projectURL?.path,
            targetPath: destination.path,
            createdAt: Date(),
            )
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func symlink(_ link: URL, pointsTo source: URL) throws -> Bool {
        guard isSymlink(link) else {
            return false
        }

        let rawTarget = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        let targetURL = URL(
            fileURLWithPath: rawTarget, relativeTo: link.deletingLastPathComponent(),
            )
        .standardizedFileURL
        return targetURL.path == source.standardizedFileURL.path
    }
}

enum OpenActionService {
    static func openFolder(_ url: URL, mode: FolderOpenMode, applicationPath: String) throws {
        switch mode {
        case .defaultFolderApp:
            try ProcessRunner.runDetached("/usr/bin/open", [url.path])
        case .finder:
            try ProcessRunner.runDetached("/usr/bin/open", ["-a", "Finder", url.path])
        case .selectedApplication:
            guard !applicationPath.isEmpty else {
                throw AppError.message("Choose an application in Settings first.")
            }
            try ProcessRunner.runDetached("/usr/bin/open", ["-a", applicationPath, url.path])
        }
    }

    static func openURL(_ url: URL) throws {
        try ProcessRunner.runDetached("/usr/bin/open", [url.absoluteString])
    }
}
