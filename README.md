# 直说 ZhiShuo

**拿起 DJI Mic，直接说话，自动转录发送。**

本机用 DJI 无线麦的实时音量做声控（VAD）：检测到持续说话 → 模拟一次「右 Option」启动豆包免按语音；持续静音 → 再发「右 Option」结束；可选延迟后发送 Return，实现说完就发送。

- 不上传音频，不调用云端 API  
- 音频仅用于本机电平判断  
- 开源、可 launchd 常驻  

> 英文仓库目录名可能仍是 `dji-mic-voice`；产品名以 **直说 / ZhiShuo** 为准。

## 工作原理

```text
┌─────────┐    CoreAudio     ┌──────────────┐
│ DJI Mic │ ───────────────> │ RMS / VAD    │
└─────────┘                  └──────┬───────┘
                                   │ 持续说话 / 持续静音
                                   v
                         ┌─────────────────────┐
                         │ 右 Option 单击（×2）  │
                         └──────────┬──────────┘
                                    v
                         ┌─────────────────────┐
                         │ 豆包输入法 · 免按模式  │
                         └──────────┬──────────┘
                                    │ 停说 + 可配置延迟
                                    v
                              Return（可选自动发送）
```

说明：VAD **不是**检测「拿起/放下」硬件事件，而是根据**麦克风音量**判断开始与结束。

## 系统要求

- macOS 13 或更新版本  
- Xcode Command Line Tools（提供 `swiftc`）  
- [豆包输入法](https://www.doubao.com/)：语音设为 **免按模式**，快捷键设为 **右 Option（右 ⌥）**  
- DJI Mic 系列接收器；默认设备名 `Wireless Mic Rx`（以系统「声音」里显示的名称为准）

## 完整安装步骤

### 1. 克隆仓库

```sh
git clone <repository-url>
cd dji-mic-voice   # 或你的本地目录名
```

### 2. 配置豆包输入法（必须先做）

1. 打开 **豆包输入法设置** → 语音输入 / 语音快捷键。  
2. 开启全局语音输入。  
3. 选择 **「免按模式」**（点一下开始，再点一下结束）。**不要用「按住 Fn」**。  
4. 将快捷键设为 **右 Option / 右 ⌥**。  
5. 系统与豆包的麦克风输入尽量选 **Wireless Mic Rx**（或你的接收器名称）。  
6. 切换到豆包输入法，把光标放在要出字的输入框里。

### 3. 一键安装

```sh
./install/install.sh
```

安装器会依次：

1. 编译 `task/vad-voice-trigger.swift` 并运行 `--self-test`；  
2. 安全停掉旧服务（含历史 label `com.linyu.djimic-vad`；**bootout 失败则中止**，避免双进程）；  
3. 将二进制与 LaunchAgent 装到固定路径（失败会回滚上一份文件）；  
4. **默认启动** `com.zhishuo.vad`，让进程首次调用麦克风 `requestAccess`，弹出系统授权；  
5. 再打开「麦克风 / 辅助功能」设置页，引导你**确认开关**（一般无需手动「+」添加二进制）。

自定义设备名与自动回车延迟（毫秒）：

```sh
./install/install.sh \
  --device "Wireless Mic Rx" \
  --auto-enter-delay-ms 1200
```

只装文件、**不**加载 launchd、**不**触发麦克风系统弹窗：

```sh
./install/install.sh --no-permission-guide --no-start
```

| 选项 | 含义 |
| --- | --- |
| `--no-start` | 只写入二进制与 `~/Library/LaunchAgents/com.zhishuo.vad.plist`，**不** `bootout`/`bootstrap`。不会触发 TCC 麦克风弹窗；需你稍后自行 `launchctl bootstrap` 或前台运行二进制。 |
| `--no-permission-guide` | 不打开系统设置与说明对话框；与是否启动服务无关。 |

### 4. 签名（推荐，减少「重编就丢权限」）

```sh
# 查看本机可用的代码签名身份
security find-identity -v -p codesigning

./install/install.sh --sign "证书名称或 SHA-1"
```

可在「钥匙串访问 → 证书助理 → 创建证书」中创建类型为 **代码签名** 的自签名证书，再把名称传给 `--sign`。私钥只留在本机，不要提交到仓库。

未指定 `--sign` 时，安装器使用 **ad-hoc 签名 + 固定安装路径 + 固定 bundle id（`com.zhishuo.vad`）**，仍比「每次在仓库里临时编译」更稳定，但升级二进制后 macOS 有时仍会要求重新授权。

## 权限说明（麦克风 + 辅助功能）

| 权限 | 用途 |
| --- | --- |
| **麦克风** | 读取 DJI 接收器音量，做本机 VAD |
| **辅助功能** | 向系统发送右 Option / Return 键事件 |

### 路径固定

运行与授权对象应是安装后的程序，而不是仓库里临时编出来的副本：

```text
~/Library/Application Support/zhishuo/vad-voice-trigger
```

**推荐流程（安装器默认）：** 先 `bootstrap` 服务 → 系统弹出麦克风授权时点「好」→ 在设置页确认列表里该程序开关为开。麦克风条目通常在首次 `requestAccess` 后**自动出现**，不必依赖手动「+」。

辅助功能：首次需要发键时系统也可能提示；若列表没有，再对上述固定路径点「+」。

### macOS TCC 坑（按「启动者 / 身份」授权）

1. **按可执行文件（及代码签名）记账**，不是按「你觉得这是哪个 App」。  
   从 Terminal 直接跑、从 launchd 跑、从 Herdr 拉起，若路径或签名不同，系统可能当成不同主体，**反复弹权限**。  
2. **只勾选 Terminal 不够**：launchd 启动的是上面的固定二进制，请确认 **该二进制** 在麦克风/辅助功能列表中已允许。  
3. **改权限后**请 `bootout`/`bootstrap` 或重开服务，否则旧进程仍无权限。  
4. **未稳定签名时重新编译**会换 CDHash，旧授权可能失效 → 用 `./install/install.sh` 装到固定路径，并尽量 `--sign`。  
5. **`--no-start` 不会触发麦克风弹窗**——只有进程真正访问麦克风时才会。  

### 日志路径

默认日志：

```text
~/Library/Logs/zhishuo.log
```

可用环境变量覆盖（安装前 export）：

| 变量 | 作用 |
| --- | --- |
| `ZHISHUO_LOG_PATH` | 日志文件完整路径（会自动 `mkdir -p` 其父目录） |
| `ZHISHUO_INSTALL_DIR` | 安装目录（默认 `~/Library/Application Support/zhishuo`） |
| `ZHISHUO_DEVICE_NAME` | 默认设备名 |
| `ZHISHUO_AUTO_ENTER_DELAY_MS` | 默认自动回车延迟 |
| `ZHISHUO_CODESIGN_IDENTITY` | 默认签名身份 |

仍兼容旧前缀 `DJIMIC_*`。

## 使用说明

### 日常使用

1. 插上 / 唤醒 DJI 接收器，确认系统输入设备正常。  
2. 确认 `com.zhishuo.vad` 已在运行（安装脚本默认会启动）。  
3. 焦点放在目标输入框，用豆包输入法。  
4. 对着 Mic **直接说话** → 自动开始转录；**停说约 0.8–1.2 秒** → 结束；默认再延迟后 **Return 发送**（由 `--auto-enter` 控制，安装默认开启）。

### 服务管理

```sh
# 状态
launchctl print gui/$(id -u)/com.zhishuo.vad

# 停止
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.zhishuo.vad.plist"

# 启动
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.zhishuo.vad.plist"

# 日志（若设置了 ZHISHUO_LOG_PATH 则用该路径）
tail -f "${ZHISHUO_LOG_PATH:-$HOME/Library/Logs/zhishuo.log}"
```

### 手动编译 / 调试

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
./task/vad-voice-trigger --list-devices
./task/vad-voice-trigger --dry-run --simulate-vad --auto-enter \
  --auto-enter-delay-ms 1200
./task/vad-voice-trigger --device "Wireless Mic Rx" --auto-enter
```

调试时优先 `--dry-run`（只打印 VAD，不发真实按键）。

### 安装器与主程序参数对照

| `install.sh` 选项 | 写入 launchd 的程序参数 | `vad-voice-trigger` CLI |
| --- | --- | --- |
| （固定） | 二进制路径 | — |
| `--device NAME` | `--device NAME` | `--device NAME` |
| （默认开启） | `--auto-enter` | `--auto-enter` |
| `--auto-enter-delay-ms MS` | `--auto-enter-delay-ms MS` | 同左（默认 1200） |

LaunchAgent Label：`com.zhishuo.vad`  
环境变量（可选）：`ZHISHUO_INSTALL_DIR`、`ZHISHUO_LOG_PATH`、`ZHISHUO_DEVICE_NAME`、`ZHISHUO_AUTO_ENTER_DELAY_MS`、`ZHISHUO_CODESIGN_IDENTITY`（仍兼容旧前缀 `DJIMIC_*`）。

## FAQ

### 为什么不用按键？

DJI Mic 2 的按键事件经 USB 是否稳定暴露给 macOS 因型号而异；社区在 Mic Mini 上有 HID 映射方案，但本项目刻意做成 **与按键无关的声控**：只要接收器作为输入设备进系统，就能「开口即录」。作者实测方向也是「拿起直接说、停说若干秒结束」。若你更需要硬件键触发，可另接 Karabiner / hidutil 方案，与本工具可并存讨论。

### 常驻听麦费电吗？

- **电脑侧**：进程轻量，主要是 CoreAudio 回调做 RMS；CPU 占用通常很低。  
- **麦克风侧**：接收器/发射器按 DJI 官方续航使用；本工具不会改变射频协议，只是电脑一直在读已打开的音频输入。  
- 不需要时用 `launchctl bootout ...` 停掉服务即可。

### 隐私：会上传音频吗？

**不会。** 本仓库程序只在本机计算音量并模拟按键；**不录音文件、不联网、不调云端 ASR**。  
真正做语音识别的是你本机已安装的 **豆包输入法**（其隐私策略以字节跳动产品说明为准）。直说本身不经手转写内容。

### 为什么重新编译后又提示权限？

未使用稳定证书时，新二进制 CDHash 会变。请用 `./install/install.sh` 装到固定路径，并尽量 `--sign`；授权时添加的是安装路径下的 `vad-voice-trigger`。

### 找不到 `Wireless Mic Rx`？

```sh
./task/vad-voice-trigger --list-devices
# 或
"~/Library/Application Support/zhishuo/vad-voice-trigger" --list-devices
```

用实际名称重装：

```sh
./install/install.sh --device "你在列表里看到的名字"
```

### 说完没有自动发送？

- 确认输入框仍有焦点。  
- 豆包是异步上屏，默认等 **1200ms** 再 Return；慢则加大：  
  `./install/install.sh --auto-enter-delay-ms 1800`  
- 日志里是否有 stop / auto-enter 记录。

### 服务反复重启？

`KeepAlive` 为 true。查看：

```sh
tail -50 "$HOME/Library/Logs/zhishuo.log"
```

常见原因：权限未给、设备断开、音频回调看门狗（约 1.5s 无回调）报错退出。

### 如何避免误发送？

自动回车会向**当前焦点**发真实 Return。先 `--dry-run` 调阈值；确认焦点在目标 App；可暂时去掉自动发送（需改 plist 去掉 `--auto-enter` 或自行改安装模板后重装）。

### 从旧版 `com.linyu.djimic-vad` 升级？

重新执行 `./install/install.sh` 即可：会卸载旧 Label、安装 `com.zhishuo.vad`。旧目录  
`~/Library/Application Support/djimic-vad` 可手动删除（不再默认使用）。

## 项目结构

```text
task/vad-voice-trigger.swift   主程序（VAD + 键鼠事件）
install/install.sh             编译、签名、权限引导、launchd
install/com.zhishuo.vad.plist  LaunchAgent 模板
LICENSE                        MIT
```

## 致谢

- **豆包输入法**（字节跳动）— 本地方便的免按语音与语义润色体验  
- **DJI 大疆** — Mic 系列无线麦克风硬件  
- 社区关于 Mic 电平声控、HID 映射与多 Agent 协作的讨论与实践  

本项目与上述厂商无官方关联。

## 免责声明

本项目 **不是** DJI 或字节跳动的官方产品。键鼠模拟、自动回车与常驻服务在错误焦点下可能产生非预期输入；请在可控环境测试并自行承担风险。软件按 MIT License「按原样」提供，不作特定用途担保。
