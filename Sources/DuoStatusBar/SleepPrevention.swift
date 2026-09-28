import Foundation

enum SleepPrevention {
    enum Status: Equatable {
        case checking
        case enabled
        case disabled
        case unavailable

        var isEnabled: Bool? {
            switch self {
            case .enabled: true
            case .disabled: false
            case .checking, .unavailable: nil
            }
        }

        var title: String {
            switch self {
            case .checking: "確認中"
            case .enabled: "オン"
            case .disabled: "オフ"
            case .unavailable: "不明"
            }
        }
    }

    struct ChangeResult {
        let status: Status
        let message: String?
    }

    static func parseStatus(from output: String, terminationStatus: Int32) -> Status {
        guard terminationStatus == 0 else { return .unavailable }

        let values = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Substring? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2, fields[0] == "SleepDisabled" else { return nil }
                return fields[1]
            }

        guard values.count == 1 else { return .unavailable }
        switch values[0] {
        case "1": return .enabled
        case "0": return .disabled
        default: return .unavailable
        }
    }

    static func readStatus() -> Status {
        let result = run("/usr/bin/pmset", arguments: ["-g"])
        guard let terminationStatus = result.terminationStatus else { return .unavailable }
        return parseStatus(from: result.output, terminationStatus: terminationStatus)
    }

    static func setEnabled(_ enabled: Bool, completion: @escaping (ChangeResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let commandMessage = runPrivilegedChange(enabled: enabled)
            let observedStatus = readStatus()
            let expectedStatus: Status = enabled ? .enabled : .disabled
            let message: String?

            if observedStatus == expectedStatus {
                message = nil
            } else if let commandMessage {
                message = commandMessage
            } else if observedStatus == .unavailable {
                message = "変更後の状態を読み取れません。オン／オフは確定できませんでした。"
            } else {
                message = "設定値が要求した状態と一致しません。現在値を表示しています。"
            }

            let result = ChangeResult(status: observedStatus, message: message)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runPrivilegedChange(enabled: Bool) -> String? {
        let value = enabled ? "1" : "0"
        let direct = run("/usr/bin/sudo", arguments: [
            "-n", "/usr/bin/pmset", "-a", "disablesleep", value
        ])
        if direct.terminationStatus == 0 { return nil }

        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges with prompt \"スリープ抑止設定を変更します。\""
        let authenticated = run("/usr/bin/osascript", arguments: ["-e", script])
        if authenticated.terminationStatus == 0 { return nil }

        let details = authenticated.output + authenticated.error
        if details.contains("-128") || details.localizedCaseInsensitiveContains("cancel") {
            return "管理者認証がキャンセルされました。現在の状態を再確認しました。"
        }
        return "管理者認証またはpmsetの実行に失敗しました。現在の状態を再確認しました。"
    }

    private struct ProcessResult {
        let terminationStatus: Int32?
        let output: String
        let error: String
    }

    private static func run(_ executable: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessResult(
                terminationStatus: process.terminationStatus,
                output: String(data: outputData, encoding: .utf8) ?? "",
                error: String(data: errorData, encoding: .utf8) ?? ""
            )
        } catch {
            return ProcessResult(terminationStatus: nil, output: "", error: error.localizedDescription)
        }
    }
}
