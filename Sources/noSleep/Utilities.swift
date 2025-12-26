// Utilities.swift

import Foundation

@discardableResult
func shell(_ command: String) -> (output: String, status: Int32) {
    autoreleasepool {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", command]
        task.launch()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, task.terminationStatus)
    }
}

func getUID() -> String {
    return "\(getuid())"
}

// osascript because UNUserNotificationCenter requires bundled app
func notify(_ message: String, subtitle: String? = nil, sound: String = "Glass") {
    let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
    var script = "display notification \"\(escapedMessage)\" with title \"noSleep\""
    
    if let sub = subtitle {
        let escapedSub = sub.replacingOccurrences(of: "\"", with: "\\\"")
        script += " subtitle \"\(escapedSub)\""
    }
    script += " sound name \"\(sound)\""
    
    shell("osascript -e '\(script)'")
}

func notifyPreventing() {
    notify("Sleep Prevention Active", subtitle: "AC Power + Lid Closed", sound: "Hero")
}

func notifyRestored(reason: String) {
    notify("Normal Behaviour Restored", subtitle: reason, sound: "Glass")
}
