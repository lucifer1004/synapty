import Foundation
import os

/// Persistent subscription to the hub event stream per [[RFC-0004]]
/// C-SUBSCRIPTION: connect to the loopback hub, send the subscribe
/// envelope, deliver the snapshot and then every pushed event as parsed
/// JSON on the main queue.
///
/// Reconnect policy belongs to the OWNER (AgentMonitor): this client
/// reports the disconnect and stops — it never retries by itself.
/// Callbacks must be assigned BEFORE start() and are not mutated after.
final class HubEventClient: @unchecked Sendable {
    private let port: Int
    private let queue = DispatchQueue(label: "dev.synapty.hub-events", qos: .utility)
    private var fd: Int32 = -1
    private let fdLock = NSLock()
    private var stopped = false

    /// Snapshot: the full agents array (dicts with id/tool/project/
    /// session/status/generation). Called on the main queue.
    var onSnapshot: (([[String: Any]]) -> Void)?
    /// One pushed event payload (kind/agent/…). Called on the main queue.
    var onEvent: (([String: Any]) -> Void)?
    /// Stream ended (hub gone, or stop()). Called on the main queue.
    var onDisconnect: (() -> Void)?

    init(port: Int) {
        self.port = port
    }

    func start() {
        queue.async { [weak self] in
            self?.readLoop()
        }
    }

    /// Unblock the reader and end the stream. Safe from any thread.
    func stop() {
        fdLock.lock()
        stopped = true
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
        }
        fdLock.unlock()
    }

    // MARK: - Reader

    private func readLoop() {
        guard let sock = Self.connectLoopback(port: port) else {
            deliverDisconnect()
            return
        }
        fdLock.lock()
        if stopped {
            fdLock.unlock()
            close(sock)
            deliverDisconnect()
            return
        }
        fd = sock
        fdLock.unlock()
        defer {
            fdLock.lock()
            close(sock)
            fd = -1
            fdLock.unlock()
            deliverDisconnect()
        }

        let subscribe = "{\"type\":\"subscribe\",\"id\":\"gui-0\",\"source\":\"workbench\",\"target\":\"hub\"}\n"
        guard Self.writeAll(sock, Array(subscribe.utf8)) else { return }

        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var sawSnapshot = false
        while true {
            let n = read(sock, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<nl])
                buffer.removeSubrange(...nl)
                handleLine(line, sawSnapshot: &sawSnapshot)
            }
            // Runaway unterminated frame — bail; the owner reconnects and
            // resyncs from a fresh snapshot.
            if buffer.count > 1 << 20 { return }
        }
    }

    private func handleLine(_ bytes: [UInt8], sawSnapshot: inout Bool) {
        guard !bytes.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any]
        else { return }
        let type = obj["type"] as? String
        if type == "response", !sawSnapshot {
            sawSnapshot = true
            let agents = ((payload["data"] as? [String: Any])?["agents"] as? [[String: Any]]) ?? []
            let cb = onSnapshot
            DispatchQueue.main.async { cb?(agents) }
        } else if type == "event" {
            // Presence/receipt events: consumers key on payload["kind"].
            let cb = onEvent
            DispatchQueue.main.async { cb?(payload) }
        } else if type == "exec_request" || type == "tool_request" {
            // Control frames forwarded to the workbench: pass the WHOLE
            // envelope (consumers key on obj["type"]). Event consumers key
            // on "kind" and ignore these; the controllers key on "type"
            // and ignore events — mutually exclusive shapes.
            // tool_request joined for [[ADR-0008]] decision 6: the hub no
            // longer holds the GitHub credential, so task tools arrive
            // here to be executed with it.
            let cb = onEvent
            DispatchQueue.main.async { cb?(obj) }
        }
    }

    private func deliverDisconnect() {
        let cb = onDisconnect
        DispatchQueue.main.async { cb?() }
    }

    // MARK: - One-shot workbench signal

    /// Fire a workbench presence signal (RFC-0004 C-OWNERSHIP) as an
    /// anonymous one-shot `agent_status` connection: the done→idle gaze
    /// transition (explicit), passive detector edges, and lifecycle
    /// unknown. The hub's acceptance rules (C-PRECEDENCE) bound what each
    /// class can do, so callers may emit optimistically.
    static func sendStatusSignal(port: Int, agent: String, state: String, signalClass: String = "explicit") {
        DispatchQueue.global(qos: .utility).async {
            guard let sock = connectLoopback(port: port) else { return }
            defer { close(sock) }
            let envelope: [String: Any] = [
                "type": "agent_status",
                "id": "wb-0",
                "source": "workbench",
                "target": "",
                "payload": ["state": state, "class": signalClass, "agent": agent],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
            guard writeAll(sock, Array(data) + [0x0A]) else { return }
            // Read the response (bounded) so the hub has consumed the line
            // before we close.
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var resp = [UInt8](repeating: 0, count: 1024)
            _ = read(sock, &resp, resp.count)
        }
    }

    /// RFC-0005 C-WAKE-ACK: report an injection outcome as an anonymous
    /// one-shot `wake_report` envelope; the hub records the receipt on
    /// the event log (wake_delivered resolves the candidate hub-side).
    static func sendWakeReport(port: Int, agent: String, generation: UInt64, outcome: String) {
        DispatchQueue.global(qos: .utility).async {
            guard let sock = connectLoopback(port: port) else { return }
            defer { close(sock) }
            let envelope: [String: Any] = [
                "type": "wake_report",
                "id": "wb-wake",
                "source": "workbench",
                "target": "",
                "payload": ["agent": agent, "generation": generation, "outcome": outcome],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
            guard writeAll(sock, Array(data) + [0x0A]) else { return }
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var resp = [UInt8](repeating: 0, count: 1024)
            _ = read(sock, &resp, resp.count)
        }
    }

    /// RFC-0007 C-PRIMITIVES: report an exec outcome as an anonymous
    /// one-shot `exec_receipt`; the hub records the receipt event and
    /// routes the exec_response back to the requesting agent.
    /// Test seam: where a receipt goes instead of the hub. Nil in the app.
    /// Exec receipts are the only evidence an agent gets that its request
    /// ended, and until this existed nothing could observe one.
    nonisolated(unsafe) static var execReceiptSink:
        ((_ kind: String, _ pane: String?, _ detail: String?, _ data: [String: Any]) -> Void)?

    static func sendExecReceipt(
        port: Int, kind: String, owner: String, generation: UInt64,
        pane: String?, detail: String?, requester: String, requestID: String,
        data: [String: Any]
    ) {
        if let execReceiptSink {
            execReceiptSink(kind, pane, detail, data)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            guard let sock = connectLoopback(port: port) else { return }
            defer { close(sock) }
            var payload: [String: Any] = [
                "kind": kind, "owner": owner, "generation": generation,
                "requester": requester, "request_id": requestID, "data": data,
            ]
            if let pane { payload["pane"] = pane }
            if let detail { payload["detail"] = detail }
            let envelope: [String: Any] = [
                "type": "exec_receipt", "id": "exec-rcpt",
                "source": "workbench", "target": "", "payload": payload,
            ]
            guard let bytes = try? JSONSerialization.data(withJSONObject: envelope) else { return }
            guard writeAll(sock, Array(bytes) + [0x0A]) else { return }
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var resp = [UInt8](repeating: 0, count: 1024)
            _ = read(sock, &resp, resp.count)
        }
    }

    /// [[ADR-0008]] decision 6: the workbench's answer to a forwarded
    /// task tool. Same one-shot geometry as sendExecReceipt — the hub
    /// routes it back to the agent that asked, under its original id.
    static func sendToolReceipt(
        port: Int, requester: String, requestID: String,
        ok: Bool, data: Any?, error: String?
    ) {
        DispatchQueue.global(qos: .utility).async {
            guard let sock = connectLoopback(port: port) else { return }
            defer { close(sock) }
            var payload: [String: Any] = [
                "requester": requester, "request_id": requestID, "ok": ok,
            ]
            if let data { payload["data"] = data }
            if let error { payload["error"] = error }
            let envelope: [String: Any] = [
                "type": "tool_receipt", "id": "tool-rcpt",
                "source": "workbench", "target": "", "payload": payload,
            ]
            guard let bytes = try? JSONSerialization.data(withJSONObject: envelope) else { return }
            guard writeAll(sock, Array(bytes) + [0x0A]) else { return }
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var resp = [UInt8](repeating: 0, count: 1024)
            _ = read(sock, &resp, resp.count)
        }
    }

    /// [[ADR-0008]] stage 3b: ask this machine's hub to dial a peer hub
    /// reachable on a loopback port (the local end of an SSH forward the
    /// workbench established). One-shot, same shape as the other
    /// workbench-authority frames.
    static func sendPeerConnect(port: Int, peerLoopbackPort: Int, selfPeerID: String) {
        DispatchQueue.global(qos: .utility).async {
            guard let sock = connectLoopback(port: port) else { return }
            defer { close(sock) }
            let envelope: [String: Any] = [
                "type": "peer_connect", "id": "peer-conn",
                "source": "workbench", "target": "",
                "payload": ["port": peerLoopbackPort, "self_peer_id": selfPeerID],
            ]
            guard let bytes = try? JSONSerialization.data(withJSONObject: envelope) else { return }
            guard writeAll(sock, Array(bytes) + [0x0A]) else { return }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var resp = [UInt8](repeating: 0, count: 1024)
            _ = read(sock, &resp, resp.count)
        }
    }

    // MARK: - Socket helpers

    static func connectLoopback(port: Int) -> Int32? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(sock)
            return nil
        }
        return sock
    }

    static func writeAll(_ sock: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { raw in
                write(sock, raw.baseAddress, raw.count)
            }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
