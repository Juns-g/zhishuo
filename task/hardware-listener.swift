#!/usr/bin/env swift

/*
 DJI Mic 2 HID event listener for macOS.

 Build and run from the repository root:

   swiftc -framework IOKit -framework CoreFoundation \
     task/hardware-listener.swift -o task/hardware-listener
   ./task/hardware-listener

 Or run it directly without keeping a binary:

   swift task/hardware-listener.swift

 Optional modes:

   ./task/hardware-listener --dji-only   # reduce unrelated HID event noise
   ./task/hardware-listener --self-test  # test the executable without HID access

 Press Ctrl-C to stop. The program listens to input values from every HID
 device. Press each DJI Mic 2 transmitter button once and then hold it briefly.
 Relevant lines are marked "DJI CONSUMER" when all of these match:

   Vendor ID:   11427 (0x2CA3)
   Product ID:  16401 (0x4011)
   Usage Page:  12    (0x000C, Consumer Control)

 A normal button press generally emits a non-zero value followed by value=0
 on release. If the DJI receiver is listed at startup but no "DJI CONSUMER"
 line appears while pressing a transmitter button, macOS did not expose that
 press through this IOHIDManager input-value path during the test.

 If keyboard/consumer events are missing, grant Input Monitoring permission to
 the terminal application that launches this program, quit that application,
 reopen it, and test again.
 */

import CoreFoundation
import Foundation
import IOKit.hid

private let djiVendorID = 11_427
private let djiProductID = 16_401
private let consumerControlUsagePage = 0x0C

private func deviceProperty(_ device: IOHIDDevice, key: String) -> Any? {
    IOHIDDeviceGetProperty(device, key as CFString)
}

private func integerProperty(_ device: IOHIDDevice, key: String) -> Int? {
    (deviceProperty(device, key: key) as? NSNumber)?.intValue
}

private func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
    deviceProperty(device, key: key) as? String
}

private func deviceDescription(_ device: IOHIDDevice) -> String {
    let name = stringProperty(device, key: kIOHIDProductKey) ?? "Unknown HID Device"
    let vendorID = integerProperty(device, key: kIOHIDVendorIDKey) ?? -1
    let productID = integerProperty(device, key: kIOHIDProductIDKey) ?? -1
    return "device=\"\(name)\" vendorID=\(vendorID) productID=\(productID)"
}

private func isDJIReceiver(_ device: IOHIDDevice) -> Bool {
    integerProperty(device, key: kIOHIDVendorIDKey) == djiVendorID
        && integerProperty(device, key: kIOHIDProductIDKey) == djiProductID
}

private func consumerUsageName(_ usage: UInt32) -> String? {
    switch usage {
    case 0x00B0: return "Play"
    case 0x00B1: return "Pause"
    case 0x00B2: return "Record"
    case 0x00B7: return "Stop"
    case 0x00CD: return "Play/Pause"
    case 0x00E2: return "Mute"
    case 0x00E9: return "Volume Increment"
    case 0x00EA: return "Volume Decrement"
    default: return nil
    }
}

private func printUsage() {
    print(
        """
        Usage: hardware-listener [--dji-only] [--self-test] [--help]

          no option     Listen to input values from every matched HID device.
          --dji-only    Match only vendorID 11427 and productID 16401.
          --self-test   Validate target constants and usage-name formatting.
          --help        Show this help text.
        """
    )
}

private let deviceMatchedCallback: IOHIDDeviceCallback = { _, result, _, device in
    guard result == kIOReturnSuccess else { return }
    let marker = isDJIReceiver(device) ? "DJI TARGET" : "HID DEVICE"
    print("[\(marker) CONNECTED] \(deviceDescription(device))")
    fflush(stdout)
}

private let deviceRemovedCallback: IOHIDDeviceCallback = { _, _, _, device in
    let marker = isDJIReceiver(device) ? "DJI TARGET" : "HID DEVICE"
    print("[\(marker) REMOVED] \(deviceDescription(device))")
    fflush(stdout)
}

private let inputValueCallback: IOHIDValueCallback = { _, result, _, value in
    guard result == kIOReturnSuccess else { return }

    let element = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(element)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let integerValue = IOHIDValueGetIntegerValue(value)
    let isDJI = isDJIReceiver(device)
    let isDJIConsumer = isDJI && usagePage == consumerControlUsagePage

    let marker: String
    if isDJIConsumer {
        marker = "DJI CONSUMER"
    } else if isDJI {
        marker = "DJI OTHER"
    } else {
        marker = "HID EVENT"
    }

    var usageLabel = ""
    if usagePage == consumerControlUsagePage,
       let name = consumerUsageName(usage) {
        usageLabel = " usageName=\"\(name)\""
    }

    print(
        String(
            format: "[%@] %@ usagePage=0x%04X (%u) usage=0x%04X (%u)%@ value=%lld",
            marker,
            deviceDescription(device),
            usagePage,
            usagePage,
            usage,
            usage,
            usageLabel,
            integerValue
        )
    )
    fflush(stdout)
}

let arguments = Set(CommandLine.arguments.dropFirst())
let validArguments: Set<String> = ["--dji-only", "--self-test", "--help"]

if !arguments.isSubset(of: validArguments) {
    fputs("Unknown option.\n", stderr)
    printUsage()
    exit(EXIT_FAILURE)
}

if arguments.contains("--help") {
    printUsage()
    exit(EXIT_SUCCESS)
}

if arguments.contains("--self-test") {
    let passed = djiVendorID == 11_427
        && djiProductID == 16_401
        && consumerControlUsagePage == 12
        && consumerUsageName(0x00E2) == "Mute"
        && consumerUsageName(0x00E9) == "Volume Increment"
    guard passed else {
        fputs("SELF-TEST FAIL\n", stderr)
        exit(EXIT_FAILURE)
    }
    print("SELF-TEST PASS: DJI IDs, Consumer Control page, and usage labels are correct.")
    exit(EXIT_SUCCESS)
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

if arguments.contains("--dji-only") {
    let djiMatching: [String: Int] = [
        kIOHIDVendorIDKey: djiVendorID,
        kIOHIDProductIDKey: djiProductID,
    ]
    IOHIDManagerSetDeviceMatching(manager, djiMatching as CFDictionary)
} else {
    // A nil matching dictionary means all HID devices.
    IOHIDManagerSetDeviceMatching(manager, nil)
}

// A nil input-value dictionary means all input elements on matched devices.
IOHIDManagerSetInputValueMatching(manager, nil)
IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, nil)
IOHIDManagerRegisterInputValueCallback(manager, inputValueCallback, nil)
IOHIDManagerScheduleWithRunLoop(
    manager,
    CFRunLoopGetCurrent(),
    CFRunLoopMode.defaultMode.rawValue
)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    fputs(String(format: "Unable to open IOHIDManager (IOReturn 0x%08X).\n", openResult), stderr)
    if openResult == kIOReturnNotPermitted {
        fputs(
            "HID listen access is not permitted. Grant Input Monitoring permission "
                + "to the terminal application launching this tool, restart that application, "
                + "and run the command again.\n",
            stderr
        )
    }
    exit(EXIT_FAILURE)
}

print("Listening for HID input values from all devices. Press Ctrl-C to stop.")
print(
    "DJI target: vendorID=\(djiVendorID) (0x2CA3) "
        + "productID=\(djiProductID) (0x4011) usagePage=12 (0x000C)."
)
fflush(stdout)

CFRunLoopRun()
IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
