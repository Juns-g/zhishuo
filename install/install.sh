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
DEFAULT_LOG_DIR="$HOME/Library/Logs"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LOG_PATH="${ZHISHUO_LOG_PATH:-${DJIMIC_LOG_PATH:-$DEFAULT_LOG_DIR/zhishuo.log}}"
LOG_PARENT="$(dirname -- "$LOG_PATH")"
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
    print -r -- "  --no-permission-guide      不打开 macOS 权限引导对话框"
    print -r -- "  --no-start                 只安装二进制与 plist，不 bootout/bootstrap launchd"
    print -r -- "                             （不会触发麦克风 requestAccess 系统弹窗）"
    print -r -- "  --help                     显示帮助"
}

fail() {
    print -u2 -r -- "ERROR: $1"
    exit 1
}

# Unload a LaunchAgent and require that launchctl no longer lists it.
# On failure: abort immediately (do not delete plists or start a new job).
stop_launch_agent() {
    local domain="$1"
    local label="$2"
    local service="$domain/$label"

    if ! launchctl print "$service" >/dev/null 2>&1; then
        return 0
    fi

    print -r -- "Stopping LaunchAgent: $label ..."
    if ! launchctl bootout "$service"; then
        fail "Failed to bootout $service. Fix or stop it manually, then re-run install."
    fi

    # bootout is async on some systems; wait briefly for the job to vanish.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! launchctl print "$service" >/dev/null 2>&1; then
            print -r -- "Confirmed stopped: $label"
            return 0
        fi
        sleep 0.2
    done

    fail "LaunchAgent $service is still loaded after bootout. Refusing to continue (would risk dual processes)."
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
HAD_PREVIOUS_BINARY=0
HAD_PREVIOUS_PLIST=0

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

mkdir -p -- "$INSTALL_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_PARENT"

USER_ID="$(id -u)"
LAUNCH_DOMAIN="gui/$USER_ID"

# --- Stop running agents before replacing files (fail hard if unload fails) ---
stop_launch_agent "$LAUNCH_DOMAIN" "$LEGACY_LABEL"
if [[ -f "$LEGACY_PLIST_PATH" ]]; then
    print -r -- "Removing legacy plist: $LEGACY_PLIST_PATH"
    rm -f -- "$LEGACY_PLIST_PATH"
fi
stop_launch_agent "$LAUNCH_DOMAIN" "$LABEL"

# --- Install with rollback on failure ---
if [[ -f "$BIN_PATH" ]]; then
    cp -p -- "$BIN_PATH" "$PREVIOUS_BINARY"
    HAD_PREVIOUS_BINARY=1
fi
if [[ -f "$PLIST_PATH" ]]; then
    cp -p -- "$PLIST_PATH" "$PREVIOUS_PLIST"
    HAD_PREVIOUS_PLIST=1
fi

rollback_install() {
    print -u2 -r -- "Install failed; rolling back previous binary/plist if present..."
    if (( HAD_PREVIOUS_BINARY )) && [[ -f "$PREVIOUS_BINARY" ]]; then
        install -m 755 "$PREVIOUS_BINARY" "$BIN_PATH" || true
    fi
    if (( HAD_PREVIOUS_PLIST )) && [[ -f "$PREVIOUS_PLIST" ]]; then
        install -m 644 "$PREVIOUS_PLIST" "$PLIST_PATH" || true
    fi
}

if ! install -m 755 "$STAGED_BINARY" "$BIN_PATH"; then
    rollback_install
    fail "Failed to install binary to $BIN_PATH"
fi
if ! install -m 644 "$STAGED_PLIST" "$PLIST_PATH"; then
    rollback_install
    fail "Failed to install plist to $PLIST_PATH"
fi
if ! plutil -lint "$PLIST_PATH" >/dev/null; then
    rollback_install
    fail "Installed plist failed plutil -lint: $PLIST_PATH"
fi

# --- Start service first (triggers TCC requestAccess for microphone) ---
if (( START_SERVICE )); then
    if ! launchctl enable "$LAUNCH_DOMAIN/$LABEL"; then
        rollback_install
        fail "launchctl enable failed for $LAUNCH_DOMAIN/$LABEL"
    fi
    if ! launchctl bootstrap "$LAUNCH_DOMAIN" "$PLIST_PATH"; then
        rollback_install
        fail "launchctl bootstrap failed for $PLIST_PATH"
    fi
    # Confirm the new job is listed.
    if ! launchctl print "$LAUNCH_DOMAIN/$LABEL" >/dev/null 2>&1; then
        rollback_install
        fail "LaunchAgent $LABEL did not appear after bootstrap."
    fi
    print -r -- "LaunchAgent started: $LABEL"
    # Give the process a moment to call requestAccess / touch Accessibility.
    sleep 1.5
else
    print -r -- "LaunchAgent was not started (--no-start)."
    print -r -- "  --no-start: only files were installed; launchd was not loaded."
    print -r -- "  Microphone TCC prompt will not fire until you bootstrap or run the binary."
fi

# --- Permission guide AFTER first launch (confirm system prompts / toggles) ---
if (( SHOW_PERMISSION_GUIDE )); then
    export ZHISHUO_GUIDE_BINARY="$BIN_PATH"
    if (( START_SERVICE )); then
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        osascript <<'APPLESCRIPT'
set binaryPath to system attribute "ZHISHUO_GUIDE_BINARY"
display dialog "【直说 ZhiShuo】服务已启动。" & return & return & "若系统弹出「要访问麦克风吗」，请点「好」。" & return & return & "然后在「麦克风」列表中确认已开启（路径应类似）：" & return & binaryPath & return & return & "一般无需手动点「+」添加；首次 requestAccess 后会自动出现。" & return & return & "完成后点「下一步」。" buttons {"下一步"} default button "下一步" with title "直说 ZhiShuo 安装"
APPLESCRIPT
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        osascript <<'APPLESCRIPT'
set binaryPath to system attribute "ZHISHUO_GUIDE_BINARY"
display dialog "【直说 ZhiShuo】请在「辅助功能」中确认已允许本程序（或允许系统弹窗）：" & return & return & binaryPath & return & return & "用途：发送右 Option / Return。若列表中暂无，可点「+」添加上述固定路径并打开开关。" & return & return & "完成后点「完成」。" buttons {"完成"} default button "完成" with title "直说 ZhiShuo 安装"
APPLESCRIPT
    else
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        osascript <<APPLESCRIPT
set binaryPath to system attribute "ZHISHUO_GUIDE_BINARY"
display dialog "【直说 ZhiShuo】本次使用了 --no-start，尚未加载服务，因此不会自动弹出麦克风授权。" & return & return & "请稍后执行：" & return & "  launchctl bootstrap gui/$USER_ID $PLIST_PATH" & return & return & "或运行：" & return & binaryPath & return & return & "首次访问麦克风时按系统弹窗授权，再在设置里确认开关。" & return & return & "完成后点「下一步」。" buttons {"下一步"} default button "下一步" with title "直说 ZhiShuo 安装"
APPLESCRIPT
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        osascript <<'APPLESCRIPT'
set binaryPath to system attribute "ZHISHUO_GUIDE_BINARY"
display dialog "【直说 ZhiShuo】「辅助功能」也可在首次发送按键时由系统提示。" & return & return & "固定路径：" & return & binaryPath & return & return & "完成后点「完成」。" buttons {"完成"} default button "完成" with title "直说 ZhiShuo 安装"
APPLESCRIPT
    fi
fi

print -r -- ""
print -r -- "直说 (ZhiShuo) installed."
print -r -- "Binary:  $BIN_PATH"
print -r -- "plist:   $PLIST_PATH"
print -r -- "Log:     $LOG_PATH"
print -r -- "Signing: $SIGNING_MODE"
print -r -- "Device:  $DEVICE_NAME"
print -r -- "Auto-enter delay: ${AUTO_ENTER_DELAY_MS} ms"
if (( ! START_SERVICE )); then
    print -r -- "Note:     --no-start was set; start later with:"
    print -r -- "  launchctl bootstrap gui/$(id -u) \"$PLIST_PATH\""
fi
