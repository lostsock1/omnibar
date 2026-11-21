// OmniBar: a tiny macOS menu bar view of OmniRoute's recent calls.
//
// Polls GET <url> (default http://localhost:20128/api/usage/call-logs, OmniRoute's local
// address) with a Bearer token from the login keychain (generic password, service
// "omniroute-bar") and lists the newest calls. Click a row to copy its JSON.
//
//   ./build.sh                 build, install to /Applications, start now and at login
//   OmniBar --once             print the rows to stdout and exit (no menu bar item)
//   defaults write local.omnibar url|interval|rows <value>, then restart

import AppKit

// MARK: Settings

let prefs = UserDefaults.standard
let endpoint = prefs.string(forKey: "url") ?? "http://localhost:20128/api/usage/call-logs"
let endpointHost = URL(string: endpoint)?.host ?? endpoint
let pollSeconds = prefs.double(forKey: "interval") > 0 ? prefs.double(forKey: "interval") : 30
let rowLimit = prefs.integer(forKey: "rows") > 0 ? prefs.integer(forKey: "rows") : 15
let keychainService = "omniroute-bar"

// MARK: Data

struct Failure: Error, CustomStringConvertible {
    let description: String
    var auth = false
}

/// One call-log row, kept as raw JSON so unknown or changed fields never break decoding.
struct Call {
    let raw: [String: Any]
    var attempts: [Call] = []  // the provider-attempt rows folded into this one

    var date: Date? { (raw["timestamp"] as? String).flatMap(parseDate) }
    var active: Bool { raw["active"] as? Bool ?? false }
    var status: Int { Int(number(raw["status"]) ?? 0) }
    var model: String { text(raw["model"]) ?? text(raw["requestedModel"]) ?? "?" }
    var tokens: [String: Any] { raw["tokens"] as? [String: Any] ?? [:] }
    var failed: Bool { !active && (status >= 400 || describe(raw["error"]) != nil) }
    var isClientRow: Bool { text(raw["apiKeyName"]) != nil || text(raw["comboName"]) != nil }
}

/// OmniRoute logs a request as one client-facing row (combo, API key) plus one row per
/// provider attempt, all with the same correlationId. Keep one line per request: the
/// client row, else the in-flight attempt, and fold the rest into `attempts`.
func collapse(_ rows: [Call]) -> [Call] {
    var groups: [String: [Call]] = [:]
    var order: [String] = []
    for (index, row) in rows.enumerated() {
        let key = text(row.raw["correlationId"]) ?? "#\(index)"
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(row)
    }
    return order.map { key in
        let group = groups[key] ?? []
        let pick = group.firstIndex(where: \.isClientRow) ?? group.firstIndex(where: \.active) ?? 0
        var call = group[pick]
        call.attempts = group.enumerated().filter { $0.offset != pick }.map(\.element)
        return call
    }
}

func text(_ value: Any?) -> String? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    return s
}

func number(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    return (value as? String).flatMap(Double.init)
}

func describe(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let s = value as? String { return s.isEmpty ? nil : s }
    if let d = value as? [String: Any], let message = d["message"] as? String { return message }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value) {
        return String(decoding: data, as: UTF8.self)
    }
    return "\(value)"
}

let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()
let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func parseDate(_ s: String) -> Date? { isoFractional.date(from: s) ?? isoPlain.date(from: s) }

// MARK: Formatting

func compact(_ n: Double) -> String {
    switch n {
    case ..<1_000: return String(Int(n))
    case ..<9_950: return String(format: "%.1fk", n / 1_000)
    case ..<999_500: return String(format: "%.0fk", n / 1_000)
    default: return String(format: "%.1fM", n / 1_000_000)
    }
}

func elapsed(_ ms: Double) -> String {
    let ms = max(0, ms)
    if ms < 1_000 { return "\(Int(ms))ms" }
    let s = ms / 1_000
    if s < 60 { return String(format: "%.1fs", s) }
    return String(format: "%ldm%02lds", Int(s) / 60, Int(s) % 60)
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

/// "14:40:24  200   43.0s  152k→4.1k  model" plus "provider · combo · key".
func columns(_ call: Call, now: Date = Date()) -> (main: String, extra: String) {
    let time = call.date.map(clock.string(from:)) ?? "--:--:--"
    let status = call.active ? "…" : call.status > 0 ? String(call.status) : call.failed ? "ERR" : "-"
    let ms = call.active ? call.date.map { now.timeIntervalSince($0) * 1_000 } : number(call.raw["duration"])
    let tokensIn = number(call.tokens["in"]), tokensOut = number(call.tokens["out"])
    let tokens = call.active || (tokensIn == nil && tokensOut == nil)
        ? "-" : "\(compact(tokensIn ?? 0))→\(compact(tokensOut ?? 0))"
    let main = "\(time)  \(pad(status, 3))  \(pad(ms.map(elapsed) ?? "-", 6))  \(pad(tokens, 9))  \(call.model)"
    let extra = ["provider", "comboName", "apiKeyName"].compactMap { text(call.raw[$0]) }.joined(separator: " · ")
    return (main, extra)
}

func details(_ call: Call) -> String {
    var lines: [String] = []
    for (label, key) in [("model", "model"), ("requested", "requestedModel"), ("provider", "provider"),
                         ("combo", "comboName"), ("api key", "apiKeyName"), ("path", "path"),
                         ("correlation", "correlationId"), ("error", "error")] {
        if let value = describe(call.raw[key]) { lines.append("\(label): \(value)") }
    }
    let tokens = call.tokens.compactMap { key, value in number(value).map { "\(key) \(compact($0))" } }.sorted()
    if !tokens.isEmpty { lines.append("tokens: " + tokens.joined(separator: ", ")) }
    if call.attempts.count > 1 || call.attempts.contains(where: \.failed) {
        lines.append("attempts: " + call.attempts.map { attempt in
            let status = attempt.active ? "…" : String(attempt.status)
            let ms = number(attempt.raw["duration"]).map(elapsed) ?? "-"
            return "\(status) \(text(attempt.raw["provider"]) ?? "?")/\(attempt.model) \(ms)"
        }.joined(separator: ", "))
    }
    lines.append("Click to copy the JSON")
    return lines.joined(separator: "\n")
}

// MARK: Fetching

/// Reads the token through /usr/bin/security, which created the item and is therefore
/// on its ACL, so there is no keychain prompt (rebuilds change the app's ad-hoc signature).
func readToken() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["find-generic-password", "-s", keychainService, "-w"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return task.terminationStatus == 0 && !token.isEmpty ? token : nil
}

func fetchCalls(token: String) async throws -> [Call] {
    guard var parts = URLComponents(string: endpoint) else { throw Failure(description: "Bad URL: \(endpoint)") }
    var query = parts.queryItems ?? []
    // limit is only a hint to OmniRoute (limit=15 returns ~35 rows), and most requests take
    // two rows, so ask for twice the rows shown. That keeps a poll around 50 KB.
    if !query.contains(where: { $0.name == "limit" }) {
        query.append(URLQueryItem(name: "limit", value: String(rowLimit * 2)))
    }
    parts.queryItems = query
    guard let url = parts.url else { throw Failure(description: "Bad URL: \(endpoint)") }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
        let auth = code == 401 || code == 403
        throw Failure(description: auth ? "HTTP \(code): token rejected" : "HTTP \(code)", auth: auth)
    }
    let json = try JSONSerialization.jsonObject(with: data)
    let rows = json as? [[String: Any]]
        ?? (json as? [String: Any])?.values.compactMap { $0 as? [[String: Any]] }.first
        ?? []
    // The server's order is not strictly newest-first, so sort here.
    let newestFirst: (Call, Call) -> Bool = { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    return collapse(rows.map { Call(raw: $0) }.sorted(by: newestFirst)).sorted(by: newestFirst)
}

// MARK: Menu bar

@MainActor
final class OmniBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var calls: [Call] = []
    private var problem: String?
    private var updated: Date?
    private var loading = false
    private var token: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        item.menu = menu
        render()
        refresh()
        Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if Date().timeIntervalSince(updated ?? .distantPast) > 5 { refresh() }
    }

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false; render() }
            guard let token = token ?? readToken() else {
                problem = "No token in the keychain (service \(keychainService))"
                return
            }
            self.token = token
            do {
                calls = try await fetchCalls(token: token)
                problem = nil
                updated = Date()
            } catch let failure as Failure {
                if failure.auth { self.token = nil }  // re-read the keychain next time
                problem = failure.description
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func render() {
        let now = Date()
        let running = calls.filter(\.active).count
        let failures = calls.filter { $0.failed && now.timeIntervalSince($0.date ?? .distantPast) < 300 }.count

        if let button = item.button {
            let image = NSImage(systemSymbolName: problem == nil ? "arrow.triangle.branch" : "exclamationmark.triangle",
                                accessibilityDescription: "OmniRoute calls")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = running > 0 ? "\(running)" : ""
            let tint: NSColor? = problem != nil ? .systemOrange : failures > 0 ? .systemRed : nil
            button.contentTintColor = tint
            button.toolTip = problem ?? "OmniRoute: \(running) running, \(failures) failed in the last 5 min"
        }

        menu.removeAllItems()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for call in calls.prefix(rowLimit) {
            let (main, extra) = columns(call, now: now)
            let color: NSColor = call.failed ? .systemRed : call.active ? .systemBlue : .labelColor
            let title = NSMutableAttributedString(string: main, attributes: [.font: mono, .foregroundColor: color])
            if !extra.isEmpty {
                title.append(NSAttributedString(string: "  " + extra,
                                                attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let row = NSMenuItem(title: main, action: #selector(copyJSON(_:)), keyEquivalent: "")
            row.target = self
            row.attributedTitle = title
            row.toolTip = details(call)
            row.representedObject = call.raw
            menu.addItem(row)
        }
        if calls.isEmpty { menu.addItem(note(problem ?? "No calls yet")) }
        menu.addItem(.separator())
        if let problem, !calls.isEmpty { menu.addItem(note("⚠︎ " + problem)) }
        menu.addItem(note(updated.map { "Updated \(clock.string(from: $0)) · \(endpointHost)" } ?? "Not updated yet"))
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quit OmniBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
    }

    private func note(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    @objc private func copyJSON(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject,
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }
}

// MARK: Main

if CommandLine.arguments.contains("--once") {
    Task {
        guard let token = readToken() else {
            print("No token in the keychain (service \(keychainService))")
            exit(2)
        }
        do {
            for call in try await fetchCalls(token: token).prefix(rowLimit) {
                let (main, extra) = columns(call)
                print(extra.isEmpty ? main : "\(main)  \(extra)")
            }
            exit(0)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let bar = OmniBar()
    app.delegate = bar  // weak reference, hence withExtendedLifetime below
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(bar) { app.run() }
}
