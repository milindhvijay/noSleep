// PowerState.swift

import Foundation
import IOKit
import IOKit.ps

struct PowerState {
    let isOnAC: Bool
    let isLidClosed: Bool
    let batteryPercent: Int?
}

private let rootDomainName = "IOPMrootDomain"
private let clamshellStateKey = "AppleClamshellState" as CFString
private var gRootDomainService: io_service_t = 0

func getRootDomainService() -> io_service_t {
    if gRootDomainService == 0 {
        gRootDomainService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(rootDomainName))
    }

    return gRootDomainService
}

private func currentBatteryPercent(from snapshot: CFTypeRef) -> Int? {
    let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
    guard let source = sources.first,
          let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] else {
        return nil
    }

    return desc[kIOPSCurrentCapacityKey] as? Int
}

private func currentLidClosed() -> Bool {
    let service = getRootDomainService()
    guard service != 0 else { return false }

    guard let prop = IORegistryEntryCreateCFProperty(service, clamshellStateKey, kCFAllocatorDefault, 0) else {
        return false
    }

    return prop.takeRetainedValue() as? Bool ?? false
}

func releasePowerStateResources() {
    if gRootDomainService != 0 {
        IOObjectRelease(gRootDomainService)
        gRootDomainService = 0
    }
}

func getCurrentPowerState(includeBattery: Bool = true) -> PowerState {
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()

    let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
    let isOnAC = type == kIOPSACPowerValue as String

    return PowerState(
        isOnAC: isOnAC,
        isLidClosed: currentLidClosed(),
        batteryPercent: includeBattery ? currentBatteryPercent(from: snapshot) : nil
    )
}
