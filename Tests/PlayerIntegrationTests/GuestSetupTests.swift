import XCTest
import Foundation
import StratovoCore
@testable import Stratovo

final class GuestSetupTests: XCTestCase {
    private let token = String(repeating: "a", count: 32)
    private var publicKey: String {
        "ssh-ed25519 " + (SFTPBytes.string("ssh-ed25519") + SFTPBytes.blob(Data(repeating: 7, count: 32))).base64EncodedString() + " Stratovo-Dateiaustausch"
    }
    func testHTTPParserSupportsFragmentedRequestsAndRejectsAmbiguousLengths() throws {
        let body = Data("{\"stage\":\"ready\"}".utf8)
        let header = Data("POST /\(token)/status HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        XCTAssertNil(try GuestSetupRequest.parse(header + body.prefix(3)))
        let request = try XCTUnwrap(GuestSetupRequest.parse(header + body))
        XCTAssertEqual(request.body, body); XCTAssertEqual(request.method, "POST")
        for raw in ["GET / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nxx",
                    "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
                    "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
                    "POST / HTTP/1.1\r\nContent-Length: 32769\r\n\r\n"] {
            XCTAssertThrowsError(try GuestSetupRequest.parse(Data(raw.utf8)))
        }
    }

    @MainActor
    func testLoopbackServerDeliversScriptAndAuthenticatedAccountCallback() async throws {
        let server = GuestSetupServer(); server.script = Data("setup ä".utf8)
        try await server.start(); defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)/\(server.token)"
        let (data, response) = try await URLSession.shared.data(from: URL(string: base + "/setup")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "setup ä"); XCTAssertTrue(server.fetched)
        var post = URLRequest(url: URL(string: base + "/status")!)
        post.httpMethod = "POST"; post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: ["stage": "ready", "user": "TestUser", "key": publicKey])
        let (_, result) = try await URLSession.shared.data(for: post)
        XCTAssertEqual((result as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(server.update?.user, "TestUser"); XCTAssertEqual(server.update?.key, publicKey)
        let (_, denied) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)/wrong/setup")!)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
    }

    @MainActor
    func testScreenshotUploadUsesOnlyTheExpectedCapabilityAndDestination() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("stratovo-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: target) }
        let server = GuestSetupServer(); server.captureFile = target
        try await server.start(); defer { server.stop() }
        let payload = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/wrong/image")!)
        request.httpMethod = "POST"; request.httpBody = payload
        let (_, denied) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404); XCTAssertFalse(server.captureReceived)
        request.url = URL(string: "http://127.0.0.1:\(server.port)/\(server.token)/image")!
        let (_, allowed) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((allowed as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: target), payload); XCTAssertTrue(server.captureReceived)
    }

    func testCapturedADBCommandsSeparateStderrFromBinaryAndCanBeCancelled() throws {
        let result = try SSHFileOperation().capture(executable: "/bin/sh", arguments: ["-c", "printf abc; printf daemon-noise >&2"], mergeErrors: false)
        XCTAssertEqual(result.status, 0); XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "abc")
        let operation = SSHFileOperation(), start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { operation.cancel() }
        XCTAssertThrowsError(try operation.capture(executable: "/bin/sleep", arguments: ["30"])) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testReadOnlyWindowsMediaContainsOnlyLocalHelperAndConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper.exe")
        try Data("test helper".utf8).write(to: helper)
        let base = "http://10.0.2.2:51234/" + token
        let media = try WindowsExchangeMedia.create(helper: helper, baseURL: base, publicKey: publicKey)
        defer { media.remove() }
        let mounted = root.appendingPathComponent("Mounted")
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: false)
        let attach = try CommandCapture.run(CommandSpec(executable: "/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-nobrowse", "-mountpoint", mounted.path, media.iso.path]))
        XCTAssertEqual(attach.status, 0, attach.output)
        defer { _ = try? CommandCapture.run(CommandSpec(executable: "/usr/bin/hdiutil", arguments: ["detach", mounted.path])) }
        XCTAssertEqual(try Data(contentsOf: mounted.appendingPathComponent("Stratovo.exe")), Data("test helper".utf8))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: mounted.appendingPathComponent("exchange.json"))) as? [String: String])
        XCTAssertEqual(config["endpoint"], base); XCTAssertEqual(config["publicKey"], publicKey); XCTAssertEqual(config["mode"], "setup")
    }

    func testExportAndParseGeneratedGuestScripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stratovo-scripts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = "http://10.0.2.2:51234/" + token
        let ubuntu = try GuestBootstrapScripts.script(kind: .ubuntu, publicKey: publicKey, baseURL: base)
        let pyRegex = try NSRegularExpression(pattern: #"base64.b64decode\('([A-Za-z0-9+/=]+)'\)"#)
        let pyMatch = try XCTUnwrap(pyRegex.firstMatch(in: ubuntu, range: NSRange(ubuntu.startIndex..., in: ubuntu)))
        let pyRange = try XCTUnwrap(Range(pyMatch.range(at: 1), in: ubuntu))
        let ubuntuRoot = try XCTUnwrap(String(data: XCTUnwrap(Data(base64Encoded: String(ubuntu[pyRange]))), encoding: .utf8))
        let scripts = ["ubuntu.py": ubuntu, "ubuntu-admin.py": "target={}\n" + ubuntuRoot]
        for (name, code) in scripts {
            let file = root.appendingPathComponent(name); try code.write(to: file, atomically: true, encoding: .utf8)
            if name.hasSuffix(".py") {
                let result = try CommandCapture.run(CommandSpec(executable: "/usr/bin/python3", arguments: ["-c", "import ast,pathlib,sys;ast.parse(pathlib.Path(sys.argv[1]).read_text())", file.path]))
                XCTAssertEqual(result.status, 0, result.output)
            }
        }
        XCTAssertTrue(ubuntuRoot.contains("pkexec") == false)
        XCTAssertTrue(ubuntu.contains("pkexec")); XCTAssertTrue(ubuntuRoot.contains("openssh-server"))
        if let directory = ProcessInfo.processInfo.environment["STRATOVO_SETUP_TEST_DIRECTORY"] {
            let target = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for (name, code) in scripts { try code.write(to: target.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        }
    }
}
