import Foundation
import SwiftUI

/// Reads Claude Code's OAuth token from the Keychain and polls the same usage
/// endpoint Claude Code's `/usage` command uses.
@MainActor
final class UsageMonitor: ObservableObject {
    struct Limit: Identifiable {
        let id: String
        let label: String
        let percent: Int
        let resetsAt: Date?

        var tint: Color {
            percent >= 90 ? Palette.error : percent >= 70 ? Palette.needs : Palette.quiet
        }

        /// "2h 14m", "3d 4h": how long until this limit starts over.
        var resetShort: String? {
            guard let resetsAt else { return nil }
            let seconds = max(0, Int(resetsAt.timeIntervalSinceNow))
            let h = seconds / 3600, m = (seconds % 3600) / 60
            return seconds >= 86400 ? "\(seconds / 86400)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
        }

        var resetText: String {
            guard let resetsAt else { return label }
            let seconds = max(0, Int(resetsAt.timeIntervalSinceNow))
            let h = seconds / 3600, m = (seconds % 3600) / 60
            let when = seconds >= 86400 ? "\(seconds / 86400)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return "\(label) resets in \(when)"
        }
    }

    @Published private(set) var limits: [Limit] = []
    /// Short, for the sidebar; `detail` says what to do about it.
    @Published private(set) var error: String?
    @Published private(set) var detail: String?

    private var timer: Timer?

    /// Polls at the interval chosen in Settings (seconds); re-arms when it changes.
    func start() {
        let interval = UserDefaults.standard.double(forKey: Prefs.usageInterval)
        schedule(every: interval > 0 ? interval : 300)
        refresh()
    }

    func schedule(every seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task { await load() }
    }

    private enum Credentials { case token(String), notFound, noPlan, denied(String) }

    private func fail(_ short: String, _ long: String) {
        limits = []; error = short; detail = long
    }

    private func load() async {
        let token: String
        switch await Task.detached(operation: Self.readToken).value {
        case .token(let value): token = value
        case .notFound:
            return fail("No Claude login", "No Claude Code login found. Run claude, then /login with a Claude.ai plan. Click to check again.")
        case .noPlan:
            return fail("Needs a Claude.ai plan", "Claude Code is signed in with an API key. Usage limits exist only for Claude.ai plans (/login in claude). Click to check again.")
        case .denied(let message):
            return fail("Keychain access denied", "Couldn't read Claude Code's login from the Keychain: \(message). Click to try again and choose Allow when macOS asks.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // The endpoint is Claude Code's; it answers clients that say they are it.
        request.setValue("claude-code/omux", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Self.note("status \(status)\n" + String(decoding: data.prefix(2000), as: UTF8.self))
            guard status == 200 else {
                if status == 401 || status == 403 {
                    return fail("Claude login expired", "Claude Code's login no longer works. Run claude to sign in again, then click to check again.")
                }
                return fail("Usage unavailable", "Anthropic's usage endpoint answered \(status). Click to try again.")
            }
            guard let parsed = Self.parse(data) else {
                return fail("Usage unavailable", "Anthropic's usage endpoint answered in a form omux doesn't read. Click to try again.")
            }
            limits = parsed
            error = nil; detail = nil
        } catch {
            Self.note("error \(error)")
            fail("Usage unavailable", "Couldn't reach Anthropic's usage endpoint: \(error.localizedDescription). Click to try again.")
        }
    }

    /// The last answer, for finding out why limits don't show: the status and the body (which
    /// holds no credentials; the token is never written).
    nonisolated static func note(_ text: String) {
        let url = Persistence.directory.appendingPathComponent("usage-last.txt")
        try? (ISO8601DateFormatter().string(from: Date()) + "\n" + text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The endpoint has answered in two forms: a `limits` list, and one object per window
    /// (`five_hour`, `seven_day`, `seven_day_opus`…) with a `utilization` from 0 to 100. Both
    /// are read; anything else is nil.
    nonisolated static func parse(_ data: Data) -> [Limit]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func percent(_ value: Any?) -> Int? {
            if let n = value as? NSNumber { return Int(n.doubleValue.rounded()) }
            if let s = value as? String, let d = Double(s) { return Int(d.rounded()) }
            return nil
        }
        if let entries = json["limits"] as? [[String: Any]] {
            let limits = entries.compactMap { entry -> Limit? in
                guard let kind = entry["kind"] as? String, let value = percent(entry["percent"] ?? entry["utilization"]) else { return nil }
                let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let label = kind == "session" ? "5h" : kind == "weekly_all" ? "Week" : model ?? kind
                return Limit(id: kind + (model ?? ""), label: label, percent: value, resetsAt: date(entry["resets_at"]))
            }
            return limits.isEmpty ? nil : limits
        }
        let windows: [(key: String, label: String)] = [
            ("five_hour", "5h"), ("seven_day", "Week"), ("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet"),
        ]
        let limits = windows.compactMap { window -> Limit? in
            guard let entry = json[window.key] as? [String: Any], let value = percent(entry["utilization"] ?? entry["percent"]) else { return nil }
            return Limit(id: window.key, label: window.label, percent: value, resetsAt: date(entry["resets_at"]))
        }
        return limits.isEmpty ? nil : limits
    }

    /// ISO 8601 with or without fractional seconds, of any length ("…59.943648+00:00").
    nonisolated static func date(_ value: Any?) -> Date? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) { text.removeSubrange(range) }
        return plain.date(from: text)
    }

    /// Reads the token the way Claude Code stores it, through /usr/bin/security, which is
    /// already allowed on that Keychain item, so macOS never prompts for omux itself.
    private static func readToken() -> Credentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return .denied("couldn't run /usr/bin/security") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 44 || message.contains("could not be found") { return .notFound }
            return .denied(message.isEmpty ? "security exited with \(process.terminationStatus)" : message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .denied("the Keychain item isn't the expected JSON") }
        guard let oauth = json["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else { return .noPlan }
        return .token(token)
    }
}
