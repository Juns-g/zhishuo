# ZhiShuo · Fn dictation adaptation

[中文](README.md) | English

**Detect speaking, start your input method's dictation automatically, and stop it when you stop speaking.**

A personal adaptation of [ythx-101/zhishuo](https://github.com/ythx-101/zhishuo). It monitors microphone levels and simulates a dictation shortcut. **WeType or Doubao performs the actual speech-to-text**; this project does not include a speech recognition model.

```text
Microphone → level detection → Fn down/up → WeType speech-to-text
```

## What differs from upstream?

Voice-triggered dictation, silence detection, and launchd background operation **already exist upstream**. They are not new inventions in this fork.

The code changes here are primarily:

- `--key-mode fn-hold`: hold Fn while speaking and release it after silence, for WeType's hold-Fn dictation. The original right-Option toggle mode remains available.
- Native `AVCaptureSession` audio capture instead of `AVAudioEngine`, addressing missing audio callbacks observed on the local setup. Input selection uses an exact device UID match rather than silently substituting another microphone.
- `--run-seconds SEC|unlimited` for bounded or continuous listening, with Fn release during shutdown. Fn mode rejects `--auto-enter` and does not send Return automatically.

## Requirements

- A Mac, Xcode Command Line Tools, and an input method with dictation enabled.
- A connected microphone. The locally exercised setup is a DJI USB receiver (`Wireless Mic Rx`) with WeType's hold-Fn mode.
- **Microphone** and **Accessibility** permission for the program under macOS Privacy & Security.
- The input method must also use the correct microphone; focus the intended text field.

## Build and run

```sh
git clone https://github.com/Juns-g/zhishuo.git
cd zhishuo
xcrun swiftc -framework AVFoundation -framework AVFAudio -framework CoreAudio \
  -framework AudioToolbox -framework CoreMedia -framework CoreGraphics \
  -framework ApplicationServices task/vad-voice-trigger.swift -o task/vad-voice-trigger

./task/vad-voice-trigger --self-test
./task/vad-voice-trigger --list-devices
./task/vad-voice-trigger --key-mode fn-hold --device "Wireless Mic Rx" \
  --run-seconds unlimited --start-ms 30 --threshold-db -50 --stop-threshold-db -56
```

These thresholds are local settings, not universal presets. Adjust them for your microphone and room. Stop with `Control-C`; see `--help` for options. `--dry-run --simulate-vad --key-mode fn-hold` checks the state transitions without hardware or real key events.

This repository distributes source, not the locally signed App or personal login service. The upstream `install/install.sh` still configures the right-Option/Doubao workflow with automatic Return enabled; **it does not install the Fn configuration above**. The complete original documentation is retained in [README.upstream.md](README.upstream.md).

## Known limitations

- **Initial words may be clipped.** Dictation starts only after sound is detected; there is no audio pre-buffer. A short spoken lead-in can help. Avoid a long pause before the main sentence: the example stops after roughly one second of silence.
- Detection is level-based, not speaker recognition or a microphone pickup sensor. Environmental sound can trigger it.
- Disconnecting the selected microphone makes this trigger path unavailable; it does not automatically switch to the built-in microphone. Continuous listening keeps the microphone in use.
- This tool does not save recordings or transcripts or upload audio. The input method's own network use is governed by its privacy policy.

## Credits and license

Based on Yu Lin's (ythx-101) [ZhiShuo](https://github.com/ythx-101/zhishuo). Original copyright and [MIT License](LICENSE) are retained. This project is not affiliated with DJI, Tencent, or ByteDance.
