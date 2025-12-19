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
swiftc -O Sources/noSleep/*.swift -o noSleep

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
    echo "Add this to your ~/.zshrc or ~/.bashrc:"
    echo '  export PATH="$HOME/bin:$PATH"'
fi

echo ""
echo "✓ Installed to ~/bin/noSleep"
echo "✓ Plist created at $PLIST_DEST"
echo ""
echo "To start: noSleep start"
echo "To check: noSleep status"
