// PowerState.swift

import Foundation
import IOKit.ps

struct PowerState {
    let isOnAC: Bool
    let isLidClosed: Bool
    let batteryPercent: Int?
}

func isLidClosed() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    
    guard let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) else {
        return false
    }
    return prop.takeRetainedValue() as? Bool ?? false
}

func getCurrentPowerState() -> PowerState {
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
    
    let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
    let isOnAC = type == kIOPSACPowerValue as String
    
    var batteryPercent: Int?
    
    if let source = sources.first,
       let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
        batteryPercent = desc[kIOPSCurrentCapacityKey] as? Int
    }
    
    return PowerState(isOnAC: isOnAC, isLidClosed: isLidClosed(), batteryPercent: batteryPercent)
}
