import Foundation
import Network

/// One call from an agent to its model API, as recorded by the relay.
struct TrafficExchange: Identifiable {
    let id = UUID()
    let cardID: UUID
    let started: Date
    let provider: AgentTraffic.Provider
    let method: String
    /// Upstream path with query, e.g. "/v1/messages?beta=true".
    let path: String
    let requestBody: Data
    var status: Int?
    var responseBody = Data()
    var duration: TimeInterval?
    var error: String?

    var isFinished: Bool { duration != nil }
}

/// Records what agents in terminal cards send to their model APIs. A card gets `ANTHROPIC_BASE_URL` and
/// `OPENAI_BASE_URL` pointing to this relay on 127.0.0.1; the relay forwards each call over HTTPS to the real API
/// and keeps a copy. It only forwards to those APIs, needs no certificates, and keeps everything in memory.
@MainActor
final class AgentTraffic: ObservableObject {
    static let shared = AgentTraffic()

    static let port: UInt16 = 18090
    /// Recorded calls kept in memory; requests carry whole conversations, so this stays modest.
    static let limit = 100

    enum Provider: String {
        case anthropic, openai

        var upstream: URL {
            switch self {
            case .anthropic: return URL(string: "https://api.anthropic.com")!
            case .openai: return URL(string: "https://api.openai.com")!
            }
        }

        var name: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI"
            }
        }
    }

    @Published private(set) var exchanges: [TrafficExchange] = []
    /// Why the relay can't listen, e.g. the port is taken.
    @Published private(set) var listenerError: String?
    /// Card whose calls the Agent Traffic card shows; nil shows all.
    @Published var filterCardID: UUID?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: RelayConnection] = [:]
    private lazy var forwarder = Forwarder(owner: self)

    // MARK: - Use

    /// Environment for a card whose model calls should be recorded. Nil when the relay can't run.
    func environment(for cardID: UUID) -> [String: String]? {
        guard startListening() else { return nil }
        let base = "http://127.0.0.1:\(Self.port)/card/\(cardID.uuidString)"
        return [
            "ANTHROPIC_BASE_URL": base + "/anthropic",
            "OPENAI_BASE_URL": base + "/openai/v1",
            "SHADE_AGENT_TRAFFIC": "1",
        ]
    }

    func clear() {
        exchanges.removeAll { $0.isFinished }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
    }

    // MARK: - Listening

    private func startListening() -> Bool {
        if listener != nil { return listenerError == nil }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback // never reachable from the network
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .failed(let error) = state {
                        self?.listenerError = "Agent Traffic couldn't listen on port \(Self.port): \(error.localizedDescription)"
                        self?.listener = nil
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            listenerError = nil
            return true
        } catch {
            listenerError = "Agent Traffic couldn't start: \(error.localizedDescription)"
            return false
        }
    }

    private func accept(_ connection: NWConnection) {
        let relay = RelayConnection(connection: connection, owner: self)
        connections[ObjectIdentifier(relay)] = relay
        relay.start()
    }

    fileprivate func closed(_ relay: RelayConnection) {
        connections[ObjectIdentifier(relay)] = nil
    }

    // MARK: - Recording

    fileprivate func record(_ exchange: TrafficExchange) {
        exchanges.append(exchange)
        if exchanges.count > Self.limit { exchanges.removeFirst(exchanges.count - Self.limit) }
    }

    fileprivate func update(_ id: UUID, _ change: (inout TrafficExchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }

    fileprivate func forward(_ request: URLRequest, for relay: RelayConnection, exchange: UUID) {
        forwarder.start(request, relay: relay, exchange: exchange)
    }
}

// MARK: - HTTP parsing

/// A complete HTTP/1.1 request read from an agent.
private struct HTTPRequest {
    let method: String
    let target: String
    let headers: [(name: String, value: String)]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Parses one request from the start of `buffer`; nil while more bytes are needed.
    static func parse(_ buffer: Data) -> (request: HTTPRequest, length: Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let headers: [(name: String, value: String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let request = HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: Data())
        let bodyStart = headerEnd.upperBound

        if request.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            guard let decoded = decodeChunked(buffer, from: bodyStart) else { return nil }
            return (HTTPRequest(method: request.method, target: request.target, headers: headers, body: decoded.body),
                    decoded.end - buffer.startIndex)
        }
        let length = Int(request.header("Content-Length") ?? "0") ?? 0
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return (HTTPRequest(method: request.method, target: request.target, headers: headers, body: body),
                bodyStart + length - buffer.startIndex)
    }

    private static func decodeChunked(_ buffer: Data, from start: Data.Index) -> (body: Data, end: Data.Index)? {
        var body = Data()
        var position = start
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = buffer.range(of: crlf, in: position..<buffer.endIndex) else { return nil }
            let sizeText = String(decoding: buffer[position..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            position = lineEnd.upperBound
            if size == 0 {
                // Skip optional trailers up to the empty line.
                guard let end = buffer.range(of: crlf, in: position..<buffer.endIndex) else { return nil }
                return (body, end.upperBound)
            }
            guard buffer.endIndex - position >= size + 2 else { return nil }
            body.append(buffer[position..<(position + size)])
            position += size + 2
        }
    }
}

// MARK: - Connections

/// One TCP connection from an agent. Requests on a keep-alive connection are handled one after another.
@MainActor
private final class RelayConnection {
    private let connection: NWConnection
    private weak var owner: AgentTraffic?
    private var buffer = Data()
    private var isBusy = false
    private var isClosed = false

    /// Headers that only describe this hop, not the request itself.
    private static let hopHeaders: Set<String> = [
        "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding", "content-length",
        "accept-encoding", "te", "upgrade", "trailer",
    ]

    init(connection: NWConnection, owner: AgentTraffic) {
        self.connection = connection
        self.owner = owner
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        owner?.closed(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.handleBufferedRequest()
                }
                if isComplete || error != nil {
                    if !self.isBusy { self.close() }
                } else {
                    self.receive()
                }
            }
        }
    }

    private func handleBufferedRequest() {
        guard !isBusy, let parsed = HTTPRequest.parse(buffer) else { return }
        let request = parsed.request
        buffer.removeFirst(parsed.length)
        isBusy = true

        // Target: /card/<card id>/<anthropic|openai>/<path on the API>
        let parts = request.target.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "card", let cardID = UUID(uuidString: String(parts[1])),
              let provider = AgentTraffic.Provider(rawValue: String(parts[2]))
        else {
            respond(status: 404, message: "Shade's Agent Traffic relay only forwards calls to the Anthropic and OpenAI APIs.")
            return
        }
        let path = parts.count == 4 ? "/" + parts[3] : "/"
        guard let url = URL(string: provider.upstream.absoluteString + path) else {
            respond(status: 400, message: "Invalid path.")
            return
        }

        var forwarded = URLRequest(url: url, timeoutInterval: 600)
        forwarded.httpMethod = request.method
        for header in request.headers where !Self.hopHeaders.contains(header.name.lowercased()) {
            forwarded.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if !request.body.isEmpty { forwarded.httpBody = request.body }

        let exchange = TrafficExchange(
            cardID: cardID, started: Date(), provider: provider, method: request.method, path: path,
            requestBody: request.body)
        owner?.record(exchange)
        owner?.forward(forwarded, for: self, exchange: exchange.id)
    }

    // MARK: Responding

    func sendHead(status: Int, headers: [AnyHashable: Any]) {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for (name, value) in headers {
            let name = "\(name)"
            // URLSession already removed the transfer framing and decompressed the body.
            guard !["content-length", "transfer-encoding", "connection", "content-encoding", "keep-alive"]
                .contains(name.lowercased()) else { continue }
            head += "\(name): \(value)\r\n"
        }
        head += "Transfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n"
        send(Data(head.utf8))
    }

    func sendChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        send(Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n".utf8))
    }

    /// Ends the response; the connection stays open for the agent's next request.
    func finishResponse() {
        send(Data("0\r\n\r\n".utf8))
        isBusy = false
        handleBufferedRequest()
    }

    func respond(status: Int, message: String) {
        sendHead(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"])
        sendChunk(Data(message.utf8))
        finishResponse()
    }

    private func send(_ data: Data) {
        guard !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

// MARK: - Forwarding

/// Sends recorded requests to the real API and streams the answers back as they arrive.
private final class Forwarder: NSObject, URLSessionDataDelegate {
    private weak var owner: AgentTraffic?
    private var session: URLSession!
    /// Running calls by task identifier. Only touched on the main queue (the session's delegate queue).
    private var calls: [Int: (relay: RelayConnection, exchange: UUID)] = [:]

    init(owner: AgentTraffic) {
        self.owner = owner
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    }

    @MainActor
    func start(_ request: URLRequest, relay: RelayConnection, exchange: UUID) {
        let task = session.dataTask(with: request)
        calls[task.taskIdentifier] = (relay, exchange)
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        MainActor.assumeIsolated {
            if let call = calls[dataTask.taskIdentifier], let http = response as? HTTPURLResponse {
                call.relay.sendHead(status: http.statusCode, headers: http.allHeaderFields)
                owner?.update(call.exchange) { $0.status = http.statusCode }
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard let call = calls[dataTask.taskIdentifier] else { return }
            call.relay.sendChunk(data)
            owner?.update(call.exchange) { $0.responseBody.append(data) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let call = calls.removeValue(forKey: task.taskIdentifier) else { return }
            if let error, (task.response as? HTTPURLResponse) == nil {
                // Nothing was sent to the agent yet: answer with a gateway error it can show.
                call.relay.respond(status: 502, message: "Shade's Agent Traffic relay couldn't reach the API: "
                    + error.localizedDescription)
            } else {
                call.relay.finishResponse()
            }
            owner?.update(call.exchange) { exchange in
                exchange.duration = Date().timeIntervalSince(exchange.started)
                exchange.error = error?.localizedDescription
            }
        }
    }
}
