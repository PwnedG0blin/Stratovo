import Foundation
import StratovoCore

@MainActor
enum QMPClient {
    static func insertExchangeMedia(_ iso: URL, socket: String) async throws {
        let stream = LocalStream(socket: socket)
        let timeout = watchdog(stream)
        defer { timeout.cancel(); stream.close() }
        _ = try await line(stream)
        _ = try await command("qmp_capabilities", id: 1, stream: stream)
        _ = try await command("blockdev-change-medium", id: 2, stream: stream,
            arguments: ["id": "stratovo-exchange-cd", "filename": iso.path, "format": "raw", "read-only-mode": "read-only"])
    }
    static func forwardSSH(port: Int, socket: String) async throws {
        guard (49152...65535).contains(port) else { throw GuestError.invalidResources }
        let stream = LocalStream(socket: socket)
        let timeout = watchdog(stream)
        defer { timeout.cancel(); stream.close() }
        _ = try await line(stream)
        _ = try await command("qmp_capabilities", id: 1, stream: stream)
        let result = try await command("human-monitor-command", id: 2, stream: stream,
            arguments: ["command-line": "hostfwd_add net0 tcp:127.0.0.1:\(port)-:22"])
        guard let output = result as? String, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageMigration.failure("Der lokale SSH-Zugang zur VM konnte nicht geöffnet werden.")
        }
    }
    static func sendKeys(_ keys: [String], socket: String) async throws {
        let stream = LocalStream(socket: socket)
        let timeout = watchdog(stream)
        defer { timeout.cancel(); stream.close() }
        _ = try await line(stream)
        _ = try await command("qmp_capabilities", id: 1, stream: stream)
        _ = try await command("send-key", id: 2, stream: stream,
            arguments: ["keys": keys.map { ["type": "qcode", "data": $0] }, "hold-time": 80])
    }
    static func shutdown(socket: String) async throws {
        let stream = LocalStream(socket: socket)
        let timeout = watchdog(stream)
        defer { timeout.cancel(); stream.close() }
        _ = try await line(stream)
        _ = try await command("qmp_capabilities", id: 1, stream: stream)
        _ = try await command("system_powerdown", id: 2, stream: stream)
    }
    static func inspect(socket: String) async throws -> WindowsBootEvidence {
        let stream = LocalStream(socket: socket)
        let timeout = watchdog(stream)
        defer { timeout.cancel(); stream.close() }
        _ = try await line(stream)
        _ = try await command("qmp_capabilities", id: 1, stream: stream)
        let state = try await command("query-status", id: 2, stream: stream)
        let blocks = try await command("query-block", id: 3, stream: stream)
        return try WindowsBootEvidence(status: JSONSerialization.data(withJSONObject: state),
                                       blocks: JSONSerialization.data(withJSONObject: blocks))
    }
    static func machineUUID(socket: String) async throws -> String {
        let stream = LocalStream(socket: socket)
        let timeout = watchdog(stream)
        defer { timeout.cancel(); stream.close() }
        _ = try await line(stream)
        _ = try await command("qmp_capabilities", id: 1, stream: stream)
        let response = try await command("query-uuid", id: 2, stream: stream) as? [String: Any]
        guard let uuid = response?["UUID"] as? String, UUID(uuidString: uuid) != nil else {
            throw StorageMigration.failure(L10n.text("QEMU hat keine gültige VM-UUID zurückgegeben."))
        }
        return uuid.lowercased()
    }
    static func typeText(_ input: WindowsTextInput, socket: String, interval: Double = 0.045, progress: @escaping (Int) -> Void) async throws {
        let stream = LocalStream(socket: socket)
        let timeout = watchdog(stream, seconds: Double(input.chordCount) * max(0.08, interval + 0.035) + 10)
        defer { timeout.cancel(); stream.close() }
        try await withTaskCancellationHandler {
            _ = try await line(stream)
            _ = try await command("qmp_capabilities", id: 1, stream: stream)
            var id = 2
            for (index, unit) in input.units.enumerated() {
                for chord in unit.chords {
                    try Task.checkCancellation()
                    let keys = chord.map { ["type": "qcode", "data": $0] }
                    // QEMU releases these keys itself after 20 ms, even if the app disconnects.
                    _ = try await command("send-key", id: id, stream: stream, arguments: ["keys": keys, "hold-time": 20])
                    id += 1
                    try await Task.sleep(nanoseconds: UInt64(max(0.045, interval) * 1_000_000_000))
                }
                progress(index + 1)
            }
        } onCancel: {
            Task { @MainActor in stream.close() }
        }
    }
    private static func watchdog(_ stream: LocalStream, seconds: Double = 5) -> Task<Void, Never> {
        Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); if !Task.isCancelled { stream.close() } }
    }
    private static func command(_ name: String, id: Int, stream: LocalStream, arguments: [String: Any]? = nil) async throws -> Any {
        var object: [String: Any] = ["execute": name, "id": id]
        if let arguments { object["arguments"] = arguments }
        var request = try JSONSerialization.data(withJSONObject: object)
        request.append(10)
        stream.send(request)
        for _ in 0..<100 {
            try Task.checkCancellation()
            let value = try JSONSerialization.jsonObject(with: await line(stream)) as? [String: Any]
            if value?["id"] as? Int == id {
                if let result = value?["return"] { return result }
                throw NSError(domain: "OpenGuest.QMP", code: 1, userInfo: [NSLocalizedDescriptionKey: "QEMU hat die Anfrage \(name) abgelehnt."])
            }
        }
        throw NSError(domain: "OpenGuest.QMP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine QEMU-Antwort."])
    }
    private static func line(_ stream: LocalStream) async throws -> Data {
        var data = Data()
        for _ in 0..<262144 {
            let byte = try await stream.read(1)
            data += byte
            if byte[0] == 10 { return data }
        }
        throw NSError(domain: "OpenGuest.QMP", code: 1, userInfo: [NSLocalizedDescriptionKey: "QEMU-Nachricht zu lang."])
    }
}

