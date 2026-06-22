// SleepPreventer.swift

import Foundation
import IOKit.pwr_mgt

private let sleepAssertionType = kIOPMAssertionTypePreventSystemSleep as CFString
private let sleepAssertionName = "noSleep - lid closed on AC power" as CFString

class SleepPreventer {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func preventSleep() {
        guard !isActive else { return }
        let result = IOPMAssertionCreateWithName(
            sleepAssertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            sleepAssertionName,
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
