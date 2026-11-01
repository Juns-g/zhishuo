#!/usr/bin/env swift

/*
 DJI Mic 2 voice-triggered Doubao dictation for macOS.

 What it does
 ------------
 - Reads audio from "Wireless Mic Rx" by default (or another selected input).
 - Starts after sustained speech, then clicks Right Option once.
 - Clicks Right Option again after 0.8-1.2 seconds of silence or at the
   configured maximum recording time.
 - With --key-mode fn-hold, holds Fn for speech and releases it at stop
   instead (for existing WeType hold-Fn dictation); --auto-enter is rejected.
 - With --run-seconds SEC, exits through normal shutdown after SEC of listening.
 - The com.juns.zhishuo.trial app defaults to fn-hold and 60 seconds;
   the standalone CLI defaults to right-option-toggle and no run limit.
 - With --auto-enter, presses Return after a successful stop so the focused
   composer can send the completed transcription.
 - Uses an energy-based VAD with separate start/stop thresholds, hysteresis,
   sustained-speech confirmation, cooldown debounce, and a timeout failsafe.
 - Retains the recording state and retries if a stop event cannot be created.
 - If audio callbacks disappear for 1.5 seconds (for example, the receiver is
   unplugged), attempts a final stop and exits with an explicit error.

 Configure Doubao Input Method before running
 --------------------------------------------
 1. Open 豆包输入法设置 and find 语音输入 / 语音快捷键.
 2. Enable the global voice-input shortcut.
 3. Select "免按模式" (one click starts, the next click stops).
 4. Set that shortcut to "右 Option" / "右 ⌥". Do not use the hold-Fn mode.
 5. Select "Wireless Mic Rx" as Doubao/macOS microphone input as well; this
    tool selects its own input but cannot change which microphone Doubao uses.
 6. Switch macOS to 豆包输入法 and focus the text field where text should go.

 Build and run from the repository root
 --------------------------------------
   swiftc -framework AVFoundation -framework AVFAudio -framework CoreAudio \
     -framework AudioToolbox -framework CoreMedia -framework CoreGraphics \
     -framework ApplicationServices \
     task/vad-voice-trigger.swift -o task/vad-voice-trigger

   ./task/vad-voice-trigger --list-devices
   ./task/vad-voice-trigger --device "Wireless Mic Rx"
   ./task/vad-voice-trigger --device "Wireless Mic Rx" --auto-enter

 The default device is already "Wireless Mic Rx", so the final command may
 also be written as:

   ./task/vad-voice-trigger

 Useful diagnostics and tuning
 -----------------------------
   ./task/vad-voice-trigger --self-test
   ./task/vad-voice-trigger --dry-run --device "Wireless Mic Rx"
   ./task/vad-voice-trigger --dry-run --simulate-vad
   ./task/vad-voice-trigger --threshold-db -42 --silence-ms 1000
   ./task/vad-voice-trigger --default-input

 In --dry-run mode, VAD transitions are printed but no keyboard events are
 posted. Press Control-C to stop. If room noise starts dictation, raise the
 threshold (for example, from -42 to -36). If normal speech is missed, lower
 it. Keep --silence-ms between 800 and 1200 as required by this workflow.
 Use --dry-run --simulate-vad for a hardware-independent start-to-stop check.
 --simulate-vad uses synthetic time and exits on its simulated silence;
 --run-seconds bounds live listening, not this offline simulation.

 Permissions
 -----------
 - Microphone: allow the Terminal (or other launcher) that runs this tool in
   System Settings > Privacy & Security > Microphone.
 - Accessibility: allow that launcher in System Settings > Privacy & Security
   > Accessibility so it can post the Right Option event.
 After changing either permission, quit and reopen the launcher before retrying.

 Keyboard implementation note
 ----------------------------
 Swift imports CGEventCreateKeyboardEvent as
 CGEvent(keyboardEventSource:virtualKey:keyDown:). The key code below is 61,
 the macOS virtual key code for Right Option; Return uses key code 36. Right
 Option carries the Option modifier flag, while Return is posted without
 modifiers. Both use paired key-down/key-up events on the HID event tap.
 */

import ApplicationServices
import AudioToolbox
import AVFAudio
import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import Darwin
import Foundation

private let defaultDJIDeviceName = "Wireless Mic Rx"
private let rightOptionKeyCode: CGKeyCode = 61
private let fnKeyCode: CGKeyCode = 63
private let returnKeyCode: CGKeyCode = 36
private let defaultAutoEnterDelayMilliseconds = 1_200.0
private let minimumSilenceMilliseconds = 800.0
private let maximumSilenceMilliseconds = 1_200.0
private let audioWatchdogSeconds = 1.5
private let stopRetrySeconds = 0.25
private let isTrialApp = Bundle.main.bundleIdentifier == "com.juns.zhishuo.trial"

private struct UserError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private enum DeviceSelection {
    case named(String)
    case systemDefault
}

private enum KeyMode: String {
    case fnHold = "fn-hold"
    case rightOptionToggle = "right-option-toggle"
}

private struct Configuration {
    var deviceSelection: DeviceSelection = .named(defaultDJIDeviceName)
    var startThresholdDB = -40.0
    var stopThresholdDB = -46.0
    var startMilliseconds = 200.0
    var silenceMilliseconds = 1_000.0
    var cooldownMilliseconds = 700.0
    var maxSessionSeconds = 120.0
    var runSeconds: Double? = isTrialApp ? 60 : nil
    var keyMode: KeyMode = isTrialApp ? .fnHold : .rightOptionToggle
    var dryRun = false
    var autoEnter = false
    var autoEnterDelayMilliseconds = defaultAutoEnterDelayMilliseconds
    var listDevices = false
    var selfTest = false
    var simulateVAD = false
    var verbose = false
    var showHelp = false
}

private func printUsage() {
    let defaults = Configuration()
    let runLimit = defaults.runSeconds.map { "\(Int($0)) s" } ?? "no limit"
    print(
        """
        Usage: vad-voice-trigger [options]

          --device NAME         Use a named input device (default: "Wireless Mic Rx").
          --default-input       Use the current macOS default input device.
          --list-devices        List input devices and exit.
          --threshold-db DB     Speech-start threshold in dBFS (default: -40).
          --stop-threshold-db DB
                                Silence threshold in dBFS (default: -46).
          --start-ms MS         Required sustained speech (default: 200 ms).
          --silence-ms MS       Silence before stopping, 800-1200 (default: 1000 ms).
          --cooldown-ms MS      Post-stop debounce window (default: 700 ms).
          --max-seconds SEC     Failsafe recording timeout (default: 120 s).
          --run-seconds SEC|unlimited
                                Positive listening seconds, or unlimited (default: \(runLimit)).
          --key-mode MODE       fn-hold or right-option-toggle (default: \(defaults.keyMode.rawValue)).
          --dry-run             Print VAD actions without sending keyboard events.
          --auto-enter          Press Return after stop (default: off; incompatible with fn-hold).
          --auto-enter-delay-ms MS
                                Wait before Return (default: 1200 ms).
          --verbose             Print periodic [LEVEL] dBFS meter lines (default: off).
          --simulate-vad        With --dry-run, simulate speech then silence and exit.
          --self-test           Test VAD transitions without audio or permissions.
          --help                Show this help.
        """
    )
}

private func parseDouble(_ value: String, option: String) throws -> Double {
    guard let number = Double(value), number.isFinite else {
        throw UserError("\(option) requires a finite number; got \"\(value)\".")
    }
    return number
}

private func parseArguments(_ arguments: [String]) throws -> Configuration {
    var configuration = Configuration()
    var index = 0

    func requiredValue(after option: String) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw UserError("\(option) requires a value.")
        }
        return arguments[valueIndex]
    }

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--device":
            let value = try requiredValue(after: argument)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UserError("--device requires a non-empty device name.")
            }
            configuration.deviceSelection = .named(value)
            index += 2
        case "--default-input":
            configuration.deviceSelection = .systemDefault
            index += 1
        case "--list-devices":
            configuration.listDevices = true
            index += 1
        case "--threshold-db":
            configuration.startThresholdDB = try parseDouble(
                requiredValue(after: argument),
                option: argument
            )
            index += 2
        case "--stop-threshold-db":
            configuration.stopThresholdDB = try parseDouble(
                requiredValue(after: argument),
                option: argument
            )
            index += 2
        case "--start-ms":
            configuration.startMilliseconds = try parseDouble(
                requiredValue(after: argument),
                option: argument
            )
            index += 2
        case "--silence-ms":
            configuration.silenceMilliseconds = try parseDouble(
                requiredValue(after: argument),
                option: argument
            )
            index += 2
        case "--cooldown-ms":
            configuration.cooldownMilliseconds = try parseDouble(
                requiredValue(after: argument),
                option: argument
            )
            index += 2
        case "--max-seconds":
            configuration.maxSessionSeconds = try parseDouble(
                requiredValue(after: argument),
                option: argument
            )
            index += 2
        case "--run-seconds":
            let value = try requiredValue(after: argument)
            if value == "unlimited" {
                configuration.runSeconds = nil
            } else {
                configuration.runSeconds = try parseDouble(value, option: argument)
            }
            index += 2
        case "--key-mode":
            let value = try requiredValue(after: argument)
            guard let mode = KeyMode(rawValue: value) else {
                throw UserError("--key-mode must be fn-hold or right-option-toggle.")
            }
            configuration.keyMode = mode
            index += 2
        case "--dry-run":
            configuration.dryRun = true
            index += 1
        case "--auto-enter":
            configuration.autoEnter = true
            index += 1
        case "--auto-enter-delay-ms":
            configuration.autoEnterDelayMilliseconds = try parseDouble(
                requiredValue(after: argument),
                option: argument
            )
            index += 2
        case "--verbose", "-v":
            configuration.verbose = true
            index += 1
        case "--self-test":
            configuration.selfTest = true
            index += 1
        case "--simulate-vad":
            configuration.simulateVAD = true
            index += 1
        case "--help", "-h":
            configuration.showHelp = true
            index += 1
        default:
            throw UserError("Unknown option: \(argument)")
        }
    }

    guard configuration.startThresholdDB <= 0 else {
        throw UserError("--threshold-db must be at or below 0 dBFS.")
    }
    guard configuration.stopThresholdDB < configuration.startThresholdDB else {
        throw UserError("--stop-threshold-db must be lower than --threshold-db for hysteresis.")
    }
    guard configuration.startMilliseconds > 0 else {
        throw UserError("--start-ms must be greater than 0.")
    }
    guard (minimumSilenceMilliseconds...maximumSilenceMilliseconds)
        .contains(configuration.silenceMilliseconds) else {
        throw UserError("--silence-ms must be between 800 and 1200 milliseconds.")
    }
    guard configuration.cooldownMilliseconds >= 0 else {
        throw UserError("--cooldown-ms must be at least 0.")
    }
    guard configuration.maxSessionSeconds > 0 else {
        throw UserError("--max-seconds must be greater than 0.")
    }
    if let runSeconds = configuration.runSeconds, runSeconds <= 0 {
        throw UserError("--run-seconds must be greater than 0.")
    }
    guard configuration.keyMode != .fnHold || !configuration.autoEnter else {
        throw UserError("--auto-enter is incompatible with --key-mode fn-hold.")
    }
    guard configuration.autoEnterDelayMilliseconds >= 0 else {
        throw UserError("--auto-enter-delay-ms must be at least 0.")
    }
    guard !configuration.simulateVAD || configuration.dryRun else {
        throw UserError("--simulate-vad must be used with --dry-run.")
    }

    return configuration
}

private struct AudioInputDevice {
    let id: AudioDeviceID
    let name: String
    let inputChannels: UInt32
    let isSystemDefault: Bool
}

private func coreAudioStatus(_ status: OSStatus) -> String {
    let bigEndian = UInt32(bitPattern: status).bigEndian
    let bytes = withUnsafeBytes(of: bigEndian) { Array($0) }
    if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
        return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
    }
    return "\(status)"
}

private func systemDefaultInputDeviceID() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else {
        throw UserError("Unable to read the system default input device (CoreAudio \(coreAudioStatus(status))).")
    }
    return deviceID
}

private func audioDeviceName(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanagedName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &size,
        &unmanagedName
    )
    guard status == noErr, let unmanagedName else {
        throw UserError("Unable to read audio device \(deviceID) name (CoreAudio \(coreAudioStatus(status))).")
    }
    return unmanagedName.takeUnretainedValue() as String
}

private func audioDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
    guard status == noErr, let uid else {
        throw UserError("Unable to read audio device \(deviceID) UID (CoreAudio \(coreAudioStatus(status))).")
    }
    return uid.takeUnretainedValue() as String
}

private func inputChannelCount(_ deviceID: AudioDeviceID) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else {
        return 0
    }

    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    guard status == noErr else {
        throw UserError("Unable to inspect audio device \(deviceID) inputs (CoreAudio \(coreAudioStatus(status))).")
    }

    // AudioBufferList has a variable-length trailing buffer array. CoreAudio
    // may legitimately report only the mNumberBuffers field for an output-only
    // device, which is smaller than Swift's fixed AudioBufferList layout.
    // Treat an empty/short list as zero input channels instead of aborting the
    // enumeration of every device (the former code produced "CoreAudio 0").
    guard size >= MemoryLayout<UInt32>.size else { return 0 }

    let allocationSize = max(Int(size), MemoryLayout<AudioBufferList>.size)
    let rawBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: allocationSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawBuffer.deallocate() }
    rawBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: allocationSize)

    status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawBuffer)
    guard status == noErr else {
        throw UserError("Unable to read audio device \(deviceID) inputs (CoreAudio \(coreAudioStatus(status))).")
    }

    let bufferList = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
        $0 + $1.mNumberChannels
    }
}

private func audioInputDevices() throws -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size
    )
    guard status == noErr else {
        throw UserError("Unable to enumerate audio devices (CoreAudio \(coreAudioStatus(status))).")
    }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    status = deviceIDs.withUnsafeMutableBytes { bytes in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            bytes.baseAddress!
        )
    }
    guard status == noErr else {
        throw UserError("Unable to read audio device IDs (CoreAudio \(coreAudioStatus(status))).")
    }

    let defaultID = try? systemDefaultInputDeviceID()
    return deviceIDs.compactMap { deviceID in
        do {
            let channels = try inputChannelCount(deviceID)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: deviceID,
                name: try audioDeviceName(deviceID),
                inputChannels: channels,
                isSystemDefault: deviceID == defaultID
            )
        } catch {
            // A stale/virtual device must not hide otherwise valid inputs such
            // as Wireless Mic Rx. Keep enumerating and expose the skipped ID.
            fputs("WARNING: Skipping audio device \(deviceID): \(error)\n", stderr)
            return nil
        }
    }.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}

private func selectAudioDevice(
    _ selection: DeviceSelection,
    from devices: [AudioInputDevice]
) throws -> AudioInputDevice {
    switch selection {
    case .systemDefault:
        guard let device = devices.first(where: { $0.isSystemDefault }) else {
            throw UserError("No usable macOS default input device was found.")
        }
        return device
    case .named(let requestedName):
        if let exact = devices.first(where: {
            $0.name.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }) {
            return exact
        }

        let partialMatches = devices.filter {
            $0.name.range(
                of: requestedName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
        if partialMatches.count == 1, let match = partialMatches.first {
            return match
        }
        if partialMatches.count > 1 {
            let names = partialMatches.map(\.name).joined(separator: ", ")
            throw UserError("Audio device name \"\(requestedName)\" is ambiguous: \(names).")
        }
        throw UserError(
            "Input device \"\(requestedName)\" was not found. "
                + "Connect the DJI receiver, use --list-devices, or use --default-input."
        )
    }
}

private enum VADAction: Equatable {
    case start
    case stop(reason: String)
}

private struct VADDetector {
    let startThresholdDB: Double
    let stopThresholdDB: Double
    let requiredSpeechSeconds: Double
    let requiredSilenceSeconds: Double
    let cooldownSeconds: Double
    let maxSessionSeconds: Double

    private(set) var isActive = false
    private var speechSeconds = 0.0
    private var silenceSeconds = 0.0
    private var activeStartedAt = 0.0
    private var cooldownUntil = 0.0
    private(set) var pendingStopReason: String?

    init(
        startThresholdDB: Double,
        stopThresholdDB: Double,
        requiredSpeechSeconds: Double,
        requiredSilenceSeconds: Double,
        cooldownSeconds: Double,
        maxSessionSeconds: Double
    ) {
        self.startThresholdDB = startThresholdDB
        self.stopThresholdDB = stopThresholdDB
        self.requiredSpeechSeconds = requiredSpeechSeconds
        self.requiredSilenceSeconds = requiredSilenceSeconds
        self.cooldownSeconds = cooldownSeconds
        self.maxSessionSeconds = maxSessionSeconds
    }

    mutating func process(levelDB: Double, duration: Double, now: Double) -> VADAction? {
        guard duration > 0 else { return nil }

        if isActive {
            guard pendingStopReason == nil else { return nil }
            if let timeoutAction = checkTimeout(now: now) { return timeoutAction }

            if levelDB < stopThresholdDB {
                silenceSeconds += duration
            } else {
                silenceSeconds = 0
            }

            if silenceSeconds >= requiredSilenceSeconds {
                return requestStop(reason: "sustained silence")
            }
            return nil
        }

        guard now >= cooldownUntil else {
            speechSeconds = 0
            return nil
        }

        if levelDB >= startThresholdDB {
            speechSeconds += duration
        } else {
            speechSeconds = 0
        }

        guard speechSeconds >= requiredSpeechSeconds else { return nil }
        isActive = true
        activeStartedAt = now
        speechSeconds = 0
        silenceSeconds = 0
        return .start
    }

    mutating func checkTimeout(now: Double) -> VADAction? {
        guard isActive,
              pendingStopReason == nil,
              now - activeStartedAt >= maxSessionSeconds else { return nil }
        return requestStop(reason: "maximum session timeout")
    }

    mutating func forceStop(reason: String) -> VADAction? {
        guard isActive else { return nil }
        if let pendingStopReason {
            return .stop(reason: pendingStopReason)
        }
        return requestStop(reason: reason)
    }

    func retryPendingStop() -> VADAction? {
        pendingStopReason.map { .stop(reason: $0) }
    }

    mutating func confirmStop(now: Double) {
        guard isActive, pendingStopReason != nil else { return }
        isActive = false
        activeStartedAt = 0
        speechSeconds = 0
        silenceSeconds = 0
        pendingStopReason = nil
        cooldownUntil = now + cooldownSeconds
    }

    mutating func cancelFailedStart(now: Double) {
        guard isActive else { return }
        isActive = false
        activeStartedAt = 0
        speechSeconds = 0
        silenceSeconds = 0
        pendingStopReason = nil
        cooldownUntil = now + cooldownSeconds
    }

    private mutating func requestStop(reason: String) -> VADAction {
        pendingStopReason = reason
        return .stop(reason: reason)
    }
}

private struct AudioCallbackWatchdog {
    let timeoutSeconds: Double
    private(set) var isMonitoring = false
    private(set) var hasReportedStall = false
    private var lastCallbackAt = 0.0

    init(timeoutSeconds: Double) {
        self.timeoutSeconds = timeoutSeconds
    }

    mutating func begin(now: Double) {
        isMonitoring = true
        hasReportedStall = false
        lastCallbackAt = now
    }

    mutating func heartbeat(now: Double) {
        lastCallbackAt = now
    }

    mutating func detectStall(now: Double) -> Bool {
        guard isMonitoring,
              !hasReportedStall,
              now - lastCallbackAt >= timeoutSeconds else { return false }
        hasReportedStall = true
        return true
    }

    mutating func stop() {
        isMonitoring = false
    }
}

private final class KeyboardTapper: @unchecked Sendable {
    private let dryRun: Bool
    private let keyMode: KeyMode
    private let autoEnterDelayMilliseconds: Double
    private var fnReleaseEvent: CGEvent?
    private(set) var isFnHeld = false

    init(dryRun: Bool, keyMode: KeyMode, autoEnterDelayMilliseconds: Double) {
        self.dryRun = dryRun
        self.keyMode = keyMode
        self.autoEnterDelayMilliseconds = autoEnterDelayMilliseconds
    }

    // Match SayAll v1.9.21 postKeyState; macOS makes modifier events flagsChanged.
    static func makeFnEvents() -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: fnKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: fnKeyCode, keyDown: false)
        else { return nil }
        down.flags = .maskSecondaryFn
        up.flags = []
        return (down, up)
    }

    func startVoice(context: String) -> Bool {
        guard keyMode == .fnHold else { return tapRightOption(context: context) }
        guard !isFnHeld else { return true }
        if !dryRun {
            guard let events = Self.makeFnEvents() else {
                fputs("Unable to create paired Fn CGEvents.\n", stderr)
                return false
            }
            // Allocate the release before posting down, so cleanup needs no new event.
            fnReleaseEvent = events.up
            events.down.post(tap: .cghidEventTap)
        }
        isFnHeld = true
        print("[\(dryRun ? "DRY RUN" : "KEY")] Fn down (keycode 63, maskSecondaryFn): \(context)")
        fflush(stdout)
        return true
    }

    func stopVoice(context: String) -> Bool {
        guard keyMode == .fnHold else { return tapRightOption(context: context) }
        guard isFnHeld else { return true }
        if !dryRun {
            guard let event = fnReleaseEvent else { return false }
            event.post(tap: .cghidEventTap)
        }
        fnReleaseEvent = nil
        isFnHeld = false
        print("[\(dryRun ? "DRY RUN" : "KEY")] Fn up (keycode 63, flags cleared): \(context)")
        fflush(stdout)
        return true
    }

    func tapRightOption(context: String) -> Bool {
        if dryRun {
            print("[DRY RUN] Right Option click: \(context)")
            fflush(stdout)
            return true
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              // Swift overlay for CGEventCreateKeyboardEvent(..., true).
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: rightOptionKeyCode,
                  keyDown: true
              ),
              // Swift overlay for CGEventCreateKeyboardEvent(..., false).
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: rightOptionKeyCode,
                  keyDown: false
              ) else {
            fputs("Unable to create Right Option CGEvents.\n", stderr)
            return false
        }

        keyDown.flags = .maskAlternate
        keyUp.flags = .maskAlternate
        keyDown.post(tap: .cghidEventTap)
        usleep(30_000)
        keyUp.post(tap: .cghidEventTap)
        print("[KEY] Right Option click: \(context)")
        fflush(stdout)
        return true
    }

    func tapReturn(context: String) -> Bool {
        guard keyMode != .fnHold else { return false }
        if dryRun {
            print("[DRY RUN] Return click: \(context)")
            fflush(stdout)
            return true
        }

        // Doubao finalizes and streams the last transcription asynchronously
        // after its stop shortcut. Return sent too early can hit an empty or
        // unfinished composer, so the configurable delay defaults to 1200 ms.
        // It stays outside the VAD state machine: a failed Return must never
        // reopen or retry the already-completed voice stop.
        Thread.sleep(forTimeInterval: autoEnterDelayMilliseconds / 1_000)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: returnKeyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: returnKeyCode,
                  keyDown: false
              ) else {
            fputs("Unable to create Return CGEvents.\n", stderr)
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        usleep(30_000)
        keyUp.post(tap: .cghidEventTap)
        print("[KEY] Return click: \(context)")
        fflush(stdout)
        return true
    }
}

private final class VADController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dji-mic-voice.vad")
    private let tapper: KeyboardTapper
    private let autoEnter: Bool
    private let verbose: Bool
    private let onAudioStall: @Sendable (String) -> Void
    private var detector: VADDetector
    private var audioWatchdog = AudioCallbackWatchdog(timeoutSeconds: audioWatchdogSeconds)
    private var lastMeterPrintAt = 0.0
    private var lastStopAttemptAt = 0.0
    private var safetyTimer: DispatchSourceTimer?
    private var isShuttingDown = false

    init(
        configuration: Configuration,
        tapper: KeyboardTapper,
        onAudioStall: @escaping @Sendable (String) -> Void
    ) {
        detector = VADDetector(
            startThresholdDB: configuration.startThresholdDB,
            stopThresholdDB: configuration.stopThresholdDB,
            requiredSpeechSeconds: configuration.startMilliseconds / 1_000,
            requiredSilenceSeconds: configuration.silenceMilliseconds / 1_000,
            cooldownSeconds: configuration.cooldownMilliseconds / 1_000,
            maxSessionSeconds: configuration.maxSessionSeconds
        )
        self.tapper = tapper
        autoEnter = configuration.autoEnter
        verbose = configuration.verbose
        self.onAudioStall = onAudioStall

        // One timer owns stop retries, maximum-session checks, and the audio
        // callback watchdog. It runs independently of audio capture callbacks.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.checkSafety()
        }
        timer.resume()
        safetyTimer = timer
    }

    func beginAudioWatchdog() {
        queue.sync { [self] in
            audioWatchdog.begin(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    func accept(levelDB: Double, duration: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            guard !isShuttingDown else { return }
            audioWatchdog.heartbeat(now: now)
            if verbose, now - lastMeterPrintAt >= 0.25 {
                let state = detector.isActive ? "recording" : "waiting"
                print(String(format: "[LEVEL] %6.1f dBFS  %@", levelDB, state))
                fflush(stdout)
                lastMeterPrintAt = now
            }

            guard let action = detector.process(levelDB: levelDB, duration: duration, now: now) else {
                return
            }
            handle(action, now: now)
        }
    }

    func shutdown() {
        safetyTimer?.cancel()
        safetyTimer = nil
        queue.sync { [self] in
            isShuttingDown = true
            audioWatchdog.stop()
            let now = ProcessInfo.processInfo.systemUptime
            if let action = detector.forceStop(reason: "program shutdown") {
                handle(action, now: now)
            }
        }
    }

    private func checkSafety() {
        guard !isShuttingDown else { return }
        let now = ProcessInfo.processInfo.systemUptime

        if audioWatchdog.detectStall(now: now) {
            let message = String(
                format: "No audio callback for %.1f seconds; the input was disconnected or stalled.",
                audioWatchdogSeconds
            )
            if let action = detector.forceStop(reason: "audio input stalled") {
                handle(action, now: now)
            }
            fputs("ERROR: \(message)\n", stderr)
            onAudioStall(message)
            return
        }

        if now - lastStopAttemptAt >= stopRetrySeconds,
           let action = detector.retryPendingStop() {
            handle(action, now: now)
            return
        }

        if let action = detector.checkTimeout(now: now) {
            handle(action, now: now)
        }
    }

    private func handle(_ action: VADAction, now: Double) {
        switch action {
        case .start:
            print("[VAD] Sustained speech detected; starting voice input.")
            if !tapper.startVoice(context: "start") {
                detector.cancelFailedStart(now: now)
                fputs("Start click failed; VAD returned to waiting state.\n", stderr)
            }
        case .stop(let reason):
            print("[VAD] Stopping voice input: \(reason).")
            lastStopAttemptAt = now
            if tapper.stopVoice(context: "stop (\(reason))") {
                detector.confirmStop(now: now)
                print("[VAD] Stop confirmed; returned to waiting state.")
                if autoEnter,
                   !tapper.tapReturn(context: "auto-enter after stop") {
                    fputs(
                        "WARNING: stop succeeded, but the automatic Return click failed.\n",
                        stderr
                    )
                }
            } else {
                fputs(
                    "WARNING: stop click failed; recording state is retained and retry is scheduled.\n",
                    stderr
                )
            }
        }
        fflush(stdout)
    }
}

private final class AudioMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let controlQueue = DispatchQueue(label: "dji-mic-voice.audio-control")
    private let sampleQueue = DispatchQueue(label: "dji-mic-voice.audio-samples")
    private let onFailure: @Sendable (String) -> Void
    // Only sampleQueue reads or writes callback state.
    private var controller: VADController?
    private var failed = false

    init(onFailure: @escaping @Sendable (String) -> Void) {
        self.onFailure = onFailure
        super.init()
    }

    func start(device: AudioInputDevice, controller: VADController) throws -> AVAudioFormat {
        try controlQueue.sync {
            let uid = try audioDeviceUID(device.id)
            guard !uid.isEmpty,
                  let captureDevice = AVCaptureDevice(uniqueID: uid),
                  captureDevice.uniqueID == uid, captureDevice.hasMediaType(.audio),
                  captureDevice.isConnected else {
                throw UserError(
                    "No connected AVCapture audio device matches \"\(device.name)\" "
                        + "(CoreAudio id=\(device.id), UID=\(uid)); no other input was substituted."
                )
            }
            let input = try AVCaptureDeviceInput(device: captureDevice)
            guard let native = CMAudioFormatDescriptionGetStreamBasicDescription(
                captureDevice.activeFormat.formatDescription
            )?.pointee,
                  native.mSampleRate.isFinite, native.mSampleRate > 0,
                  native.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: native.mSampleRate,
                      channels: native.mChannelsPerFrame,
                      interleaved: true
                  ) else {
                throw UserError("AVCapture input has no valid native audio format.")
            }

            session.beginConfiguration()
            do {
                defer { session.commitConfiguration() }
                guard session.canAddInput(input) else {
                    throw UserError("AVCaptureSession cannot add the selected audio input.")
                }
                session.addInput(input)
                guard session.canAddOutput(output) else {
                    throw UserError("AVCaptureSession cannot add audio data output.")
                }
                session.addOutput(output)
                output.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: native.mSampleRate,
                    AVNumberOfChannelsKey: native.mChannelsPerFrame,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            }
            sampleQueue.sync {
                self.controller = controller
                failed = false
            }
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            print(
                "[AUDIO] AVCaptureSession input=\"\(captureDevice.localizedName)\", UID=\(uid) "
                    + "(exact CoreAudio UID match); requesting interleaved Float32 PCM, "
                    + "\(native.mChannelsPerFrame) ch, \(native.mSampleRate) Hz."
            )
            fflush(stdout)
            session.startRunning()
            guard session.isRunning else {
                throw UserError("AVCaptureSession failed to start the selected audio input.")
            }
            return format
        }
    }

    func stop() {
        controlQueue.sync {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            // Drain in-flight callbacks before releasing the controller and input.
            sampleQueue.sync {
                controller = nil
                failed = true
            }
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let controller, !failed else { return }
        do {
            let audio = try Self.levelAndDuration(sampleBuffer)
            controller.accept(levelDB: audio.levelDB, duration: audio.duration)
        } catch {
            failed = true
            let message = "AVCapture audio callback failed: \(error)"
            fputs("ERROR: \(message)\n", stderr)
            onFailure(message)
        }
    }

    static func levelAndDuration(_ sampleBuffer: CMSampleBuffer) throws -> (levelDB: Double, duration: Double) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw UserError("Missing ready PCM audio data or format description.")
        }
        let flags = format.mFormatFlags
        guard format.mFormatID == kAudioFormatLinearPCM,
              flags & kAudioFormatFlagIsFloat != 0,
              flags & kAudioFormatFlagIsPacked != 0,
              flags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= UInt32.max / 4,
              format.mBytesPerFrame == format.mChannelsPerFrame * 4,
              format.mFramesPerPacket == 1, format.mBytesPerPacket == format.mBytesPerFrame,
              format.mSampleRate.isFinite, format.mSampleRate > 0 else {
            throw UserError(
                "Expected packed interleaved little-endian Float32 PCM; received "
                    + "format=\(format.mFormatID), flags=\(flags), bits=\(format.mBitsPerChannel), "
                    + "channels=\(format.mChannelsPerFrame), rate=\(format.mSampleRate)."
            )
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= Int.max / Int(format.mBytesPerFrame) else {
            throw UserError("AVCapture supplied an empty or oversized PCM buffer.")
        }
        // Interleaved PCM has one AudioBuffer. CoreMedia retains and aligns its data.
        var buffers = AudioBufferList()
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &buffers,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlock
        )
        guard status == noErr, buffers.mNumberBuffers == 1,
              buffers.mBuffers.mNumberChannels == format.mChannelsPerFrame,
              Int(buffers.mBuffers.mDataByteSize) == frames * Int(format.mBytesPerFrame),
              let data = buffers.mBuffers.mData else {
            throw UserError("Invalid interleaved PCM buffer layout (CoreMedia \(status)).")
        }
        return try withExtendedLifetime(retainedBlock) {
            let count = frames * Int(format.mChannelsPerFrame)
            let samples = data.assumingMemoryBound(to: Float.self)
            var sumSquares = 0.0
            for index in 0..<count {
                let sample = Double(samples[index])
                guard sample.isFinite else { throw UserError("Non-finite PCM sample received.") }
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Double(count))
            return (max(-120, 20 * log10(max(rms, 0.000_001))), Double(frames) / format.mSampleRate)
        }
    }
}

private final class ShutdownGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return false }
        started = true
        return true
    }
}

private final class RuntimeExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32 = EXIT_SUCCESS
    private var reason: String?

    func fail(_ reason: String) {
        lock.lock()
        code = EXIT_FAILURE
        self.reason = reason
        lock.unlock()
    }

    func snapshot() -> (code: Int32, reason: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (code, reason)
    }
}

private func requestMicrophonePermission() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .denied, .restricted:
        return false
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            granted = allowed
            semaphore.signal()
        }
        semaphore.wait()
        return granted
    @unknown default:
        return false
    }
}

private func hasAccessibilityPermission(prompt: Bool) -> Bool {
    guard prompt else { return AXIsProcessTrusted() }
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
}

private func runSelfTest() throws {
    let defaultConfiguration = try parseArguments([])
    let autoEnterConfiguration = try parseArguments([
        "--key-mode", "right-option-toggle", "--run-seconds", "5",
        "--auto-enter", "--auto-enter-delay-ms", "1750",
    ])
    guard !defaultConfiguration.autoEnter,
          defaultConfiguration.keyMode == (isTrialApp ? .fnHold : .rightOptionToggle),
          defaultConfiguration.runSeconds == (isTrialApp ? 60 : nil),
          defaultConfiguration.autoEnterDelayMilliseconds == 1_200,
          autoEnterConfiguration.keyMode == .rightOptionToggle,
          autoEnterConfiguration.runSeconds == 5,
          autoEnterConfiguration.autoEnter,
          autoEnterConfiguration.autoEnterDelayMilliseconds == 1_750 else {
        throw UserError("SELF-TEST FAIL: auto-enter parsing/default is incorrect.")
    }
    var rejectedNegativeAutoEnterDelay = false
    do {
        _ = try parseArguments(["--auto-enter-delay-ms", "-1"])
    } catch {
        rejectedNegativeAutoEnterDelay = true
    }
    guard rejectedNegativeAutoEnterDelay else {
        throw UserError("SELF-TEST FAIL: negative auto-enter delay was accepted.")
    }

    var fnConfiguration = try parseArguments(["--key-mode", "fn-hold", "--run-seconds", "0.5"])
    guard fnConfiguration.keyMode == .fnHold, fnConfiguration.runSeconds == 0.5,
          !fnConfiguration.autoEnter else {
        throw UserError("SELF-TEST FAIL: Fn/run limit parsing is incorrect.")
    }
    let unlimitedConfiguration = try parseArguments(["--run-seconds", "unlimited"])
    guard unlimitedConfiguration.runSeconds == nil else {
        throw UserError("SELF-TEST FAIL: explicit unlimited run limit was not applied.")
    }
    for arguments in [
        ["--key-mode", "unknown"], ["--key-mode"],
        ["--key-mode", "fn-hold", "--auto-enter"],
        ["--auto-enter", "--key-mode", "fn-hold"],
        ["--run-seconds", "0"], ["--run-seconds", "-1"],
        ["--run-seconds", "nan"], ["--run-seconds", "inf"], ["--run-seconds"],
    ] {
        var rejected = false
        do { _ = try parseArguments(arguments) } catch { rejected = true }
        guard rejected else {
            throw UserError("SELF-TEST FAIL: invalid arguments accepted: \(arguments).")
        }
    }

    // Construct and inspect events only; self-test never posts them.
    guard let fnEvents = KeyboardTapper.makeFnEvents(),
          fnEvents.down.getIntegerValueField(.keyboardEventKeycode) == 63,
          fnEvents.up.getIntegerValueField(.keyboardEventKeycode) == 63,
          fnEvents.down.type == .flagsChanged, fnEvents.up.type == .flagsChanged,
          fnEvents.down.flags == .maskSecondaryFn, fnEvents.up.flags.isEmpty else {
        throw UserError("SELF-TEST FAIL: Fn event codes/types/flags are incorrect.")
    }
    let fnTapper = KeyboardTapper(dryRun: true, keyMode: .fnHold, autoEnterDelayMilliseconds: 0)
    guard fnTapper.startVoice(context: "self-test"), fnTapper.isFnHeld,
          fnTapper.stopVoice(context: "self-test"), !fnTapper.isFnHeld,
          fnTapper.stopVoice(context: "already released"),
          !fnTapper.tapReturn(context: "forbidden in fn-hold") else {
        throw UserError("SELF-TEST FAIL: Fn pairing or Return guard failed.")
    }
    fnConfiguration.startMilliseconds = 50
    let fnController = VADController(configuration: fnConfiguration, tapper: fnTapper,
                                     onAudioStall: { _ in })
    fnController.accept(levelDB: -20, duration: 0.05)
    fnController.shutdown()
    guard !fnTapper.isFnHeld else {
        throw UserError("SELF-TEST FAIL: shutdown left Fn held.")
    }

    var detector = VADDetector(
        startThresholdDB: -40,
        stopThresholdDB: -46,
        requiredSpeechSeconds: 0.2,
        requiredSilenceSeconds: 1.0,
        cooldownSeconds: 0.7,
        maxSessionSeconds: 2.0
    )

    var now = 10.0
    for _ in 0..<3 {
        let action = detector.process(levelDB: -30, duration: 0.05, now: now)
        guard action == nil else { throw UserError("SELF-TEST FAIL: speech triggered too early.") }
        now += 0.05
    }
    guard detector.process(levelDB: -30, duration: 0.05, now: now) == .start else {
        throw UserError("SELF-TEST FAIL: sustained speech did not start.")
    }

    now += 0.05
    for _ in 0..<19 {
        let action = detector.process(levelDB: -80, duration: 0.05, now: now)
        guard action == nil else { throw UserError("SELF-TEST FAIL: silence stopped too early.") }
        now += 0.05
    }
    guard detector.process(levelDB: -80, duration: 0.05, now: now)
        == .stop(reason: "sustained silence"),
          detector.isActive,
          detector.pendingStopReason == "sustained silence" else {
        throw UserError("SELF-TEST FAIL: sustained silence did not stop.")
    }
    guard detector.retryPendingStop() == .stop(reason: "sustained silence"),
          detector.isActive else {
        throw UserError("SELF-TEST FAIL: failed stop did not retain active state for retry.")
    }
    detector.confirmStop(now: now)
    guard !detector.isActive, detector.pendingStopReason == nil else {
        throw UserError("SELF-TEST FAIL: successful stop was not confirmed.")
    }

    for _ in 0..<5 {
        now += 0.05
        guard detector.process(levelDB: -20, duration: 0.05, now: now) == nil else {
            throw UserError("SELF-TEST FAIL: cooldown did not debounce retriggering.")
        }
    }

    var timeoutDetector = VADDetector(
        startThresholdDB: -40,
        stopThresholdDB: -46,
        requiredSpeechSeconds: 0.1,
        requiredSilenceSeconds: 1.0,
        cooldownSeconds: 0.7,
        maxSessionSeconds: 0.2
    )
    guard timeoutDetector.process(levelDB: -20, duration: 0.1, now: 20) == .start else {
        throw UserError("SELF-TEST FAIL: timeout scenario did not start.")
    }
    guard timeoutDetector.checkTimeout(now: 20.21)
        == .stop(reason: "maximum session timeout"),
          timeoutDetector.isActive else {
        throw UserError("SELF-TEST FAIL: maximum session timeout did not stop.")
    }
    timeoutDetector.confirmStop(now: 20.21)

    var failedStartDetector = VADDetector(
        startThresholdDB: -40,
        stopThresholdDB: -46,
        requiredSpeechSeconds: 0.1,
        requiredSilenceSeconds: 1.0,
        cooldownSeconds: 0.7,
        maxSessionSeconds: 2.0
    )
    guard failedStartDetector.process(levelDB: -20, duration: 0.1, now: 25) == .start else {
        throw UserError("SELF-TEST FAIL: failed-start scenario did not start.")
    }
    failedStartDetector.cancelFailedStart(now: 25)
    guard !failedStartDetector.isActive,
          failedStartDetector.pendingStopReason == nil else {
        throw UserError("SELF-TEST FAIL: failed start was not cleaned up.")
    }

    var watchdog = AudioCallbackWatchdog(timeoutSeconds: 1.5)
    watchdog.begin(now: 30)
    guard !watchdog.detectStall(now: 31.49) else {
        throw UserError("SELF-TEST FAIL: audio watchdog fired too early.")
    }
    watchdog.heartbeat(now: 31.0)
    guard !watchdog.detectStall(now: 32.49),
          watchdog.detectStall(now: 32.5),
          !watchdog.detectStall(now: 34) else {
        throw UserError("SELF-TEST FAIL: audio watchdog timing is incorrect.")
    }

    let fakeDevices = [
        AudioInputDevice(id: 1, name: "Mac Microphone", inputChannels: 1, isSystemDefault: true),
        AudioInputDevice(id: 2, name: "Wireless Mic Rx", inputChannels: 2, isSystemDefault: false),
    ]
    guard try selectAudioDevice(.named("wireless mic rx"), from: fakeDevices).id == 2,
          try selectAudioDevice(.systemDefault, from: fakeDevices).id == 1 else {
        throw UserError("SELF-TEST FAIL: audio-device selection is incorrect.")
    }

    // Exercise the real callback decoder with synthetic stereo PCM, without a capture session.
    func pcmFixture(_ samples: [Float]) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: true)!
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        let allocationStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        )
        guard allocationStatus == noErr, let block else {
            throw UserError("SELF-TEST FAIL: PCM fixture allocation failed (\(allocationStatus)).")
        }
        let copyStatus = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var bytesPerFrame = 2 * MemoryLayout<Float>.size
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format.formatDescription,
            sampleCount: samples.count / 2, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &bytesPerFrame, sampleBufferOut: &buffer
        )
        guard copyStatus == noErr, status == noErr, let buffer else {
            throw UserError("SELF-TEST FAIL: PCM fixture creation failed (\(copyStatus), \(status)).")
        }
        return buffer
    }
    let pcm = try AudioMonitor.levelAndDuration(pcmFixture([0.5, -0.5, 0, 0]))
    let silence = try AudioMonitor.levelAndDuration(pcmFixture([0, 0, 0, 0]))
    guard abs(pcm.levelDB - (-9.0308998699)) < 0.000001,
          abs(pcm.duration - 2.0 / 48_000) < 0.000000001,
          silence.levelDB == -120, silence.duration == pcm.duration else {
        throw UserError("SELF-TEST FAIL: interleaved PCM RMS, silence floor or duration is incorrect.")
    }

    guard rightOptionKeyCode == 61,
          fnKeyCode == 63,
          returnKeyCode == 36,
          defaultAutoEnterDelayMilliseconds == 1_200,
          minimumSilenceMilliseconds == 800,
          maximumSilenceMilliseconds == 1_200 else {
        throw UserError("SELF-TEST FAIL: required constants changed.")
    }

    print(
        "SELF-TEST DEFAULTS: key-mode=\(defaultConfiguration.keyMode.rawValue), "
            + "run-seconds=\(defaultConfiguration.runSeconds.map { String($0) } ?? "unlimited"), "
            + "auto-enter=\(defaultConfiguration.autoEnter)."
    )
    print(
        "SELF-TEST PASS: stereo Float32 CMSampleBuffer RMS/silence/duration, "
            + "device selection, start cleanup, retained/retried stop, "
            + "silence stop, debounce, 1.5 s audio watchdog, session timeout, "
            + "auto-enter delay parsing/default/rejection, Fn paired down/up and shutdown release, "
            + "run limit parsing/rejection, and key codes 61/63/36 (no events posted)."
    )
}

private func runDryRunSimulation(configuration: Configuration) throws {
    var detector = VADDetector(
        startThresholdDB: configuration.startThresholdDB,
        stopThresholdDB: configuration.stopThresholdDB,
        requiredSpeechSeconds: configuration.startMilliseconds / 1_000,
        requiredSilenceSeconds: configuration.silenceMilliseconds / 1_000,
        cooldownSeconds: configuration.cooldownMilliseconds / 1_000,
        maxSessionSeconds: configuration.maxSessionSeconds
    )
    let tapper = KeyboardTapper(
        dryRun: true,
        keyMode: configuration.keyMode,
        autoEnterDelayMilliseconds: configuration.autoEnterDelayMilliseconds
    )
    let frameSeconds = 0.05
    var now = 100.0
    var startCount = 0
    var stopCount = 0

    let speechFrames = Int(ceil(configuration.startMilliseconds / 50.0)) + 1
    for _ in 0..<speechFrames {
        if detector.process(
            levelDB: configuration.startThresholdDB + 10,
            duration: frameSeconds,
            now: now
        ) == .start {
            guard tapper.startVoice(context: "start") else {
                detector.cancelFailedStart(now: now)
                throw UserError("DRY-RUN FAIL: simulated start click failed.")
            }
            startCount += 1
        }
        now += frameSeconds
    }

    let silenceFrames = Int(ceil(configuration.silenceMilliseconds / 50.0)) + 1
    for _ in 0..<silenceFrames {
        if case .stop = detector.process(
            levelDB: configuration.stopThresholdDB - 10,
            duration: frameSeconds,
            now: now
        ) {
            guard tapper.stopVoice(context: "stop") else {
                throw UserError("DRY-RUN FAIL: simulated stop click failed.")
            }
            detector.confirmStop(now: now)
            if configuration.autoEnter,
               !tapper.tapReturn(context: "auto-enter after stop") {
                throw UserError("DRY-RUN FAIL: simulated Return click failed.")
            }
            stopCount += 1
        }
        now += frameSeconds
    }

    guard startCount == 1,
          stopCount == 1,
          !tapper.isFnHeld,
          !detector.isActive,
          detector.pendingStopReason == nil else {
        throw UserError(
            "DRY-RUN FAIL: expected one complete start-to-silence-stop transition."
        )
    }
    print("DRY-RUN PASS: one speech start and one sustained-silence stop were confirmed.")
}

do {
    let configuration = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    if configuration.showHelp {
        printUsage()
        exit(EXIT_SUCCESS)
    }
    if configuration.selfTest {
        try runSelfTest()
        exit(EXIT_SUCCESS)
    }
    if configuration.simulateVAD {
        try runDryRunSimulation(configuration: configuration)
        exit(EXIT_SUCCESS)
    }

    let devices = try audioInputDevices()
    if configuration.listDevices {
        print("macOS audio input devices:")
        for device in devices {
            let marker = device.isSystemDefault ? " [default]" : ""
            print("  id=\(device.id) channels=\(device.inputChannels) \"\(device.name)\"\(marker)")
        }
        exit(EXIT_SUCCESS)
    }

    let selectedDevice = try selectAudioDevice(configuration.deviceSelection, from: devices)
    guard requestMicrophonePermission() else {
        throw UserError(
            "Microphone access is denied. Allow the launcher in System Settings > "
                + "Privacy & Security > Microphone, restart it, and run again."
        )
    }
    if !configuration.dryRun, !hasAccessibilityPermission(prompt: true) {
        throw UserError(
            "Accessibility access is required to post the voice shortcut. Allow the launcher in "
                + "System Settings > Privacy & Security > Accessibility, restart it, and run again."
        )
    }

    let runtimeExitState = RuntimeExitState()
    let tapper = KeyboardTapper(
        dryRun: configuration.dryRun,
        keyMode: configuration.keyMode,
        autoEnterDelayMilliseconds: configuration.autoEnterDelayMilliseconds
    )
    let controller = VADController(
        configuration: configuration,
        tapper: tapper,
        onAudioStall: { message in
            runtimeExitState.fail(message)
            // Route watchdog failure through the normal serialized teardown.
            _ = kill(getpid(), SIGTERM)
        }
    )
    let monitor = AudioMonitor(onFailure: { message in
        runtimeExitState.fail(message)
        _ = kill(getpid(), SIGTERM)
    })
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signalQueue = DispatchQueue(label: "dji-mic-voice.signals")
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    let shutdownGate = ShutdownGate()
    let shutdown: @Sendable () -> Void = {
        guard shutdownGate.begin() else { return }

        print("\nStopping safely...")
        controller.shutdown()
        monitor.stop()
        let result = runtimeExitState.snapshot()
        if let reason = result.reason {
            fputs("EXITING WITH ERROR: \(reason)\n", stderr)
        }
        exit(result.code)
    }
    interruptSource.setEventHandler(handler: shutdown)
    terminateSource.setEventHandler(handler: shutdown)
    interruptSource.resume()
    terminateSource.resume()

    let format: AVAudioFormat
    do {
        format = try monitor.start(device: selectedDevice, controller: controller)
    } catch {
        controller.shutdown()
        monitor.stop()
        throw error
    }
    controller.beginAudioWatchdog()

    print(
        "Listening to \"\(selectedDevice.name)\" "
            + "(id=\(selectedDevice.id), \(Int(format.channelCount)) ch, "
            + "\(Int(format.sampleRate)) Hz)."
    )
    print("Key mode: \(configuration.keyMode.rawValue).")
    print(
        String(
            format: "VAD: start %.1f dBFS for %.0f ms; stop below %.1f dBFS for %.0f ms; max %.0f s.%@",
            configuration.startThresholdDB,
            configuration.startMilliseconds,
            configuration.stopThresholdDB,
            configuration.silenceMilliseconds,
            configuration.maxSessionSeconds,
            configuration.dryRun ? " DRY RUN." : ""
        )
    )
    if configuration.autoEnter {
        print(
            String(
                format: "Auto-enter is ON: Return will be pressed %.0f ms after each successful stop.",
                configuration.autoEnterDelayMilliseconds
            )
        )
    }
    // Use the same serialized cleanup as SIGTERM, including release of a held Fn.
    let runTimer: DispatchSourceTimer?
    if let seconds = configuration.runSeconds {
        let timer = DispatchSource.makeTimerSource(queue: signalQueue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler {
            print("[RUN LIMIT] Trial listening time elapsed.")
            shutdown()
        }
        timer.resume()
        runTimer = timer
        print("Run limit: \(seconds) seconds of listening.")
    } else {
        runTimer = nil
    }
    print("Press Control-C to stop safely.")
    fflush(stdout)
    // Keep dispatch sources alive until process exit.
    withExtendedLifetime((interruptSource, terminateSource, runTimer)) {
        dispatchMain()
    }
} catch {
    fputs("ERROR: \(error)\n", stderr)
    fputs("Run with --help for usage.\n", stderr)
    exit(EXIT_FAILURE)
}
