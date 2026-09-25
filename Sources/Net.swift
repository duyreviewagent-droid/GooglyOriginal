import Foundation

/// WebSocket connection to the GooglyOriginal lobby server. Messages are JSON objects with a "t" field.
/// Callbacks arrive on URLSession's queue; the game drains them once per frame.
final class Net: NSObject, URLSessionWebSocketDelegate {
    static var defaultServer: String {
        if let i = CommandLine.arguments.firstIndex(of: "--server"), i + 1 < CommandLine.arguments.count { return CommandLine.arguments[i + 1] }
        if let e = ProcessInfo.processInfo.environment["GOOGLY_SERVER"] { return e }
        return "wss://googlyoriginal.onrender.com/ws"
    }

    enum Status: Equatable { case connecting, open, closed(String) }

    let url: URL
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var inbox: [[String: Any]] = []
    private var _status = Status.connecting
    var status: Status { lock.lock(); defer { lock.unlock() }; return _status }
    var host: String { url.host ?? "server" }
    private var started = Date()
    var secondsConnecting: Double { Date().timeIntervalSince(started) }
    private(set) var rtt: Double = 0
    private var pingTimer: Timer?
    private var everOpened = false
    private var attempts = 0
    private var closedByUs = false
    var bytesOut = 0, bytesIn = 0

    init(server: String = Net.defaultServer) {
        url = URL(string: server) ?? URL(string: "wss://googlyoriginal.onrender.com/ws")!
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: OperationQueue())
        connect()
    }

    private func connect() {
        started = Date()
        setStatus(.connecting)
        var req = URLRequest(url: url)
        req.timeoutInterval = 90
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 1 << 20
        task = t
        t.resume()
        receive()
    }

    private func setStatus(_ s: Status) { lock.lock(); _status = s; lock.unlock() }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        everOpened = true
        setStatus(.open)
        let name = Net.playerName
        send(["t": "hello", "name": name])
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
                self?.send(["t": "ping", "at": Date().timeIntervalSince1970])
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if webSocketTask === task { failed("connection closed") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let e = error, task === self.task else { return }
        failed(e.localizedDescription)
    }

    /// Before the first successful connection, keep retrying (the free server may be waking up or
    /// its edge may bounce a handshake); after that, a drop really is a disconnect.
    private func failed(_ why: String) {
        if closedByUs { return }
        if !everOpened && attempts < 40 {
            attempts += 1
            setStatus(.connecting)
            task?.cancel()
            task = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + min(3, 0.6 + Double(attempts) * 0.3)) { [weak self] in
                guard let self = self, !self.closedByUs else { return }
                self.reconnect()
            }
        } else {
            setStatus(.closed(why))
        }
    }

    private func reconnect() {
        var req = URLRequest(url: url)
        req.timeoutInterval = 90
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 1 << 20
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        let current = task
        current?.receive { [weak self] result in
            guard let self = self, current === self.task else { return }
            switch result {
            case .success(let msg):
                var data: Data?
                switch msg {
                case .string(let s): data = s.data(using: .utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let d = data {
                    self.bytesIn += d.count
                    if let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        if obj["t"] as? String == "pong", let at = obj["at"] as? Double {
                            self.rtt = Date().timeIntervalSince1970 - at
                        } else {
                            self.lock.lock(); self.inbox.append(obj); self.lock.unlock()
                        }
                    }
                }
                self.receive()
            case .failure(let e):
                self.failed(e.localizedDescription)
            }
        }
    }

    func drain() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let m = inbox
        inbox.removeAll()
        return m
    }

    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        bytesOut += d.count
        task?.send(.string(s)) { _ in }
    }

    func close() {
        closedByUs = true
        send(["t": "leave"])
        DispatchQueue.main.async { self.pingTimer?.invalidate() }
        task?.cancel(with: .normalClosure, reason: nil)
        setStatus(.closed("left"))
    }

    static var playerName: String {
        if let i = CommandLine.arguments.firstIndex(of: "--name"), i + 1 < CommandLine.arguments.count { return CommandLine.arguments[i + 1] }
        let full = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return full.isEmpty ? "Googly" : String(full.prefix(12))
    }
}

// MARK: - tiny JSON helpers

extension Dictionary where Key == String, Value == Any {
    func i(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
    func f(_ k: String) -> Float { (self[k] as? NSNumber)?.floatValue ?? 0 }
    func s(_ k: String) -> String { self[k] as? String ?? "" }
    func b(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? false }
    func arr(_ k: String) -> [Any] { self[k] as? [Any] ?? [] }
}

@inline(__always) func num(_ a: Any?) -> Float { (a as? NSNumber)?.floatValue ?? 0 }
@inline(__always) func inum(_ a: Any?) -> Int { (a as? NSNumber)?.intValue ?? 0 }
