import os

/// Central Logger namespace — one place for the service loggers
/// (WI-2026-08-08-036). Subsystem is the app bundle id; categories match
/// the service names.
enum AppLog {
    static let agentMonitor = Logger(subsystem: "com.synapty.app", category: "AgentMonitor")
    static let taskMonitor = Logger(subsystem: "com.synapty.app", category: "TaskMonitor")
    static let tunnelManager = Logger(subsystem: "com.synapty.app", category: "TunnelManager")
}
