import Foundation

enum AIUsageProvider: String, CaseIterable, Identifiable {
    case codex
    case claude
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }
}

enum AIUsageDisplayMode: String, CaseIterable, Identifiable {
    case used
    case remaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .used: return "使用率"
        case .remaining: return "残り使用率"
        }
    }

    func percent(for usedPercent: Double) -> Int {
        let used = max(0, min(100, Int(usedPercent.rounded())))
        return self == .used ? used : 100 - used
    }

    static var selected: AIUsageDisplayMode {
        AIUsageDisplayMode(
            rawValue: UserDefaults.standard.string(forKey: "aiUsageDisplayMode") ?? "used"
        ) ?? .used
    }
}

struct AIUsageWindow: Equatable, Identifiable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    let resetDescription: String?

    func displayPercent(for mode: AIUsageDisplayMode) -> Int {
        mode.percent(for: usedPercent)
    }
}

struct AIUsageSnapshot: Equatable {
    let provider: AIUsageProvider
    let windows: [AIUsageWindow]
    let updatedAt: Date
    let error: String?

    var usedPercent: Int? {
        windows.map { Int($0.usedPercent.rounded()) }.max()
    }

    func displayPercent(for mode: AIUsageDisplayMode) -> Int? {
        usedPercent.map { mode.percent(for: Double($0)) }
    }
}

enum AIUsageError: Error {
    case cliNotFound
    case timedOut
    case commandFailed
    case invalidResponse

    var userMessage: String {
        switch self {
        case .cliNotFound:
            return "CodexBar CLIが見つかりません。CodexBarをインストールしてください。"
        case .timedOut:
            return "使用量の取得がタイムアウトしました。"
        case .commandFailed:
            return "使用量を取得できませんでした。CodexBar側のログイン状態を確認してください。"
        case .invalidResponse:
            return "CodexBarから認識できない形式の応答が返りました。"
        }
    }
}

enum CodexBarUsage {
    static func fetch(provider: AIUsageProvider, now: Date = Date()) throws -> AIUsageSnapshot {
        guard let executable = executableURL() else { throw AIUsageError.cliNotFound }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [
            "usage", "--provider", provider.rawValue, "--format", "json",
            "--json-only", "--no-credits", "--no-color"
        ]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AIUsageError.commandFailed
        }

        let timeout = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let timeoutLock = NSLock()
        var didTimeOut = false
        timeout.schedule(deadline: .now() + 45)
        timeout.setEventHandler {
            guard process.isRunning else { return }
            timeoutLock.lock()
            didTimeOut = true
            timeoutLock.unlock()
            process.terminate()
        }
        timeout.resume()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        timeoutLock.lock()
        let timedOut = didTimeOut
        timeoutLock.unlock()
        if timedOut { throw AIUsageError.timedOut }
        guard process.terminationStatus == 0 else {
            throw AIUsageError.commandFailed
        }
        return try parse(data, provider: provider, now: now)
    }

    static func parse(_ data: Data, provider: AIUsageProvider, now: Date = Date()) throws -> AIUsageSnapshot {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw AIUsageError.invalidResponse
        }

        let candidates: [[String: Any]]
        if let array = json as? [[String: Any]] {
            candidates = array
        } else if let root = json as? [String: Any],
                  let providers = root["providers"] as? [[String: Any]] {
            candidates = providers
        } else if let root = json as? [String: Any] {
            candidates = [root]
        } else {
            throw AIUsageError.invalidResponse
        }

        guard let payload = candidates.first(where: {
            ($0["provider"] as? String)?.lowercased() == provider.rawValue
                || ($0["id"] as? String)?.lowercased() == provider.rawValue
        }) ?? candidates.first else {
            throw AIUsageError.invalidResponse
        }

        if let providerID = (payload["provider"] as? String ?? payload["id"] as? String)?.lowercased(),
           providerID != provider.rawValue {
            throw AIUsageError.invalidResponse
        }

        let usage = payload["usage"] as? [String: Any]
            ?? payload["snapshot"] as? [String: Any]
            ?? payload
        let labels = (payload["rateWindowLabels"] as? [String: Any])
            ?? (usage["rateWindowLabels"] as? [String: Any])
            ?? [:]

        let keys = ["primary", "secondary", "tertiary"]
        let windows = keys.enumerated().compactMap { index, key -> AIUsageWindow? in
            guard let item = usage[key] as? [String: Any] else { return nil }
            let used = number(item["usedPercent"] ?? item["used_percent"])
                ?? number(item["remainingPercent"] ?? item["remaining_percent"]).map { 100 - $0 }
            guard let used, used.isFinite, (0...100).contains(used) else { return nil }

            let duration = number(item["windowMinutes"] ?? item["window_minutes"])
            let label = (labels[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? duration.map(windowTitle(minutes:))
                ?? fallbackTitle(provider: provider, index: index)
            let resetDescription = (item["resetDescription"] as? String)
                ?? (item["reset_description"] as? String)

            return AIUsageWindow(
                id: key,
                title: label,
                usedPercent: used,
                resetsAt: date(item["resetsAt"] ?? item["resets_at"] ?? item["resetAt"]),
                resetDescription: resetDescription
            )
        }

        guard !windows.isEmpty else { throw AIUsageError.invalidResponse }
        return AIUsageSnapshot(
            provider: provider,
            windows: windows,
            updatedAt: date(usage["updatedAt"] ?? usage["updated_at"]) ?? now,
            error: nil
        )
    }

    private static func executableURL() -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent("Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"),
            URL(fileURLWithPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codexbar"),
            URL(fileURLWithPath: "/usr/local/bin/codexbar"),
            home.appendingPathComponent(".local/bin/codexbar")
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codexbar")
            }
        }
        return candidates.first(where: { manager.isExecutableFile(atPath: $0.path) })
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            let timestamp = number > 1_000_000_000 ? number : number + 978_307_200
            return Date(timeIntervalSince1970: timestamp)
        }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = fractional.date(from: string) { return result }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    private static func windowTitle(minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        if rounded > 0, rounded % 1_440 == 0 { return "\(rounded / 1_440)日" }
        if rounded > 0, rounded % 60 == 0 { return "\(rounded / 60)時間" }
        return "\(rounded)分"
    }

    private static func fallbackTitle(provider: AIUsageProvider, index: Int) -> String {
        switch provider {
        case .codex: return index == 0 ? "使用枠" : "追加枠"
        case .claude, .gemini: return index == 0 ? "使用枠" : "追加枠"
        }
    }
}

final class AIUsageMonitor {
    static let refreshInterval: TimeInterval = 300

    private let fetchUsage: (AIUsageProvider) throws -> AIUsageSnapshot
    private(set) var snapshot: AIUsageSnapshot?
    var onUpdate: ((AIUsageSnapshot?) -> Void)?

    private var enabled = false
    private var provider: AIUsageProvider = .codex
    private var requestID = 0
    private var inFlight = false
    private var lastAttempt: Date?

    init(fetchUsage: @escaping (AIUsageProvider) throws -> AIUsageSnapshot = {
        try CodexBarUsage.fetch(provider: $0)
    }) {
        self.fetchUsage = fetchUsage
    }

    func configure(enabled: Bool, provider: AIUsageProvider) {
        let changed = self.enabled != enabled || self.provider != provider
        self.enabled = enabled
        self.provider = provider
        guard changed else { return }

        requestID += 1
        inFlight = false
        lastAttempt = nil
        snapshot = nil
        onUpdate?(nil)
        if enabled { fetchNow() }
    }

    func refreshIfNeeded(now: Date = Date()) {
        guard enabled, !inFlight else { return }
        guard lastAttempt.map({ now.timeIntervalSince($0) >= Self.refreshInterval }) ?? true else { return }
        fetchNow(now: now)
    }

    private func fetchNow(now: Date = Date()) {
        guard enabled, !inFlight else { return }
        requestID += 1
        let currentRequest = requestID
        let currentProvider = provider
        let fetchUsage = self.fetchUsage
        inFlight = true
        lastAttempt = now

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: AIUsageSnapshot
            do {
                result = try fetchUsage(currentProvider)
            } catch let error as AIUsageError {
                result = AIUsageSnapshot(provider: currentProvider, windows: [], updatedAt: Date(), error: error.userMessage)
            } catch {
                result = AIUsageSnapshot(provider: currentProvider, windows: [], updatedAt: Date(), error: AIUsageError.commandFailed.userMessage)
            }

            DispatchQueue.main.async {
                guard let self, self.enabled, self.requestID == currentRequest else { return }
                self.inFlight = false
                self.snapshot = result
                self.onUpdate?(result)
            }
        }
    }
}

func aiResetCountdown(until date: Date, now: Date = Date()) -> String {
    let seconds = max(0, date.timeIntervalSince(now))
    if seconds < 60 { return "1分以内" }
    if seconds < 3_600 { return "\(Int(ceil(seconds / 60)))分後" }
    if seconds < 86_400 { return "\(Int(ceil(seconds / 3_600)))時間後" }
    return "\(Int(ceil(seconds / 86_400)))日後"
}
