import AppKit
import SwiftUI

/// What a recorded call contained, read from the Anthropic or OpenAI request and response.
struct TrafficSummary {
    var model: String?
    var system: String?
    var lastUserMessage: String?
    var reply = ""
    var toolsOffered: [String] = []
    var toolsCalled: [String] = []
    var messageCount = 0
    var inputTokens: Int?
    var outputTokens: Int?

    init(_ exchange: TrafficExchange) {
        let request = (try? JSONSerialization.jsonObject(with: exchange.requestBody)) as? [String: Any] ?? [:]
        model = request["model"] as? String
        system = Self.text(request["system"])
        let messages = request["messages"] as? [[String: Any]] ?? []
        messageCount = messages.count
        lastUserMessage = messages.last { $0["role"] as? String == "user" }.flatMap { Self.text($0["content"]) }
        toolsOffered = (request["tools"] as? [[String: Any]] ?? []).compactMap {
            $0["name"] as? String ?? ($0["function"] as? [String: Any])?["name"] as? String
        }
        if exchange.provider == .openai, system == nil {
            system = messages.first { $0["role"] as? String == "system" }.flatMap { Self.text($0["content"]) }
        }
        readResponse(exchange.responseBody)
    }

    /// Handles a plain JSON response and a streamed (server-sent events) one.
    private mutating func readResponse(_ body: Data) {
        if let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            readEvent(json)
            return
        }
        for line in String(decoding: body, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            readEvent(event)
        }
    }

    private mutating func readEvent(_ event: [String: Any]) {
        // Anthropic, streamed
        if let message = event["message"] as? [String: Any] { readUsage(message["usage"]) }
        if let delta = event["delta"] as? [String: Any], let text = delta["text"] as? String { reply += text }
        if let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
           let name = block["name"] as? String { toolsCalled.append(name) }
        // Anthropic, complete
        for block in event["content"] as? [[String: Any]] ?? [] {
            if let text = block["text"] as? String { reply += text }
            if block["type"] as? String == "tool_use", let name = block["name"] as? String { toolsCalled.append(name) }
        }
        // OpenAI chat completions, complete and streamed
        for choice in event["choices"] as? [[String: Any]] ?? [] {
            let message = (choice["message"] ?? choice["delta"]) as? [String: Any]
            if let text = message?["content"] as? String { reply += text }
            for call in message?["tool_calls"] as? [[String: Any]] ?? [] {
                if let name = (call["function"] as? [String: Any])?["name"] as? String { toolsCalled.append(name) }
            }
        }
        readUsage(event["usage"])
    }

    private mutating func readUsage(_ value: Any?) {
        guard let usage = value as? [String: Any] else { return }
        if let input = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int { inputTokens = input }
        if let output = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int { outputTokens = output }
    }

    /// Text of a string, or of an array of content blocks.
    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let blocks = value as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            if let text = block["text"] as? String { return text }
            if block["type"] as? String == "tool_result" { return "[tool result]" }
            if block["type"] as? String == "image" { return "[image]" }
            return nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func prettyJSON(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: pretty, as: UTF8.self)
    }
}

/// A terminal card the traffic list can be filtered by.
struct TrafficCard: Identifiable {
    let id: UUID
    let name: String
}

/// The Agent Traffic card: every call agents in recorded terminal cards made to their model API.
struct TrafficView: View {
    @ObservedObject var traffic: AgentTraffic
    let cards: [TrafficCard]
    let theme: Theme
    let highlightTheme: String
    let codeSize: CGFloat
    let codeBackgroundOpacity: Double

    private enum Tab: String, CaseIterable {
        case summary = "Summary", request = "Request", response = "Response"
    }

    @State private var selection: UUID?
    @State private var tab = Tab.summary
    @State private var rendered: NSAttributedString?

    private var visible: [TrafficExchange] {
        traffic.exchanges.filter {
            (traffic.filterCardID == nil || $0.cardID == traffic.filterCardID) && (traffic.showAllTraffic || $0.isAgent)
        }.reversed()
    }

    private var selected: TrafficExchange? {
        traffic.exchanges.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 340)
            detail
                .frame(minWidth: 320, maxWidth: .infinity)
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Card", selection: $traffic.filterCardID) {
                    Text("All cards").tag(UUID?.none)
                    ForEach(cards) { card in
                        Text(card.name).tag(UUID?.some(card.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Show", selection: $traffic.showAllTraffic) {
                    Text("Agents").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Agents: calls to model and agent services. All: every connection the card's programs made.")
                Spacer()
                Text("\(visible.count) calls")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    traffic.clear()
                    selection = nil
                }
                .help("Forget the recorded calls")
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider().opacity(0.4)
            if let error = traffic.listenerError {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(12)
            }
            if visible.isEmpty {
                Text("No calls yet. Turn on Record Agent Traffic in the 🛡 menu, open a terminal card and run claude, "
                    + "copilot or another agent. Its calls appear here; choose All to see every connection.")
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            } else {
                List(visible, selection: $selection) { exchange in
                    row(exchange).tag(exchange.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ exchange: TrafficExchange) -> some View {
        let summary = exchange.isConnection ? nil : TrafficSummary(exchange)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                statusBadge(exchange)
                Text(summary.map { $0.model ?? exchange.path } ?? exchange.address + exchange.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if exchange.isFinished {
                    Text(String(format: "%.1fs", exchange.duration ?? 0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Text(exchange.started, format: .dateTime.hour().minute().second())
                Text(cardName(exchange.cardID))
                    .lineLimit(1)
                if let process = exchange.process {
                    Text(process).lineLimit(1)
                }
                if let input = summary?.inputTokens {
                    Text("\(input) in · \(summary?.outputTokens ?? 0) out")
                } else if exchange.isConnection, !exchange.blocked {
                    Text("↑ \(Self.bytes(exchange.bytesSent)) ↓ \(Self.bytes(exchange.bytesReceived))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ exchange: TrafficExchange) -> some View {
        let status = exchange.status
        let color: Color = exchange.error != nil || exchange.blocked ? .red
            : status.map { (200..<300).contains($0) ? .green : .orange } ?? .secondary
        // A tunnel's own status says nothing about the encrypted requests inside it.
        let label = exchange.blocked ? "BLOCKED"
            : exchange.error != nil && exchange.isConnection ? "FAILED"
            : exchange.method == "CONNECT" && status != nil ? "HTTPS"
            : status.map { String($0) } ?? "…"
        return Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }

    private func cardName(_ id: UUID?) -> String {
        guard let id else { return "Unknown card" }
        return cards.first { $0.id == id }?.name ?? "Closed card"
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let exchange = selected, exchange.isConnection {
            connectionView(exchange)
        } else if let exchange = selected, let provider = exchange.provider {
            VStack(spacing: 0) {
                HStack {
                    Picker("Show", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Text("\(exchange.method) \(provider.name) \(exchange.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(8)
                Divider().opacity(0.4)
                switch tab {
                case .summary:
                    summaryView(exchange)
                case .request, .response:
                    Group {
                        if let rendered {
                            ReadOnlyText(text: rendered)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .background(Color(nsColor: codeBackground))
                }
            }
            .task(id: RenderRequest(exchange: exchange.id, tab: tab, finished: exchange.isFinished,
                                    size: tab == .request ? exchange.requestBody.count : exchange.responseBody.count)) {
                rendered = tab == .summary ? nil : render(exchange)
            }
        } else {
            Text("Select a call to see what was sent and what came back.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct RenderRequest: Equatable {
        let exchange: UUID
        let tab: Tab
        let finished: Bool
        let size: Int
    }

    /// A proxied connection: who made it and how much went each way. HTTPS keeps the rest encrypted.
    private func connectionView(_ exchange: TrafficExchange) -> some View {
        let isTunnel = exchange.method == "CONNECT"
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Card").foregroundStyle(.secondary); Text(cardName(exchange.cardID)) }
                    GridRow { Text("Program").foregroundStyle(.secondary); Text(exchange.process ?? "unknown") }
                    GridRow { Text("Host").foregroundStyle(.secondary); Text(exchange.host) }
                    GridRow { Text("Port").foregroundStyle(.secondary); Text(String(exchange.port)) }
                    GridRow {
                        Text("Kind").foregroundStyle(.secondary)
                        Text((isTunnel ? "HTTPS" : "HTTP \(exchange.method) \(exchange.path)")
                            + (exchange.isAgent ? " · agent service" : ""))
                    }
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        Text(exchange.blocked ? "Blocked: a Strict card may only reach agent services"
                             : exchange.error ?? (exchange.isFinished ? "Closed" : "Open")
                                + (isTunnel ? "" : exchange.status.map { " · \($0)" } ?? ""))
                    }
                    GridRow { Text("Sent").foregroundStyle(.secondary); Text(Self.bytes(exchange.bytesSent)) }
                    GridRow { Text("Received").foregroundStyle(.secondary); Text(Self.bytes(exchange.bytesReceived)) }
                    GridRow {
                        Text("Duration").foregroundStyle(.secondary)
                        Text(exchange.duration.map { String(format: "%.1fs", $0) } ?? "still open")
                    }
                }
                if isTunnel && !exchange.blocked {
                    Text("HTTPS is encrypted between the program and \(exchange.host), so Shade sees only the host and "
                        + "how much was sent. Calls to the Anthropic and OpenAI APIs are recorded in full instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private func summaryView(_ exchange: TrafficExchange) -> some View {
        let summary = TrafficSummary(exchange)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Card").foregroundStyle(.secondary); Text(cardName(exchange.cardID)) }
                    GridRow { Text("Model").foregroundStyle(.secondary); Text(summary.model ?? "unknown") }
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        Text(exchange.error ?? exchange.status.map { String($0) } ?? "waiting…")
                    }
                    GridRow {
                        Text("Tokens").foregroundStyle(.secondary)
                        Text(summary.inputTokens.map { "\($0) in · \(summary.outputTokens ?? 0) out" } ?? "not reported")
                    }
                    GridRow {
                        Text("Sent").foregroundStyle(.secondary)
                        Text("\(summary.messageCount) messages, \(ByteCountFormatter.string(fromByteCount: Int64(exchange.requestBody.count), countStyle: .file))")
                    }
                    if !summary.toolsOffered.isEmpty {
                        GridRow {
                            Text("Tools offered").foregroundStyle(.secondary)
                            Text(summary.toolsOffered.joined(separator: ", ")).lineLimit(3)
                        }
                    }
                    if !summary.toolsCalled.isEmpty {
                        GridRow { Text("Tools called").foregroundStyle(.secondary); Text(summary.toolsCalled.joined(separator: ", ")) }
                    }
                }
                section("Last message from the agent's user", summary.lastUserMessage)
                section("Reply", summary.reply.isEmpty ? nil : summary.reply)
                section("System prompt", summary.system)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text.count > 4_000 ? String(text.prefix(4_000)) + "…" : text)
                    .font(.system(size: codeSize, design: .monospaced))
            }
        }
    }

    // MARK: - Rendering

    private var codeBackground: NSColor {
        let base = SyntaxHighlighting.shared.background(ofTheme: highlightTheme) ?? theme.terminalBackground
        return base.withAlphaComponent(CGFloat(codeBackgroundOpacity))
    }

    /// Pretty-printed JSON, highlighted like code; streamed responses stay as their raw events.
    private func render(_ exchange: TrafficExchange) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        let body = tab == .request ? exchange.requestBody : exchange.responseBody
        let text = TrafficSummary.prettyJSON(body)
        let isJSON = (try? JSONSerialization.jsonObject(with: body)) != nil
        if isJSON, text.utf8.count <= SyntaxHighlighting.maxHighlightedSize,
           let highlightr = SyntaxHighlighting.shared.highlightr,
           SyntaxHighlighting.shared.use(theme: highlightTheme, font: font),
           let highlighted = highlightr.highlight(text, as: "json") {
            return highlighted
        }
        return NSAttributedString(string: text.isEmpty ? "(empty)" : text,
                                  attributes: [.font: font, .foregroundColor: theme.codeTextColor])
    }
}
