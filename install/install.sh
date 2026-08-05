#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
SOURCE_PATH="$REPO_ROOT/task/vad-voice-trigger.swift"
PLIST_TEMPLATE="$SCRIPT_DIR/com.zhishuo.vad.plist"

LABEL="com.zhishuo.vad"
# Prefer ZHISHUO_* env; fall back to legacy DJIMIC_* for existing installs.
INSTALL_DIR="${ZHISHUO_INSTALL_DIR:-${DJIMIC_INSTALL_DIR:-$HOME/Library/Application Support/zhishuo}}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LOG_PATH="${ZHISHUO_LOG_PATH:-${DJIMIC_LOG_PATH:-$LOG_DIR/zhishuo.log}}"
DEVICE_NAME="${ZHISHUO_DEVICE_NAME:-${DJIMIC_DEVICE_NAME:-Wireless Mic Rx}}"
AUTO_ENTER_DELAY_MS="${ZHISHUO_AUTO_ENTER_DELAY_MS:-${DJIMIC_AUTO_ENTER_DELAY_MS:-1200}}"
CODESIGN_IDENTITY="${ZHISHUO_CODESIGN_IDENTITY:-${DJIMIC_CODESIGN_IDENTITY:-}}"
SHOW_PERMISSION_GUIDE=1
START_SERVICE=1

# Old personal label (migrated away in this release).
LEGACY_LABEL="com.linyu.djimic-vad"
LEGACY_PLIST_PATH="$LAUNCH_AGENTS_DIR/$LEGACY_LABEL.plist"

usage() {
    print -r -- "Usage: ./install/install.sh [options]"
    print -r -- ""
    print -r -- "  直说 (ZhiShuo) — 安装本机 VAD 声控服务"
    print -r -- ""
    print -r -- "  --device NAME              输入设备名（默认: Wireless Mic Rx）"
    print -r -- "  --auto-enter-delay-ms MS   停说后发送 Return 的延迟（默认: 1200）"
    print -r -- "  --sign IDENTITY            使用钥匙串中的代码签名身份签名"
    print -r -- "  --no-permission-guide      不打开 macOS 权限引导"
    print -r -- "  --no-start                 只安装文件，不加载 launchd"
    print -r -- "  --help                     显示帮助"
}

fail() {
    print -u2 -r -- "ERROR: $1"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --device)
            (( $# >= 2 )) || fail "--device requires a value."
            DEVICE_NAME="$2"
            shift 2
            ;;
        --auto-enter-delay-ms)
            (( $# >= 2 )) || fail "--auto-enter-delay-ms requires a value."
            AUTO_ENTER_DELAY_MS="$2"
            shift 2
            ;;
        --sign)
            (( $# >= 2 )) || fail "--sign requires an identity name or SHA-1 hash."
            CODESIGN_IDENTITY="$2"
            shift 2
            ;;
        --no-permission-guide)
            SHOW_PERMISSION_GUIDE=0
            shift
            ;;
        --no-start)
            START_SERVICE=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[[ -f "$SOURCE_PATH" ]] || fail "Source not found: $SOURCE_PATH"
[[ -f "$PLIST_TEMPLATE" ]] || fail "plist template not found: $PLIST_TEMPLATE"
[[ -n "$DEVICE_NAME" ]] || fail "The input device name cannot be empty."
case "$AUTO_ENTER_DELAY_MS" in
    ''|*[!0-9]*) fail "--auto-enter-delay-ms must be a non-negative integer." ;;
esac

command -v swiftc >/dev/null || fail "swiftc is required. Install Xcode Command Line Tools first."
command -v codesign >/dev/null || fail "codesign is required."

BUILD_PARENT="${TMPDIR:-/tmp}"
BUILD_PARENT="${BUILD_PARENT%/}"
BUILD_DIR="$(mktemp -d "$BUILD_PARENT/zhishuo-install.XXXXXX")"
STAGED_BINARY="$BUILD_DIR/vad-voice-trigger"
STAGED_PLIST="$BUILD_DIR/$LABEL.plist"

cleanup() {
    case "${BUILD_DIR:-}" in
        "$BUILD_PARENT"/zhishuo-install.*)
            [[ -d "$BUILD_DIR" ]] && rm -rf -- "$BUILD_DIR"
            ;;
    esac
}
trap cleanup EXIT INT TERM

print -r -- "Building 直说 (vad-voice-trigger)..."
swiftc \
    -framework AVFoundation \
    -framework AVFAudio \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework CoreGraphics \
    -framework ApplicationServices \
    "$SOURCE_PATH" \
    -o "$STAGED_BINARY"

if [[ -n "$CODESIGN_IDENTITY" ]]; then
    security find-identity -v -p codesigning | grep -F -- "$CODESIGN_IDENTITY" >/dev/null \
        || fail "Code-signing identity not found: $CODESIGN_IDENTITY"
    codesign --force --sign "$CODESIGN_IDENTITY" \
        --identifier "$LABEL" --timestamp=none "$STAGED_BINARY"
    SIGNING_MODE="identity: $CODESIGN_IDENTITY"
else
    codesign --force --sign - --identifier "$LABEL" --timestamp=none "$STAGED_BINARY"
    SIGNING_MODE="ad-hoc fallback at a fixed install path"
fi

BIN_PATH="$INSTALL_DIR/vad-voice-trigger"
PREVIOUS_BINARY="$INSTALL_DIR/vad-voice-trigger.previous"
PREVIOUS_PLIST="$INSTALL_DIR/$LABEL.plist.previous"

codesign --verify --strict --verbose=2 "$STAGED_BINARY"
"$STAGED_BINARY" --self-test

# ProgramArguments layout (must stay 6 entries, matching the template):
#   0: binary path
#   1: --device
#   2: device name
#   3: --auto-enter
#   4: --auto-enter-delay-ms
#   5: delay ms
cp -- "$PLIST_TEMPLATE" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Set :Label $LABEL" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 \"$BIN_PATH\"" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:2 \"$DEVICE_NAME\"" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:5 \"$AUTO_ENTER_DELAY_MS\"" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Set :WorkingDirectory \"$INSTALL_DIR\"" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath \"$LOG_PATH\"" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath \"$LOG_PATH\"" "$STAGED_PLIST"
plutil -lint "$STAGED_PLIST"
if grep -F '__' "$STAGED_PLIST" >/dev/null; then
    fail "Generated plist still contains template placeholders."
fi
ARGUMENT_COUNT="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$STAGED_PLIST" \
    | sed -n '/^[[:space:]]/p' | wc -l | tr -d ' ')"
[[ "$ARGUMENT_COUNT" == "6" ]] || fail "Generated plist must contain exactly 6 arguments."

mkdir -p -- "$INSTALL_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

USER_ID="$(id -u)"
LAUNCH_DOMAIN="gui/$USER_ID"

# Unload legacy personal label if present.
if launchctl print "$LAUNCH_DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
    print -r -- "Stopping legacy LaunchAgent: $LEGACY_LABEL ..."
    launchctl bootout "$LAUNCH_DOMAIN/$LEGACY_LABEL" || true
fi
if [[ -f "$LEGACY_PLIST_PATH" ]]; then
    print -r -- "Removing legacy plist: $LEGACY_PLIST_PATH"
    rm -f -- "$LEGACY_PLIST_PATH"
fi

if launchctl print "$LAUNCH_DOMAIN/$LABEL" >/dev/null 2>&1; then
    print -r -- "Stopping the existing LaunchAgent..."
    launchctl bootout "$LAUNCH_DOMAIN/$LABEL"
fi

if [[ -f "$BIN_PATH" ]]; then
    cp -p -- "$BIN_PATH" "$PREVIOUS_BINARY"
fi
if [[ -f "$PLIST_PATH" ]]; then
    cp -p -- "$PLIST_PATH" "$PREVIOUS_PLIST"
fi
install -m 755 "$STAGED_BINARY" "$BIN_PATH"
install -m 644 "$STAGED_PLIST" "$PLIST_PATH"
plutil -lint "$PLIST_PATH"

if (( SHOW_PERMISSION_GUIDE )); then
    export ZHISHUO_GUIDE_BINARY="$BIN_PATH"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    osascript <<'APPLESCRIPT'
set binaryPath to system attribute "ZHISHUO_GUIDE_BINARY"
display dialog "【直说 ZhiShuo】请在「辅助功能」中点击 +，添加下面的程序并打开开关：" & return & return & binaryPath & return & return & "说明：macOS 按「可执行文件身份」授权。请添加安装后的固定路径（不要只勾 Terminal）。" & return & return & "完成后点「下一步」。" buttons {"下一步"} default button "下一步" with title "直说 ZhiShuo 安装"
APPLESCRIPT
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    osascript <<'APPLESCRIPT'
set binaryPath to system attribute "ZHISHUO_GUIDE_BINARY"
display dialog "【直说 ZhiShuo】请在「麦克风」中点击 +，添加同一程序并打开开关：" & return & return & binaryPath & return & return & "完成后点「继续安装」。" buttons {"继续安装"} default button "继续安装" with title "直说 ZhiShuo 安装"
APPLESCRIPT
fi

if (( START_SERVICE )); then
    launchctl enable "$LAUNCH_DOMAIN/$LABEL"
    launchctl bootstrap "$LAUNCH_DOMAIN" "$PLIST_PATH"
    print -r -- "LaunchAgent started: $LABEL"
else
    print -r -- "LaunchAgent was not started (--no-start)."
fi

print -r -- ""
print -r -- "直说 (ZhiShuo) installed."
print -r -- "Binary:  $BIN_PATH"
print -r -- "plist:   $PLIST_PATH"
print -r -- "Log:     $LOG_PATH"
print -r -- "Signing: $SIGNING_MODE"
print -r -- "Device:  $DEVICE_NAME"
print -r -- "Auto-enter delay: ${AUTO_ENTER_DELAY_MS} ms"
