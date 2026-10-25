import Foundation
import Darwin
import StratovoCore

struct SSHRemoteFile: Identifiable, Equatable, Sendable {
    let name: String
    let size: UInt64
    let directory: Bool
    var id: String { name }
}

/// SFTP v3 over the system SSH client. Filenames are protocol strings, never shell commands.
/// Each operation owns its process, so cancellation also interrupts a blocked protocol read.
final class SSHFileOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timeoutExpired = false

    func cancel(timedOut: Bool = false) {
        lock.lock(); cancelled = true; timeoutExpired = timeoutExpired || timedOut; let child = process; lock.unlock()
        if let child, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    func check() throws {
        lock.lock(); let stopped = cancelled, expired = timeoutExpired; lock.unlock()
        if expired { throw StorageMigration.failure("Windows-SSH antwortet nicht mehr. Verbindung prüfen und erneut versuchen.") }
        if stopped { throw CancellationError() }
    }

    func capture(executable: String, arguments: [String], timeout: TimeInterval = 30, mergeErrors: Bool = true,
                 tick: (String) -> Void = { _ in }) throws -> (status: Int32, data: Data) {
        let child = Process()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("stratovo-transfer-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw GuestError.missingFile(log.path)
        }
        let output = try FileHandle(forWritingTo: log)
        let errorLog = log.appendingPathExtension("stderr")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let errors = try FileHandle(forWritingTo: errorLog)
        defer { try? output.close(); try? errors.close(); try? FileManager.default.removeItem(at: log); try? FileManager.default.removeItem(at: errorLog) }
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = mergeErrors ? output : errors
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() } catch { lock.unlock(); throw error }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        defer {
            if child.isRunning { child.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
            child.waitUntilExit()
            lock.lock(); process = nil; lock.unlock()
        }
        var nextTick = 0.0
        while child.isRunning {
            try check()
            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline { cancel(timedOut: true); try check() }
            if now >= nextTick {
                let reader = try FileHandle(forReadingFrom: log)
                let size = try reader.seekToEnd()
                try reader.seek(toOffset: size > 4096 ? size - 4096 : 0)
                tick(String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self)); try reader.close()
                nextTick = now + 0.25
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        child.waitUntilExit(); try check()
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? reader.close() }
        let bytes = try reader.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 16 * 1024 * 1024 else { throw StorageMigration.failure("Dateiliste ist zu groß.") }
        let failure = child.terminationStatus != 0 && !mergeErrors ? ((try? Data(contentsOf: errorLog)) ?? Data()) : Data()
        return (child.terminationStatus, failure + bytes)
    }

    func run<T>(executable: String = "/usr/bin/ssh", arguments: [String], timeout: TimeInterval = 30,
                body: (SFTPChannel) throws -> T) throws -> T {
        let child = Process(), input = Pipe(), output = Pipe()
        // A cancelled/closed SSH child must produce an EPIPE error, never terminate the app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw StorageMigration.failure("SSH-Übertragung konnte nicht sicher geöffnet werden.")
        }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("stratovo-ssh-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close(); try? FileManager.default.removeItem(at: log) }
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        // Bound even a peer that keeps TCP alive but stops answering SFTP requests.
        let deadline = DispatchWorkItem { [weak self] in self?.cancel(timedOut: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
            child.waitUntilExit()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        do {
            let channel = SFTPChannel(input: output.fileHandleForReading, output: input.fileHandleForWriting,
                                      check: { try self.check() })
            try channel.start()
            return try body(channel)
        } catch {
            try check()
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if detail.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || detail.contains("Host key verification failed") {
                throw StorageMigration.failure("Die Windows-Identität stimmt nicht mit der Kopplung überein. Nur nach einer bewussten Neuinstallation erneut koppeln.")
            }
            if detail.contains("Permission denied") {
                throw StorageMigration.failure("Windows hat den SSH-Schlüssel abgelehnt. Windows-Benutzer prüfen und SSH-Einrichtung für dieses Konto ausführen.")
            }
            if detail.contains("Connection refused") || detail.contains("Connection timed out") {
                throw StorageMigration.failure("Windows-SSH antwortet noch nicht. Einrichtung in Windows abschließen und erneut verbinden.")
            }
            throw error
        }
    }
}

final class SFTPChannel {
    struct Packet { let type: UInt8; let id: UInt32; var body: SFTPBytes }
    let input: FileHandle, output: FileHandle
    let check: () throws -> Void
    private var nextID: UInt32 = 0
    init(input: FileHandle, output: FileHandle, check: @escaping () throws -> Void = {}) {
        self.input = input; self.output = output; self.check = check
    }
    func start() throws {
        var initPacket = Data([1]); initPacket.append(SFTPBytes.uint32(3))
        try writePacket(initPacket)
        var response = SFTPBytes(data: try readPacket())
        guard try response.byte() == 2, try response.u32() == 3 else { throw failure("SFTP-Version wird nicht unterstützt.") }
    }
    private func writePacket(_ payload: Data) throws {
        try check()
        try output.write(contentsOf: SFTPBytes.uint32(UInt32(payload.count)) + payload)
    }
    private func exact(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            try check()
            guard let part = try input.read(upToCount: count - data.count), !part.isEmpty else {
                throw failure("Die SSH-Verbindung wurde beendet. Windows-SSH-Einrichtung und Verbindung prüfen.")
            }
            data.append(part)
        }
        return data
    }
    private func readPacket() throws -> Data {
        var header = SFTPBytes(data: try exact(4))
        let length = try header.u32()
        guard length >= 1, length <= 4 * 1024 * 1024 else { throw failure("Ungültige SFTP-Antwort.") }
        return try exact(Int(length))
    }
    @discardableResult private func send(_ type: UInt8, _ body: Data) throws -> UInt32 {
        nextID &+= 1
        try writePacket(Data([type]) + SFTPBytes.uint32(nextID) + body)
        return nextID
    }
    private func receive() throws -> Packet {
        var data = SFTPBytes(data: try readPacket())
        return try Packet(type: data.byte(), id: data.u32(), body: data)
    }
    private func request(_ type: UInt8, _ body: Data) throws -> Packet {
        let id = try send(type, body), packet = try receive()
        guard packet.id == id else { throw failure("SFTP-Antwort gehört nicht zur Anfrage.") }
        return packet
    }
    private func status(_ packet: Packet, eof: Bool = false) throws -> Bool {
        guard packet.type == 101 else { throw failure("Unerwartete SFTP-Antwort.") }
        var bytes = packet.body
        let code = try bytes.u32()
        if code == 0 { return true }
        if eof && code == 1 { return false }
        let message = (try? bytes.string()) ?? ""
        throw failure("Windows-Dateizugriff fehlgeschlagen (\(code)): \(message)")
    }
    private func handle(_ packet: Packet) throws -> Data {
        guard packet.type == 102 else { _ = try status(packet); throw failure("SFTP-Dateihandle fehlt.") }
        var bytes = packet.body
        return try bytes.blob()
    }
    private func close(_ handle: Data) throws { _ = try status(request(4, SFTPBytes.blob(handle))) }
    func createDirectory(_ path: String) throws {
        _ = try status(request(14, SFTPBytes.string(path) + SFTPBytes.uint32(0)))
    }
    func rename(_ source: String, to destination: String) throws {
        _ = try status(request(18, SFTPBytes.string(source) + SFTPBytes.string(destination)))
    }
    private func fileSize(_ handle: Data) throws -> UInt64 {
        let packet = try request(8, SFTPBytes.blob(handle))
        guard packet.type == 105 else { _ = try status(packet); throw failure("Dateigröße konnte nicht gelesen werden.") }
        var bytes = packet.body
        return try bytes.attributes().size
    }

    func list(_ path: String) throws -> [SSHRemoteFile] {
        let directory = try handle(request(11, SFTPBytes.string(path)))
        defer { try? close(directory) }
        var files = [SSHRemoteFile]()
        while true {
            let packet = try request(12, SFTPBytes.blob(directory))
            if packet.type == 101 { _ = try status(packet, eof: true); break }
            guard packet.type == 104 else { throw failure("Ungültige SFTP-Ordnerliste.") }
            var bytes = packet.body
            let count = try bytes.u32()
            guard count <= 100_000, files.count + Int(count) <= 100_000 else { throw failure("Ordner enthält zu viele Einträge.") }
            for _ in 0..<count {
                let name = try bytes.string(); _ = try bytes.string()
                let attrs = try bytes.attributes()
                // Symlinks and special files are intentionally not downloaded as regular files.
                let kind = attrs.permissions & 0o170000
                if name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                   !name.unicodeScalars.contains(where: { $0.value < 32 }), kind == 0o100000 || kind == 0o040000 {
                    files.append(SSHRemoteFile(name: name, size: attrs.size, directory: kind == 0o040000))
                }
            }
        }
        return files.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func upload(local: URL, remote: String, progress: (UInt64) -> Void) throws {
        let file = try FileHandle(forReadingFrom: local)
        defer { try? file.close() }
        // WRITE | CREAT | EXCL: a second transfer cannot overwrite a remote file.
        let handle = try handle(request(3, SFTPBytes.string(remote) + SFTPBytes.uint32(2 | 8 | 32) + SFTPBytes.uint32(0)))
        var opened = true
        defer { if opened { try? close(handle) } }
        var offset: UInt64 = 0, acknowledged: UInt64 = 0
        var pending = [UInt32: Int]()
        var ended = false
        while !ended || !pending.isEmpty {
            while !ended && pending.count < 16 {
                let data = try file.read(upToCount: 64 * 1024) ?? Data()
                if data.isEmpty { ended = true; break }
                let id = try send(6, SFTPBytes.blob(handle) + SFTPBytes.uint64(offset) + SFTPBytes.blob(data))
                pending[id] = data.count; offset += UInt64(data.count)
            }
            if pending.isEmpty { break }
            let packet = try receive()
            guard let size = pending.removeValue(forKey: packet.id) else { throw failure("Unbekannte SFTP-Schreibantwort.") }
            _ = try status(packet); acknowledged += UInt64(size); progress(acknowledged)
        }
        try close(handle); opened = false
    }

    func download(remote: String, local: URL, size: UInt64, progress: (UInt64) -> Void) throws {
        guard FileManager.default.createFile(atPath: local.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw failure("Importdatei kann nicht angelegt werden.")
        }
        let file = try FileHandle(forWritingTo: local)
        defer { try? file.close() }
        let handle = try handle(request(3, SFTPBytes.string(remote) + SFTPBytes.uint32(1) + SFTPBytes.uint32(0)))
        var opened = true
        defer { if opened { try? close(handle) } }
        guard try fileSize(handle) == size else { throw failure("Datei wurde verändert. Dateiliste aktualisieren und erneut auswählen.") }
        var offset: UInt64 = 0, completed: UInt64 = 0
        var pending = [UInt32: (UInt64, UInt32)]()
        while offset < size || !pending.isEmpty {
            while offset < size && pending.count < 16 {
                let count = UInt32(min(UInt64(64 * 1024), size - offset))
                let id = try send(5, SFTPBytes.blob(handle) + SFTPBytes.uint64(offset) + SFTPBytes.uint32(count))
                pending[id] = (offset, count); offset += UInt64(count)
            }
            let packet = try receive()
            guard let (position, requested) = pending.removeValue(forKey: packet.id) else { throw failure("Unbekannte SFTP-Leseantwort.") }
            guard packet.type == 103 else { _ = try status(packet); throw failure("Datei wurde während der Übertragung verändert.") }
            var body = packet.body
            let data = try body.blob()
            guard !data.isEmpty, data.count <= requested else { throw failure("Ungültiger SFTP-Dateiblock.") }
            try file.seek(toOffset: position); try file.write(contentsOf: data)
            completed += UInt64(data.count); progress(completed)
            if data.count < requested {
                let newPosition = position + UInt64(data.count), remaining = requested - UInt32(data.count)
                let id = try send(5, SFTPBytes.blob(handle) + SFTPBytes.uint64(newPosition) + SFTPBytes.uint32(remaining))
                pending[id] = (newPosition, remaining)
            }
        }
        guard try fileSize(handle) == size else { throw failure("Datei wurde während der Übertragung verändert. Bitte erneut abholen.") }
        try file.synchronize(); try close(handle); opened = false
    }
    private func failure(_ message: String) -> NSError { StorageMigration.failure(message) }
}

struct SFTPBytes {
    let data: Data
    private var position = 0
    init(data: Data) { self.data = data }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - position else { throw StorageMigration.failure("Unvollständige SFTP-Antwort.") }
        defer { position += count }
        return data.subdata(in: position..<(position + count))
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func u32() throws -> UInt32 { try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    mutating func blob() throws -> Data { try take(Int(u32())) }
    mutating func string() throws -> String {
        guard let result = String(data: try blob(), encoding: .utf8) else { throw StorageMigration.failure("Windows hat einen ungültigen Dateinamen gesendet.") }
        return result
    }
    mutating func attributes() throws -> (size: UInt64, permissions: UInt32) {
        let flags = try u32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw StorageMigration.failure("Unbekannte SFTP-Dateiattribute.") }
        let size: UInt64 = flags & 1 != 0 ? try u64() : 0
        if flags & 2 != 0 { _ = try take(8) }
        let permissions: UInt32 = flags & 4 != 0 ? try u32() : 0
        if flags & 8 != 0 { _ = try take(8) }
        if flags & 0x80000000 != 0 {
            let count = try u32()
            guard count <= 1024 else { throw StorageMigration.failure("Zu viele SFTP-Dateiattribute.") }
            for _ in 0..<count { _ = try blob(); _ = try blob() }
        }
        return (size, permissions)
    }
    static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func uint64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func blob(_ value: Data) -> Data { uint32(UInt32(value.count)) + value }
    static func string(_ value: String) -> Data { blob(Data(value.utf8)) }
}
