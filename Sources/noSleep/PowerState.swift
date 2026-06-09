// PowerState.swift

import Foundation
import IOKit.ps

// Shared CFString keys -- internal so Daemon.swift can use the same instance.
let kAppleClamshellStateKey: CFString = "AppleClamshellState" as CFString
private let kCurrentCapacityKey: CFString = kIOPSCurrentCapacityKey as CFString
// Cached once to avoid bridging on every power-source check.
let kACPowerType: String = kIOPSACPowerValue as String

struct PowerState {
    let isOnAC: Bool
    let isLidClosed: Bool
    let batteryPercent: Int?
}

func isLidClosed() -> Bool {
    // This is used by short-lived CLI commands (status/doctor), so a simple lookup is fine.
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    
    // IORegistryEntryCreateCFProperty follows the Create Rule: we own the returned CF object.
    guard let prop = IORegistryEntryCreateCFProperty(service, kAppleClamshellStateKey, kCFAllocatorDefault, 0) else {
        return false
    }
    return prop.takeRetainedValue() as? Bool ?? false
}

func getCurrentPowerState() -> PowerState {
    // Keep the allocations predictable for CLI invocations.
    // The daemon uses a tighter fast-path; this is primarily for user-facing status output.
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()

    let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
    let isOnAC = type == kACPowerType

    var batteryPercent: Int?
    let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue()
    let count = CFArrayGetCount(sources)

    if count > 0, let rawSource = CFArrayGetValueAtIndex(sources, 0) {
        let source = unsafeBitCast(rawSource, to: CFTypeRef.self)

        if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() {
            if let rawValue = CFDictionaryGetValue(desc, Unmanaged.passUnretained(kCurrentCapacityKey).toOpaque()) {
                let value = unsafeBitCast(rawValue, to: CFTypeRef.self)
                if CFGetTypeID(value) == CFNumberGetTypeID() {
                    var percent: Int = 0
                    if CFNumberGetValue(unsafeBitCast(value, to: CFNumber.self), .intType, &percent) {
                        batteryPercent = percent
                    }
                }
            }
        }
    }

    return PowerState(isOnAC: isOnAC, isLidClosed: isLidClosed(), batteryPercent: batteryPercent)
}
