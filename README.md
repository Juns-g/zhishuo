# 直说 ZhiShuo · Fn 语音输入适配

中文 | [English](README.en.md)

**检测到说话后，自动触发输入法的语音输入；停说后，自动结束。**

这是 [ythx-101/zhishuo](https://github.com/ythx-101/zhishuo) 的个人适配 fork。程序根据麦克风音量判断起停，并模拟输入法快捷键。**真正的语音转文字由微信输入法或豆包输入法完成**，本项目不包含语音识别模型。

```text
麦克风 → 音量判断 → 按下/松开 Fn → 微信输入法转文字
```

## 和原项目有什么区别？

自动检测说话、触发输入法、静音后停止以及 launchd 常驻，**原项目已经具备**，不是本 fork 新发明的功能。

本 fork 的代码改动主要是：

- 新增 `--key-mode fn-hold`：说话时按住 Fn，停说后松开，适配微信输入法的长按 Fn 模式；保留原版的右 Option 点按模式。
- 将采音从 `AVAudioEngine` 改为原生 `AVCaptureSession`，用于解决本机遇到的无音频回调问题；按设备 UID 匹配输入，不静默换用其他麦克风。
- 新增运行时限参数 `--run-seconds SEC|unlimited`，退出时释放已按住的 Fn；Fn 模式拒绝 `--auto-enter`，不会自动回车发送。

## 使用前提

- Mac、Xcode Command Line Tools，以及已启用语音输入的输入法。
- 已连接的麦克风。本地实测组合为 DJI USB 接收器（`Wireless Mic Rx`）和微信输入法长按 Fn。
- 在 macOS「隐私与安全」中允许运行程序使用**麦克风**和**无障碍**权限。
- 输入法也要选择正确的麦克风，并将光标放在目标输入框。

## 编译与运行

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

阈值是本地使用参数，需要按麦克风音量与环境调整。按 `Control-C` 停止；`--help` 查看选项。无硬件模拟检查可用 `--dry-run --simulate-vad --key-mode fn-hold`，不会发真实按键。

这里发布的是源码，不包含本机签名的 App 或个人登录服务。上游 `install/install.sh` 仍配置右 Option／豆包工作流，并开启自动回车；**不要把它当作上述 Fn 模式的安装器**。原版完整说明保留在 [README.upstream.md](README.upstream.md)。

## 已知边界

- **开头可能丢字**：检测声音后才启动输入法，没有音频预缓冲。可先说一句短引导，再接正文；中间不要停太久，当前示例静音约一秒结束。
- 按音量判断，不识别说话者，也不检测「拿起麦克风」；环境声音可能误触发。
- 指定的麦克风断开后不能继续使用这一路声控，不会自动切到电脑麦克风。持续待命会持续使用麦克风。
- 本工具不保存录音或转写内容，也不上传音频；输入法自身是否联网，以其隐私政策为准。

## 来源与许可

基于 Yu Lin（ythx-101）的 [ZhiShuo](https://github.com/ythx-101/zhishuo)，保留原作者版权与 [MIT License](LICENSE)。本项目与 DJI、腾讯或字节跳动无官方关联。
