// main.swift

import Foundation

func printHelp() {
    print("""
    noSleep v\(VERSION) - Prevent macOS sleep when lid is closed on AC power
    
    USAGE:
        noSleep              Run as daemon (foreground)
        noSleep status       Show current power/lid/daemon state
        noSleep start        Start daemon via launchd (auto-start on login)
        noSleep stop         Stop daemon (keeps files for restart)
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
if args.count > 1 {
    switch args[1] {
    case "status":              cmdStatus()
    case "start":               cmdStart()
    case "stop":                cmdStop()
    case "restart":             cmdRestart()
    case "doctor":              cmdDoctor()
    case "uninstall":           cmdUninstall()
    case "--version", "-v":     printVersion()
    case "--help", "-h", "help": printHelp()
    default:
        print("Unknown command: \(args[1])")
        print("Run 'noSleep --help' for usage.")
        exit(1)
    }
} else {
    runDaemon()
}
