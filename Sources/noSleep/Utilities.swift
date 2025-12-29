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
        static var hasPendingUpdate: Bool = false
        static var inFlight: Process?
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
        NotifyState.hasPendingUpdate = true

        func attemptSend() {
            guard NotifyState.hasPendingUpdate else { return }
            guard NotifyState.inFlight == nil else { return }

            NotifyState.pending?.cancel()
            NotifyState.pending = nil

            let nowNanos = DispatchTime.now().uptimeNanoseconds
            let last = NotifyState.lastFireUptimeNanos
            let elapsed = last == 0 ? NotifyState.minIntervalNanos : (nowNanos &- last)
            let remaining = elapsed >= NotifyState.minIntervalNanos ? 0 : (NotifyState.minIntervalNanos - elapsed)

            if remaining > 0 {
                var work: DispatchWorkItem!
                work = DispatchWorkItem {
                    if work.isCancelled { return }
                    attemptSend()
                }
                NotifyState.pending = work
                NotifyState.queue.asyncAfter(deadline: .now() + .nanoseconds(Int(remaining)), execute: work)
                return
            }

            NotifyState.hasPendingUpdate = false

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
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            // We don't need output; avoiding pipes keeps allocations down in long-running daemons.
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice

            task.terminationHandler = { _ in
                NotifyState.queue.async {
                    NotifyState.inFlight = nil
                    attemptSend()
                }
            }

            do {
                try task.run()

                // Update the rate-limit at successful spawn time.
                // If osascript runs long, we still won't overlap spawns.
                NotifyState.lastFireUptimeNanos = DispatchTime.now().uptimeNanoseconds
                NotifyState.inFlight = task
            } catch {
                // Failed to spawn; clear in-flight and retry later (still coalesced).
                NotifyState.inFlight = nil
                NotifyState.hasPendingUpdate = true
                var work: DispatchWorkItem!
                work = DispatchWorkItem {
                    if work.isCancelled { return }
                    attemptSend()
                }
                NotifyState.pending = work
                NotifyState.queue.asyncAfter(deadline: .now() + .seconds(1), execute: work)
            }
        }

        NotifyState.pending?.cancel()
        NotifyState.pending = nil
        attemptSend()
    }
}

func notifyPreventing() {
    notify("Sleep Prevention Active", subtitle: "AC Power + Lid Closed", sound: "Hero")
}

func notifyRestored(reason: String) {
    notify("Normal Behaviour Restored", subtitle: reason, sound: "Glass")
}
