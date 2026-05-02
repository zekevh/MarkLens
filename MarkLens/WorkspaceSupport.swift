import Foundation

// MARK: - FolderWatcher
// Watches a set of directories with kqueue and fires a debounced callback when
// any of them changes (file created, deleted, or renamed inside them).

@MainActor
final class FolderWatcher {
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var debounceWork: DispatchWorkItem?
    private var pendingChangedDirectories: Set<URL> = []
    private var handler: ((Set<URL>) -> Void)?

    func watch(directories: [URL], onChange: @escaping (Set<URL>) -> Void) {
        handler = onChange
        let newSet = Set(directories)
        let oldSet = Set(sources.keys)

        for url in oldSet.subtracting(newSet) {
            sources[url]?.cancel()
            sources.removeValue(forKey: url)
        }
        for url in newSet.subtracting(oldSet) {
            let fd = open(url.path, O_EVTONLY)
            guard fd != -1 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            src.setEventHandler { [weak self] in self?.schedule(changedDirectory: url) }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources[url] = src
        }
    }

    func stopAll() {
        debounceWork?.cancel()
        debounceWork = nil
        pendingChangedDirectories = []
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
        handler = nil
    }

    private func schedule(changedDirectory: URL) {
        pendingChangedDirectories.insert(changedDirectory)
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changedDirectories = self.pendingChangedDirectories
            self.pendingChangedDirectories = []
            self.handler?(changedDirectories)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

// MARK: - FileNode

struct FileNode: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    var optionalChildren: [FileNode]? { isDirectory ? (children ?? []) : nil }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

// MARK: - GitignoreFilter

/// Parses a single .gitignore file and reports whether a path should be hidden.
struct GitignoreFilter {
    private struct Rule {
        let pattern: String
        let isNegated: Bool
        let isDirOnly: Bool
        let anchored: Bool
    }

    private let rules: [Rule]
    private let basePath: String

    nonisolated init(at directoryURL: URL) {
        basePath = directoryURL.path
        let gitignoreURL = directoryURL.appendingPathComponent(".gitignore")
        guard let text = try? String(contentsOf: gitignoreURL, encoding: .utf8) else {
            rules = []
            return
        }
        rules = text.components(separatedBy: .newlines).compactMap { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            let negated = s.hasPrefix("!")
            if negated { s.removeFirst() }
            let dirOnly = s.hasSuffix("/")
            if dirOnly { s.removeLast() }
            let hadLeadingSlash = s.hasPrefix("/")
            if hadLeadingSlash { s.removeFirst() }
            let anchored = hadLeadingSlash || s.contains("/")
            return Rule(pattern: s, isNegated: negated, isDirOnly: dirOnly, anchored: anchored)
        }
    }

    nonisolated func isIgnored(_ url: URL, isDirectory: Bool) -> Bool {
        guard url.path.hasPrefix(basePath + "/") else { return false }
        let rel = String(url.path.dropFirst(basePath.count + 1))
        let name = url.lastPathComponent
        var result = false
        for rule in rules {
            if rule.isDirOnly && !isDirectory { continue }
            let hit = rule.anchored
                ? Self.globMatch(pattern: rule.pattern, string: rel)
                : Self.globMatch(pattern: rule.pattern, string: name)
                    || Self.globMatchAnywhere(pattern: rule.pattern, relativePath: rel)
            if hit { result = !rule.isNegated }
        }
        return result
    }

    nonisolated private static func globMatch(pattern: String, string: String) -> Bool {
        if pattern.hasPrefix("**/") {
            return globMatchAnywhere(pattern: String(pattern.dropFirst(3)), relativePath: string)
        }
        if pattern.hasSuffix("/**") {
            let dir = String(pattern.dropLast(3))
            return string == dir || string.hasPrefix(dir + "/")
        }
        return fnmatch(pattern, string, FNM_PATHNAME | FNM_PERIOD) == 0
    }

    nonisolated private static func globMatchAnywhere(pattern: String, relativePath: String) -> Bool {
        let parts = relativePath.components(separatedBy: "/")
        for i in 0..<parts.count {
            let suffix = parts[i...].joined(separator: "/")
            if fnmatch(pattern, suffix, FNM_PATHNAME | FNM_PERIOD) == 0 { return true }
        }
        return false
    }
}

// MARK: - ExternalEditConflict

struct ExternalEditConflict {
    let diskContent: String
    let fileName: String
}

enum GitFileChange: Equatable {
    case new
    case modified
}

struct GitFileHistoryEntry: Identifiable, Equatable {
    let fullHash: String
    let shortHash: String
    let subject: String
    let authorDate: Date

    var id: String { fullHash }
}

struct GitDiffSummary: Equatable {
    let added: Int
    let deleted: Int
}

struct GitRepositoryInfo: Equatable {
    let remoteName: String
    let branchName: String
    let diffSummary: GitDiffSummary
}

enum GitStatusService {
    nonisolated private static let preferredGitExecutablePath = "/Library/Developer/CommandLineTools/usr/bin/git"
    nonisolated private static let fallbackGitExecutablePath = "/usr/bin/git"
    nonisolated private static let historyFieldSeparator = "\u{1F}"

    nonisolated static func loadChanges(for workspaceURL: URL) async -> [String: GitFileChange] {
        await Task.detached(priority: .utility) {
            loadChangesSync(for: workspaceURL)
        }.value
    }

    nonisolated static func loadRepositoryInfo(for workspaceURL: URL) async -> GitRepositoryInfo? {
        await Task.detached(priority: .utility) {
            loadRepositoryInfoSync(for: workspaceURL)
        }.value
    }

    nonisolated static func loadHistory(for fileURL: URL) async -> [GitFileHistoryEntry]? {
        await Task.detached(priority: .utility) {
            loadHistorySync(for: fileURL)
        }.value
    }

    nonisolated private static func loadChangesSync(for workspaceURL: URL) -> [String: GitFileChange] {
        guard let gitRoot = gitRoot(for: workspaceURL) else {
            AppLogger.debug("No git root for \(workspaceURL.path)", category: "Git")
            return [:]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutablePath())
        process.arguments = ["-C", gitRoot.path, "status", "--porcelain=v1", "--untracked-files=all"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            AppLogger.error("Failed to launch git status in \(gitRoot.path): \(error.localizedDescription)", category: "Git")
            return [:]
        }

        process.waitUntilExit()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            AppLogger.error(
                "git status failed in \(gitRoot.path) code \(process.terminationStatus) stderr: \(stderrText)",
                category: "Git"
            )
            return [:]
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            AppLogger.info("git status returned no changes for \(gitRoot.path)", category: "Git")
            return [:]
        }

        var changes: [String: GitFileChange] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count >= 3 else { continue }
            let status = String(line.prefix(2))
            let payload = line.dropFirst(3)

            let pathComponent: String
            if let renameSeparator = payload.range(of: " -> ") {
                pathComponent = String(payload[renameSeparator.upperBound...])
            } else {
                pathComponent = String(payload)
            }

            let absolutePath = gitRoot.appendingPathComponent(pathComponent).standardizedFileURL.path

            if status == "??" {
                changes[absolutePath] = .new
                continue
            }

            let symbols = Set(status.filter { $0 != " " })
            if !symbols.isEmpty {
                changes[absolutePath] = .modified
            }
        }

        AppLogger.info("Loaded \(changes.count) git changes for \(gitRoot.lastPathComponent)", category: "Git")
        return changes
    }

    nonisolated private static func loadRepositoryInfoSync(for workspaceURL: URL) -> GitRepositoryInfo? {
        guard let gitRoot = gitRoot(for: workspaceURL) else { return nil }

        let branchName = runGitCommand(["branch", "--show-current"], at: gitRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteAlias = runGitCommand(["remote"], at: gitRoot)?
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteURL = remoteAlias.flatMap { alias in
            runGitCommand(["remote", "get-url", alias], at: gitRoot)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let diffSummary = loadDiffSummary(at: gitRoot)

        return GitRepositoryInfo(
            remoteName: remoteDisplayName(remoteAlias: remoteAlias, remoteURL: remoteURL),
            branchName: branchName?.isEmpty == false ? branchName! : "Detached HEAD",
            diffSummary: diffSummary
        )
    }

    nonisolated private static func loadHistorySync(for fileURL: URL) -> [GitFileHistoryEntry]? {
        guard let gitRoot = gitRoot(for: fileURL) else {
            AppLogger.debug("No git root for file history \(fileURL.path)", category: "Git")
            return nil
        }

        let standardizedFileURL = fileURL.standardizedFileURL
        guard standardizedFileURL.path.hasPrefix(gitRoot.standardizedFileURL.path + "/") else {
            AppLogger.error("File \(fileURL.path) is not inside git root \(gitRoot.path)", category: "Git")
            return []
        }

        let relativePath = String(standardizedFileURL.path.dropFirst(gitRoot.standardizedFileURL.path.count + 1))
        let format = "%H\(historyFieldSeparator)%h\(historyFieldSeparator)%ct\(historyFieldSeparator)%s"
        let arguments = ["log", "--follow", "--format=\(format)", "--", relativePath]
        let output = runGitCommand(arguments, at: gitRoot) ?? ""
        let entries = parseFileHistory(output)
        AppLogger.info(
            "Loaded \(entries.count) history entries for \(relativePath) in \(gitRoot.lastPathComponent)",
            category: "Git"
        )
        return entries
    }

    nonisolated private static func loadDiffSummary(at gitRoot: URL) -> GitDiffSummary {
        let unstaged = parseNumstat(runGitCommand(["diff", "--numstat"], at: gitRoot))
        let staged = parseNumstat(runGitCommand(["diff", "--cached", "--numstat"], at: gitRoot))
        return GitDiffSummary(
            added: unstaged.added + staged.added,
            deleted: unstaged.deleted + staged.deleted
        )
    }

    nonisolated private static func parseNumstat(_ output: String?) -> GitDiffSummary {
        guard let output, !output.isEmpty else {
            return GitDiffSummary(added: 0, deleted: 0)
        }

        var added = 0
        var deleted = 0

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            if let plus = Int(columns[0]) {
                added += plus
            }
            if let minus = Int(columns[1]) {
                deleted += minus
            }
        }

        return GitDiffSummary(added: added, deleted: deleted)
    }

    nonisolated static func parseFileHistory(_ output: String) -> [GitFileHistoryEntry] {
        guard !output.isEmpty else { return [] }

        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let columns = line.split(
                    separator: Character(historyFieldSeparator),
                    omittingEmptySubsequences: false
                )
                guard columns.count >= 4 else { return nil }
                guard let timestamp = TimeInterval(columns[2]) else { return nil }
                return GitFileHistoryEntry(
                    fullHash: String(columns[0]),
                    shortHash: String(columns[1]),
                    subject: String(columns[3]),
                    authorDate: Date(timeIntervalSince1970: timestamp)
                )
            }
    }

    nonisolated private static func runGitCommand(_ arguments: [String], at gitRoot: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutablePath())
        process.arguments = ["-C", gitRoot.path] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            AppLogger.error(
                "Failed to launch git \(arguments.joined(separator: " ")) in \(gitRoot.path): \(error.localizedDescription)",
                category: "Git"
            )
            return nil
        }

        process.waitUntilExit()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            AppLogger.error(
                "git \(arguments.joined(separator: " ")) failed in \(gitRoot.path) code \(process.terminationStatus) stderr: \(stderrText)",
                category: "Git"
            )
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func remoteDisplayName(remoteAlias: String?, remoteURL: String?) -> String {
        guard let remoteURL, !remoteURL.isEmpty else {
            return remoteAlias?.isEmpty == false ? remoteAlias! : "No remote"
        }

        if let slug = repositorySlug(from: remoteURL) {
            return slug
        }

        return remoteAlias?.isEmpty == false ? remoteAlias! : remoteURL
    }

    nonisolated private static func repositorySlug(from remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleaned = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
            return cleaned.isEmpty ? nil : cleaned
        }

        if let colonIndex = trimmed.lastIndex(of: ":") {
            let path = String(trimmed[trimmed.index(after: colonIndex)...])
            let cleaned = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
            return cleaned.isEmpty ? nil : cleaned
        }

        return nil
    }

    nonisolated private static func gitExecutablePath() -> String {
        if FileManager.default.isExecutableFile(atPath: preferredGitExecutablePath) {
            return preferredGitExecutablePath
        }
        return fallbackGitExecutablePath
    }

    nonisolated static func gitRoot(for url: URL) -> URL? {
        let startingURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        var currentURL = startingURL.standardizedFileURL

        while currentURL.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent(".git").path) {
                return currentURL
            }
            currentURL.deleteLastPathComponent()
        }

        if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent(".git").path) {
            return currentURL
        }

        return nil
    }
}

// MARK: - WorkspaceTreeBuilder

enum WorkspaceTreeBuilder {
    private struct BuildResult {
        let nodes: [FileNode]
        let watchedDirectories: [URL]
    }

    nonisolated static func buildTree(
        at url: URL,
        pinnedURLs: Set<String>,
        parentFilters: [GitignoreFilter] = []
    ) -> [FileNode] {
        build(at: url, pinnedURLs: pinnedURLs, parentFilters: parentFilters).nodes
    }

    nonisolated static func buildSnapshot(
        at url: URL,
        pinnedURLs: Set<String>,
        parentFilters: [GitignoreFilter] = []
    ) -> WorkspaceSnapshot {
        let result = build(at: url, pinnedURLs: pinnedURLs, parentFilters: parentFilters)
        return WorkspaceSnapshot(
            rootFolder: url,
            nodes: result.nodes,
            watchedDirectories: [url] + result.watchedDirectories
        )
    }

    nonisolated static func collectDirectories(from nodes: [FileNode]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            guard node.isDirectory else { return [] }
            return [node.url] + collectDirectories(from: node.children ?? [])
        }
    }

    nonisolated static func replacingSubtree(
        in nodes: [FileNode],
        directoryURL: URL,
        replacementChildren: [FileNode]
    ) -> [FileNode]? {
        var replaced = false
        let updatedNodes = replacingSubtree(
            in: nodes,
            directoryURL: directoryURL,
            replacementChildren: replacementChildren,
            replaced: &replaced
        )
        return replaced ? updatedNodes : nil
    }

    nonisolated private static func build(
        at url: URL,
        pinnedURLs: Set<String>,
        parentFilters: [GitignoreFilter]
    ) -> BuildResult {
        let fm = FileManager.default
        var filters = parentFilters
        if fm.fileExists(atPath: url.appendingPathComponent(".gitignore").path) {
            filters.append(GitignoreFilter(at: url))
        }
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else { return BuildResult(nodes: [], watchedDirectories: []) }

        var watchedDirectories: [URL] = []
        let nodes = contents.compactMap { child -> FileNode? in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if filters.contains(where: { $0.isIgnored(child, isDirectory: isDir) }) { return nil }
            if isDir {
                let result = build(at: child, pinnedURLs: pinnedURLs, parentFilters: filters)
                guard !result.nodes.isEmpty else { return nil }
                watchedDirectories.append(child)
                watchedDirectories.append(contentsOf: result.watchedDirectories)
                return FileNode(
                    url: child,
                    name: child.lastPathComponent,
                    isDirectory: true,
                    children: result.nodes
                )
            }

            guard isDisplayableMarkdownFile(child) else { return nil }
            return FileNode(url: child, name: child.lastPathComponent, isDirectory: false)
        }
        .sorted { lhs, rhs in
            let lhsPinned = pinnedURLs.contains(lhs.url.absoluteString)
            let rhsPinned = pinnedURLs.contains(rhs.url.absoluteString)
            if lhsPinned != rhsPinned { return lhsPinned }
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return BuildResult(nodes: nodes, watchedDirectories: watchedDirectories)
    }

    nonisolated private static func isDisplayableMarkdownFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "md" || ext == "markdown" else { return false }

        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.hasSuffix("~") else { return false }

        return true
    }

    nonisolated private static func replacingSubtree(
        in nodes: [FileNode],
        directoryURL: URL,
        replacementChildren: [FileNode],
        replaced: inout Bool
    ) -> [FileNode] {
        nodes.compactMap { node in
            if node.url == directoryURL {
                replaced = true
                guard node.isDirectory, !replacementChildren.isEmpty else { return nil }
                var updatedNode = node
                updatedNode.children = replacementChildren
                return updatedNode
            }

            guard node.isDirectory,
                  directoryURL.path.hasPrefix(node.url.path + "/") else {
                return node
            }

            let updatedChildren = replacingSubtree(
                in: node.children ?? [],
                directoryURL: directoryURL,
                replacementChildren: replacementChildren,
                replaced: &replaced
            )
            guard !updatedChildren.isEmpty else { return nil }
            var updatedNode = node
            updatedNode.children = updatedChildren
            return updatedNode
        }
    }
}

struct WorkspaceSnapshot {
    let rootFolder: URL
    let nodes: [FileNode]
    let watchedDirectories: [URL]
}

struct WorkspaceLinkRewriteResult {
    let rewrittenFiles: [URL: String]
    let errors: [String]

    nonisolated var changedFiles: [URL] {
        rewrittenFiles.keys.sorted { $0.path < $1.path }
    }
}

struct WorkspaceBrokenLinkReport {
    let brokenLinkCountsByFile: [URL: Int]
    let errors: [String]
}

struct WorkspaceResolvedLink: Codable, Equatable, Sendable {
    let sourcePath: String
    let text: String
    let destination: String
    let resolvedPath: String?
    let isExternal: Bool
    let exists: Bool
    let line: Int
}

struct WorkspaceFileLinks: Codable, Equatable, Sendable {
    let path: String
    let links: [WorkspaceResolvedLink]
}

struct WorkspaceBacklinkMatch: Codable, Equatable, Sendable {
    let targetPath: String
    let sourcePath: String
    let text: String
    let destination: String
    let line: Int
}

struct WorkspaceLinkHealthFileReport: Codable, Equatable, Sendable {
    let path: String
    let brokenLinks: [WorkspaceResolvedLink]
}

enum WorkspaceMarkdownSupport {
    nonisolated static let inlineLinkPattern =
        try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^\)\n]+)(\))"#)

    nonisolated static func markdownFiles(in rootFolderURL: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard isDisplayableMarkdownFile(url) else { continue }
            urls.append(url.standardizedFileURL)
        }
        return urls
    }

    nonisolated static func isDisplayableMarkdownFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "md" || ext == "markdown" else { return false }

        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.hasSuffix("~") else { return false }

        return true
    }

    nonisolated static func pathPart(for destination: String) -> String {
        let splitIndex = destination.firstIndex { $0 == "#" || $0 == "?" }
        return splitIndex.map { String(destination[..<$0]) } ?? destination
    }

    nonisolated static func isExternalDestination(_ destination: String) -> Bool {
        guard let absoluteURL = URL(string: destination),
              let scheme = absoluteURL.scheme?.lowercased() else {
            return false
        }
        return ["http", "https", "mailto", "ftp"].contains(scheme)
    }

    nonisolated static func resolvedPath(for destination: String, relativeTo baseURL: URL) -> URL? {
        let pathPart = pathPart(for: destination)
        guard !pathPart.isEmpty else { return nil }
        return URL(fileURLWithPath: pathPart, relativeTo: baseURL).standardizedFileURL
    }
}

enum WorkspaceLinkInspector {
    nonisolated static func links(inFileAt fileURL: URL) throws -> [WorkspaceResolvedLink] {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return links(in: text, at: fileURL)
    }

    nonisolated static func links(in text: String, at fileURL: URL) -> [WorkspaceResolvedLink] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let sourceURL = fileURL.standardizedFileURL
        let sourceBaseURL = sourceURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        let nsText = text as NSString
        var links: [WorkspaceResolvedLink] = []

        WorkspaceMarkdownSupport.inlineLinkPattern.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            let textRange = match.range(at: 2)
            let destinationRange = match.range(at: 4)
            guard textRange.location != NSNotFound,
                  destinationRange.location != NSNotFound,
                  let textSubstringRange = Range(textRange, in: text),
                  let destinationSubstringRange = Range(destinationRange, in: text) else {
                return
            }

            let linkText = String(text[textSubstringRange])
            let destination = String(text[destinationSubstringRange])
            let isExternal = WorkspaceMarkdownSupport.isExternalDestination(destination)
            let resolvedURL = isExternal ? nil : WorkspaceMarkdownSupport.resolvedPath(for: destination, relativeTo: sourceBaseURL)
            let exists = resolvedURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
            let line = nsText.substring(to: destinationRange.location).reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }

            links.append(
                WorkspaceResolvedLink(
                    sourcePath: sourceURL.path,
                    text: linkText,
                    destination: destination,
                    resolvedPath: resolvedURL?.path,
                    isExternal: isExternal,
                    exists: isExternal ? true : exists,
                    line: line
                )
            )
        }

        return links
    }

    nonisolated static func links(
        inWorkspace rootFolderURL: URL,
        matching targetURLs: [URL]? = nil
    ) -> [WorkspaceFileLinks] {
        let fileManager = FileManager.default
        let normalizedRoot = rootFolderURL.standardizedFileURL
        let requested = targetURLs?.map(\.standardizedFileURL)
        let markdownFiles = requested ?? WorkspaceMarkdownSupport.markdownFiles(in: normalizedRoot, fileManager: fileManager)

        return markdownFiles.compactMap { fileURL in
            guard WorkspaceMarkdownSupport.isDisplayableMarkdownFile(fileURL) else { return nil }
            guard let fileLinks = try? links(inFileAt: fileURL) else { return nil }
            return WorkspaceFileLinks(path: fileURL.path, links: fileLinks)
        }
    }

    nonisolated static func backlinks(
        to targetURL: URL,
        inWorkspace rootFolderURL: URL
    ) -> [WorkspaceBacklinkMatch] {
        let normalizedTarget = targetURL.standardizedFileURL
        return links(inWorkspace: rootFolderURL)
            .flatMap(\.links)
            .filter { $0.resolvedPath == normalizedTarget.path }
            .map {
                WorkspaceBacklinkMatch(
                    targetPath: normalizedTarget.path,
                    sourcePath: $0.sourcePath,
                    text: $0.text,
                    destination: $0.destination,
                    line: $0.line
                )
            }
            .sorted {
                if $0.sourcePath == $1.sourcePath { return $0.line < $1.line }
                return $0.sourcePath < $1.sourcePath
            }
    }

    nonisolated static func health(
        inWorkspace rootFolderURL: URL,
        matching targetURLs: [URL]? = nil
    ) -> [WorkspaceLinkHealthFileReport] {
        links(inWorkspace: rootFolderURL, matching: targetURLs)
            .compactMap { fileLinks in
                let broken = fileLinks.links.filter { !$0.isExternal && !$0.exists }
                guard !broken.isEmpty else { return nil }
                return WorkspaceLinkHealthFileReport(path: fileLinks.path, brokenLinks: broken)
            }
            .sorted { $0.path < $1.path }
    }
}

enum WorkspaceLinkRewriter {
    nonisolated static func rewriteLinks(
        inWorkspace rootFolderURL: URL,
        movedURLsBySource: [URL: URL],
        inMemoryContents: [URL: String] = [:]
    ) -> WorkspaceLinkRewriteResult {
        let fm = FileManager.default
        let normalizedRoot = rootFolderURL.standardizedFileURL
        let normalizedMoves = Dictionary(uniqueKeysWithValues: movedURLsBySource.map {
            ($0.key.standardizedFileURL, $0.value.standardizedFileURL)
        })
        let originalURLsByMovedURL = Dictionary(uniqueKeysWithValues: normalizedMoves.map { ($0.value, $0.key) })

        let markdownFiles = markdownFiles(in: normalizedRoot, fileManager: fm)
        guard !markdownFiles.isEmpty else {
            return WorkspaceLinkRewriteResult(rewrittenFiles: [:], errors: [])
        }

        var rewrittenFiles: [URL: String] = [:]
        var errors: [String] = []

        for fileURL in markdownFiles {
            let sourceText: String
            if let inMemory = inMemoryContents[fileURL] {
                sourceText = inMemory
            } else {
                do {
                    sourceText = try String(contentsOf: fileURL, encoding: .utf8)
                } catch {
                    errors.append("Could not read \"\(fileURL.lastPathComponent)\" for link updates.")
                    continue
                }
            }

            guard let rewritten = rewriteContent(
                sourceText,
                sourceFileURL: fileURL,
                linkResolutionBaseURL: originalURLsByMovedURL[fileURL]?.deletingLastPathComponent(),
                movedURLsBySource: normalizedMoves
            ), rewritten != sourceText else {
                continue
            }

            do {
                try rewritten.write(to: fileURL, atomically: true, encoding: .utf8)
                rewrittenFiles[fileURL] = rewritten
            } catch {
                errors.append("Could not update links in \"\(fileURL.lastPathComponent)\".")
            }
        }

        return WorkspaceLinkRewriteResult(rewrittenFiles: rewrittenFiles, errors: errors)
    }

    nonisolated private static func markdownFiles(in rootFolderURL: URL, fileManager: FileManager) -> [URL] {
        WorkspaceMarkdownSupport.markdownFiles(in: rootFolderURL, fileManager: fileManager)
    }

    nonisolated private static func isDisplayableMarkdownFile(_ url: URL) -> Bool {
        WorkspaceMarkdownSupport.isDisplayableMarkdownFile(url)
    }

    nonisolated private static func rewriteContent(
        _ text: String,
        sourceFileURL: URL,
        linkResolutionBaseURL: URL?,
        movedURLsBySource: [URL: URL]
    ) -> String? {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let sourceBaseURL = sourceFileURL.deletingLastPathComponent()
        let lookupBaseURL = linkResolutionBaseURL ?? sourceBaseURL
        let mutable = NSMutableString(string: text)
        var replacements: [(NSRange, String)] = []

        WorkspaceMarkdownSupport.inlineLinkPattern.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            let destinationRange = match.range(at: 4)
            guard destinationRange.location != NSNotFound,
                  let destinationSubstringRange = Range(destinationRange, in: text) else {
                return
            }

            let destination = String(text[destinationSubstringRange])
            guard let rewritten = rewriteDestination(
                destination,
                lookupBaseURL: lookupBaseURL,
                rewrittenBaseURL: sourceBaseURL,
                movedURLsBySource: movedURLsBySource
            ), rewritten != destination else {
                return
            }

            replacements.append((destinationRange, rewritten))
        }

        guard !replacements.isEmpty else { return nil }
        for (range, replacement) in replacements.reversed() {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return mutable as String
    }

    nonisolated private static func rewriteDestination(
        _ destination: String,
        lookupBaseURL: URL,
        rewrittenBaseURL: URL,
        movedURLsBySource: [URL: URL]
    ) -> String? {
        if WorkspaceMarkdownSupport.isExternalDestination(destination) {
            return nil
        }

        let pathPart = WorkspaceMarkdownSupport.pathPart(for: destination)
        let suffix = String(destination.dropFirst(pathPart.count))
        guard !pathPart.isEmpty else { return nil }

        let resolvedURL = URL(fileURLWithPath: pathPart, relativeTo: lookupBaseURL).standardizedFileURL
        if let relocatedURL = relocatedURL(for: resolvedURL, movedURLsBySource: movedURLsBySource) {
            let relativePath = relativePath(from: rewrittenBaseURL, to: relocatedURL)
            return relativePath + suffix
        }

        guard lookupBaseURL.standardizedFileURL != rewrittenBaseURL.standardizedFileURL else {
            return nil
        }

        let rebasedPath = relativePath(from: rewrittenBaseURL, to: resolvedURL)
        return rebasedPath == pathPart ? nil : rebasedPath + suffix
    }

    nonisolated private static func relocatedURL(
        for resolvedURL: URL,
        movedURLsBySource: [URL: URL]
    ) -> URL? {
        if let exactMatch = movedURLsBySource[resolvedURL] {
            return exactMatch
        }

        let path = resolvedURL.path
        let candidateParents = movedURLsBySource.keys
            .filter { path.hasPrefix($0.path + "/") }
            .sorted { $0.path.count > $1.path.count }

        guard let matchedParent = candidateParents.first,
              let relocatedParent = movedURLsBySource[matchedParent] else {
            return nil
        }

        let suffix = String(path.dropFirst(matchedParent.path.count + 1))
        return relocatedParent.appendingPathComponent(suffix).standardizedFileURL
    }

    nonisolated private static func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        let commonCount = zip(baseComponents, targetComponents).prefix { $0 == $1 }.count

        let upwardCount = max(baseComponents.count - commonCount, 0)
        let upwardComponents = Array(repeating: "..", count: upwardCount)
        let downwardComponents = Array(targetComponents.dropFirst(commonCount))
        let components = upwardComponents + downwardComponents

        if components.isEmpty {
            return "./" + targetURL.lastPathComponent
        }
        let path = NSString.path(withComponents: components)
        if path.hasPrefix("../") || path.hasPrefix("./") {
            return path
        }
        return "./" + path
    }
}

enum WorkspaceBrokenLinkScanner {
    nonisolated static func scanWorkspace(
        inWorkspace rootFolderURL: URL,
        inMemoryContents: [URL: String] = [:]
    ) -> WorkspaceBrokenLinkReport {
        let fm = FileManager.default
        let normalizedRoot = rootFolderURL.standardizedFileURL
        let markdownFiles = WorkspaceMarkdownSupport.markdownFiles(in: normalizedRoot, fileManager: fm)
        guard !markdownFiles.isEmpty else {
            return WorkspaceBrokenLinkReport(brokenLinkCountsByFile: [:], errors: [])
        }

        var brokenLinkCountsByFile: [URL: Int] = [:]
        var errors: [String] = []

        for fileURL in markdownFiles {
            let sourceText: String
            if let inMemory = inMemoryContents[fileURL] {
                sourceText = inMemory
            } else {
                do {
                    sourceText = try String(contentsOf: fileURL, encoding: .utf8)
                } catch {
                    errors.append("Could not read \"\(fileURL.lastPathComponent)\" for link health.")
                    continue
                }
            }

            let brokenLinkCount = brokenInternalLinkCount(in: sourceText, sourceFileURL: fileURL, fileManager: fm)
            if brokenLinkCount > 0 {
                brokenLinkCountsByFile[fileURL] = brokenLinkCount
            }
        }

        return WorkspaceBrokenLinkReport(
            brokenLinkCountsByFile: brokenLinkCountsByFile,
            errors: errors
        )
    }

    nonisolated static func scanFile(_ text: String, at fileURL: URL) -> Int {
        brokenInternalLinkCount(
            in: text,
            sourceFileURL: fileURL.standardizedFileURL,
            fileManager: .default
        )
    }

    nonisolated private static func brokenInternalLinkCount(
        in text: String,
        sourceFileURL: URL,
        fileManager: FileManager
    ) -> Int {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let sourceBaseURL = sourceFileURL.deletingLastPathComponent()
        var brokenLinkCount = 0

        WorkspaceMarkdownSupport.inlineLinkPattern.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            let destinationRange = match.range(at: 4)
            guard destinationRange.location != NSNotFound,
                  let destinationSubstringRange = Range(destinationRange, in: text) else {
                return
            }

            let destination = String(text[destinationSubstringRange])
            guard !WorkspaceMarkdownSupport.isExternalDestination(destination) else { return }

            let pathPart = WorkspaceMarkdownSupport.pathPart(for: destination)
            guard !pathPart.isEmpty else { return }

            let resolvedURL = URL(fileURLWithPath: pathPart, relativeTo: sourceBaseURL).standardizedFileURL
            guard !fileManager.fileExists(atPath: resolvedURL.path) else { return }
            brokenLinkCount += 1
        }

        return brokenLinkCount
    }
}

enum WorkspaceRefreshService {
    static func buildSnapshot(at folder: URL, pinnedURLs: Set<String>) async -> WorkspaceSnapshot {
        await Task.detached(priority: .utility) {
            WorkspaceTreeBuilder.buildSnapshot(at: folder, pinnedURLs: pinnedURLs)
        }.value
    }

    static func refreshSnapshot(
        from snapshot: WorkspaceSnapshot,
        changedDirectory: URL,
        pinnedURLs: Set<String>
    ) async -> WorkspaceSnapshot {
        await Task.detached(priority: .utility) {
            guard changedDirectory == snapshot.rootFolder || changedDirectory.path.hasPrefix(snapshot.rootFolder.path + "/") else {
                return snapshot
            }

            if changedDirectory == snapshot.rootFolder {
                return WorkspaceTreeBuilder.buildSnapshot(at: snapshot.rootFolder, pinnedURLs: pinnedURLs)
            }

            let replacementChildren = WorkspaceTreeBuilder.buildTree(at: changedDirectory, pinnedURLs: pinnedURLs)
            guard let nodes = WorkspaceTreeBuilder.replacingSubtree(
                in: snapshot.nodes,
                directoryURL: changedDirectory,
                replacementChildren: replacementChildren
            ) else {
                return WorkspaceTreeBuilder.buildSnapshot(at: snapshot.rootFolder, pinnedURLs: pinnedURLs)
            }

            return WorkspaceSnapshot(
                rootFolder: snapshot.rootFolder,
                nodes: nodes,
                watchedDirectories: [snapshot.rootFolder] + WorkspaceTreeBuilder.collectDirectories(from: nodes)
            )
        }.value
    }

    @MainActor
    static func applyWatch(
        _ snapshot: WorkspaceSnapshot,
        using watcher: FolderWatcher,
        onChange: @escaping (Set<URL>) -> Void
    ) {
        watcher.watch(directories: snapshot.watchedDirectories, onChange: onChange)
    }
}
