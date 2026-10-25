import Foundation
import Network
import StratovoCore

enum ExchangeGuest: String, CaseIterable, Identifiable, Sendable {
    case windows, ubuntu
    var id: String { rawValue }
    var title: String { self == .windows ? "Windows" : "Ubuntu" }
    var initialPath: String { "." }
    var rootPath: String { "." }
}

struct GuestSetupUpdate: Decodable, Sendable {
    let stage: String
    let message: String?
    let user: String?
    let key: String?
}

struct GuestSetupRequest {
    let method: String
    let path: String
    let body: Data
    static func parse(_ data: Data, bodyLimit: Int = 32768) throws -> Self? {
        guard data.count <= bodyLimit + 8192 else { throw GuestError.invalidResources }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 8192 else { throw GuestError.invalidResources }; return nil
        }
        guard separator.lowerBound <= 8192,
              let header = String(data: data[..<separator.lowerBound], encoding: .ascii) else { throw GuestError.invalidResources }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "POST"].contains(String(first[0])),
              ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])) else { throw GuestError.invalidResources }
        var length: Int?
        for line in lines.dropFirst() {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { throw GuestError.invalidResources }
            let key = fields[0].lowercased(), value = fields[1].trimmingCharacters(in: .whitespaces)
            guard key != "transfer-encoding" else { throw GuestError.invalidResources }
            if key == "content-length" {
                guard length == nil, let count = Int(value), (0...bodyLimit).contains(count) else { throw GuestError.invalidResources }
                length = count
            }
        }
        let count = length ?? 0, start = separator.upperBound
        guard data.count >= start + count else { return nil }
        guard data.count == start + count else { throw GuestError.invalidResources }
        return Self(method: String(first[0]), path: String(first[1]), body: Data(data[start..<(start + count)]))
    }
}

/// Short-lived bootstrap channel on loopback only. A random capability URL belongs to one setup.
/// The guest reports its account and host key through this channel, so users need no key copying.
@MainActor
final class GuestSetupServer {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var listener: NWListener?
    private var connections = [UUID: NWConnection]()
    private var startup: CheckedContinuation<UInt16, Error>?
    private(set) var port: UInt16 = 0
    private(set) var fetched = false
    private(set) var update: GuestSetupUpdate?
    var script = Data()
    var captureFile: URL?
    private(set) var captureReceived = false
    var baseURL: String { "http://10.0.2.2:\(port)/\(token)" }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        try await withTaskCancellationHandler {
            port = try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.state(state) }
                }
                listener.start(queue: .main)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard let self, self.startup != nil else { return }
                    self.startup?.resume(throwing: GuestError.timedOut); self.startup = nil; self.stop()
                }
            }
        } onCancel: { Task { @MainActor in self.stop() } }
    }
    private func state(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue { startup?.resume(returning: port); startup = nil }
        case .failed(let error): startup?.resume(throwing: error); startup = nil; stop()
        default: break
        }
    }
    func stop() {
        startup?.resume(throwing: CancellationError()); startup = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self?.connections.removeValue(forKey: id)?.cancel()
        }
        receive(id, Data())
    }
    private func receive(_ id: UUID, _ accumulated: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let data = accumulated + (chunk ?? Data())
                do {
                    if let request = try GuestSetupRequest.parse(data, bodyLimit: self.captureFile == nil ? 32768 : 16 * 1024 * 1024) { self.respond(id, request); return }
                    if error != nil || complete { self.connections.removeValue(forKey: id)?.cancel(); return }
                    self.receive(id, data)
                } catch { self.send(id, code: 400, data: Data()) }
            }
        }
    }
    private func respond(_ id: UUID, _ request: GuestSetupRequest) {
        if request.method == "GET", request.path == "/\(token)/setup", !script.isEmpty {
            fetched = true
            send(id, code: 200, data: script, type: "text/plain; charset=utf-8")
        } else if request.method == "POST", request.path == "/\(token)/status",
                  let value = try? JSONDecoder().decode(GuestSetupUpdate.self, from: request.body),
                  ["confirm", "install", "configure", "ready", "error"].contains(value.stage),
                  (value.message?.count ?? 0) <= 2048 {
            update = value
            send(id, code: 200, data: Data("{}".utf8))
        } else if request.method == "POST", request.path == "/\(token)/image", let target = captureFile,
                  request.body.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            do {
                try request.body.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                captureReceived = true; send(id, code: 200, data: Data("{}".utf8))
            } catch { send(id, code: 500, data: Data()) }
        } else { send(id, code: 404, data: Data()) }
    }
    private func send(_ id: UUID, code: Int, data: Data, type: String = "application/json") {
        guard let connection = connections[id] else { return }
        let response = Data("HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + data
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.connections.removeValue(forKey: id)?.cancel() }
        })
    }
}
