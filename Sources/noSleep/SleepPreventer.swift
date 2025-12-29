// SleepPreventer.swift

import Foundation
import IOKit.pwr_mgt

class SleepPreventer {
    // IOKit returns a handle we must keep around to release later.
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func preventSleep() {
        guard !isActive else { return }
        // Keep the assertion message stable; it shows up in pmset/Activity Monitor power assertions.
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "noSleep - lid closed on AC power" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isActive = true
        }
    }

    func allowSleep() {
        guard isActive else { return }
        // Releasing is idempotent only if we guard on isActive + reset the ID.
        IOPMAssertionRelease(assertionID)
        isActive = false
        assertionID = 0
    }
}
