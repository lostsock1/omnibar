// OmniBar: a tiny macOS menu bar view of OmniRoute's recent calls.
//
// Polls GET <url> (default http://localhost:20128/api/usage/call-logs, OmniRoute's local
// address) with a Bearer token from the login keychain (generic password, service
// "omniroute-bar") and lists the newest calls. Click a row to copy its JSON. A combo call
// also shows its place in the combo's fallback chain, from GET /api/combos on the same server.
// Below the calls, Providers shows the health of each provider connection, from
// GET /api/providers and the last hour of GET /api/providers/health-matrix.
//
//   ./build.sh                 build, install to /Applications, start now and at login
//   OmniBar --once             print the rows to stdout and exit (no menu bar item)
//   defaults write local.omnibar url|interval|rows <value>, then restart
//   defaults write local.omnibar providers -array glm "openai=codex"   pick the Providers block

import AppKit

// MARK: Settings

let prefs = UserDefaults.standard
let endpoint = prefs.string(forKey: "url") ?? "http://localhost:20128/api/usage/call-logs"
let endpointHost = URL(string: endpoint)?.host ?? endpoint
let pollSeconds = prefs.double(forKey: "interval") > 0 ? prefs.double(forKey: "interval") : 30
let rowLimit = prefs.integer(forKey: "rows") > 0 ? prefs.integer(forKey: "rows") : 15
let keychainService = "omniroute-bar"

/// The Providers block, from `defaults write local.omnibar providers -array …`. Each entry is
/// a label, or "label=match" when the label is not what picks the connections (see `pick`).
/// Unset: every active connection, under its own name.
let watched: [(label: String, match: String)] = (prefs.stringArray(forKey: "providers") ?? []).compactMap { entry in
    let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let label = parts.first, !label.isEmpty else { return nil }
    return (label, parts.count > 1 && !parts[1].isEmpty ? parts[1] : label)
}

// MARK: Data

struct Failure: Error, CustomStringConvertible {
    let description: String
    var auth = false
}

func message(_ error: Error) -> String { (error as? Failure)?.description ?? error.localizedDescription }

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
    var stepId: String? { text(raw["comboStepId"]) }
    func step(in chains: Chains) -> Step? { stepId.flatMap { chains[$0] } }
}

/// A combo step's place in its fallback chain, counted from 1: 1/3 is the combo's first
/// choice, 3/3 its last fallback.
struct Step {
    let position: Int
    let count: Int
    var label: String { "\(position)/\(count)" }
}

/// Combo step id → its place in the chain, from GET /api/combos. A step id contains a
/// "model-N" fixed when the step was added, which goes stale once the chain is reordered
/// (position 2 can hold "…-model-3-…"), so the position is the step's index in the combo.
typealias Chains = [String: Step]

func parseChains(_ json: Any) -> Chains {
    let combos = (json as? [String: Any])?["combos"] as? [[String: Any]] ?? json as? [[String: Any]] ?? []
    var chains: Chains = [:]
    for combo in combos {
        let steps = combo["models"] as? [[String: Any]] ?? []
        for (index, step) in steps.enumerated() {
            if let id = text(step["id"]), chains[id] == nil { chains[id] = Step(position: index + 1, count: steps.count) }
        }
    }
    return chains
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

/// A column of a menu table. Numbers are right-aligned; a tight column sits close to the one
/// before it, as in "152k → 4.1k".
struct Column {
    var right = false
    var tight = false
    var font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
}

/// Rows of cells as menu lines in aligned columns: a tab stop after the widest cell of each.
func tabbed(_ rows: [[String]], _ columns: [Column]) -> [NSAttributedString] {
    var widths = columns.map { _ in CGFloat(0) }
    for row in rows {
        for (i, cell) in row.prefix(columns.count).enumerated() {
            widths[i] = max(widths[i], ceil((cell as NSString).size(withAttributes: [.font: columns[i].font]).width))
        }
    }
    var stops: [NSTextTab] = []
    var x = widths.first ?? 0
    for i in columns.indices.dropFirst() {
        x += columns[i].tight ? 5 : 16
        stops.append(NSTextTab(textAlignment: columns[i].right ? .right : .left, location: columns[i].right ? x + widths[i] : x))
        x += widths[i]
    }
    let style = NSMutableParagraphStyle()
    style.tabStops = stops
    return rows.map { row in
        let line = NSMutableAttributedString()
        for (i, cell) in row.prefix(columns.count).enumerated() {
            line.append(NSAttributedString(string: (i > 0 ? "\t" : "") + cell,
                                           attributes: [.font: columns[i].font, .paragraphStyle: style]))
        }
        return line
    }
}

/// The same table as plain text padded with spaces, for --once.
func padded(_ rows: [[String]], _ columns: [Column]) -> [String] {
    var widths = columns.map { _ in 0 }
    for row in rows {
        for (i, cell) in row.prefix(columns.count).enumerated() { widths[i] = max(widths[i], cell.count) }
    }
    return rows.map { row in
        row.prefix(columns.count).enumerated().map { i, cell in
            let fill = String(repeating: " ", count: widths[i] - cell.count)
            return (i == 0 ? "" : columns[i].tight ? " " : "  ") + (columns[i].right ? fill + cell : cell + fill)
        }.joined().replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
    }
}

/// A call as table cells: time, status, duration, tokens in, → tokens out, chain position, model,
/// and "provider · combo · API key". The status shows only a failure ("429") or "…" while running.
/// The position is the step of the combo's fallback chain that served the call: 1/3 is the
/// combo's first choice, 3/3 its last fallback.
func cells(_ call: Call, _ chains: Chains, _ names: [String: String], now: Date = Date()) -> [String] {
    let status = call.active ? "…" : !call.failed ? "" : call.status > 0 ? String(call.status) : "ERR"
    let ms = call.active ? call.date.map { now.timeIntervalSince($0) * 1_000 } : number(call.raw["duration"])
    let tokensIn = number(call.tokens["in"]), tokensOut = number(call.tokens["out"])
    let counted = !call.active && ((tokensIn ?? 0) > 0 || (tokensOut ?? 0) > 0)
    let extra = [text(call.raw["provider"]).map { names[$0] ?? $0 }, text(call.raw["comboName"]), text(call.raw["apiKeyName"])]
        .compactMap { $0 }.joined(separator: " · ")
    return [call.date.map(clock.string(from:)) ?? "--:--:--", status, ms.map(elapsed) ?? "",
            counted ? compact(tokensIn ?? 0) : "", counted ? "→ " + compact(tokensOut ?? 0) : "",
            call.step(in: chains)?.label ?? "", call.model, extra]
}

let callColumns = [Column(), Column(right: true), Column(right: true), Column(right: true), Column(tight: true),
                   Column(right: true), Column(font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium)), Column()]

func details(_ call: Call, _ chains: Chains, _ names: [String: String]) -> String {
    var lines: [String] = []
    for (label, key) in [("model", "model"), ("requested", "requestedModel"), ("provider", "provider"),
                         ("combo", "comboName"), ("api key", "apiKeyName"), ("path", "path"),
                         ("correlation", "correlationId"), ("error", "error")] {
        guard var value = describe(call.raw[key]) else { continue }
        if key == "comboName", let step = call.step(in: chains) { value += ", position \(step.position) of \(step.count)" }
        if key == "provider", let name = names[value] { value = "\(name) (\(value))" }
        lines.append("\(label): \(value)")
    }
    let tokens = call.tokens.compactMap { key, value in number(value).map { "\(key) \(compact($0))" } }.sorted()
    if !tokens.isEmpty { lines.append("tokens: " + tokens.joined(separator: ", ")) }
    if call.attempts.count > 1 || call.attempts.contains(where: \.failed) {
        lines.append("attempts: " + call.attempts.map { attempt in
            let status = attempt.active ? "…" : String(attempt.status)
            let ms = number(attempt.raw["duration"]).map(elapsed) ?? "-"
            let step = attempt.step(in: chains).map { "\($0.label) " } ?? ""
            let provider = text(attempt.raw["provider"]).map { names[$0] ?? $0 } ?? "?"
            return "\(status) \(step)\(provider)/\(attempt.model) \(ms)"
        }.joined(separator: ", "))
    }
    lines.append("Click to copy the JSON")
    return lines.joined(separator: "\n")
}

// MARK: Provider health

/// A provider line's state, best first, with its menu symbol.
enum Health: Int {
    case ok, off, errors, cooldown, failing, broken

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle"
        case .off: return "minus.circle"
        case .errors: return "exclamationmark.circle"
        case .cooldown: return "clock"
        case .failing: return "exclamationmark.triangle"
        case .broken: return "xmark.circle"
        }
    }

    /// The symbol's stand-in for --once.
    var glyph: String { ["✓", "–", "!", "◷", "!", "✕"][rawValue] }
}

/// One line of the Providers block.
struct HealthRow {
    let label: String
    let health: Health
    let status: String   // in a few words, for the icon's tooltip: "cooling down", "login expired", …
    let quota: String    // "5h 90% · week 77%": the share used of each quota window
    let detail: String   // the rest of the line, empty when ok
    let countdowns: [[String]]  // indented lines below it: window, bar, time left, "available Sun 22 Nov 17:01"
    let tooltip: String
    let raw: Any         // the connection JSON, copied on click
}

func nodeName(_ connection: [String: Any]) -> String? {
    text((connection["providerSpecificData"] as? [String: Any])?["nodeName"])
}

/// What a `providers` entry is matched against: the provider id, the connection's name and,
/// for a custom (OpenAI-compatible) node, its node name.
func names(_ connection: [String: Any]) -> [String] {
    [text(connection["provider"]), text(connection["name"]), nodeName(connection)].compactMap { $0 }
}

/// The connections a `providers` entry picks: those with a name equal to `match`, else those
/// whose names contain it, ignoring case. "glm" is the glm provider, "silk" the node "Silk Compute".
func pick(_ match: String, from connections: [[String: Any]]) -> [[String: Any]] {
    let match = match.lowercased()
    let exact = connections.filter { names($0).contains { $0.lowercased() == match } }
    return exact.isEmpty ? connections.filter { names($0).contains { $0.lowercased().contains(match) } } : exact
}

/// A connection's own label: its node name or name, else the provider id. Most API-key
/// connections are named "main", and OAuth ones after the account's email address.
func connectionLabel(_ connection: [String: Any]) -> String {
    [nodeName(connection), text(connection["name"])].compactMap { $0 }.first { $0 != "main" && !$0.contains("@") }
        ?? text(connection["provider"]) ?? "?"
}

/// Provider id → the name the calls show: the `providers` label that picks it, else a custom
/// node's name, so "openai-compatible-chat-<uuid>" shows as "ppq".
func providerNames(_ connections: [[String: Any]]) -> [String: String] {
    var names: [String: String] = [:]
    for entry in watched {
        for connection in pick(entry.match, from: connections) {
            if let id = text(connection["provider"]), names[id] == nil { names[id] = entry.label }
        }
    }
    for connection in connections {
        if let id = text(connection["provider"]), names[id] == nil, let node = nodeName(connection) { names[id] = node }
    }
    return names
}

/// The gist of a provider's error for its menu line; the tooltip keeps all of it.
/// "[429]: Weekly/Monthly Limit Exhausted. Your limit will reset at …" → "Weekly/Monthly Limit Exhausted",
/// "Shared egress IP quota exhausted (opencode-go)" → "Shared egress IP quota exhausted".
func gist(_ error: String) -> String {
    var s = error.components(separatedBy: .newlines).first ?? error
    s = s.replacingOccurrences(of: #"^\[?\d{3}\]?(:\s*|\s+)"#, with: "", options: .regularExpression)
    if let end = s.range(of: ". ") { s = String(s[..<end.lowerBound]) }
    s = s.replacingOccurrences(of: #"\s*\([^()]*\)\.?$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    return s.count > 60 ? String(s.prefix(59)) + "…" : s
}

/// A check status in words: "expired" → "login expired".
func phrase(_ test: String) -> String {
    ["expired": "login expired", "credits_exhausted": "out of credits", "error": "check failed"][test]
        ?? test.replacingOccurrences(of: "_", with: " ")
}

/// A quota window's short name, from its length or its name: "5h", "week" or "month".
func windowName(_ key: String, _ window: [String: Any]) -> String {
    switch Int(number(window["windowSeconds"]) ?? 0) {
    case 18_000: return "5h"
    case 604_800: return "week"
    default: break
    }
    let name = (key + " " + (text(window["displayName"]) ?? "")).lowercased()
    if ["5h", "5-hour", "5 hour", "session"].contains(where: name.contains) { return "5h" }
    if ["week", "7d"].contains(where: name.contains) { return "week" }
    if name.contains("month") { return "month" }
    return key
}

func money(_ n: Double, _ currency: String) -> String {
    let s = n == n.rounded() ? String(Int(n)) : String(format: "%.2f", n)
    return currency == "USD" ? "$" + s : "\(s) \(currency)"
}

/// A quota window of a connection, from GET /api/usage/provider-limits.
struct QuotaWindow {
    let name: String             // "5h", "week" or "month"
    let used: Int                // percent
    let reset: Date?
    let length: TimeInterval?    // the window's length, which the countdown bar is a share of
    let line: String             // for the tooltip
}

let windowLengths: [String: TimeInterval] = ["5h": 18_000, "week": 604_800, "month": 2_592_000]

/// A connection's quota windows, shortest first. A window whose reset time has passed counts
/// as unused, as in OmniRoute's own quota filter.
func quotaWindows(_ cache: [String: Any]?, now: Date) -> [QuotaWindow] {
    let order = ["5h": 0, "week": 1, "month": 2]
    let windows = (cache?["quotas"] as? [String: [String: Any]] ?? [:]).compactMap { key, window -> QuotaWindow? in
        guard window["unlimited"] as? Bool != true else { return nil }
        let name = windowName(key, window)
        let title = text(window["displayName"]) ?? key
        let reset = text(window["resetAt"]).flatMap(parseDate)
        let length = number(window["windowSeconds"]) ?? windowLengths[name]
        if let reset, reset < now {
            return QuotaWindow(name: name, used: 0, reset: nil, length: length, line: "\(title): reset at \(when(reset, now: now))")
        }
        let used: Int
        if let remaining = number(window["remainingPercentage"]) {
            used = Int((100 - remaining).rounded())
        } else if let u = number(window["used"]), let t = number(window["total"]), t > 0 {
            used = Int((u / t * 100).rounded())
        } else {
            return nil
        }
        var line = "\(title): \(used)% used"
        if let u = number(window["used"]), let t = number(window["total"]), let currency = text(window["currency"]) {
            line += " (\(money(u, currency)) of \(money(t, currency)))"
        }
        if let reset { line += ", resets \(dateTime.string(from: reset))" }
        return QuotaWindow(name: name, used: used, reset: reset, length: length, line: line)
    }
    return windows.sorted { (order[$0.name] ?? 9, $0.name) < (order[$1.name] ?? 9, $1.name) }
}

/// "45m", "4h 15m", "1d 14h", "6d".
func span(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded(.up)))
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 1_440 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
    return minutes % 1_440 / 60 == 0 ? "\(minutes / 1_440)d" : "\(minutes / 1_440)d \(minutes % 1_440 / 60)h"
}

/// A countdown bar of ten cells: the solid part is the share of the wait still to go.
func bar(_ fraction: Double) -> String {
    let full = min(10, max(fraction > 0 ? 1 : 0, Int((fraction * 10).rounded())))
    return String(repeating: "█", count: full) + String(repeating: "░", count: 10 - full)
}

/// A countdown line's cells: window, bar, time left, and when the quota is available again.
func countdown(_ name: String, until: Date, from start: Date, available: Bool, now: Date) -> [String] {
    let left = until.timeIntervalSince(now)
    return [name, bar(left / max(1, until.timeIntervalSince(start))), span(left),
            (available ? "available " : "resets ") + dateTime.string(from: until)]
}

// The bar is in SF Mono, which draws █ and ░ itself at one width; the system font falls back
// to two other fonts whose widths differ, so a bar's length changed with its fill.
let countdownColumns = [Column(font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)),
                        Column(font: .monospacedSystemFont(ofSize: 12, weight: .regular)),
                        Column(right: true, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)),
                        Column(font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))]

/// One connection's health now. GET /api/providers gives its switch, cooldown and last check;
/// `lastHour` (the health matrix, which lists only providers that were not healthy in the last
/// hour) gives its calls. OmniRoute's hourly check calls a model of its own, "connection-test",
/// so it can pass while every real call fails: those calls count here, the check does not.
func health(_ connection: [String: Any], lastHour: [String: [String: Any]], limits: [String: [String: Any]],
            now: Date) -> HealthRow {
    let provider = text(connection["provider"]) ?? "?"
    let label = connectionLabel(connection)
    let test = text(connection["testStatus"]) ?? "unknown"
    let checked = text(connection["lastTested"]).flatMap(parseDate)
    let until = text(connection["rateLimitedUntil"]).flatMap(parseDate).flatMap { $0 > now ? $0 : nil }
    let error = describe(connection["lastError"])
    let off = connection["isActive"] as? Bool == false

    let accounts = lastHour[provider]?["accounts"] as? [[String: Any]] ?? []
    let account = accounts.first { text($0["connectionId"]) == text(connection["id"]) }
    let models = (account?["models"] as? [[String: Any]] ?? [])
        .filter { text($0["model"]) != "connection-test" && (number($0["requests"]) ?? 0) > 0 }
    let count = { (model: [String: Any], key: String) in Int(number(model[key]) ?? 0) }
    let calls = models.reduce(0) { $0 + count($1, "requests") }
    let failed = calls - models.reduce(0) { $0 + count($1, "successes") }
    let newest = models.filter { text($0["lastErrorAt"]) != nil }
        .max { (text($0["lastErrorAt"]) ?? "") < (text($1["lastErrorAt"]) ?? "") }
    // Quota, refreshed by OmniRoute every 10 min; an hour-old cache is left out of the line.
    let cache = limits[text(connection["id"]) ?? ""]
    let fetched = text(cache?["fetchedAt"]).flatMap(parseDate)
    let windows = quotaWindows(cache, now: now)
    let fresh = fetched.map { now.timeIntervalSince($0) < 3_600 } ?? false
    let quota = fresh && !windows.isEmpty ? windows.map { "\($0.name) \($0.used)%" }.joined(separator: " · ") + " used" : ""
    // Countdown lines: each window in use, until it resets (a used-up one is available again
    // then), and a cooldown that no used-up window explains. OmniRoute skips a used-up window.
    let exhausted = fresh ? windows.filter { $0.used >= 100 && $0.reset != nil } : []
    var countdowns: [[String]] = []
    if let until, exhausted.isEmpty {
        let start = text(connection["lastErrorAt"]).flatMap(parseDate) ?? until.addingTimeInterval(-3_600)
        countdowns.append(countdown("cooldown", until: until, from: start, available: true, now: now))
    }
    for window in fresh ? windows : [] where window.used > 0 {
        guard let reset = window.reset else { continue }
        countdowns.append(countdown(window.name, until: reset, from: reset.addingTimeInterval(-(window.length ?? reset.timeIntervalSince(now))),
                                    available: window.used >= 100, now: now))
    }

    var tooltip = [label == provider ? provider : "\(provider) · \(label)"]
    tooltip.append((test == "active" ? "Hourly check passed" : "Hourly check: \(phrase(test))")
                   + (checked.map { ", \(when($0, now: now))" } ?? ""))
    if off { tooltip.append("Switched off in OmniRoute") }
    if let until { tooltip.append("Cooling down until \(dateTime.string(from: until))") }
    if let error { tooltip.append("Error: \(error)") }
    if windows.isEmpty {
        tooltip.append("No quota data in OmniRoute")
    } else {
        let about = [text(cache?["plan"]).map { "\($0) plan" }, fetched.map { "as of \(when($0, now: now))" }].compactMap { $0 }
        tooltip.append("Quota" + (about.isEmpty ? "" : " (\(about.joined(separator: ", ")))") + ":")
        tooltip += windows.map { "  " + $0.line }
    }
    if calls > 0 {
        tooltip.append("Last hour: \(calls) calls, \(failed) failed")
        for model in models {
            let n = count(model, "requests"), bad = n - count(model, "successes")
            let at = text(model["lastErrorAt"]).flatMap(parseDate).map { when($0, now: now) }
            let last = bad > 0 ? number(model["lastErrorStatus"]).map { ", last \(Int($0))" + (at.map { " at \($0)" } ?? "") } ?? "" : ""
            tooltip.append("  \(text(model["model"]) ?? "?"): \(bad) of \(n) failed\(last)")
        }
    }
    let row = { (health: Health, status: String, detail: String) in
        HealthRow(label: label, health: health, status: status, quota: quota, detail: detail, countdowns: countdowns,
                  tooltip: tooltip.joined(separator: "\n"), raw: connection)
    }
    let because = error.map { " · " + gist($0) } ?? ""
    let broken = !["active", "unavailable", "degraded", "unknown"].contains(test)
    if broken { return row(.broken, phrase(test), phrase(test) + because) }  // even when switched off
    if off { return row(.off, "off", "switched off") }
    if until != nil { return row(.cooldown, "cooling down", "cooling down" + because) }
    if !exhausted.isEmpty {
        let names = exhausted.map(\.name).joined(separator: " and ") + " quota used up"
        return row(.cooldown, names, names)
    }
    if test != "active" { return row(.failing, phrase(test), phrase(test) + because) }
    if failed > 0 {
        let what = newest.flatMap { model in
            number(model["lastErrorStatus"]).map { " · \(Int($0)) on \(text(model["model"]) ?? "?")" }
        } ?? ""
        return failed == calls
            ? row(.failing, "failing", "all \(calls) calls failed in the last hour" + what)
            : row(.errors, "\(failed) of \(calls) calls failed", "\(failed) of \(calls) calls failed in the last hour" + what)
    }
    return row(.ok, "ok", "")
}

/// The Providers block: the `providers` entries in their order, or every active connection.
/// An entry that picks several connections shows the worst of them.
func healthRows(_ connections: [[String: Any]], _ lastHour: [String: [String: Any]], _ limits: [String: [String: Any]],
                now: Date) -> [HealthRow] {
    guard !connections.isEmpty else { return [] }
    let entries = watched.isEmpty
        ? connections.filter { $0["isActive"] as? Bool != false }.map { (label: connectionLabel($0), picks: [$0]) }
        : watched.map { (label: $0.label, picks: pick($0.match, from: connections)) }
    return entries.map { entry in
        let rows = entry.picks.map { health($0, lastHour: lastHour, limits: limits, now: now) }
        guard let worst = rows.max(by: { $0.health.rawValue < $1.health.rawValue }) else {
            return HealthRow(label: entry.label, health: .broken, status: "missing", quota: "", detail: "no connection matches",
                             countdowns: [],
                             tooltip: "No connection's provider id, name or node name matches this providers entry",
                             raw: [String: Any]())
        }
        return HealthRow(label: entry.label, health: worst.health, status: worst.status, quota: worst.quota, detail: worst.detail,
                         countdowns: worst.countdowns,
                         tooltip: rows.map(\.tooltip).joined(separator: "\n\n") + "\nClick to copy the JSON",
                         raw: entry.picks.count == 1 ? entry.picks[0] : entry.picks)
    }
}

let providerColumns = [Column(font: .systemFont(ofSize: 13, weight: .medium)), Column(), Column(font: .systemFont(ofSize: 13))]

let hourMinute: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()
let weekdayHourMinute: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE HH:mm"
    return f
}()
let dateTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM HH:mm"
    return f
}()
let dateHourMinute: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM HH:mm"
    return f
}()

/// "14:05" today, "Tue 03:00" within six days, "15 Nov 01:48" further away.
func when(_ date: Date, now: Date) -> String {
    if Calendar.current.isDate(date, inSameDayAs: now) { return hourMinute.string(from: date) }
    return (abs(date.timeIntervalSince(now)) < 6 * 86_400 ? weekdayHourMinute : dateHourMinute).string(from: date)
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
    return try await parseCalls(getJSON(url, token: token))
}

func parseCalls(_ json: Any) -> [Call] {
    let rows = json as? [[String: Any]]
        ?? (json as? [String: Any])?.values.compactMap { $0 as? [[String: Any]] }.first
        ?? []
    // The server's order is not strictly newest-first, so sort here.
    let newestFirst: (Call, Call) -> Bool = { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    return collapse(rows.map { Call(raw: $0) }.sorted(by: newestFirst)).sorted(by: newestFirst)
}

/// Another OmniRoute API on the same server: <url> with /usage/call-logs swapped for `path`.
func apiURL(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
    guard var parts = URLComponents(string: endpoint) else { throw Failure(description: "Bad URL: \(endpoint)") }
    let suffix = "/usage/call-logs"
    parts.path = parts.path.hasSuffix(suffix) ? String(parts.path.dropLast(suffix.count)) + path : "/api" + path
    parts.queryItems = query.isEmpty ? nil : query
    guard let url = parts.url else { throw Failure(description: "Bad URL: \(endpoint)") }
    return url
}

/// The combo chains, from GET /api/combos.
func fetchChains(token: String) async throws -> Chains {
    try await parseChains(getJSON(apiURL("/combos"), token: token))
}

typealias HealthData = (connections: [[String: Any]], lastHour: [String: [String: Any]], limits: [String: [String: Any]])

/// The provider connections (GET /api/providers, ~11 KB); by provider id, the providers that
/// were not healthy in the last hour (the health matrix without healthy ones, ~30 KB; with them
/// it is ~180 KB); and by connection id, the quota caches (GET /api/usage/provider-limits, ~4 KB).
func fetchHealth(token: String) async throws -> HealthData {
    let list = try await getJSON(apiURL("/providers"), token: token)
    let matrix = try await getJSON(apiURL("/providers/health-matrix", [URLQueryItem(name: "range", value: "1h"),
                                                                       URLQueryItem(name: "includeHealthy", value: "false")]),
                                   token: token)
    var lastHour: [String: [String: Any]] = [:]
    for provider in (matrix as? [String: Any])?["providers"] as? [[String: Any]] ?? [] {
        if let id = text(provider["provider"]) { lastHour[id] = provider }
    }
    let limits = try? await getJSON(apiURL("/usage/provider-limits"), token: token)
    return ((list as? [String: Any])?["connections"] as? [[String: Any]] ?? [], lastHour,
            (limits as? [String: Any])?["caches"] as? [String: [String: Any]] ?? [:])
}

/// GET `url` with the Bearer token and decode the JSON body.
func getJSON(_ url: URL, token: String) async throws -> Any {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
        let auth = code == 401 || code == 403
        throw Failure(description: auth ? "HTTP \(code): token rejected" : "HTTP \(code)", auth: auth)
    }
    return try JSONSerialization.jsonObject(with: data)
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
    private var chains: Chains = [:]
    private var chainsRead: Date?
    private var chainProblem: String?
    private var connections: [[String: Any]] = []
    private var lastHour: [String: [String: Any]] = [:]
    private var limits: [String: [String: Any]] = [:]
    private var healthRead: Date?
    private var healthProblem: String?

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
                return
            } catch {
                problem = error.localizedDescription
                return
            }
            // Chains rarely change: re-read them every 5 min, or after 1 min if a call names an unknown step.
            let unknown = calls.contains { $0.stepId != nil && $0.step(in: chains) == nil }
            if Date().timeIntervalSince(chainsRead ?? .distantPast) > (unknown ? 60 : 300) {
                chainsRead = Date()
                do {
                    chains = try await fetchChains(token: token)
                    chainProblem = nil
                } catch {
                    chainProblem = message(error)
                }
            }
            // Provider health: once a minute (~40 KB).
            if Date().timeIntervalSince(healthRead ?? .distantPast) > 60 {
                healthRead = Date()
                do {
                    let health = try await fetchHealth(token: token)
                    connections = health.connections
                    lastHour = health.lastHour
                    limits = health.limits
                    healthProblem = nil
                } catch {
                    healthProblem = message(error)
                }
            }
        }
    }

    private func render() {
        let now = Date()
        let running = calls.filter(\.active).count
        let failures = calls.filter { $0.failed && now.timeIntervalSince($0.date ?? .distantPast) < 300 }.count
        let providers = healthRows(connections, lastHour, limits, now: now)
        let sick = providers.filter { $0.health.rawValue >= Health.errors.rawValue }.map { "\($0.label) \($0.status)" }
        let names = providerNames(connections)

        if let button = item.button {
            let image = NSImage(systemSymbolName: problem == nil ? "arrow.triangle.branch" : "exclamationmark.triangle",
                                accessibilityDescription: "OmniRoute calls")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = running > 0 ? "\(running)" : ""
            button.toolTip = problem ?? "OmniRoute: \(running) running, \(failures) failed in the last 5 min"
                + (sick.isEmpty ? "" : "\nNot ok: " + sick.joined(separator: ", "))
        }

        // No colours: a coloured title keeps its colour under the hover highlight, but the
        // menu inverts template symbols and plain text.
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Recent calls"))
        let shown = Array(calls.prefix(rowLimit))
        for (call, line) in zip(shown, tabbed(shown.map { cells($0, chains, names, now: now) }, callColumns)) {
            menu.addItem(row(line, symbol: call.active ? "hourglass" : call.failed ? "exclamationmark.triangle" : nil,
                             tooltip: details(call, chains, names), json: call.raw))
        }
        if calls.isEmpty { menu.addItem(note(problem ?? "No calls yet")) }
        menu.addItem(.separator())
        if !providers.isEmpty || healthProblem != nil {
            menu.addItem(.sectionHeader(title: "Providers"))
            var countdowns = tabbed(providers.flatMap(\.countdowns), countdownColumns).makeIterator()
            for (health, line) in zip(providers, tabbed(providers.map { [$0.label, $0.quota, $0.detail] }, providerColumns)) {
                menu.addItem(row(line, symbol: health.health.symbol, tooltip: health.tooltip, json: health.raw))
                for _ in health.countdowns {
                    guard let countdown = countdowns.next() else { break }
                    // Disabled, so never highlighted: the one place a text colour is safe. (An attributed
                    // title is not dimmed by itself.)
                    let item = NSMenuItem(title: countdown.string, action: nil, keyEquivalent: "")
                    let grey = NSMutableAttributedString(attributedString: countdown)
                    grey.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: grey.length))
                    item.attributedTitle = grey
                    item.indentationLevel = 1
                    menu.addItem(item)
                }
            }
            if let healthProblem { menu.addItem(note("No provider health: " + healthProblem)) }
            menu.addItem(.separator())
        }
        if let problem, !calls.isEmpty { menu.addItem(note("⚠︎ " + problem)) }
        if let chainProblem, problem == nil { menu.addItem(note("No chain positions: " + chainProblem)) }
        menu.addItem(note(updated.map { "Updated \(clock.string(from: $0)) · \(endpointHost)" } ?? "Not updated yet"))
        let refresh = menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(withTitle: "Quit OmniBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
    }

    /// A clickable line that copies `json`, with an optional SF Symbol in the image column.
    private func row(_ line: NSAttributedString, symbol: String?, tooltip: String, json: Any) -> NSMenuItem {
        let row = NSMenuItem(title: line.string, action: #selector(copyJSON(_:)), keyEquivalent: "")
        row.target = self
        row.attributedTitle = line
        row.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        row.toolTip = tooltip
        row.representedObject = json
        return row
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
            let calls = try await fetchCalls(token: token)
            var chains: Chains = [:]
            do { chains = try await fetchChains(token: token) } catch { fputs("No chain positions: \(message(error))\n", stderr) }
            var health: HealthData = ([], [:], [:])
            do { health = try await fetchHealth(token: token) } catch { fputs("No provider health: \(message(error))\n", stderr) }
            let names = providerNames(health.connections)
            padded(calls.prefix(rowLimit).map { cells($0, chains, names) }, callColumns).forEach { print($0) }
            let rows = healthRows(health.connections, health.lastHour, health.limits, now: Date())
            if !rows.isEmpty { print("") }
            let lines = padded(rows.map { [$0.health.glyph, $0.label, $0.quota, $0.detail] },
                               [Column(), Column(tight: true), Column(), Column()])
            var countdowns = padded(rows.flatMap(\.countdowns), countdownColumns).makeIterator()
            for (row, line) in zip(rows, lines) {
                print(line)
                for _ in row.countdowns { if let countdown = countdowns.next() { print("    " + countdown) } }
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
