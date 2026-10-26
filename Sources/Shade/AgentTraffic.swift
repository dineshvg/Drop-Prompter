import Foundation
import Network

/// One call recorded by the relay: an agent's call to its model API, with everything sent and received, or a
/// connection a program made through the proxy, of which only the host and the amount of data are known.
struct TrafficExchange: Identifiable {
    let id = UUID()
    /// Nil when the proxy couldn't tell which card the call came from.
    let cardID: UUID?
    let started: Date
    /// Set for model API calls through the relay; nil for proxied connections.
    let provider: AgentTraffic.Provider?
    let host: String
    let port: Int
    let method: String
    /// Path with query, e.g. "/v1/messages?beta=true"; empty for an HTTPS tunnel, whose contents stay encrypted.
    let path: String
    /// Program that made the call, when the proxy could find it.
    var process: String?
    /// Goes to a model or agent service (built-in list or ⚙︎ › Agent Traffic).
    let isAgent: Bool
    let requestBody: Data
    var status: Int?
    var responseBody = Data()
    var bytesSent = 0
    var bytesReceived = 0
    /// Refused by the proxy: a Strict card may only reach agent hosts.
    var blocked = false
    var duration: TimeInterval?
    var error: String?

    var isFinished: Bool { duration != nil }
    var isConnection: Bool { provider == nil }

    /// "api.github.com", with the port when it isn't the usual one.
    var address: String {
        port == 443 || port == 80 ? host : "\(host):\(port)"
    }
}

/// Records what programs in terminal cards send over the network. A card gets `ANTHROPIC_BASE_URL` and
/// `OPENAI_BASE_URL` pointing to this relay on 127.0.0.1; the relay forwards each call over HTTPS to the real API
/// and keeps a copy. The card's `HTTPS_PROXY` and `HTTP_PROXY` point here too: every other connection passes
/// through unchanged and is logged by host and size, since HTTPS keeps its contents encrypted. No certificates,
/// and everything stays in memory.
@MainActor
final class AgentTraffic: ObservableObject {
    static let shared = AgentTraffic()

    static let port: UInt16 = 18090
    /// Recorded model calls kept in memory; requests carry whole conversations, so this stays modest.
    static let limit = 100
    /// Proxied connections kept in memory; they're small, but a package install makes hundreds.
    static let connectionLimit = 1_000

    /// Model and agent services: their calls show under "Agents", and they're all a Strict card may reach.
    /// Copilot CLI talks to githubcopilot.com and api.github.com; Claude Code signs in through claude.com.
    static let builtInAgentHosts = [
        "anthropic.com", "claude.ai", "claude.com", "openai.com", "chatgpt.com",
        "githubcopilot.com", "api.github.com", "generativelanguage.googleapis.com", "cloudcode-pa.googleapis.com",
    ]

    /// Who opened a proxy connection, found from the calling process.
    struct Caller {
        let cardID: UUID
        let process: String?
        /// A Strict card: only agent hosts.
        let restricted: Bool
    }

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
    /// Show every recorded connection, not only calls to agent hosts.
    @Published var showAllTraffic = false

    /// Hosts the user added in ⚙︎, one per entry; a host also covers its subdomains.
    var extraAgentHosts: [String] = []
    /// Finds the card (and program) behind a proxy connection from its local port. Set by the terminal sessions.
    var identifyCaller: ((_ clientPort: UInt16) -> Caller?)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: RelayConnection] = [:]
    private lazy var forwarder = Forwarder(owner: self)

    // MARK: - Use

    /// Environment for a card whose network calls should be recorded. Nil when the relay can't run.
    func environment(for cardID: UUID) -> [String: String]? {
        guard startListening() else { return nil }
        let local = "127.0.0.1:\(Self.port)"
        let base = "http://\(local)/card/\(cardID.uuidString)"
        // The card's ID as proxy credentials names the card when Shade can't find the calling process.
        let proxy = "http://card:\(cardID.uuidString)@\(local)"
        let noProxy = "localhost,127.0.0.1,::1"
        return [
            "ANTHROPIC_BASE_URL": base + "/anthropic",
            "OPENAI_BASE_URL": base + "/openai/v1",
            // Tools differ in which spelling they read.
            "HTTPS_PROXY": proxy, "https_proxy": proxy, "HTTP_PROXY": proxy, "http_proxy": proxy,
            "NO_PROXY": noProxy, "no_proxy": noProxy,
            // Node's built-in fetch only follows the proxy variables when asked to.
            "NODE_USE_ENV_PROXY": "1",
            "SHADE_AGENT_TRAFFIC": "1",
        ]
    }

    func isAgentHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return (Self.builtInAgentHosts + extraAgentHosts).contains { host == $0 || host.hasSuffix("." + $0) }
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
        let limit = exchange.isConnection ? Self.connectionLimit : Self.limit
        let sameKind = exchanges.indices.filter { exchanges[$0].isConnection == exchange.isConnection }
        if sameKind.count > limit, let oldest = sameKind.first { exchanges.remove(at: oldest) }
    }

    /// The card behind a proxy connection: found from the calling process, else named by the proxy credentials.
    /// Only a process Shade found in a card that isn't Strict may reach any host; credentials can be copied.
    fileprivate func caller(clientPort: UInt16?, authorization: String?) -> (cardID: UUID?, process: String?, restricted: Bool) {
        if let clientPort, let caller = identifyCaller?(clientPort) {
            return (caller.cardID, caller.process, caller.restricted)
        }
        return (Self.cardID(fromProxyAuthorization: authorization), nil, true)
    }

    /// "Basic base64(card:<id>)", as sent for the credentials in the card's proxy URL.
    private static func cardID(fromProxyAuthorization header: String?) -> UUID? {
        guard let header, header.lowercased().hasPrefix("basic "),
              let data = Data(base64Encoded: String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
              let credentials = String(data: data, encoding: .utf8), credentials.hasPrefix("card:")
        else { return nil }
        return UUID(uuidString: String(credentials.dropFirst(5)))
    }

    fileprivate func update(_ id: UUID?, _ change: (inout TrafficExchange) -> Void) {
        guard let id, let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
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

/// One TCP connection from a program in a card. Model API requests on a keep-alive connection are handled one
/// after another. A proxy request (CONNECT, or a full `http://` URL) turns the connection into a tunnel to that
/// host: from then on bytes pass through unchanged and are only counted.
@MainActor
private final class RelayConnection {
    private let connection: NWConnection
    private weak var owner: AgentTraffic?
    private var buffer = Data()
    private var isBusy = false
    private var isClosed = false

    // Tunnel state, once the connection is proxied.
    private var upstream: NWConnection?
    private var tunnelExchange: UUID?
    private var isUpstreamReady = false
    /// Bytes from the program that arrived before the upstream connection was ready.
    private var pendingUpstream = Data()
    /// A plain `http://` request reads the status from the first line of the response.
    private var readsResponseStatus = false
    private var clientDone = false
    private var upstreamDone = false
    private var bytesSent = 0
    private var bytesReceived = 0
    private var lastPublished = Date.distantPast

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
        upstream?.cancel()
        finishTunnel(error: nil)
        owner?.closed(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    if self.upstream != nil {
                        self.sendUpstream(data)
                    } else {
                        self.buffer.append(data)
                        self.handleBufferedRequest()
                    }
                }
                if isComplete || error != nil {
                    if self.upstream != nil {
                        self.clientFinished()
                    } else if !self.isBusy {
                        self.close()
                    }
                } else {
                    self.receive()
                }
            }
        }
    }

    private func handleBufferedRequest() {
        guard !isBusy, upstream == nil, let parsed = HTTPRequest.parse(buffer) else { return }
        let request = parsed.request
        buffer.removeFirst(parsed.length)
        if request.method == "CONNECT" || request.target.lowercased().hasPrefix("http://") {
            proxy(request)
            return
        }
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
            cardID: cardID, started: Date(), provider: provider, host: provider.upstream.host ?? "", port: 443,
            method: request.method, path: path, process: owner?.caller(clientPort: clientPort, authorization: nil).process,
            isAgent: true, requestBody: request.body)
        owner?.record(exchange)
        owner?.forward(forwarded, for: self, exchange: exchange.id)
    }

    // MARK: Proxy

    private func proxy(_ request: HTTPRequest) {
        guard let owner else { return close() }
        let isConnect = request.method == "CONNECT"
        let target: (host: String, port: Int, path: String)?
        if isConnect {
            target = Self.hostAndPort(request.target).map { ($0.host, $0.port, "") }
        } else if let url = URLComponents(string: request.target), let host = url.host {
            let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath)
                + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
            target = (host, url.port ?? 80, path)
        } else {
            target = nil
        }
        guard let target, let port = NWEndpoint.Port(rawValue: UInt16(clamping: target.port)) else {
            return refuse(status: 400, message: "Shade's proxy couldn't read the address \(request.target).")
        }

        let caller = owner.caller(clientPort: clientPort, authorization: request.header("Proxy-Authorization"))
        let isLocal = ["localhost", "127.0.0.1", "::1"].contains(target.host.lowercased())
        let isAgent = owner.isAgentHost(target.host)
        var exchange = TrafficExchange(
            cardID: caller.cardID, started: Date(), provider: nil, host: target.host, port: target.port,
            method: request.method, path: target.path, process: caller.process, isAgent: isAgent,
            requestBody: Data())

        if isLocal && target.port == Int(AgentTraffic.port) {
            exchange.error = "Refused: the proxy can't connect to itself."
            exchange.duration = 0
            owner.record(exchange)
            return refuse(status: 400, message: "Shade's proxy can't connect to itself.")
        }
        // A Strict card's sandbox only lets programs reach this Mac, so the proxy is their only way out.
        if caller.restricted && !isAgent && !isLocal {
            exchange.blocked = true
            exchange.status = 403
            exchange.duration = 0
            owner.record(exchange)
            return refuse(status: 403, message: "Shade blocked this connection: a Strict card may only reach agent "
                + "services. Add \(target.host) in ⚙︎ › Agent Traffic to allow it.")
        }
        owner.record(exchange)
        tunnelExchange = exchange.id

        // A plain HTTP request goes on in its usual form, one per connection, so the tunnel ends with its response.
        var opening = Data()
        if !isConnect {
            readsResponseStatus = true
            var head = "\(request.method) \(target.path) HTTP/1.1\r\nHost: \(target.host)"
                + (target.port == 80 ? "" : ":\(target.port)") + "\r\n"
            for header in request.headers where !Self.hopHeaders.contains(header.name.lowercased())
                && !header.name.lowercased().hasPrefix("proxy-") {
                head += "\(header.name): \(header.value)\r\n"
            }
            if !request.body.isEmpty || ["POST", "PUT", "PATCH"].contains(request.method) {
                head += "Content-Length: \(request.body.count)\r\n"
            }
            head += "Connection: close\r\n\r\n"
            opening = Data(head.utf8) + request.body
        }
        pendingUpstream = opening + buffer
        buffer.removeAll()

        let upstream = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.upstreamChanged(state, isConnect: isConnect) }
        }
        upstream.start(queue: .main)
    }

    private func upstreamChanged(_ state: NWConnection.State, isConnect: Bool) {
        guard !isClosed, let upstream else { return }
        switch state {
        case .ready:
            guard !isUpstreamReady else { return }
            isUpstreamReady = true
            if isConnect {
                send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                owner?.update(tunnelExchange) { $0.status = 200 }
            }
            if !pendingUpstream.isEmpty {
                bytesSent += pendingUpstream.count
                upstream.send(content: pendingUpstream, completion: .contentProcessed { _ in })
                pendingUpstream.removeAll()
            }
            if clientDone { upstream.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) }
            receiveUpstream()
        case .waiting(let error), .failed(let error):
            // .waiting means it can't connect yet (e.g. the name doesn't resolve); don't let the program hang.
            if isUpstreamReady {
                // Once data has flowed, this is just how the connection ended (e.g. a reset), not a failure.
                finishTunnel(error: bytesReceived == 0 ? error.localizedDescription : nil)
                close()
            } else {
                finishTunnel(error: error.localizedDescription)
                refuse(status: 502, message: "Shade's proxy couldn't connect: \(error.localizedDescription)")
            }
        default:
            break
        }
    }

    private func receiveUpstream() {
        upstream?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    if self.readsResponseStatus {
                        self.readsResponseStatus = false
                        // "HTTP/1.1 200 OK"
                        let line = String(decoding: data.prefix(32), as: UTF8.self).split(separator: " ")
                        if line.count >= 2, let status = Int(line[1]) {
                            self.owner?.update(self.tunnelExchange) { $0.status = status }
                        }
                    }
                    self.bytesReceived += data.count
                    self.send(data)
                    self.publishCounts()
                }
                if isComplete || error != nil {
                    self.upstreamDone = true
                    // Pass the end on to the program, then close once it's sent.
                    self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                         completion: .contentProcessed { [weak self] _ in
                        MainActor.assumeIsolated { self?.close() }
                    })
                } else {
                    self.receiveUpstream()
                }
            }
        }
    }

    private func sendUpstream(_ data: Data) {
        guard let upstream else { return }
        guard isUpstreamReady else {
            pendingUpstream.append(data)
            return
        }
        bytesSent += data.count
        upstream.send(content: data, completion: .contentProcessed { _ in })
        publishCounts()
    }

    /// The program closed its side: pass that on, and close once the other side is done too.
    private func clientFinished() {
        clientDone = true
        if upstreamDone { return close() }
        if isUpstreamReady {
            upstream?.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        }
    }

    /// Counts are published at most twice a second, so a download doesn't redraw the list for every packet.
    private func publishCounts(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPublished) > 0.5 else { return }
        lastPublished = Date()
        let sent = bytesSent, received = bytesReceived
        owner?.update(tunnelExchange) {
            $0.bytesSent = sent
            $0.bytesReceived = received
        }
    }

    private func finishTunnel(error: String?) {
        guard let id = tunnelExchange else { return }
        publishCounts(force: true)
        owner?.update(id) { exchange in
            guard !exchange.isFinished else { return }
            exchange.duration = Date().timeIntervalSince(exchange.started)
            if let error { exchange.error = error }
        }
    }

    /// Answers a proxy request that won't be tunnelled, then closes: the program may not reuse the connection.
    private func refuse(status: Int, message: String) {
        let body = Data(message.utf8)
        let head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    /// The program's end of the connection, to find which process opened it.
    private var clientPort: UInt16? {
        if case .hostPort(_, let port) = connection.endpoint { return port.rawValue }
        return nil
    }

    /// "host:443", or "[::1]:443" for IPv6.
    private static func hostAndPort(_ target: String) -> (host: String, port: Int)? {
        guard let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]) else { return nil }
        var host = String(target[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
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
