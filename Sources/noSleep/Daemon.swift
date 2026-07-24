// Daemon.swift

import Foundation
import IOKit
import IOKit.ps

private var gSleepPreventer = SleepPreventer()
private var gPreviousState: PowerState?
private var gNotifyPort: IONotificationPortRef?
private var gNotifierObject: io_object_t = 0
private var gSetupComplete = false
private var gDebounceTimer: CFRunLoopTimer?
private var gPowerSource: CFRunLoopSource?

private let debounceInterval: CFTimeInterval = 0.15
private let debounceIdleInterval: CFTimeInterval = 60 * 60 * 24 * 365

func shouldPreventSleep(_ state: PowerState) -> Bool {
    return state.isOnAC && state.isLidClosed
}

func applyStateChange() {
    let current = getCurrentPowerState(includeBattery: false)
    
    guard gPreviousState != nil else {
        gPreviousState = current
        return
    }
    
    let shouldPrevent = shouldPreventSleep(current)
    let wasActive = gSleepPreventer.isActive
    
    if shouldPrevent && !wasActive {
        gSleepPreventer.preventSleep()
    } else if !shouldPrevent && wasActive {
        gSleepPreventer.allowSleep()
    }
    
    gPreviousState = current
}

func handleStateChange() {
    guard gSetupComplete else { return }

    if let timer = gDebounceTimer {
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + debounceInterval)
    } else {
        applyStateChange()
    }
}

func clamshellCallback(refCon: UnsafeMutableRawPointer?, service: io_service_t, messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
    // messageType varies across macOS versions, just check state
    handleStateChange()
}

func setupClamshellNotification() -> Bool {
    let service = getRootDomainService()
    guard service != 0 else { return false }

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

func setupPowerSourceNotification() -> Bool {
    let powerSource = IOPSNotificationCreateRunLoopSource({ _ in
        handleStateChange()
    }, nil).takeRetainedValue()

    gPowerSource = powerSource
    CFRunLoopAddSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
    return true
}

func setupDebounceTimer() {
    var ctx = CFRunLoopTimerContext()
    gDebounceTimer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent() + debounceIdleInterval, debounceIdleInterval, 0, 0, { timer, _ in
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + debounceIdleInterval)
        applyStateChange()
    }, &ctx)

    if let timer = gDebounceTimer {
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
    }
}

func cleanupAndExit() {
    gSleepPreventer.allowSleep()

    if let timer = gDebounceTimer {
        CFRunLoopTimerInvalidate(timer)
        gDebounceTimer = nil
    }

    if let source = gPowerSource {
        CFRunLoopSourceInvalidate(source)
        gPowerSource = nil
    }
    
    if gNotifierObject != 0 {
        IOObjectRelease(gNotifierObject)
        gNotifierObject = 0
    }
    if let port = gNotifyPort {
        IONotificationPortDestroy(port)
        gNotifyPort = nil
    }

    releasePowerStateResources()
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
    let initialState = getCurrentPowerState(includeBattery: false)
    gPreviousState = initialState

    setupDebounceTimer()
    _ = setupClamshellNotification()
    _ = setupPowerSourceNotification()

    if shouldPreventSleep(initialState) {
        gSleepPreventer.preventSleep()
    }

    gSetupComplete = true
    CFRunLoopRun()
    
    cleanupAndExit()
}
