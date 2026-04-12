import Foundation

// MARK: - FileWatcher
// Uses kqueue (O_EVTONLY) to detect writes, renames, and atomic replacements
// (git checkout, most editors) without participating in file-system locking.

@MainActor
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var watchedURL: URL?
    private var handler: (() -> Void)?

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        watchedURL = url
        handler = onChange
        start(at: url)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func start(at url: URL) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd != -1 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = src.data
            if events.contains(.rename) || events.contains(.delete) {
                // Atomic replacement (git, most editors write to a temp file then rename).
                // Re-arm after a short delay so the new inode is in place.
                self.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, let url = self.watchedURL else { return }
                    self.start(at: url)
                    self.handler?()
                }
            } else {
                self.handler?()
            }
        }

        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}

// MARK: - FolderWatcher
// Watches a set of directories with kqueue and fires a debounced callback when
// any of them changes (file created, deleted, or renamed inside them).

@MainActor
final class FolderWatcher {
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var debounceWork: DispatchWorkItem?
    private var handler: (() -> Void)?

    func watch(directories: [URL], onChange: @escaping () -> Void) {
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
            src.setEventHandler { [weak self] in self?.schedule() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources[url] = src
        }
    }

    func stopAll() {
        debounceWork?.cancel()
        debounceWork = nil
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
        handler = nil
    }

    private func schedule() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handler?() }
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

// MARK: - WorkspaceTreeBuilder

enum WorkspaceTreeBuilder {
    nonisolated static func buildTree(
        at url: URL,
        pinnedURLs: Set<String>,
        parentFilters: [GitignoreFilter] = []
    ) -> [FileNode] {
        let fm = FileManager.default
        var filters = parentFilters
        if fm.fileExists(atPath: url.appendingPathComponent(".gitignore").path) {
            filters.append(GitignoreFilter(at: url))
        }
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { child -> FileNode? in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if filters.contains(where: { $0.isIgnored(child, isDirectory: isDir) }) { return nil }
            if isDir {
                let children = buildTree(at: child, pinnedURLs: pinnedURLs, parentFilters: filters)
                guard !children.isEmpty else { return nil }
                return FileNode(
                    url: child,
                    name: child.lastPathComponent,
                    isDirectory: true,
                    children: children
                )
            }

            let ext = child.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { return nil }
            return FileNode(url: child, name: child.lastPathComponent, isDirectory: false)
        }
        .sorted { lhs, rhs in
            let lhsPinned = pinnedURLs.contains(lhs.url.absoluteString)
            let rhsPinned = pinnedURLs.contains(rhs.url.absoluteString)
            if lhsPinned != rhsPinned { return lhsPinned }
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated static func collectDirectories(from nodes: [FileNode]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            guard node.isDirectory else { return [] }
            return [node.url] + collectDirectories(from: node.children ?? [])
        }
    }
}

struct WorkspaceSnapshot {
    let rootFolder: URL
    let nodes: [FileNode]
    let watchedDirectories: [URL]
}

enum WorkspaceRefreshService {
    static func buildSnapshot(at folder: URL, pinnedURLs: Set<String>) async -> WorkspaceSnapshot {
        await Task.detached(priority: .utility) {
            let nodes = WorkspaceTreeBuilder.buildTree(at: folder, pinnedURLs: pinnedURLs)
            let watchedDirectories = [folder] + WorkspaceTreeBuilder.collectDirectories(from: nodes)
            return WorkspaceSnapshot(
                rootFolder: folder,
                nodes: nodes,
                watchedDirectories: watchedDirectories
            )
        }.value
    }

    @MainActor
    static func applyWatch(
        _ snapshot: WorkspaceSnapshot,
        using watcher: FolderWatcher,
        onChange: @escaping () -> Void
    ) {
        watcher.watch(directories: snapshot.watchedDirectories, onChange: onChange)
    }
}
