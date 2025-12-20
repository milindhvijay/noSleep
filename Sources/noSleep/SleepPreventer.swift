// SleepPreventer.swift

import Foundation
import IOKit.pwr_mgt

class SleepPreventer {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func preventSleep() {
        guard !isActive else { return }
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
        IOPMAssertionRelease(assertionID)
        isActive = false
        assertionID = 0
    }
}
