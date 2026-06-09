#!/usr/bin/env zsh
set -e

echo "Installing noSleep..."
echo ""

if ! command -v swiftc &> /dev/null; then
    echo "Error: Swift compiler not found."
    echo "Please install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

echo "Compiling..."
CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
TARGET_CPU=$(echo "$CPU_BRAND" | grep -oiE 'Apple M[0-9]+' | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
COMPILED=false

if [[ -n "$TARGET_CPU" ]]; then
    echo "Detected $CPU_BRAND -- trying optimised build with -target-cpu $TARGET_CPU"
    if swiftc -O -target-cpu "$TARGET_CPU" Sources/noSleep/*.swift -o noSleep 2>/tmp/noSleep_compile_error.log; then
        echo "Optimised compilation successful"
        COMPILED=true
    else
        echo "Optimised compilation failed, falling back to standard build"
        cat /tmp/noSleep_compile_error.log
    fi
    rm -f /tmp/noSleep_compile_error.log
fi

if [[ "$COMPILED" == false ]]; then
    if ! swiftc -O Sources/noSleep/*.swift -o noSleep 2>/tmp/noSleep_compile_error.log; then
        echo "Compilation failed:"
        cat /tmp/noSleep_compile_error.log
        rm -f /tmp/noSleep_compile_error.log
        exit 1
    fi
    rm -f /tmp/noSleep_compile_error.log
    echo "Standard compilation successful"
fi

mkdir -p ~/bin
cp noSleep ~/bin/noSleep
chmod +x ~/bin/noSleep

# Generate plist with expanded $HOME
PLIST_DEST=~/Library/LaunchAgents/com.noSleep.daemon.plist
cat > "$PLIST_DEST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.noSleep.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/bin/noSleep</string>
        <string>daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/noSleep.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/noSleep.err</string>
</dict>
</plist>
EOF

if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
    echo ""
    echo "Note: ~/bin is not in your PATH."
    echo "Add this to your ~/.zshrc:"
    echo '  export PATH="$HOME/bin:$PATH"'
fi

echo ""
echo "✓ Installed to ~/bin/noSleep"
echo "✓ Plist created at $PLIST_DEST"
echo ""
echo "To start: noSleep start"
echo "To check: noSleep status"
