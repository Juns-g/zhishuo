#!/usr/bin/env swift

/*
 DJI Mic 2 voice-triggered Doubao dictation for macOS.

 What it does
 ------------
 - Reads audio from "Wireless Mic Rx" by default (or another selected input).
 - Starts after sustained speech, then clicks Right Option once.
 - Clicks Right Option again after 0.8-1.2 seconds of silence or at the
   configured maximum recording time.
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
     -framework AudioToolbox -framework CoreGraphics \
     -framework ApplicationServices \
     task/vad-voice-trigger.swift -o task/vad-voice-trigger

   ./task/vad-voice-trigger --list-devices
   ./task/vad-voice-trigger --device "Wireless Mic Rx"

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
 the macOS virtual key code for Right Option. Both key-down and key-up carry
 the Option modifier flag and are posted to the HID event tap.
 */

import ApplicationServices
import AudioToolbox
import AVFAudio
import AVFoundation
import CoreAudio
import CoreGraphics
import Darwin
import Foundation

private let defaultDJIDeviceName = "Wireless Mic Rx"
private let rightOptionKeyCode: CGKeyCode = 61
private let minimumSilenceMilliseconds = 800.0
private let maximumSilenceMilliseconds = 1_200.0
private let audioWatchdogSeconds = 1.5
private let stopRetrySeconds = 0.25

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

private struct Configuration {
    var deviceSelection: DeviceSelection = .named(defaultDJIDeviceName)
    var startThresholdDB = -40.0
    var stopThresholdDB = -46.0
    var startMilliseconds = 200.0
    var silenceMilliseconds = 1_000.0
    var cooldownMilliseconds = 700.0
    var maxSessionSeconds = 120.0
    var dryRun = false
    var listDevices = false
    var selfTest = false
    var simulateVAD = false
    var showHelp = false
}

private func printUsage() {
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
          --dry-run             Print VAD actions without sending Right Option.
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
        case "--dry-run":
            configuration.dryRun = true
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

private func inputChannelCount(_ deviceID: AudioDeviceID) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    guard status == noErr, size >= MemoryLayout<AudioBufferList>.size else {
        throw UserError("Unable to inspect audio device \(deviceID) inputs (CoreAudio \(coreAudioStatus(status))).")
    }

    let rawBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawBuffer.deallocate() }

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
    return try deviceIDs.compactMap { deviceID in
        let channels = try inputChannelCount(deviceID)
        guard channels > 0 else { return nil }
        return AudioInputDevice(
            id: deviceID,
            name: try audioDeviceName(deviceID),
            inputChannels: channels,
            isSystemDefault: deviceID == defaultID
        )
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

private final class RightOptionTapper: @unchecked Sendable {
    private let dryRun: Bool

    init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    func tap(context: String) -> Bool {
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
}

private final class VADController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dji-mic-voice.vad")
    private let tapper: RightOptionTapper
    private let onAudioStall: @Sendable (String) -> Void
    private var detector: VADDetector
    private var audioWatchdog = AudioCallbackWatchdog(timeoutSeconds: audioWatchdogSeconds)
    private var lastMeterPrintAt = 0.0
    private var lastStopAttemptAt = 0.0
    private var safetyTimer: DispatchSourceTimer?
    private var isShuttingDown = false

    init(
        configuration: Configuration,
        tapper: RightOptionTapper,
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
        self.onAudioStall = onAudioStall

        // One timer owns stop retries, maximum-session checks, and the audio
        // callback watchdog. It runs independently of AVAudioEngine callbacks.
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
            if now - lastMeterPrintAt >= 0.25 {
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
            print("[VAD] Sustained speech detected; starting Doubao voice input.")
            if !tapper.tap(context: "start") {
                detector.cancelFailedStart(now: now)
                fputs("Start click failed; VAD returned to waiting state.\n", stderr)
            }
        case .stop(let reason):
            print("[VAD] Stopping Doubao voice input: \(reason).")
            lastStopAttemptAt = now
            if tapper.tap(context: "stop") {
                detector.confirmStop(now: now)
                print("[VAD] Stop confirmed; returned to waiting state.")
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

private final class AudioMonitor: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let controlQueue = DispatchQueue(label: "dji-mic-voice.audio-control")
    private var tapInstalled = false

    func start(device: AudioInputDevice, controller: VADController) throws -> AVAudioFormat {
        try controlQueue.sync {
            let inputNode = engine.inputNode
            guard let audioUnit = inputNode.audioUnit else {
                throw UserError("AVAudioEngine did not provide an input AudioUnit.")
            }

            var deviceID = device.id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw UserError(
                    "Unable to select \"\(device.name)\" in AVAudioEngine "
                        + "(AudioUnit \(coreAudioStatus(status)))."
                )
            }

            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw UserError("Selected input has an invalid audio format: \(format).")
            }

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) {
                buffer,
                _ in
                let level = Self.levelDBFS(buffer)
                let duration = Double(buffer.frameLength) / format.sampleRate
                controller.accept(levelDB: level, duration: duration)
            }
            tapInstalled = true

            engine.prepare()
            do {
                try engine.start()
            } catch {
                // The tap was installed before engine.start(), so unwind it
                // before surfacing the startup error.
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
                throw UserError("AVAudioEngine failed to start: \(error.localizedDescription)")
            }
            return format
        }
    }

    func stop() {
        controlQueue.sync {
            // AVAudioEngine graph changes are serialized here. Remove the tap
            // exactly once before stopping the engine so no callback can race
            // a second removeTap/stop sequence.
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            if engine.isRunning {
                engine.stop()
            }
        }
    }

    private static func levelDBFS(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.channelCount > 0 else {
            return -120
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sumSquares = 0.0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = Double(samples[frame])
                sumSquares += sample * sample
            }
        }

        let sampleCount = Double(frameCount * channelCount)
        let rms = sqrt(sumSquares / sampleCount)
        return max(-120, 20 * log10(max(rms, 0.000_001)))
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

    guard rightOptionKeyCode == 61,
          minimumSilenceMilliseconds == 800,
          maximumSilenceMilliseconds == 1_200 else {
        throw UserError("SELF-TEST FAIL: required constants changed.")
    }

    print(
        "SELF-TEST PASS: device selection, start cleanup, retained/retried stop, "
            + "silence stop, debounce, 1.5 s audio watchdog, session timeout, and key code 61."
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
    let tapper = RightOptionTapper(dryRun: true)
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
            guard tapper.tap(context: "start") else {
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
            guard tapper.tap(context: "stop") else {
                throw UserError("DRY-RUN FAIL: simulated stop click failed.")
            }
            detector.confirmStop(now: now)
            stopCount += 1
        }
        now += frameSeconds
    }

    guard startCount == 1,
          stopCount == 1,
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
            "Accessibility access is required to click Right Option. Allow the launcher in "
                + "System Settings > Privacy & Security > Accessibility, restart it, and run again."
        )
    }

    let runtimeExitState = RuntimeExitState()
    let tapper = RightOptionTapper(dryRun: configuration.dryRun)
    let controller = VADController(
        configuration: configuration,
        tapper: tapper,
        onAudioStall: { message in
            runtimeExitState.fail(message)
            // Route watchdog failure through the normal serialized teardown.
            _ = kill(getpid(), SIGTERM)
        }
    )
    let monitor = AudioMonitor()
    let format = try monitor.start(device: selectedDevice, controller: controller)
    controller.beginAudioWatchdog()

    print(
        "Listening to \"\(selectedDevice.name)\" "
            + "(id=\(selectedDevice.id), \(Int(format.channelCount)) ch, "
            + "\(Int(format.sampleRate)) Hz)."
    )
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
    print("Press Control-C to stop safely.")
    fflush(stdout)

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
    dispatchMain()
} catch {
    fputs("ERROR: \(error)\n", stderr)
    fputs("Run with --help for usage.\n", stderr)
    exit(EXIT_FAILURE)
}
