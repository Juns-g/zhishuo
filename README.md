# DJI Mic Voice Trigger for macOS

用 DJI Mic 的实时音量驱动豆包输入法语音输入：检测到持续说话时发送一次右 Option，持续静音后再次发送右 Option；可选的自动回车会等待转录文本完成后发送 Return，实现“说完就发送”。

项目是一个轻量的 Swift/CoreAudio 工具，不上传音频，也不调用云端 API。音频只用于本机 VAD（Voice Activity Detection）电平判断。

## 工作原理

```text
┌─────────┐    CoreAudio     ┌──────────────┐
│ DJI Mic │ ───────────────> │ RMS / VAD    │
└─────────┘                  └──────┬───────┘
                                   │ sustained speech / silence
                                   v
                         ┌─────────────────────┐
                         │ Right Option events │
                         └──────────┬──────────┘
                                    v
                         ┌─────────────────────┐
                         │ 豆包输入法免按模式   │
                         └──────────┬──────────┘
                                    │ stop + configurable delay
                                    v
                              Return（可选）
```

VAD 不是“拿起/放下”硬件事件检测：它依据麦克风音量判断开始与结束。

## 系统要求

- macOS 13 或更新版本
- Xcode Command Line Tools（提供 `swiftc`）
- 豆包输入法，语音模式设为“免按模式”，快捷键设为“右 Option”
- DJI Mic 接收器；默认设备名为 `Wireless Mic Rx`

## 安装

```sh
git clone <repository-url>
cd dji-mic-voice
./install/install.sh
```

安装器会：

1. 编译并运行 `--self-test`；
2. 将程序安装到 `~/Library/Application Support/djimic-vad/`；
3. 从 [install/com.linyu.djimic-vad.plist](install/com.linyu.djimic-vad.plist) 生成当前用户的 LaunchAgent；
4. 引导添加麦克风和辅助功能权限；
5. 启动 `com.linyu.djimic-vad`。

自定义设备和自动回车延迟：

```sh
./install/install.sh \
  --device "Wireless Mic Rx" \
  --auto-enter-delay-ms 1200
```

只安装文件、不启动服务：

```sh
./install/install.sh --no-permission-guide --no-start
```

## 固定签名与权限

macOS 的 TCC 会同时参考路径和代码身份。普通 `swiftc` 输出使用 ad-hoc 签名，其 designated requirement 绑定构建产物的 CDHash；重新编译后 CDHash 改变，旧权限可能失效。

安装器支持两种模式：

- 推荐：使用 Keychain 中稳定的 Code Signing 身份。权限可跟随同一签名身份。
- 降级：没有签名身份时，使用固定安装路径和固定 bundle identifier。它解决仓库路径、Terminal/launchd 启动者不同的问题，但升级替换二进制后，macOS 仍可能要求重新授权。

查看可用签名身份：

```sh
security find-identity -v -p codesigning
```

使用已有的 Apple Development 或自签名 Code Signing 证书：

```sh
./install/install.sh --sign "证书名称或 SHA-1"
```

如需自签名身份，可在“钥匙串访问 → 证书助理 → 创建证书”中创建类型为“代码签名”的自签名证书，然后把名称传给 `--sign`。私钥只保存在本机钥匙串，不应提交到仓库。

需要授权的固定程序路径：

```text
~/Library/Application Support/djimic-vad/vad-voice-trigger
```

在“系统设置 → 隐私与安全性”中为该程序开启：

- 麦克风：读取 DJI Mic 音频电平；
- 辅助功能：发送右 Option 和 Return 键。

## 使用

安装后由 launchd 常驻运行：

```sh
launchctl print gui/$(id -u)/com.linyu.djimic-vad
```

停止与重新加载：

```sh
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.linyu.djimic-vad.plist"
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.linyu.djimic-vad.plist"
```

查看日志：

```sh
tail -f "$HOME/Library/Logs/djimic-vad.log"
```

手动编译和验证：

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

./task/vad-voice-trigger --self-test
./task/vad-voice-trigger --dry-run --simulate-vad --auto-enter \
  --auto-enter-delay-ms 1200
```

## FAQ

### 为什么重新编译后又提示权限？

未使用稳定证书签名时，新二进制的 CDHash 会变化。重新运行安装器并按引导更新权限；长期使用建议传入稳定的 `--sign` 身份。

### 找不到 `Wireless Mic Rx`？

先连接并唤醒接收器，然后运行：

```sh
./task/vad-voice-trigger --list-devices
```

如果系统中的名字不同，用 `install.sh --device "实际名称"` 重新安装。

### 为什么说完没有自动发送？

确认目标输入框仍有焦点。豆包转录是异步流式上屏，默认会等待 1200ms；较慢时可增大 `--auto-enter-delay-ms`。

### 为什么服务反复重启？

检查日志中的权限、设备断开或 `No audio callback` 错误。LaunchAgent 使用 `KeepAlive`，异常退出后会自动重启。

### 如何避免误发送？

自动回车会向当前聚焦应用发送真实 Return。测试时先使用 `--dry-run`，并确认焦点在目标输入框。

## 项目结构

```text
task/vad-voice-trigger.swift       主程序
install/install.sh                 编译、安装、权限引导和 launchd 加载
install/com.linyu.djimic-vad.plist 可移植 LaunchAgent 模板
LICENSE                            MIT License
```

## 免责声明

本项目不是 DJI 或字节跳动官方产品。键盘事件、自动回车和常驻服务可能在错误焦点下触发非预期操作；请在可控环境中测试并自行承担使用风险。项目按 MIT License 以“原样”提供，不保证适用于任何特定用途。
