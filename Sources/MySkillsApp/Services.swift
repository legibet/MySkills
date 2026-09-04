import CryptoKit
import Foundation
import Yams

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

    static func skillURL(_ libraryPath: String) -> URL {
        skillsDirectory.appendingPathComponent(libraryPath, isDirectory: true)
    }

    static func skillURL(_ skill: SkillRecord) -> URL {
        skillURL(skill.libraryRelativePath)
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
    static func load() throws -> (state: StoredState, recoveryMessage: String?) {
        let data: Data
        do {
            data = try Data(contentsOf: PathResolver.stateFile)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (StoredState(), nil)
        }

        do {
            return (try JSONDecoder().decode(StoredState.self, from: data), nil)
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = PathResolver.root
                .appendingPathComponent("state.corrupt-\(timestamp).json")
            try FileManager.default.moveItem(at: PathResolver.stateFile, to: backupURL)

            return (
                StoredState(),
                """
                MySkills could not read its state file. The original was saved to \
                \(backupURL.path). Skills were recovered from the library, but source metadata, \
                projects, enablements, and custom targets could not be restored.
                """
                )
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw AppError.message("This skill is no longer available on skills.sh.")
        }
        guard 200 ..< 300 ~= status else {
            throw AppError.message("Skill download from skills.sh failed.")
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

enum LibraryScanner {
    struct Candidate {
        let folder: URL
        let libraryPath: String
        let owningLinkPath: String?
    }

    struct MissingLink {
        let libraryPath: String
        let owningLinkPath: String
    }

    struct ScanResult {
        var candidates: [Candidate] = []
        var missingLinks: [MissingLink] = []

        var count: Int {
            candidates.count + missingLinks.count
        }
    }

    static func scan(_ root: URL) throws -> ScanResult {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            )
        var result = ScanResult()

        for entry in entries {
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                )
            guard values.isDirectory == true || values.isSymbolicLink == true else {
                continue
            }

            let libraryPath = entry.lastPathComponent
            let previousCount = result.count
            try visit(
                entry,
                libraryPath: libraryPath,
                owningLinkPath: nil,
                ancestors: [],
                result: &result,
                )

            if result.count == previousCount {
                let isLink = values.isSymbolicLink == true
                result.candidates.append(
                    Candidate(
                        folder: isLink ? entry.resolvingSymlinksInPath() : entry,
                        libraryPath: libraryPath,
                        owningLinkPath: isLink ? libraryPath : nil,
                        )
                    )
            }
        }

        return result
    }

    private static func visit(
        _ url: URL,
        libraryPath: String,
        owningLinkPath: String?,
        ancestors: Set<String>,
        result: inout ScanResult,
        ) throws {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            )
        let isLink = values.isSymbolicLink == true
        let owningLinkPath = owningLinkPath ?? (isLink ? libraryPath : nil)

        if isLink, !FileManager.default.fileExists(atPath: url.path) {
            result.missingLinks.append(
                MissingLink(
                    libraryPath: libraryPath,
                    owningLinkPath: owningLinkPath ?? libraryPath,
                    )
                )
            return
        }

        let folder = isLink ? url.resolvingSymlinksInPath() : url
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return
        }

        let resolvedPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard !ancestors.contains(resolvedPath) else {
            return
        }

        if FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("SKILL.md").path
        ) {
            result.candidates.append(
                Candidate(
                    folder: folder,
                    libraryPath: libraryPath,
                    owningLinkPath: owningLinkPath,
                    )
                )
            return
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
        )
        let ancestors = ancestors.union([resolvedPath])

        for entry in entries where entry.lastPathComponent != ".git" {
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                )
            guard values.isDirectory == true || values.isSymbolicLink == true else {
                continue
            }

            try visit(
                entry,
                libraryPath: "\(libraryPath)/\(entry.lastPathComponent)",
                owningLinkPath: owningLinkPath,
                ancestors: ancestors,
                result: &result,
                )
        }
    }
}

enum SkillLibrary {
    struct Metadata {
        let name: String
        let description: String
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(
            at: PathResolver.skillsDirectory,
            withIntermediateDirectories: true,
            )
    }

    static func scan(knownSkills: [SkillRecord]) throws -> [SkillRecord] {
        try prepare()

        let known = Dictionary(
            uniqueKeysWithValues: knownSkills.map { ($0.libraryRelativePath, $0) },
            )
        let scan = try LibraryScanner.scan(PathResolver.skillsDirectory)
        var records = scan.candidates.map { makeRecord($0, known: known) }
        for link in scan.missingLinks {
            records.append(contentsOf: missingRecords(for: link, known: known))
        }

        return records.sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return order == .orderedSame
                ? lhs.libraryRelativePath < rhs.libraryRelativePath
                : order == .orderedAscending
        }
    }

    private static func missingRecords(
        for link: LibraryScanner.MissingLink,
        known: [String: SkillRecord],
        ) -> [SkillRecord] {
        let descendants = link.libraryPath + "/"
        let name = URL(fileURLWithPath: link.libraryPath).lastPathComponent
        var records = known.values.filter {
            $0.libraryRelativePath == link.libraryPath
                || $0.libraryRelativePath.hasPrefix(descendants)
        }
        if records.isEmpty {
            records.append(
                SkillRecord(
                    name: name,
                    displayName: name,
                    description: "",
                    sourceKind: .local,
                    libraryPath: link.libraryPath,
                    owningLinkPath: link.owningLinkPath,
                    installedAt: Date(),
                    )
                )
        }

        return records.map { record in
            var record = record
            record.owningLinkPath = link.owningLinkPath
            record.availabilityIssue = .missingLinkTarget
            record.availabilityMessage = nil
            return record
        }
    }

    private static func makeRecord(
        _ candidate: LibraryScanner.Candidate,
        known: [String: SkillRecord],
        ) -> SkillRecord {
        let name = URL(fileURLWithPath: candidate.libraryPath).lastPathComponent
        var record = known[candidate.libraryPath]
            ?? SkillRecord(
                name: name,
                displayName: name,
                description: "",
                sourceKind: .local,
                installedAt: Date(),
                )
        record.libraryPath = candidate.libraryPath
        record.owningLinkPath = candidate.owningLinkPath

        do {
            let metadata = try validateSkill(
                at: candidate.folder,
                expectedName: name,
                )
            record.displayName = metadata.name
            record.description = metadata.description
            record.availabilityIssue = nil
            record.availabilityMessage = nil
        } catch {
            record.availabilityIssue = .invalidSkill
            record.availabilityMessage = error.localizedDescription
        }
        return record
    }

    static func installDownloadedSkill(
        result: SkillSearchResult,
        response: SkillsSearchClient.DownloadResponse,
        replacing skill: SkillRecord? = nil,
        ) throws -> SkillRecord {
        let installed = try installPreparedSkill(replacing: skill) { stagingURL in
            try writeFiles(response.files, to: stagingURL)
        }

        return SkillRecord(
            name: installed.metadata.name,
            displayName: installed.metadata.name,
            description: installed.metadata.description,
            sourceKind: .skillsSh,
            source: result.source,
            skillId: result.resolvedSkillID,
            importedHash: installed.hash,
            libraryPath: skill?.libraryRelativePath,
            owningLinkPath: skill?.owningLinkPath,
            installedAt: Date(),
            updatedAt: Date(),
            )
    }

    static func importLocalFolder(_ folder: URL) throws -> SkillRecord {
        let installed = try installSkillDirectory(from: folder)

        return SkillRecord(
            name: installed.metadata.name,
            displayName: installed.metadata.name,
            description: installed.metadata.description,
            sourceKind: .local,
            installedAt: Date(),
            )
    }

    static func removeSkill(_ skill: SkillRecord) throws {
        let url = skill.owningLinkPath.map(PathResolver.skillURL) ?? PathResolver.skillURL(skill)
        if skill.owningLinkPath != nil, !isSymlink(url) {
            throw AppError.message("The linked library entry is no longer available.")
        }
        if FileManager.default.fileExists(atPath: url.path) || isSymlink(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func skillMarkdown(_ skill: SkillRecord) throws -> String {
        let skillFile = PathResolver.skillURL(skill).appendingPathComponent("SKILL.md")
        return try MarkdownCleaner.stripFrontmatter(String(contentsOf: skillFile, encoding: .utf8))
    }

    static func installSkillDirectory(
        from source: URL,
        replacing skill: SkillRecord? = nil,
        ) throws -> (metadata: Metadata, hash: String) {
        try installPreparedSkill(replacing: skill) { stagingURL in
            try copyContents(from: source, to: stagingURL)
        }
    }

    static func parseSkillMetadata(at url: URL) -> (name: String?, description: String?) {
        guard let mapping = try? parseFrontmatter(at: url) else {
            return (nil, nil)
        }

        return (
            scalar("name", in: mapping)?.trimmingCharacters(in: .whitespacesAndNewlines),
            scalar("description", in: mapping)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @discardableResult
    static func validateSkill(at folder: URL, expectedName: String? = nil) throws -> Metadata {
        let mapping = try parseFrontmatter(at: folder.appendingPathComponent("SKILL.md"))

        guard let rawName = scalar("name", in: mapping) else {
            throw AppError.message("SKILL.md frontmatter must contain a string field named 'name'.")
        }
        let name = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping

        guard !name.isEmpty else {
            throw AppError.message("SKILL.md field 'name' must not be empty.")
        }
        guard name.count <= 64 else {
            throw AppError.message("SKILL.md field 'name' must not exceed 64 characters.")
        }
        guard name == name.lowercased() else {
            throw AppError.message("SKILL.md field 'name' must be lowercase.")
        }
        guard !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else {
            throw AppError.message(
                "SKILL.md field 'name' cannot start or end with a hyphen or contain consecutive hyphens."
            )
        }
        guard name.unicodeScalars.allSatisfy({
            $0 == "-" || CharacterSet.alphanumerics.contains($0)
        }) else {
            throw AppError.message(
                "SKILL.md field 'name' may contain only letters, numbers, and hyphens."
            )
        }

        if let expectedName {
            let normalizedExpectedName = expectedName.precomposedStringWithCompatibilityMapping
            guard name == normalizedExpectedName else {
                throw AppError.message(
                    "Skill directory '\(expectedName)' must match the name '\(name)' in SKILL.md."
                )
            }
        }

        guard let rawDescription = scalar("description", in: mapping) else {
            throw AppError.message(
                "SKILL.md frontmatter must contain a string field named 'description'."
            )
        }
        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw AppError.message("SKILL.md field 'description' must not be empty.")
        }
        guard rawDescription.count <= 1024 else {
            throw AppError.message("SKILL.md field 'description' must not exceed 1024 characters.")
        }

        if node("license", in: mapping) != nil, scalar("license", in: mapping) == nil {
            throw AppError.message("SKILL.md field 'license' must be a string.")
        }

        if node("allowed-tools", in: mapping) != nil,
           scalar("allowed-tools", in: mapping) == nil
        {
            throw AppError.message("SKILL.md field 'allowed-tools' must be a string.")
        }

        if let metadataNode = node("metadata", in: mapping) {
            guard case let .mapping(metadataMapping) = metadataNode else {
                throw AppError.message("SKILL.md field 'metadata' must be a mapping.")
            }
            for pair in metadataMapping {
                guard pair.key.scalar != nil, pair.value.scalar != nil else {
                    throw AppError.message(
                        "SKILL.md field 'metadata' must contain string keys and values."
                    )
                }
            }
        }

        if node("compatibility", in: mapping) != nil {
            guard let compatibility = scalar("compatibility", in: mapping) else {
                throw AppError.message("SKILL.md field 'compatibility' must be a string.")
            }
            guard !compatibility.isEmpty, compatibility.count <= 500 else {
                throw AppError.message(
                    "SKILL.md field 'compatibility' must contain 1 to 500 characters."
                )
            }
        }

        return Metadata(name: name, description: description)
    }

    private static func installPreparedSkill(
        replacing skill: SkillRecord?,
        populate: (URL) throws -> Void,
        ) throws -> (metadata: Metadata, hash: String) {
        try prepare()

        let fileManager = FileManager.default
        let stagingURL = PathResolver.skillsDirectory
            .appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        try populate(stagingURL)
        let metadata = try validateSkill(at: stagingURL, expectedName: skill?.name)
        let hash = try FolderHash.hash(stagingURL)
        let destination = skill.map(PathResolver.skillURL) ?? PathResolver.skillURL(metadata.name)
        let destinationExists =
            fileManager.fileExists(atPath: destination.path) || isSymlink(destination)

        if skill == nil {
            guard !destinationExists else {
                throw AppError.message("\(destination.path) already exists.")
            }
            try fileManager.moveItem(at: stagingURL, to: destination)
        } else {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: stagingURL,
                backupItemName: ".backup-\(UUID().uuidString)",
                options: .usingNewMetadataOnly,
                )
        }

        return (metadata, hash)
    }

    private static func parseFrontmatter(at url: URL) throws -> Node.Mapping {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw AppError.message("SKILL.md must exist and use UTF-8 encoding.")
        }

        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.first == "---" else {
            throw AppError.message("SKILL.md must start with YAML frontmatter.")
        }
        guard let endIndex = lines.dropFirst().firstIndex(of: "---") else {
            throw AppError.message("SKILL.md frontmatter must end with '---'.")
        }

        let yaml = lines[1 ..< endIndex].joined(separator: "\n")
        let root: Node?
        do {
            root = try compose(yaml: yaml)
        } catch {
            throw AppError.message("SKILL.md contains invalid YAML: \(error.localizedDescription)")
        }

        guard let root else {
            throw AppError.message("SKILL.md frontmatter must be a YAML mapping.")
        }
        guard case let .mapping(mapping) = root else {
            throw AppError.message("SKILL.md frontmatter must be a YAML mapping.")
        }
        return mapping
    }

    private static func scalar(_ field: String, in mapping: Node.Mapping) -> String? {
        node(field, in: mapping)?.scalar?.string
    }

    private static func node(_ field: String, in mapping: Node.Mapping) -> Node? {
        mapping.first { $0.key.scalar?.string == field }?.value
    }

    private static func writeFiles(
        _ files: [SkillsSearchClient.DownloadedFile],
        to destination: URL,
        ) throws {
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

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
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
        let selectedFolders = filterSkillFolders(skillFolders, parsed: parsed)

        guard !selectedFolders.isEmpty else {
            throw AppError.message("No matching skill was found in this source.")
        }

        return try selectedFolders.map { folder in
            let skillFile = folder.appendingPathComponent("SKILL.md")
            let metadata = SkillLibrary.parseSkillMetadata(at: skillFile)
            let skillName = normalizedLookupName(metadata.name ?? folder.lastPathComponent)
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

    static func install(
        _ result: SkillSearchResult,
        replacing skill: SkillRecord? = nil,
        ) throws -> SkillRecord {
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

        let installed = try SkillLibrary.installSkillDirectory(
            from: folder,
            replacing: skill,
            )

        return SkillRecord(
            name: installed.metadata.name,
            displayName: installed.metadata.name,
            description: installed.metadata.description,
            sourceKind: .git,
            sourceInput: result.sourceInput ?? gitURL,
            gitURL: gitURL,
            ref: result.ref,
            subpath: result.subpath,
            importedHash: installed.hash,
            libraryPath: skill?.libraryRelativePath,
            owningLinkPath: skill?.owningLinkPath,
            installedAt: Date(),
            updatedAt: Date(),
            )
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
        ) -> [URL] {
        folders.filter { folder in
            guard let filter = parsed.skillFilter else {
                return true
            }

            let metadata = SkillLibrary.parseSkillMetadata(
                at: folder.appendingPathComponent("SKILL.md"),
                )
            let folderName = normalizedLookupName(folder.lastPathComponent)
            let metadataName = metadata.name.map(normalizedLookupName)
            let cleanFilter = normalizedLookupName(filter)
            return folderName == cleanFilter || metadataName == cleanFilter
        }
    }

    private static func normalizedLookupName(_ raw: String) -> String {
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
        let source = PathResolver.skillURL(skill)
        try SkillLibrary.validateSkill(at: source, expectedName: skill.name)

        let directory = try PathResolver.targetDirectory(
            scope: scope, target: target, projectURL: projectURL,
            )
        let destination = directory.appendingPathComponent(skill.name)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destination.path) || isSymlink(destination) {
            guard try symlinkTarget(destination)?.path == source.standardizedFileURL.path else {
                throw AppError.message("\(destination.path) already exists.")
            }
        } else {
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        }

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

    static func reconcile(
        _ enablements: [EnablementRecord],
        with skills: [SkillRecord],
        ) throws -> [EnablementRecord] {
        let sourcePaths = Set(
            skills.map { PathResolver.skillURL($0).standardizedFileURL.path },
            )
        var valid: [EnablementRecord] = []

        for var enablement in enablements {
            let destination = URL(fileURLWithPath: enablement.targetPath)
            guard let source = try symlinkTarget(destination) else {
                continue
            }

            if let recordedSourcePath = enablement.sourcePath,
               URL(fileURLWithPath: recordedSourcePath).standardizedFileURL.path != source.path
            {
                continue
            }

            guard sourcePaths.contains(source.path) else {
                try FileManager.default.removeItem(at: destination)
                continue
            }

            if enablement.scope == .global {
                enablement.projectPath = nil
            }
            enablement.sourcePath = source.path
            valid.append(enablement)
        }

        return valid
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
            sourcePath: PathResolver.skillURL(skill).standardizedFileURL.path,
            createdAt: Date(),
            )
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func symlinkTarget(_ link: URL) throws -> URL? {
        guard isSymlink(link) else {
            return nil
        }

        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        return URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent())
            .standardizedFileURL
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
