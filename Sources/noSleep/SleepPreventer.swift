// SleepPreventer.swift

import Foundation
import IOKit.pwr_mgt

// Cache the CFString to avoid repeated bridging.
private let kAssertionType: CFString = kIOPMAssertionTypePreventSystemSleep as CFString
private let kAssertionName: CFString = "noSleep - lid closed on AC power" as CFString

struct SleepPreventer {
    // IOKit returns a handle we must keep around to release later.
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    @inline(__always)
    mutating func preventSleep() {
        guard !isActive else { return }
        // Keep the assertion message stable; it shows up in pmset/Activity Monitor power assertions.
        let result = IOPMAssertionCreateWithName(
            kAssertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            kAssertionName,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isActive = true
        }
    }

    @inline(__always)
    mutating func allowSleep() {
        guard isActive else { return }
        // Releasing is idempotent only if we guard on isActive + reset the ID.
        IOPMAssertionRelease(assertionID)
        isActive = false
        assertionID = 0
    }
}
