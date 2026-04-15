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
    private let newWindow: @Sendable (URL?) async -> MCPWindowInfo?
    private let setActiveWindow: @Sendable (String) async -> MCPWindowInfo?
    private let closeWindow: @Sendable (String) async -> Bool

    init(
        listWindows: @escaping @Sendable () async -> [MCPWindowInfo],
        getWindow: @escaping @Sendable (String) async -> MCPWindowInfo?,
        openFolder: @escaping @Sendable (URL, String?) async -> MCPWindowInfo?,
        openFile: @escaping @Sendable (URL, String?) async -> MCPWindowInfo?,
        newWindow: @escaping @Sendable (URL?) async -> MCPWindowInfo?,
        setActiveWindow: @escaping @Sendable (String) async -> MCPWindowInfo?,
        closeWindow: @escaping @Sendable (String) async -> Bool
    ) {
        self.listWindows = listWindows
        self.getWindow = getWindow
        self.openFolder = openFolder
        self.openFile = openFile
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
}
