// main.swift

import Foundation

func printHelp() {
    print("""
    noSleep v\(VERSION) - Prevent macOS sleep when lid is closed on AC power
    
    USAGE:
        noSleep              Show this help message
        noSleep status       Show current power/lid/daemon state
        noSleep start        Start daemon via launchd (auto-start on login)
        noSleep stop         Stop daemon (keeps files for restart)
        noSleep daemon       Run installed daemon executable (foreground)
        noSleep restart      Stop and start daemon
        noSleep doctor       Run diagnostics (read-only)
        noSleep uninstall    Stop daemon and remove all installed files
    
    OPTIONS:
        --help, -h           Show this help message
        --version, -v        Show version number
    
    BEHAVIOR:
        AC + Lid Closed  →  Prevent sleep
        AC + Lid Open    →  Allow sleep (system default)
        Battery          →  Allow sleep (system default)
    """)
}

func printVersion() {
    print("noSleep v\(VERSION)")
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : ""
switch cmd {
case "status":              cmdStatus()
case "start":               cmdStart()
case "stop":                cmdStop()
case "daemon":              execInstalledDaemonOrRunFallback()
case "restart":             cmdRestart()
case "doctor":              cmdDoctor()
case "uninstall":           cmdUninstall()
case "--version", "-v":     printVersion()
case "--help", "-h", "help": printHelp()
default:
    if cmd.isEmpty {
        printHelp()
    } else {
        print("Unknown command: \(cmd)")
        print("Run 'noSleep --help' for usage.")
        exit(1)
    }
}
