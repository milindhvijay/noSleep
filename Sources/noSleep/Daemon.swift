// Daemon.swift

import Foundation
import IOKit
import IOKit.ps

private var gSleepPreventer = SleepPreventer()
private var gPreviousState: PowerState?
private var gNotifyPort: IONotificationPortRef?
private var gNotifierObject: io_object_t = 0
private var gSetupComplete = false
private enum StateChangeGuard { static var processing = false }

func shouldPreventSleep(_ state: PowerState) -> Bool {
    return state.isOnAC && state.isLidClosed
}

func handleStateChange() {
    guard gSetupComplete else { return }

    autoreleasepool {
        // IOKit can fire rapid duplicate callbacks
        guard !StateChangeGuard.processing else { return }
        StateChangeGuard.processing = true
        defer { StateChangeGuard.processing = false }

        let current = getCurrentPowerState()

        guard gPreviousState != nil else {
            gPreviousState = current
            return
        }

        let shouldPrevent = shouldPreventSleep(current)
        let wasActive = gSleepPreventer.isActive

        if shouldPrevent && !wasActive {
            gSleepPreventer.preventSleep()
            notifyPreventing()
        } else if !shouldPrevent && wasActive {
            gSleepPreventer.allowSleep()
            if !current.isOnAC {
                notifyRestored(reason: "Switched to battery")
            } else if !current.isLidClosed {
                notifyRestored(reason: "Lid opened")
            } else {
                notifyRestored(reason: "Ready to sleep")
            }
        }

        gPreviousState = current
    }
}

func clamshellCallback(refCon: UnsafeMutableRawPointer?, service: io_service_t, messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
    // messageType varies across macOS versions, just check state
    autoreleasepool {
        handleStateChange()
    }
}

func setupClamshellNotification() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    
    gNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
    guard let notifyPort = gNotifyPort else { return false }
    
    let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
    
    let result = IOServiceAddInterestNotification(
        notifyPort,
        service,
        kIOGeneralInterest,
        clamshellCallback,
        nil,
        &gNotifierObject
    )
    
    return result == KERN_SUCCESS
}

func cleanupAndExit() {
    gSleepPreventer.allowSleep()
    
    if gNotifierObject != 0 {
        IOObjectRelease(gNotifierObject)
        gNotifierObject = 0
    }
    if let port = gNotifyPort {
        IONotificationPortDestroy(port)
        gNotifyPort = nil
    }
    
    releaseLock()
}

func runDaemon() {
    guard acquireLock() else {
        fputs("[ERROR] Another instance is already running\n", stderr)
        exit(1)
    }
    
    signal(SIGINT) { _ in
        CFRunLoopStop(CFRunLoopGetMain())
    }
    signal(SIGTERM) { _ in
        CFRunLoopStop(CFRunLoopGetMain())
    }
    
    // Init state before callbacks to avoid race
    let initialState = getCurrentPowerState()
    gPreviousState = initialState
    
    _ = setupClamshellNotification()
    
    if shouldPreventSleep(initialState) {
        gSleepPreventer.preventSleep()
        notifyPreventing()
    }
    
    let powerSource = IOPSNotificationCreateRunLoopSource({ _ in
        autoreleasepool {
            handleStateChange()
        }
    }, nil).takeRetainedValue()
    
    CFRunLoopAddSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
    
    gSetupComplete = true
    CFRunLoopRun()
    
    cleanupAndExit()
}
