#!/bin/zsh
set -e

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

echo "Installing noSleep..."
echo ""

if ! command -v swiftc &> /dev/null; then
    echo "Error: Swift compiler not found."
    echo "Please install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

if ! command -v clang &> /dev/null; then
    echo "Error: clang compiler not found."
    echo "Please install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

# Detect existing install so we can restart the daemon after upgrade.
LABEL="com.noSleep.daemon"
USER_DOMAIN="gui/$(id -u)"
COMPILE_LOG="/tmp/noSleep_compile_error.log"
DAEMON_COMPILE_LOG="/tmp/noSleep_daemon_compile_error.log"
DAEMON_PATH="$HOME/bin/noSleepDaemon"
DAEMON_LOCK="$HOME/Library/Application Support/noSleep/noSleep.lock"
DAEMON_BUILD=""
PLIST_TMP=""
WAS_RUNNING=false
PREVIOUS_DAEMON_PID=""
if [[ -r "$DAEMON_LOCK" ]]; then
    read -r PREVIOUS_DAEMON_PID < "$DAEMON_LOCK" || PREVIOUS_DAEMON_PID=""
fi
if /bin/launchctl print "$USER_DOMAIN/$LABEL" >/dev/null 2>&1; then
    WAS_RUNNING=true
fi

cleanup_empty_compile_log() {
    if [[ -f "$COMPILE_LOG" && ! -s "$COMPILE_LOG" ]]; then
        rm -f "$COMPILE_LOG"
    fi
    if [[ -f "$DAEMON_COMPILE_LOG" && ! -s "$DAEMON_COMPILE_LOG" ]]; then
        rm -f "$DAEMON_COMPILE_LOG"
    fi
}

cleanup_plist_tmp() {
    if [[ -n "$PLIST_TMP" ]]; then
        rm -f "$PLIST_TMP"
    fi
    if [[ -n "$DAEMON_BUILD" ]]; then
        rm -f "$DAEMON_BUILD"
    fi
}
trap cleanup_plist_tmp EXIT

wait_for_daemon_lock() {
    local previous_pid="${1:-}"
    local pid
    local args
    for _ in {1..50}; do
        if [[ -r "$DAEMON_LOCK" ]]; then
            read -r pid < "$DAEMON_LOCK" || pid=""
            args="$(/bin/ps -p "$pid" -o args= 2>/dev/null || true)"
            if [[ "$pid" =~ '^[0-9]+$' ]] &&
                [[ "$pid" != "$previous_pid" ]] &&
                [[ "$args" == "$DAEMON_PATH"* ]]; then
                return 0
            fi
        fi
        sleep 0.1
    done
    return 1
}

echo "Compiling..."
CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
CPU_NUMBER=$(echo "$CPU_BRAND" | sed -nE 's/.*Apple M([0-9]+).*/\1/p')
TARGET_CPUS=()
COMPILED=false

if [[ -n "$CPU_NUMBER" ]]; then
    for ((cpu = CPU_NUMBER; cpu >= 1; cpu--)); do
        TARGET_CPUS+=("apple-m$cpu")
    done
fi

for TARGET_CPU in "${TARGET_CPUS[@]}"; do
    echo "Detected CPU: $CPU_BRAND → Trying optimized build with -target-cpu $TARGET_CPU"

    # Try optimized compilation with error trapping and log to file
    if swiftc -O -target-cpu "$TARGET_CPU" Sources/noSleep/*.swift -o noSleep 2>"$COMPILE_LOG"; then
        cleanup_empty_compile_log
        echo "✓ Optimized compilation successful ($TARGET_CPU)"
        COMPILED=true
        break
    fi

    if grep -qEi "unsupported|unknown target CPU|not recognized" "$COMPILE_LOG"; then
        echo "⚠️ Compiler does not support -target-cpu $TARGET_CPU. Trying next fallback..."
    else
        echo "⚠️ Optimized compilation failed for $TARGET_CPU. Trying next fallback..."
        cat "$COMPILE_LOG"
    fi
    rm -f "$COMPILE_LOG"
done

# Fallback to standard compilation if optimized one failed or wasn't attempted
if [[ "$COMPILED" == false ]]; then
    echo "Compiling with standard settings..."
    if ! swiftc -O Sources/noSleep/*.swift -o noSleep 2>"$COMPILE_LOG"; then
        echo "❌ Compilation failed:"
        cat "$COMPILE_LOG"
        rm -f "$COMPILE_LOG"
        exit 1
    fi
    cleanup_empty_compile_log
    echo "✓ Standard compilation successful"
fi

echo "Compiling minimal daemon..."
DAEMON_BUILD="$(mktemp "${TMPDIR:-/tmp}/noSleepDaemon.XXXXXX")"
if ! clang -Os \
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion \
    -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Wshadow -Werror \
    -fstack-protector-strong -fvisibility=hidden \
    Sources/noSleep/noSleepDaemon.c \
    -framework CoreFoundation \
    -framework IOKit \
    -o "$DAEMON_BUILD" 2>"$DAEMON_COMPILE_LOG"; then
    echo "❌ Daemon compilation failed:"
    cat "$DAEMON_COMPILE_LOG"
    rm -f "$DAEMON_COMPILE_LOG"
    exit 1
fi
cleanup_empty_compile_log
echo "✓ Minimal daemon compilation successful"

mkdir -p ~/bin
mkdir -p "$HOME/Library/Application Support/noSleep"
chmod 700 "$HOME/Library/Application Support/noSleep"
cp noSleep ~/bin/noSleep
cp "$DAEMON_BUILD" ~/bin/noSleepDaemon
chmod +x ~/bin/noSleep
chmod +x ~/bin/noSleepDaemon

# Generate plist with expanded $HOME
PLIST_DEST=~/Library/LaunchAgents/com.noSleep.daemon.plist
PLIST_TMP="$PLIST_DEST.tmp.$$"
cat > "$PLIST_TMP" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.noSleep.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/bin/noSleepDaemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF

if ! /usr/bin/plutil -lint "$PLIST_TMP"; then
    echo "Error: generated launchd plist is invalid."
    exit 1
fi
mv "$PLIST_TMP" "$PLIST_DEST"
PLIST_TMP=""

if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
    echo ""
    echo "Note: ~/bin is not in your PATH."
    echo "Add this to your ~/.zshrc:"
    echo '  export PATH="$HOME/bin:$PATH"'
fi

echo ""
echo "✓ Installed to ~/bin/noSleep"
echo "✓ Installed daemon to ~/bin/noSleepDaemon"
echo "✓ Plist created at $PLIST_DEST"
echo ""

if [[ "$WAS_RUNNING" == true ]]; then
    echo "Existing daemon detected — restarting to pick up the new binary..."
    /bin/launchctl bootout "$USER_DOMAIN/$LABEL" >/dev/null 2>&1 || true
    /bin/launchctl enable "$USER_DOMAIN/$LABEL" >/dev/null 2>&1 || true
    if ! /bin/launchctl bootstrap "$USER_DOMAIN" "$PLIST_DEST"; then
        echo "Error: failed to restart daemon via launchctl."
        exit 1
    fi
    if ! wait_for_daemon_lock "$PREVIOUS_DAEMON_PID"; then
        echo "Error: daemon did not become ready after restart."
        exit 1
    fi
    echo "✓ Restarted"
else
    echo "To start: noSleep start"
    echo "To check: noSleep status"
fi
