import AppKit
import Combine
import Darwin
import Foundation
import ProseCore
import Security

/// The MCP helper's lifecycle and credentials.
@MainActor
final class MCPConnection: ObservableObject {
    private struct Configuration: Codable {
        let token: String
        let grantID: UUID
        let documentIDs: Set<UUID>?
        let canWrite: Bool
        var access: AgentToolAccess {
            AgentToolAccess(documentIDs: documentIDs, canWrite: canWrite, id: grantID)
        }
    }

    private weak var workspace: Workspace?
    private let directory: URL
    private let helperURL: URL?
    private var process: Process?
    private var pipe: MCPLinePipe?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var generation = UUID()
    private var calls: [Int: Task<Void, Never>] = [:]
    private var startup: CheckedContinuation<Void, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var dispatcher: AgentToolDispatcher?
    private var configuration: Configuration?
    private var port = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = false
    @Published private(set) var failureMessage: String?
    @Published private(set) var portInUse = false
    var allowsEditing: Bool {
        configuration?.canWrite ?? false
    }

    var grantedDocumentIDs: Set<UUID>? {
        configuration?.documentIDs
    }

    var descriptorURL: URL {
        directory.appendingPathComponent("connection.json")
    }

    init(workspace: Workspace, helperURL: URL? = nil) {
        self.workspace = workspace
        directory = workspace.stateDirectory.appendingPathComponent("MCP")
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/prose-mcp")
    }

    func resume() async {
        let file = directory.appendingPathComponent("access.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return
        }
        isEnabled = true
        do {
            let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
            try await start(value)
        } catch where !portInUse {
            failureMessage = L10n.text("Could not start the coding agent connection. Enable it again in Settings.")
        } catch {}
    }

    /// Keeps the saved permission and token but lets the helper pick a free port.
    func useNewPort() async throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("port.json"))
        let file = directory.appendingPathComponent("access.json")
        if let value = try? JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file)) {
            try await start(value)
        } else {
            try await enable()
        }
    }

    static func canListen(on port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            return true
        }
        defer { close(socket) }
        // Match the helper's listener, which reuses addresses left in TIME_WAIT.
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func enable(documentIDs: Set<UUID>? = nil, canWrite: Bool = true) async throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else {
            throw ServiceError.unavailable
        }
        let value = Configuration(
            token: bytes.map { String(format: "%02x", $0) }.joined(),
            grantID: UUID(),
            documentIDs: documentIDs,
            canWrite: canWrite,
        )
        try await start(value)
        do {
            try writePrivate(JSONEncoder().encode(value), name: "access.json")
            isEnabled = true
        } catch { stop()
            throw error
        }
    }

    private func start(_ value: Configuration) async throws {
        stop()
        guard let workspace, let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw AgentToolError("helper_unavailable", "The MCP helper is missing. Build or reinstall the macOS app.")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        guard try (directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
        else {
            throw ServiceError.unavailable
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        port = (try? JSONDecoder().decode(
            Int.self,
            from: Data(contentsOf: directory.appendingPathComponent("port.json")),
        )) ?? 0
        guard (0 ... 65535).contains(port) else {
            throw ServiceError.unavailable
        }
        // Agents are configured with this port, so explain a conflict instead of silently moving.
        guard port == 0 || Self.canListen(on: port) else {
            portInUse = true
            let message = L10n.format(
                "Port %@ is used by another app. Quit that app, or use a new port and give your coding agent the setup prompt again.",
                // A port is an identifier, so never group its digits.
                String(port),
            )
            failureMessage = message
            throw AgentToolError("port_in_use", message)
        }
        portInUse = false
        configuration = value
        dispatcher = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = helperURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let session = generation
        let connection = try MCPLinePipe(input: input.fileHandleForWriting) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, generation == session else {
                    return
                }
                switch result {
                case let .success(message): receive(message)
                case .failure: fail()
                }
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                connection.disconnected()
            } else {
                connection.receive(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == session else {
                    return
                }
                fail()
            }
        }
        self.process = process
        pipe = connection
        self.output = output.fileHandleForReading
        errorOutput = errors.fileHandleForReading
        do {
            try process.run()
            try input.fileHandleForReading.close()
            try input.fileHandleForWriting.close()
            try output.fileHandleForWriting.close()
            try errors.fileHandleForWriting.close()
            try connection.send(.object(["bridge_version": .number(2), "port": .number(Double(port)),
                                         "token": .string(value.token),
                                         "instructions": .string(AgentTools.instructions),
                                         "resources": .array(AuthoringGuides.resources()),
                                         "prompts": .array(AuthoringGuides.prompts()),
                                         "tools": .array(
                                             AgentTools.definitions.filter { value.canWrite || $0.readOnly }
                                                 .map { tool in .object([
                                                     "name": .string(tool.name),
                                                     "description": .string(tool.description),
                                                     "inputSchema": tool.inputSchema,
                                                     "outputSchema": .object(["type": .string("object")]),
                                                     "annotations": .object([
                                                         "readOnlyHint": .bool(tool.readOnly),
                                                         "destructiveHint": .bool(tool.destructive),
                                                         "openWorldHint": .bool(false),
                                                     ]),
                                                 ]) },
                                         )]))
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                startupTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, generation == session else {
                        return
                    }
                    fail()
                }
            }
        } catch { stop()
            throw error
        }
    }

    private func receive(_ message: JSONValue) {
        guard let configuration else {
            return
        }
        if message["event"].string == "ready" {
            guard !isRunning, message["bridge_version"].int == 2, let assigned = message["port"].int,
                  (1 ... 65535).contains(assigned), port == 0 || assigned == port
            else {
                fail()
                return
            }
            port = assigned
            do {
                try writePrivate(JSONEncoder().encode(port), name: "port.json")
                let descriptor: JSONValue = .object(["format_version": .number(1), "server_name": .string(serverName),
                                                     "app_bundle_id": .string(AppDistribution.current.bundleIdentifier),
                                                     "app_version": .string(Bundle.main
                                                         .object(
                                                             forInfoDictionaryKey: "CFBundleShortVersionString",
                                                         ) as? String ??
                                                         "development"),
                                                     "instance_id": .string(generation.uuidString),
                                                     "transport": .string("streamable-http"),
                                                     "url": .string("http://127.0.0.1:\(port)/mcp"),
                                                     "authentication": .object([
                                                         "type": .string("bearer"),
                                                         "token": .string(configuration.token),
                                                     ])])
                try writePrivate(JSONEncoder().encode(descriptor), name: "connection.json")
                isRunning = true
                failureMessage = nil
                startupTimeout?.cancel()
                startupTimeout = nil
                startup?.resume()
                startup = nil
            } catch { fail() }
            return
        }
        if let id = message["cancel"].int {
            calls[id]?.cancel()
            return
        }
        guard isRunning, let id = message["id"].int, let method = message["method"].string, let dispatcher,
              calls[id] == nil, calls.count < 32
        else {
            fail()
            return
        }
        let session = generation
        calls[id] = Task { [weak self] in
            let result: AgentToolResult
            do {
                switch method {
                case "resources/read":
                    result = try AgentToolResult(AuthoringGuides.readResource(
                        uri: message["arguments"]["uri"].string ?? "",
                    ))
                case "prompts/get":
                    result = try AgentToolResult(AuthoringGuides.getPrompt(
                        name: message["arguments"]["name"].string ?? "",
                        arguments: message["arguments"]["arguments"],
                    ))
                default:
                    result = await dispatcher.call(
                        method,
                        arguments: message["arguments"],
                        access: configuration.access,
                    )
                }
            } catch let error as AgentToolError {
                result = AgentToolResult(.object(["error": error.json]), isError: true)
            } catch {
                result = AgentToolResult(.object(["error": AgentToolError(
                    "unavailable", "The bundled authoring content could not be read.",
                ).json]), isError: true)
            }
            guard let self, generation == session else {
                return
            }
            calls[id] = nil
            var value = result.value
            if method == "get_app_state", !result.isError, case var .object(state) = value {
                state["instance_id"] = .string(session.uuidString)
                state["mcp"] = .object(["transport": .string("streamable-http"), "connected": .bool(true)])
                value = .object(state)
            }
            let images: [JSONValue] = result.images.map { image in .object([
                "data": .string(image.data.base64EncodedString()),
                "mime_type": .string(image.mimeType),
            ]) }
            do { try pipe?.send(.object([
                "id": .number(Double(id)),
                "result": .object(["value": value, "is_error": .bool(result.isError), "images": .array(images)]),
            ])) } catch { fail() }
        }
    }

    private var serverName: String {
        AppDistribution.current == .preview ? "prose-preview" : "prose"
    }

    func setupPrompt() throws -> String {
        guard isRunning else {
            throw AgentToolError("unavailable", "Enable the coding agent connection first.")
        }
        return """
        Set up the Prose MCP service on this Mac in the coding agent client you are using now.
        The app ships the service, so do not download a server or install Rust, Cargo, Node or Python. Keep the app running.
        Connection file: \(descriptorURL.path)
        Expected app identifier: \(AppDistribution.current.bundleIdentifier)
        Expected service name: \(serverName)
        1. Make sure you run on the same Mac, and find where the current client keeps its configuration.
        2. Read the JSON with a local program. Check format_version=1, the app identifier, the name, and that the URL host is 127.0.0.1. The file holds a credential: do not print the whole file, the token or a command that contains the credential, and do not write it to a repository or the chat.
        3. Follow the installed client's official documentation to add a Streamable HTTP service in the user's private scope, with the credential sent as Authorization Bearer. Keep other configuration. Report a conflict if a connection with the same name belongs to a different app. Do not change global approval or trust settings. Make sure the client can still get the credential after it restarts.
        4. Reload the service, list its tools, and call get_app_state read-only to check the app and instance_id. Do not read document text or change a document to test the setup. If you cannot reload in this session, report that the configuration is written but not verified, and give the steps to reconnect.
        5. Report the configuration location, the service name and the result in a few lines, without the credential. Stop if the file is missing, the identity does not match, authentication fails or you are redirected, and ask me to enable the connection again in the app. Do not search for credentials or reach the library other than through MCP.
        When connected, follow the server instructions for writing: use create_document for a single file and import_project with a full manifest for several files and resources; for continued edits use str_replace or a batched apply_patch. Use paths exactly as get_document.entry and list_files return them. On an error, follow error.recovery to read the state and repair it; do not replay write requests blindly.
        Official references: https://developers.openai.com/codex/mcp and https://code.claude.com/docs/en/mcp
        """
    }

    func disable() {
        stop()
        let savedAccess = directory.appendingPathComponent("access.json")
        try? FileManager.default.removeItem(at: savedAccess)
        isEnabled = FileManager.default.fileExists(atPath: savedAccess.path)
        if isEnabled {
            failureMessage = L10n
                .text("The connection stopped, but its saved permission could not be removed. Try disconnecting again.")
        }
    }

    func stop() {
        generation = UUID()
        isRunning = false
        startupTimeout?.cancel()
        startupTimeout = nil
        startup?.resume(throwing: ServiceError.disconnected)
        startup = nil
        calls.values.forEach { $0.cancel() }
        calls.removeAll()
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        process?.terminationHandler = nil
        pipe?.close()
        pipe = nil
        if let process, process.isRunning {
            process.terminate()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        process = nil
        output = nil
        errorOutput = nil
        dispatcher = nil
        configuration = nil
        try? FileManager.default.removeItem(at: descriptorURL)
    }

    private func fail() {
        stop()
        failureMessage = L10n.text("The coding agent connection stopped. Your writing remains open.")
        workspace?.showMessage(failureMessage ?? "", persistent: true)
    }

    private func writePrivate(_ data: Data, name: String) throws {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The serial queue owns its duplicated descriptor; slow helper I/O never blocks AppKit.
private final class MCPLinePipe: @unchecked Sendable {
    private let input: FileHandle
    private let writeQueue = DispatchQueue(label: "app.prose.mcp.write")
    private let readQueue = DispatchQueue(label: "app.prose.mcp.read")
    private let lock = NSLock()
    private var closed = false
    private var queued = 0
    private var buffer = Data()
    private let callback: @Sendable (Result<JSONValue, Error>) -> Void
    init(input: FileHandle, callback: @escaping @Sendable (Result<JSONValue, Error>) -> Void) throws {
        let descriptor = fcntl(input.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw ServiceError.unavailable
        }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            Darwin.close(descriptor)
            throw ServiceError.unavailable
        }
        self.input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.callback = callback
    }

    func send(_ message: JSONValue) throws {
        var data = try JSONEncoder().encode(message)
        data.append(10)
        let frame = data
        let allowed = lock.withLock {
            guard !closed, frame.count < 8 * 1024 * 1024, queued + frame.count <= 16 * 1024 * 1024 else {
                return false
            }
            queued += frame.count
            return true
        }
        guard allowed else {
            throw ServiceError.disconnected
        }
        writeQueue.async { [self] in
            defer { lock.withLock { queued -= frame.count } }
            guard !lock.withLock({ closed }) else {
                return
            }
            do { try input.write(contentsOf: frame) }
            catch { disconnected() }
        }
    }

    func receive(_ data: Data) {
        readQueue.async { [self] in
            guard !lock.withLock({ closed }) else {
                return
            }
            buffer.append(data)
            guard buffer.count <= 8 * 1024 * 1024 else {
                disconnected()
                return
            }
            do {
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    try callback(.success(JSONDecoder().decode(JSONValue.self, from: line)))
                }
            } catch { disconnected() }
        }
    }

    func disconnected() {
        callback(.failure(ServiceError.disconnected))
    }

    func close() {
        lock.withLock { closed = true }
        writeQueue.async { [input] in try? input.close() }
    }
}
