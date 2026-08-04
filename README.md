# DJI Mic 2 声控语音输入项目

拿起 DJI Mic 2 即说即录，持续静音后自动停止豆包语音输入。监听器使用 VAD 检测语音，并发送右 Option 控制豆包输入法的免按模式。可选的 `--auto-enter` 会在成功停止语音输入后再发送 Return，实现“说完就发送”；该功能默认关闭。

## 前置设置

1. 在豆包输入法的语音输入设置中选择“免按模式”，快捷键设为“右 Option”。
2. 将 DJI 接收器连接到 Mac，确认 `Wireless Mic Rx` 可用。
3. 为启动监听器的程序授予“麦克风”和“辅助功能”权限。Terminal 手动启动时授权 `Terminal.app`；launchd 直接启动时，如系统再次提示，应授权对应的监听器进程。

## 编译

在仓库根目录运行：

```sh
swiftc \
  -framework AVFoundation \
  -framework AVFAudio \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework CoreGraphics \
  -framework ApplicationServices \
  task/vad-voice-trigger.swift \
  -o task/vad-voice-trigger
```

验证：

```sh
./task/vad-voice-trigger --self-test
./task/vad-voice-trigger --dry-run --simulate-vad --auto-enter
```

## 手动启动

普通声控模式：

```sh
./task/vad-voice-trigger --device "Wireless Mic Rx"
```

说完自动发送：

```sh
./task/vad-voice-trigger --device "Wireless Mic Rx" --auto-enter
```

按 `Control-C` 安全停止。`--auto-enter` 会向当前聚焦的应用发送真实 Return，因此启用前应确认光标位于希望自动发送的输入框。

## launchd 常驻服务

仓库中的模板为 `launchd/com.linyu.djimic-vad.plist`。安装到当前用户的 LaunchAgents：

```sh
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
cp launchd/com.linyu.djimic-vad.plist ~/Library/LaunchAgents/com.linyu.djimic-vad.plist
```

加载并开机自启：

```sh
launchctl load ~/Library/LaunchAgents/com.linyu.djimic-vad.plist
```

卸载服务：

```sh
launchctl unload ~/Library/LaunchAgents/com.linyu.djimic-vad.plist
```

plist 使用 `RunAtLoad` 和 `KeepAlive`：登录后自动启动，进程退出或崩溃后由 launchd 重启。它固定运行以下真实模式命令：

```sh
./task/vad-voice-trigger --device "Wireless Mic Rx" --auto-enter
```

加载服务前，先在原 Terminal 窗口按 `Control-C` 停止手动监听器，避免两个实例重复发送右 Option 和 Return。

日志位置：

```text
~/Library/Logs/djimic-vad.log
```

实时查看日志：

```sh
tail -f ~/Library/Logs/djimic-vad.log
```

## 项目流程

本项目使用 Agent SOP 流程：research → plan → approval → implement → review → verify → signoff。
