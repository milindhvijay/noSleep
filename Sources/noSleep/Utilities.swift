// Utilities.swift

import Foundation

func getUID() -> String {
    return "\(getuid())"
}

// We use osascript because UNUserNotificationCenter requires a bundled app.
// This keeps the project a single small binary, but we need to be careful not to spam process launches.
func notify(_ message: String, subtitle: String? = nil, sound: String = "Glass") {
    enum NotifyState {
        static let queue = DispatchQueue(label: "com.noSleep.notify")
        static var pending: DispatchWorkItem?
        static var lastFireUptimeNanos: UInt64 = 0
        // Coalesce bursts: keep the latest message, then send at most once per interval.
        static var nextMessage: String = ""
        static var nextSubtitle: String?
        static var nextSound: String = "Glass"
        static let minIntervalNanos: UInt64 = 2_000_000_000
    }

    func escapeAppleScriptString(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    NotifyState.queue.async {
        NotifyState.nextMessage = message
        NotifyState.nextSubtitle = subtitle
        NotifyState.nextSound = sound

        NotifyState.pending?.cancel()

        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let last = NotifyState.lastFireUptimeNanos
        let elapsed = last == 0 ? NotifyState.minIntervalNanos : (nowNanos &- last)
        let remaining = elapsed >= NotifyState.minIntervalNanos ? 0 : (NotifyState.minIntervalNanos - elapsed)

        var work: DispatchWorkItem!
        work = DispatchWorkItem {
            if work.isCancelled { return }

            let msg = NotifyState.nextMessage
            let sub = NotifyState.nextSubtitle
            let snd = NotifyState.nextSound

            let escapedMessage = escapeAppleScriptString(msg)
            var script = "display notification \"\(escapedMessage)\" with title \"noSleep\""
            if let sub {
                let escapedSub = escapeAppleScriptString(sub)
                script += " subtitle \"\(escapedSub)\""
            }
            script += " sound name \"\(escapeAppleScriptString(snd))\""

            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            // We don't need output; avoiding pipes keeps allocations down in long-running daemons.
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                // ignore
            }

            NotifyState.lastFireUptimeNanos = DispatchTime.now().uptimeNanoseconds
        }

        NotifyState.pending = work

        if remaining == 0 {
            NotifyState.queue.async(execute: work)
        } else {
            NotifyState.queue.asyncAfter(deadline: .now() + .nanoseconds(Int(remaining)), execute: work)
        }
    }
}

func notifyPreventing() {
    notify("Sleep Prevention Active", subtitle: "AC Power + Lid Closed", sound: "Hero")
}

func notifyRestored(reason: String) {
    notify("Normal Behaviour Restored", subtitle: reason, sound: "Glass")
}
