import Foundation

enum LowPowerMode {
    // Only invoked by the user's button. Uses an existing narrow permission if
    // available; this app never installs permissions or stores credentials.
    static func setEnabled(_ enabled: Bool, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let direct = Process()
            direct.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            direct.arguments = ["-n", "/usr/bin/pmset", "-a", "lowpowermode", enabled ? "1" : "0"]
            direct.standardInput = FileHandle.nullDevice
            direct.standardOutput = FileHandle.nullDevice
            direct.standardError = FileHandle.nullDevice
            do {
                try direct.run()
                direct.waitUntilExit()
                if direct.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
            } catch { /* Fall back to the normal macOS authentication dialog. */ }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"/usr/bin/pmset -a lowpowermode \(enabled ? 1 : 0)\" with administrator privileges"]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            let message: String?
            do {
                try process.run()
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let detail = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    message = nil
                } else if detail.contains("-128") {
                    message = "変更をキャンセルしました。"
                } else {
                    message = "変更できませんでした。バッテリー設定から変更してください。"
                }
            } catch {
                message = "認証画面を開けませんでした。バッテリー設定から変更してください。"
            }
            DispatchQueue.main.async { completion(message) }
        }
    }
}
