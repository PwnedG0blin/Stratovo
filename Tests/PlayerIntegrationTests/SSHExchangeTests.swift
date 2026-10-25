import XCTest
import Foundation
import CryptoKit
import StratovoCore
@testable import Stratovo

final class SSHExchangeTests: XCTestCase {
    func testWindowsNamesRejectPathSeparatorsStreamsAndReservedDevicesBeforeUpload() throws {
        for name in ["..\\..\\target", "folder/file", "file:stream", "CON", "NUL.txt", "com1.log", "LPT².txt", "CONIN$", "name.", "name ", "line\nbreak", ""] {
            XCTAssertThrowsError(try WindowsSSHIdentity.validateFileName(name), name)
        }
        for name in ["Karte [1] ä.png", "normal.etl", "O'Brien $log.bin", "COM10.txt"] {
            XCTAssertNoThrow(try WindowsSSHIdentity.validateFileName(name), name)
        }
    }

    private func packet(_ type: UInt8, _ id: UInt32, _ body: Data) -> Data {
        let payload = Data([type]) + SFTPBytes.uint32(id) + body
        return SFTPBytes.uint32(UInt32(payload.count)) + payload
    }
    private var version: Data { SFTPBytes.uint32(5) + Data([2]) + SFTPBytes.uint32(3) }
    private func ok(_ id: UInt32, _ code: UInt32 = 0) -> Data {
        packet(101, id, SFTPBytes.uint32(code) + SFTPBytes.string("") + SFTPBytes.string(""))
    }
    private func attrs(_ size: UInt64, _ mode: UInt32 = 0o100644) -> Data {
        SFTPBytes.uint32(5) + SFTPBytes.uint64(size) + SFTPBytes.uint32(mode)
    }
    private func fixture<T>(_ replies: Data, _ work: (SFTPChannel, URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = root.appendingPathComponent("replies"), outgoing = root.appendingPathComponent("requests")
        try replies.write(to: incoming); try Data().write(to: outgoing)
        let input = try FileHandle(forReadingFrom: incoming), output = try FileHandle(forWritingTo: outgoing)
        defer { try? input.close(); try? output.close() }
        let channel = SFTPChannel(input: input, output: output)
        try channel.start()
        return try work(channel, root)
    }

    func testNamesTravelAsProtocolStringsAndUnsafeEntriesAreExcluded() throws {
        let names: [(String, UInt32)] = [("Karten [1] ä.png", 0o100644), ("Downloads", 0o040755),
            ("../escape", 0o100644), ("bad\\escape", 0o100644), ("link", 0o120777), ("line\nbreak", 0o100644)]
        var body = SFTPBytes.uint32(UInt32(names.count))
        for (name, mode) in names { body += SFTPBytes.string(name) + SFTPBytes.string(name) + attrs(42, mode) }
        let replies = version + packet(102, 1, SFTPBytes.blob(Data([9]))) + packet(104, 2, body) + ok(3, 1) + ok(4)
        try fixture(replies) { channel, _ in
            let files = try channel.list(".")
            XCTAssertEqual(files.map(\.name), ["Downloads", "Karten [1] ä.png"])
            XCTAssertTrue(files[0].directory); XCTAssertEqual(files[1].size, 42)
        }
    }

    func testPipelinedUploadAcceptsOutOfOrderAcknowledgementsAndUsesExclusiveCreate() throws {
        let handle = Data([5, 6])
        let replies = version + packet(102, 1, SFTPBytes.blob(handle)) + ok(3) + ok(2) + ok(4)
        try fixture(replies) { channel, root in
            let data = Data((0..<100_000).map { UInt8($0 % 251) })
            let local = root.appendingPathComponent("source"); try data.write(to: local)
            var progress = [UInt64]()
            try channel.upload(local: local, remote: "./Karte [1] ä.bin") { progress.append($0) }
            XCTAssertEqual(progress.last, 100_000)
            var wire = SFTPBytes(data: try Data(contentsOf: root.appendingPathComponent("requests")))
            _ = try wire.blob() // INIT
            var open = SFTPBytes(data: try wire.blob())
            XCTAssertEqual(try open.byte(), 3); XCTAssertEqual(try open.u32(), 1)
            XCTAssertEqual(try open.string(), "./Karte [1] ä.bin")
            XCTAssertEqual(try open.u32(), 2 | 8 | 32)
            _ = try open.u32()
            var reconstructed = Data()
            for _ in 0..<2 {
                var write = SFTPBytes(data: try wire.blob())
                XCTAssertEqual(try write.byte(), 6); _ = try write.u32(); _ = try write.blob()
                XCTAssertEqual(try write.u64(), UInt64(reconstructed.count))
                reconstructed += try write.blob()
            }
            XCTAssertEqual(reconstructed, data)
            var close = SFTPBytes(data: try wire.blob()); XCTAssertEqual(try close.byte(), 4)
            XCTAssertThrowsError(try wire.byte(), "Handle must be closed exactly once")
        }
    }

    func testDownloadHandlesShortAndOutOfOrderReadsWithoutCorruptingOffsets() throws {
        let data = Data((0..<70_000).map { UInt8($0 % 253) })
        let replies = version + packet(102, 1, SFTPBytes.blob(Data([4]))) + packet(105, 2, attrs(70_000))
            + packet(103, 4, SFTPBytes.blob(data.subdata(in: 65_536..<66_536)))
            + packet(103, 3, SFTPBytes.blob(data.prefix(65_536)))
            + packet(103, 5, SFTPBytes.blob(data.subdata(in: 66_536..<70_000)))
            + packet(105, 6, attrs(70_000)) + ok(7)
        try fixture(replies) { channel, root in
            let destination = root.appendingPathComponent("received")
            var progress: UInt64 = 0
            try channel.download(remote: "./profile.etl", local: destination, size: 70_000) { progress = $0 }
            XCTAssertEqual(try Data(contentsOf: destination), data)
            XCTAssertEqual(progress, 70_000)
        }
    }

    func testTruncatedAndOversizedPacketsFailInsteadOfHangingOrAllocatingUnboundedData() throws {
        XCTAssertThrowsError(try fixture(SFTPBytes.uint32(4 * 1024 * 1024 + 1)) { _, _ in })
        XCTAssertThrowsError(try fixture(SFTPBytes.uint32(5) + Data([2, 0])) { _, _ in })
        var bytes = SFTPBytes(data: Data([0, 0, 0, 9, 1]))
        XCTAssertThrowsError(try bytes.blob())
    }

    func testCancellationTerminatesBlockedSSHProcess() throws {
        let operation = SSHFileOperation(), start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { operation.cancel() }
        XCTAssertThrowsError(try operation.run(executable: "/bin/sh", arguments: ["-c", "exec /bin/sleep 30"]) { _ in }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testCancellationOfBlockedUploadReturnsWithoutSIGPIPEOrHanging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("large.bin")
        try Data(repeating: 7, count: 2 * 1024 * 1024).write(to: local)
        // Announce VERSION and OPEN/HANDLE, then stop reading the client's upload pipe.
        let replies = version + packet(102, 1, SFTPBytes.blob(Data([1])))
        let octal = replies.map { String(format: "\\%03o", $0) }.joined()
        let operation = SSHFileOperation(), start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { operation.cancel() }
        XCTAssertThrowsError(try operation.run(executable: "/bin/sh", arguments: ["-c", "printf '\(octal)'; exec /bin/sleep 30"]) {
            try $0.upload(local: local, remote: "large.bin") { _ in }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRoundTripAgainstSystemSFTPServerWithPipelinedLargeFileAndLiteralNames() throws {
        let server = "/usr/libexec/sftp-server"
        guard FileManager.default.isExecutableFile(atPath: server) else { throw XCTSkip("System SFTP server is unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-roundtrip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("received")
        let data = Data((0..<(5 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
        try data.write(to: source)
        try SSHFileOperation().run(executable: server, arguments: []) { channel in
            let directory = root.appendingPathComponent("Ordner ä [1]").path
            try channel.createDirectory(directory)
            let partial = directory + "/transfer.partial", final = directory + "/file \"quoted\" [1] ä.bin"
            var sent: UInt64 = 0, received: UInt64 = 0
            try channel.upload(local: source, remote: partial) { count in XCTAssertGreaterThan(count, sent); sent = count }
            try channel.rename(partial, to: final)
            let files = try channel.list(directory)
            XCTAssertEqual(files.count, 1); XCTAssertEqual(files[0].name, "file \"quoted\" [1] ä.bin")
            XCTAssertEqual(files[0].size, UInt64(data.count))
            try channel.download(remote: final, local: destination, size: UInt64(data.count)) { count in received = count }
            XCTAssertEqual(sent, UInt64(data.count)); XCTAssertEqual(received, UInt64(data.count))
            XCTAssertEqual(try Data(contentsOf: destination), data)
            XCTAssertThrowsError(try channel.upload(local: source, remote: final) { _ in })
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: final)), data)
        }
    }

    func testHostIdentityFingerprintAndStrictSSHOptions() throws {
        let key = SFTPBytes.string("ssh-ed25519") + SFTPBytes.blob(Data(repeating: 7, count: 32))
        let scan = "# comment\n[127.0.0.1]:51234 ssh-ed25519 " + key.base64EncodedString() + "\n"
        let host = try WindowsSSHIdentity.hostKey(from: scan)
        XCTAssertEqual(host.fingerprint, "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: ""))
        XCTAssertThrowsError(try WindowsSSHIdentity.hostKey(from: ""))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh path " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = WindowsSSHIdentity(directory: root)
        try (identity.alias + " " + host.key + "\n").write(to: identity.knownHosts, atomically: true, encoding: .utf8)
        let args = try identity.arguments(user: "Guest name", port: 51234)
        XCTAssertTrue(args.contains("-oStrictHostKeyChecking=yes")); XCTAssertTrue(args.contains("-oBatchMode=yes"))
        XCTAssertTrue(args.contains("-oClearAllForwardings=yes")); XCTAssertTrue(args.contains("-oIdentityAgent=none"))
        XCTAssertTrue(args.contains("-oUserKnownHostsFile=\"" + identity.knownHosts.path + "\""))
        XCTAssertThrowsError(try identity.arguments(user: "", port: 51234))
    }

    func testBootstrapLaunchersAreShortAndPublicKeyDoesNotTravelThroughKeyboard() throws {
        let base="http://10.0.2.2:51234/" + String(repeating: "a", count: 32)
        let keyBytes=SFTPBytes.string("ssh-ed25519") + SFTPBytes.blob(Data(repeating: 7, count: 32))
        let publicKey="ssh-ed25519 " + keyBytes.base64EncodedString() + " Stratovo-Dateiaustausch"
        for command in [WindowsExchangeMedia.launch, try GuestBootstrapScripts.launch(kind: .ubuntu, baseURL: base)] {
            XCTAssertLessThan(command.count, 220)
            XCTAssertFalse(command.contains(publicKey))
            XCTAssertFalse(command.contains("GzipStream"))
            _ = try StratovoCore.WindowsTextInput(text: command, layout: .german)
            _ = try StratovoCore.WindowsTextInput(text: command, layout: .us)
        }
        XCTAssertThrowsError(try GuestBootstrapScripts.launch(kind: .windows, baseURL: "http://example.com/anything"))
        XCTAssertThrowsError(try GuestBootstrapScripts.script(kind: .windows, publicKey: publicKey, baseURL: base))
        XCTAssertFalse(WindowsExchangeMedia.launch.lowercased().contains("powershell"))

    }
}
