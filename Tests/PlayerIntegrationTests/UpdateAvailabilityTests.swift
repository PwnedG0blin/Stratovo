import Foundation
import XCTest
import StratovoCore
@testable import Stratovo

final class UpdateAvailabilityTests: XCTestCase {
    @MainActor
    func testPrivateUpdateChecksAtStartupAndSharesAvailability() async throws {
        let suite = "Stratovo.UpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date(), forKey: "Stratovo.privateUpdates.lastAttempt")
        var requests = 0
        var build = 1052
        let updates = PrivateUpdateController(installedBuild: 1051, defaults: defaults, fetchLatest: { _ in
            requests += 1
            return try Self.artifact(build: build)
        }, readCredential: { interactive in
            XCTAssertFalse(interactive)
            return "test-credential"
        })
        await updates.checkIfDue()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(updates.available?.build, 1052)
        XCTAssertTrue(AppPresentation.updateAvailable(publicState: .idle, privateUpdate: updates.available, privateBuild: true))
        await updates.checkIfDue()
        XCTAssertEqual(requests, 1)
        build = 1051
        await updates.check()
        XCTAssertNil(updates.available)
        XCTAssertFalse(AppPresentation.updateAvailable(publicState: .idle, privateUpdate: updates.available, privateBuild: true))
    }

    @MainActor
    func testPublicStartupCheckIsNotSuppressedByPreviousSession() async throws {
        let suite = "Stratovo.UpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date(), forKey: "Pixelkoje.GitHubUpdates.lastAttempt")
        var requests = 0
        let checker = GitHubUpdateChecker(installedVersion: "1.0.0-beta.7.9", defaults: defaults) { request in
            requests += 1
            let data = Data("""
            [{"tag_name":"v1.0.0-beta.7.10","html_url":"https://github.com/PwnedG0blin/Stratovo/releases/tag/v1.0.0-beta.7.10","draft":false,"prerelease":true}]
            """.utf8)
            return (data, try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        await checker.checkIfDue(includePrereleases: true)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(AppPresentation.updateAvailable(publicState: checker.state, privateUpdate: nil, privateBuild: false))
        XCTAssertFalse(AppPresentation.updateAvailable(publicState: checker.state, privateUpdate: nil, privateBuild: true))
        await checker.checkIfDue(includePrereleases: true)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testPrivateBadgeSurvivesTemporaryNetworkFailure() async throws {
        let suite = "Stratovo.UpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var offline = false
        let updates = PrivateUpdateController(installedBuild: 1051, defaults: defaults, fetchLatest: { _ in
            if offline { throw URLError(.notConnectedToInternet) }
            return try Self.artifact(build: 1052)
        }, readCredential: { _ in "test-credential" })
        await updates.check()
        offline = true
        await updates.check()
        XCTAssertEqual(updates.available?.build, 1052)
        XCTAssertFalse(AppPresentation.updateAvailable(publicState: .idle, privateUpdate: updates.available, privateBuild: false))
    }

    @MainActor
    func testCancelledPrivateCheckRetriesOnNextActivation() async throws {
        let suite = "Stratovo.UpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var finish = false
        var requests = 0
        let updates = PrivateUpdateController(installedBuild: 1051, defaults: defaults, fetchLatest: { _ in
            requests += 1
            if !finish { try await Task.sleep(nanoseconds: 60_000_000_000) }
            return try Self.artifact(build: 1052)
        }, readCredential: { _ in "test-credential" })
        let task = Task { await updates.checkIfDue() }
        for _ in 0..<1000 where !updates.busy { await Task.yield() }
        XCTAssertTrue(updates.busy)
        task.cancel()
        await task.value
        finish = true
        await updates.checkIfDue()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(updates.available?.build, 1052)
    }

    @MainActor
    func testCancelledPublicCheckRetriesOnNextActivation() async throws {
        let suite = "Stratovo.UpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var finish = false
        var requests = 0
        let checker = GitHubUpdateChecker(installedVersion: "1.0.0-beta.7.9", defaults: defaults) { request in
            requests += 1
            if !finish { try await Task.sleep(nanoseconds: 60_000_000_000) }
            return (Data("[]".utf8), try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let task = Task { await checker.checkIfDue(includePrereleases: true) }
        for _ in 0..<1000 where !checker.isChecking { await Task.yield() }
        XCTAssertTrue(checker.isChecking)
        task.cancel()
        await task.value
        finish = true
        await checker.checkIfDue(includePrereleases: true)
        XCTAssertEqual(requests, 2)
        guard case .noReleases = checker.state else { return XCTFail("The resumed check did not complete") }
    }

    private static func artifact(build: Int) throws -> PrivateUpdateArtifact {
        try JSONDecoder().decode(PrivateUpdateArtifact.self, from: Data("""
        {"id":1,"name":"Stratovo-Private-Beta-App-Build\(build)","size_in_bytes":100,"expired":false,"digest":"sha256:\(String(repeating: "a", count: 64))","workflow_run":{"id":1,"repository_id":2,"head_repository_id":2,"head_branch":"main","head_sha":"\(String(repeating: "a", count: 40))"}}
        """.utf8))
    }
}
