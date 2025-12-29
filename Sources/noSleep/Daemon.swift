// Daemon.swift

import Foundation
import IOKit
import IOKit.ps

private var gSleepPreventer = SleepPreventer()
private var gNotifyPort: IONotificationPortRef?
private var gNotifierObject: io_object_t = 0
// We retain the root domain service so lid reads are just a property lookup (no matching on every event).
// Must be released on shutdown.
private var gRootDomainService: io_service_t = 0
// Power source change notifications come in via a CFRunLoopSource.
private var gPowerSource: CFRunLoopSource?
private var gSetupComplete = false
// Coalescing timer: IOKit/IOPS callbacks often fire in bursts. We delay evaluation by a short
// interval and reset the timer on each event. This runs entirely on the main RunLoop—no extra threads.
// We reuse a single timer and reschedule it to avoid allocation churn.
private var gCoalesceTimer: CFRunLoopTimer!
private let kCoalesceIntervalSeconds: CFTimeInterval = 0.15
private let kDistantFuture: CFAbsoluteTime = CFAbsoluteTime.greatestFiniteMagnitude

private func createCoalesceTimer() {
    var context = CFRunLoopTimerContext()
    gCoalesceTimer = CFRunLoopTimerCreate(
        kCFAllocatorDefault,
        kDistantFuture,  // Start dormant
        kDistantFuture,  // No repeat
        0,
        0,
        { _, _ in
            // Move timer back to dormant state
            CFRunLoopTimerSetNextFireDate(gCoalesceTimer, kDistantFuture)
            evaluateAndApplyState()
        },
        &context
    )
    CFRunLoopAddTimer(CFRunLoopGetMain(), gCoalesceTimer, .defaultMode)
}

@inline(__always)
func handleStateChange() {
    guard gSetupComplete else { return }
    // Reschedule the existing timer—no allocation, just update fire date.
    CFRunLoopTimerSetNextFireDate(gCoalesceTimer, CFAbsoluteTimeGetCurrent() + kCoalesceIntervalSeconds)
}

@inline(__always)
private func readIsOnACPower() -> Bool {
    // Use the "providing power source type" fast path.
    // Avoids list/dictionary bridging, which is heavier and unnecessary for the daemon.
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
    return type == kIOPSACPowerValue as String
}

// Cache the CFString to avoid repeated bridging on every lid check.
private let kAppleClamshellStateKey: CFString = "AppleClamshellState" as CFString

@inline(__always)
private func readIsLidClosed() -> Bool {
    guard gRootDomainService != 0 else { return false }
    // IORegistryEntryCreateCFProperty follows "Create Rule": we own the returned CF object.
    guard let prop = IORegistryEntryCreateCFProperty(gRootDomainService, kAppleClamshellStateKey, kCFAllocatorDefault, 0) else {
        return false
    }
    return prop.takeRetainedValue() as? Bool ?? false
}

private func evaluateAndApplyState() {
    let isOnAC = readIsOnACPower()
    let isLidClosed = readIsLidClosed()

    let shouldPrevent = isOnAC && isLidClosed
    let wasActive = gSleepPreventer.isActive

    if shouldPrevent && !wasActive {
        gSleepPreventer.preventSleep()
        notifyPreventing()
    } else if !shouldPrevent && wasActive {
        gSleepPreventer.allowSleep()
        if !isOnAC {
            notifyRestored(reason: "Switched to battery")
        } else if !isLidClosed {
            notifyRestored(reason: "Lid opened")
        } else {
            notifyRestored(reason: "Ready to sleep")
        }
    }

}

func clamshellCallback(refCon: UnsafeMutableRawPointer?, service: io_service_t, messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
    // messageType varies across macOS versions, just check state.
    // No autoreleasepool needed: handleStateChange is lightweight and doesn't bridge CF objects.
    handleStateChange()
}

func setupClamshellNotification() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    gRootDomainService = service
    
    gNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
    guard let notifyPort = gNotifyPort else {
        IOObjectRelease(service)
        gRootDomainService = 0
        return false
    }
    
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

    if result != KERN_SUCCESS {
        IOObjectRelease(service)
        gRootDomainService = 0
    }

    return result == KERN_SUCCESS
}

func cleanupAndExit() {
    gSetupComplete = false

    // Invalidate the coalescing timer.
    if gCoalesceTimer != nil {
        CFRunLoopTimerInvalidate(gCoalesceTimer)
        gCoalesceTimer = nil
    }

    gSleepPreventer.allowSleep()
    
    if gNotifierObject != 0 {
        IOObjectRelease(gNotifierObject)
        gNotifierObject = 0
    }
    if let port = gNotifyPort {
        IONotificationPortDestroy(port)
        gNotifyPort = nil
    }

    if let source = gPowerSource {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        gPowerSource = nil
    }

    if gRootDomainService != 0 {
        IOObjectRelease(gRootDomainService)
        gRootDomainService = 0
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
    
    // Create the coalescing timer once (reused for all events).
    createCoalesceTimer()
    
    // Register notifications first, then do a single evaluation to establish the initial assertion state.
    _ = setupClamshellNotification()
    
    gPowerSource = IOPSNotificationCreateRunLoopSource({ _ in
        handleStateChange()
    }, nil).takeRetainedValue()

    if let source = gPowerSource {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }

    gSetupComplete = true
    
    // Initial evaluation runs synchronously on main thread—no dispatch needed.
    evaluateAndApplyState()
    // Run forever; SIGINT/SIGTERM will stop the run loop and we’ll clean up on the way out.
    CFRunLoopRun()
    
    cleanupAndExit()
}
