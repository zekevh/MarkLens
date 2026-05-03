import Foundation
import Network
import MCP

// MARK: - Notification

extension Foundation.Notification.Name {
    static let marklensOpenNewWindow = Foundation.Notification.Name("marklens.openNewWindow")
}

struct MCPWindowInfo: Codable, Sendable {
    let id: String
    let title: String
    let rootFolderPath: String?
    let filePath: String?
    let isActive: Bool
}

nonisolated private func encodeWindowPayload(_ windows: [MCPWindowInfo]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(windows),
          let text = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return text
}

// MARK: - MCPServer

/// Embedded MCP server exposing MarkLens controls to AI agents via
/// Streamable HTTP transport on localhost:7474.
///
/// Add to Claude Desktop's config (~/Library/Application Support/Claude/claude_desktop_config.json):
///   { "mcpServers": { "marklens": { "url": "http://localhost:7474/mcp" } } }
actor MCPServer {
    static let port: UInt16 = 7474

    private var listener: NWListener?
    private let transport = StatefulHTTPServerTransport()
    private let server: Server

    private let listWindows: @Sendable () async -> [MCPWindowInfo]
    private let getWindow: @Sendable (String) async -> MCPWindowInfo?
    private let openFolder: @Sendable (URL, String?) async -> MCPWindowInfo?
    private let openFile: @Sendable (URL, String?) async -> MCPWindowInfo?
    private let moveFile: @Sendable (URL, URL, String?) async -> String?
    private let newWindow: @Sendable (URL?) async -> MCPWindowInfo?
    private let setActiveWindow: @Sendable (String) async -> MCPWindowInfo?
    private let closeWindow: @Sendable (String) async -> Bool

    init(
        listWindows: @escaping @Sendable () async -> [MCPWindowInfo],
        getWindow: @escaping @Sendable (String) async -> MCPWindowInfo?,
        openFolder: @escaping @Sendable (URL, String?) async -> MCPWindowInfo?,
        openFile: @escaping @Sendable (URL, String?) async -> MCPWindowInfo?,
        moveFile: @escaping @Sendable (URL, URL, String?) async -> String?,
        newWindow: @escaping @Sendable (URL?) async -> MCPWindowInfo?,
        setActiveWindow: @escaping @Sendable (String) async -> MCPWindowInfo?,
        closeWindow: @escaping @Sendable (String) async -> Bool
    ) {
        self.listWindows = listWindows
        self.getWindow = getWindow
        self.openFolder = openFolder
        self.openFile = openFile
        self.moveFile = moveFile
        self.newWindow = newWindow
        self.setActiveWindow = setActiveWindow
        self.closeWindow = closeWindow
        self.server = Server(
            name: "MarkLens",
            version: "1.0.0",
            instructions: """
                Controls the MarkLens markdown editor. \
                Use list_windows to inspect available editor windows, \
                get_window to inspect one specific editor window in detail, \
                open_folder to load a repo or folder in the active window or a specific window_id, \
                open_file to load a file in the active window or a specific window_id, \
                new_window to spawn an additional editor window, \
                set_active_window to focus a specific editor window, \
                and close_window to close a specific editor window.
                """,
            capabilities: Server.Capabilities(tools: .init(listChanged: false))
        )
    }

    // MARK: - Startup

    func start() async throws {
        await registerHandlers()
        // Run MCP protocol processing in the background (runs until transport closes)
        Task { [server, transport] in
            try await server.start(transport: transport)
        }
        try startListener()
    }

    // MARK: - Tool Handlers

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPServer.toolDefinitions)
        }

        let listWindows = listWindows
        let getWindow = getWindow
        let openFolder = openFolder
        let openFile = openFile
        let moveFile = moveFile
        let newWindow = newWindow
        let setActiveWindow = setActiveWindow
        let closeWindow = closeWindow

        await server.withMethodHandler(CallTool.self) { params in
            switch params.name {
            case "list_windows":
                return CallTool.Result(
                    content: [.text(text: encodeWindowPayload(await listWindows()), annotations: nil, _meta: nil)]
                )

            case "get_window":
                guard let windowID = params.arguments?["window_id"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: window_id", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                guard let window = await getWindow(windowID) else {
                    return CallTool.Result(
                        content: [.text(text: "Window not found: \(windowID)", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                return CallTool.Result(
                    content: [.text(text: encodeWindowPayload([window]), annotations: nil, _meta: nil)]
                )

            case "open_folder":
                guard let path = params.arguments?["path"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    return CallTool.Result(
                        content: [.text(text: "Folder not found: \(path)", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                let windowID = params.arguments?["window_id"]?.stringValue
                guard let window = await openFolder(url, windowID) else {
                    let message = windowID.map { "Window not found: \($0)" } ?? "No active MarkLens window is available"
                    return CallTool.Result(
                        content: [.text(text: message, annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                return CallTool.Result(
                    content: [.text(
                        text: "Opened folder \(url.lastPathComponent) in window \(window.id)\n\(encodeWindowPayload([window]))",
                        annotations: nil,
                        _meta: nil
                    )]
                )

            case "open_file":
                guard let path = params.arguments?["path"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return CallTool.Result(
                        content: [.text(text: "File not found: \(path)", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                let windowID = params.arguments?["window_id"]?.stringValue
                guard let window = await openFile(url, windowID) else {
                    let message = windowID.map { "Window not found: \($0)" } ?? "No active MarkLens window is available"
                    return CallTool.Result(
                        content: [.text(text: message, annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                return CallTool.Result(
                    content: [.text(
                        text: "Opened \(url.lastPathComponent) in window \(window.id)\n\(encodeWindowPayload([window]))",
                        annotations: nil,
                        _meta: nil
                    )]
                )

            case "move_file":
                guard let fromPath = params.arguments?["from_path"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: from_path", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                guard let toPath = params.arguments?["to_path"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: to_path", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

                do {
                    let requestedWindowID = params.arguments?["window_id"]?.stringValue
                    let fromBaseURL = try await self.resolveBaseURL(for: fromPath, requestedWindowID: requestedWindowID)
                    let toBaseURL = try await self.resolveBaseURL(for: toPath, requestedWindowID: requestedWindowID)
                    let sourceURL = try MCPServer.resolveConcreteFilePath(fromPath, relativeTo: fromBaseURL)
                    let destinationURL = try MCPServer.resolveConcreteFilePath(toPath, relativeTo: toBaseURL)

                    if let errorMessage = await moveFile(sourceURL, destinationURL, requestedWindowID) {
                        return CallTool.Result(
                            content: [.text(text: errorMessage, annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }

                    let payload: [String: Value] = [
                        "from_path": .string(sourceURL.path),
                        "to_path": .string(destinationURL.path)
                    ]
                    return CallTool.Result(
                        content: [.text(text: "Moved \(sourceURL.lastPathComponent) to \(destinationURL.path)", annotations: nil, _meta: nil)],
                        structuredContent: .object(payload),
                        isError: false
                    )
                } catch {
                    return CallTool.Result(
                        content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

            case "read_frontmatter":
                guard let path = params.arguments?["path"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

                let requestedWindowID = params.arguments?["window_id"]?.stringValue
                let baseURL: URL?
                if path.hasPrefix("/") {
                    baseURL = nil
                } else if let requestedWindowID {
                    guard let window = await getWindow(requestedWindowID) else {
                        return CallTool.Result(
                            content: [.text(text: "Window not found: \(requestedWindowID)", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                    baseURL = MCPServer.baseURL(for: window)
                } else {
                    let activeWindow = await listWindows().first(where: \.isActive)
                    baseURL = activeWindow.flatMap(MCPServer.baseURL(for:))
                }

                do {
                    let matches = try FrontmatterReader.readFrontmatter(at: path, relativeTo: baseURL)
                    let summary: String
                    let isGlobPath = path.contains("*") || path.contains("?") || path.contains("[")
                    if matches.count == 1, let match = matches.first, !isGlobPath {
                        summary = match.frontmatter == nil
                            ? "No frontmatter found in \(path)"
                            : "Read frontmatter from \(path)"
                    } else {
                        summary = "Read frontmatter from \(matches.count) file(s)"
                    }
                    return try CallTool.Result(
                        content: [.text(text: summary, annotations: nil, _meta: nil)],
                        structuredContent: matches,
                        isError: false
                    )
                } catch {
                    return CallTool.Result(
                        content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

            case "get_links":
                guard let path = params.arguments?["path"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

                do {
                    let baseURL = try await self.resolveBaseURL(for: path, requestedWindowID: params.arguments?["window_id"]?.stringValue)
                    let fileURLs = try MCPServer.resolveMarkdownTargets(from: path, relativeTo: baseURL)
                    let workspaceURL = MCPServer.workspaceRoot(for: fileURLs, fallback: baseURL)
                    let links = WorkspaceLinkInspector.links(inWorkspace: workspaceURL, matching: fileURLs)
                    return try CallTool.Result(
                        content: [.text(text: "Read links from \(links.count) file(s)", annotations: nil, _meta: nil)],
                        structuredContent: links,
                        isError: false
                    )
                } catch {
                    return CallTool.Result(
                        content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

            case "get_backlinks":
                guard let path = params.arguments?["path"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

                do {
                    let workspaceURL = try await self.resolveWorkspaceURL(
                        workspacePath: params.arguments?["workspace_path"]?.stringValue,
                        requestedWindowID: params.arguments?["window_id"]?.stringValue
                    )
                    let baseURL = try await self.resolveBaseURL(for: path, requestedWindowID: params.arguments?["window_id"]?.stringValue)
                    let targetURL = try MCPServer.resolveConcreteFilePath(path, relativeTo: baseURL ?? workspaceURL)
                    let backlinks = WorkspaceLinkInspector.backlinks(to: targetURL, inWorkspace: workspaceURL)
                    return try CallTool.Result(
                        content: [.text(text: "Read \(backlinks.count) backlink(s) for \(targetURL.lastPathComponent)", annotations: nil, _meta: nil)],
                        structuredContent: backlinks,
                        isError: false
                    )
                } catch {
                    return CallTool.Result(
                        content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

            case "check_link_health":
                do {
                    let requestedPath = params.arguments?["path"]?.stringValue
                    let requestedWindowID = params.arguments?["window_id"]?.stringValue
                    let baseURL: URL?
                    if let requestedPath {
                        baseURL = try await self.resolveBaseURL(for: requestedPath, requestedWindowID: requestedWindowID)
                    } else {
                        baseURL = nil
                    }
                    let workspaceURL = try await self.resolveWorkspaceURL(
                        workspacePath: params.arguments?["workspace_path"]?.stringValue,
                        requestedWindowID: requestedWindowID,
                        fallbackBaseURL: baseURL ?? nil
                    )
                    let targetURLs = try requestedPath.map { try MCPServer.resolveMarkdownTargets(from: $0, relativeTo: baseURL ?? workspaceURL) }
                    let report = WorkspaceLinkInspector.health(inWorkspace: workspaceURL, matching: targetURLs)
                    return try CallTool.Result(
                        content: [.text(text: "Found broken links in \(report.count) file(s)", annotations: nil, _meta: nil)],
                        structuredContent: report,
                        isError: false
                    )
                } catch {
                    return CallTool.Result(
                        content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

            case "rewrite_links":
                guard let moveValues = params.arguments?["moves"]?.arrayValue, !moveValues.isEmpty else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: moves", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

                do {
                    let workspaceURL = try await self.resolveWorkspaceURL(
                        workspacePath: params.arguments?["workspace_path"]?.stringValue,
                        requestedWindowID: params.arguments?["window_id"]?.stringValue
                    )
                    let movedURLsBySource = try Dictionary(uniqueKeysWithValues: moveValues.map { moveValue in
                        guard let move = moveValue.objectValue,
                              let from = move["from"]?.stringValue,
                              let to = move["to"]?.stringValue else {
                            throw FrontmatterReaderError.invalidFrontmatter("Each move must include string fields 'from' and 'to'.")
                        }
                        let fromURL = try MCPServer.resolveConcreteFilePath(from, relativeTo: workspaceURL)
                        let toURL = try MCPServer.resolveConcreteFilePath(to, relativeTo: workspaceURL)
                        return (fromURL, toURL)
                    })
                    let result = WorkspaceLinkRewriter.rewriteLinks(
                        inWorkspace: workspaceURL,
                        movedURLsBySource: movedURLsBySource
                    )
                    let payload: [String: Value] = [
                        "changed_files": .array(result.changedFiles.map { .string($0.path) }),
                        "errors": .array(result.errors.map { .string($0) })
                    ]
                    return CallTool.Result(
                        content: [.text(text: "Rewrote links in \(result.changedFiles.count) file(s)", annotations: nil, _meta: nil)],
                        structuredContent: .object(payload),
                        isError: false
                    )
                } catch {
                    return CallTool.Result(
                        content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

            case "new_window":
                let path = params.arguments?["path"]?.stringValue
                let url = path.map { URL(fileURLWithPath: $0) }
                if let url, !FileManager.default.fileExists(atPath: url.path) {
                    return CallTool.Result(
                        content: [.text(text: "File not found: \(url.path)", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                guard let window = await newWindow(url) else {
                    return CallTool.Result(
                        content: [.text(text: "Failed to create a new MarkLens window", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                let msg = url.map { "Opened new window \(window.id) with \($0.lastPathComponent)" } ?? "Opened new window \(window.id)"
                return CallTool.Result(
                    content: [.text(text: "\(msg)\n\(encodeWindowPayload([window]))", annotations: nil, _meta: nil)]
                )

            case "set_active_window":
                guard let windowID = params.arguments?["window_id"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: window_id", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                guard let window = await setActiveWindow(windowID) else {
                    return CallTool.Result(
                        content: [.text(text: "Window not found: \(windowID)", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                return CallTool.Result(
                    content: [.text(text: "Activated window \(window.id)\n\(encodeWindowPayload([window]))", annotations: nil, _meta: nil)]
                )

            case "close_window":
                guard let windowID = params.arguments?["window_id"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: window_id", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                guard await closeWindow(windowID) else {
                    return CallTool.Result(
                        content: [.text(text: "Window not found: \(windowID)", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                return CallTool.Result(
                    content: [.text(text: "Closed window \(windowID)", annotations: nil, _meta: nil)]
                )

            default:
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            }
        }
    }

    private static let toolDefinitions: [Tool] = [
        Tool(
            name: "read_frontmatter",
            description: "Read YAML frontmatter from one markdown file or every markdown file matching a glob pattern, returning parsed structured data only",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path, relative path, or glob pattern such as *.md")
                    ]),
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional editor window ID used to resolve relative paths")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            ),
            outputSchema: .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string")
                        ]),
                        "frontmatter": .object([
                            "type": .array([.string("object"), .string("null")]),
                            "additionalProperties": .bool(true)
                        ])
                    ]),
                    "required": .array([.string("path"), .string("frontmatter")]),
                    "additionalProperties": .bool(false)
                ])
            ])
        ),
        Tool(
            name: "open_file",
            description: "Open a markdown file in the active MarkLens window or a specific window_id",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the markdown file")
                    ]),
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional editor window ID returned by list_windows")
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        ),
        Tool(
            name: "get_links",
            description: "Read outgoing inline markdown links from one markdown file or files matching a glob pattern",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path, relative path, or glob pattern such as docs/*.md")
                    ]),
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional editor window ID used to resolve relative paths")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "get_backlinks",
            description: "Read backlinks for one markdown file by scanning markdown links in the workspace",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path or relative path to the target markdown file")
                    ]),
                    "workspace_path": .object([
                        "type": .string("string"),
                        "description": .string("Optional workspace root folder path. Defaults to the requested window or active workspace")
                    ]),
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional editor window ID used to resolve relative paths and infer workspace root")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "check_link_health",
            description: "Report broken inline markdown links for one file, a glob pattern, or an entire workspace",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Optional absolute path, relative path, or glob pattern to limit the health check")
                    ]),
                    "workspace_path": .object([
                        "type": .string("string"),
                        "description": .string("Optional workspace root folder path. Required when no active workspace can be inferred")
                    ]),
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional editor window ID used to resolve relative paths and infer workspace root")
                    ])
                ])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "rewrite_links",
            description: "Rewrite workspace markdown links after files were moved or renamed outside MarkLens",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "moves": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "from": .object([
                                    "type": .string("string")
                                ]),
                                "to": .object([
                                    "type": .string("string")
                                ])
                            ]),
                            "required": .array([.string("from"), .string("to")]),
                            "additionalProperties": .bool(false)
                        ])
                    ]),
                    "workspace_path": .object([
                        "type": .string("string"),
                        "description": .string("Optional workspace root folder path. Defaults to the requested window or active workspace")
                    ]),
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional editor window ID used to infer workspace root")
                    ])
                ]),
                "required": .array([.string("moves")])
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "open_folder",
            description: "Open a folder or repo in the active MarkLens window or a specific window_id",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the folder or repo")
                    ]),
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional editor window ID returned by list_windows")
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        ),
        Tool(
            name: "move_file",
            description: "Move or rename one markdown file through MarkLens, updating workspace links to match",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "from_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path or relative path to the existing markdown file")
                    ]),
                    "to_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path or relative path for the destination file path")
                    ]),
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional editor window ID used to resolve relative paths")
                    ])
                ]),
                "required": .array([.string("from_path"), .string("to_path")])
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: "new_window",
            description: "Open a new MarkLens window, optionally pre-loaded with a file",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the markdown file to open (optional)")
                    ])
                ])
            ])
        ),
        Tool(
            name: "list_windows",
            description: "List all editor windows with their MCP IDs, open repo/folder, and current markdown file",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ),
        Tool(
            name: "get_window",
            description: "Get one editor window by MCP window ID, including its open repo/folder and current markdown file",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Editor window ID returned by list_windows")
                    ])
                ]),
                "required": .array([.string("window_id")])
            ])
        ),
        Tool(
            name: "set_active_window",
            description: "Focus a specific editor window so it becomes the active MarkLens window",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Editor window ID returned by list_windows")
                    ])
                ]),
                "required": .array([.string("window_id")])
            ])
        ),
        Tool(
            name: "close_window",
            description: "Close a specific editor window",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_id": .object([
                        "type": .string("string"),
                        "description": .string("Editor window ID returned by list_windows")
                    ])
                ]),
                "required": .array([.string("window_id")])
            ])
        )
    ]

    // MARK: - HTTP Listener (Network.framework)

    private func startListener() throws {
        let tcpParams = NWParameters.tcp
        tcpParams.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else { return }
        let l = try NWListener(using: tcpParams, on: nwPort)
        listener = l

        l.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                print("[MCPServer] Listener error: \(err)")
            }
        }

        l.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }

        l.start(queue: .main)
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .main)

        guard let request = await readRequest(from: connection) else {
            connection.cancel()
            return
        }

        let response = await transport.handleRequest(request)

        switch response {
        case .stream(let sseStream, let headers):
            // Keep connection alive and stream SSE chunks
            await writeHead(statusCode: 200, headers: headers, to: connection)
            do {
                for try await chunk in sseStream {
                    guard await write(chunk, to: connection) else { break }
                }
            } catch {}

        default:
            let body = response.bodyData ?? Data()
            var headers = response.headers
            headers["Content-Length"] = "\(body.count)"
            await writeHead(statusCode: response.statusCode, headers: headers, to: connection)
            _ = await write(body, to: connection)
        }

        connection.cancel()
    }

    // MARK: - HTTP Parsing

    private func readRequest(from connection: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)

        while true {
            guard let chunk = await receive(from: connection) else { return nil }
            buffer.append(chunk)
            guard let sepRange = buffer.range(of: separator) else { continue }

            // Parse request line and headers
            let headerData = buffer[..<sepRange.lowerBound]
            guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            let method = parts[0], path = parts[1]

            var headers: [String: String] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }

            // Read body
            let contentLength = Int(headers["Content-Length"] ?? headers["content-length"] ?? "") ?? 0
            var body = Data(buffer[sepRange.upperBound...])
            while body.count < contentLength {
                guard let more = await receive(from: connection) else { return nil }
                body.append(more)
            }

            return HTTPRequest(
                method: method,
                headers: headers,
                body: contentLength > 0 ? Data(body.prefix(contentLength)) : nil,
                path: path
            )
        }
    }

    private func receive(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                cont.resume(returning: data.flatMap { $0.isEmpty ? nil : Optional($0) })
            }
        }
    }

    private func writeHead(statusCode: Int, headers: [String: String], to connection: NWConnection) async {
        let phrase: String
        switch statusCode {
        case 200: phrase = "OK"
        case 202: phrase = "Accepted"
        case 400: phrase = "Bad Request"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        default:  phrase = "Error"
        }
        var head = "HTTP/1.1 \(statusCode) \(phrase)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        _ = await write(Data(head.utf8), to: connection)
    }

    @discardableResult
    private func write(_ data: Data, to connection: NWConnection) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { err in
                cont.resume(returning: err == nil)
            })
        }
    }

    private func resolveBaseURL(for path: String, requestedWindowID: String?) async throws -> URL? {
        if path.hasPrefix("/") {
            return nil
        }
        if let requestedWindowID {
            guard let window = await getWindow(requestedWindowID) else {
                throw MCPError.invalidParams("Window not found: \(requestedWindowID)")
            }
            return MCPServer.baseURL(for: window)
        }
        let activeWindow = await listWindows().first(where: \.isActive)
        return activeWindow.flatMap(MCPServer.baseURL(for:))
    }

    private func resolveWorkspaceURL(
        workspacePath: String?,
        requestedWindowID: String?,
        fallbackBaseURL: URL? = nil
    ) async throws -> URL {
        if let workspacePath {
            let url = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FrontmatterReaderError.fileNotFound(url.path)
            }
            return url
        }
        if let requestedWindowID {
            guard let window = await getWindow(requestedWindowID) else {
                throw MCPError.invalidParams("Window not found: \(requestedWindowID)")
            }
            if let rootFolderPath = window.rootFolderPath {
                return URL(fileURLWithPath: rootFolderPath, isDirectory: true).standardizedFileURL
            }
            if let baseURL = MCPServer.baseURL(for: window) {
                return baseURL.standardizedFileURL
            }
        }
        if let activeWindow = await listWindows().first(where: \.isActive) {
            if let rootFolderPath = activeWindow.rootFolderPath {
                return URL(fileURLWithPath: rootFolderPath, isDirectory: true).standardizedFileURL
            }
            if let baseURL = MCPServer.baseURL(for: activeWindow) {
                return baseURL.standardizedFileURL
            }
        }
        if let fallbackBaseURL {
            return fallbackBaseURL.standardizedFileURL
        }
        throw FrontmatterReaderError.relativePathRequiresBase
    }

    private static func baseURL(for window: MCPWindowInfo) -> URL? {
        if let rootFolderPath = window.rootFolderPath {
            return URL(fileURLWithPath: rootFolderPath, isDirectory: true)
        }
        if let filePath = window.filePath {
            return URL(fileURLWithPath: filePath).deletingLastPathComponent()
        }
        return nil
    }

    private static func resolveMarkdownTargets(from inputPath: String, relativeTo baseURL: URL?) throws -> [URL] {
        if inputPath.contains("*") || inputPath.contains("?") || inputPath.contains("[") {
            return try FrontmatterReader.resolveGlobPathForMCP(inputPath, relativeTo: baseURL)
        }
        return [try resolveConcreteFilePath(inputPath, relativeTo: baseURL)]
    }

    private static func resolveConcreteFilePath(_ inputPath: String, relativeTo baseURL: URL?) throws -> URL {
        if inputPath.hasPrefix("/") {
            return URL(fileURLWithPath: inputPath).standardizedFileURL
        }
        guard let baseURL else {
            throw FrontmatterReaderError.relativePathRequiresBase
        }
        return baseURL.appendingPathComponent(inputPath).standardizedFileURL
    }

    private static func workspaceRoot(for fileURLs: [URL], fallback: URL?) -> URL {
        if let fallback {
            return fallback.standardizedFileURL
        }
        return fileURLs.first?.deletingLastPathComponent().standardizedFileURL ?? URL(fileURLWithPath: "/")
    }
}
