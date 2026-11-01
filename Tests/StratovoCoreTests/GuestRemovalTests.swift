import Foundation
import XCTest
import CryptoKit
@testable import StratovoCore

final class GuestRemovalTests: XCTestCase {
    private final class Fixture {
        let base: URL
        let storage: GuestStorage
        let support: URL
        let trash: URL
        let fm = FileManager.default
        init() throws {
            base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("removal-" + UUID().uuidString)
            storage = GuestStorage(root: base.appendingPathComponent("Data").path, id: UUID().uuidString)
            support = base.appendingPathComponent("Support")
            trash = base.appendingPathComponent("FixtureTrash")
            for folder in [storage.url, support, trash] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            try Data(storage.id.utf8).write(to: storage.url.appendingPathComponent(".openguest-storage-id"))
        }
        deinit { try? fm.removeItem(at: base) }
        func file(_ relative: String, _ text: String = "precious data") throws {
            let url = storage.url.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func android(_ name: String, package: String = "system-images/android-36/google_apis_playstore/arm64-v8a") throws {
            try file("Android/avd/\(name).avd/config.ini", "image.sysdir.1=\(package)/\n")
            try file("Android/avd/\(name).avd/userdata-qemu.img")
            try file("Android/avd/\(name).ini", "path=\(storage.avd.path)/\(name).avd\n")
            try file("Android/sdk/\(package)/system.img", "base image")
            try file("Android/sdk/emulator/emulator", "shared runtime")
        }
        func plan(_ target: GuestRemovalTarget) throws -> GuestRemovalPlan {
            try GuestRemoval.plan(storage: storage, target: target, support: support)
        }
        func execute(_ plan: GuestRemovalPlan) throws -> URL {
            try GuestRemoval.execute(plan, storage: storage, support: support) { bundle in
                let destination = trash.appendingPathComponent(bundle.lastPathComponent)
                try fm.moveItem(at: bundle, to: destination)
                return destination
            }
        }
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: storage.root + "/" + path) }
    }

    func testWindowsMovesGuestAndExportsButKeepsOtherGuestsAndRuntime() throws {
        let f = try Fixture()
        try f.file("Windows/windows.qcow2"); try f.file("Windows/TPM/state")
        try f.file("Austausch/Windows/Import-1/personal.txt")
        try f.file("Ubuntu/ubuntu.qcow2"); try f.file("Runtime/qemu")
        let plan = try f.plan(.windows)
        XCTAssertEqual(plan.paths.count, 2)
        let trashed = try f.execute(plan)
        XCTAssertFalse(f.exists("Windows")); XCTAssertFalse(f.exists("Austausch/Windows"))
        XCTAssertTrue(f.exists("Ubuntu/ubuntu.qcow2")); XCTAssertTrue(f.exists("Runtime/qemu"))
        XCTAssertTrue(f.fm.fileExists(atPath: trashed.appendingPathComponent("Original-Paths.json").path))
        XCTAssertTrue(try f.fm.contentsOfDirectory(atPath: trashed.path).contains { $0.hasSuffix("-Windows") })
        XCTAssertThrowsError(try f.execute(plan)) // stale approval cannot be reused
    }

    func testUbuntuMovesAllAccountsDiskFirmwareISOAndConfig() throws {
        let f = try Fixture()
        for path in ["Ubuntu/ubuntu.qcow2", "Ubuntu/uefi-vars.fd", "Ubuntu/config.json", "Ubuntu/installer.iso"] { try f.file(path) }
        try f.file("Windows/windows.qcow2")
        let trashed = try f.execute(f.plan(.ubuntu))
        XCTAssertFalse(f.exists("Ubuntu")); XCTAssertTrue(f.exists("Windows/windows.qcow2"))
        let folder = try XCTUnwrap(f.fm.contentsOfDirectory(atPath: trashed.path).first { $0.hasSuffix("-Ubuntu") })
        XCTAssertEqual(try f.fm.contentsOfDirectory(atPath: trashed.appendingPathComponent(folder).path).count, 4)
    }

    func testAndroidOnlySelectedVersionAndExclusiveImageAreRemoved() throws {
        let f = try Fixture()
        try f.android("Official")
        try f.android("Preview", package: "system-images/android-37.0/google_apis_playstore/arm64-v8a")
        let plan = try f.plan(.android("Preview"))
        XCTAssertEqual(plan.paths.count, 3); XCTAssertFalse(plan.retainedAndroidImage)
        _ = try f.execute(plan)
        XCTAssertFalse(f.exists("Android/avd/Preview.avd")); XCTAssertFalse(f.exists("Android/avd/Preview.ini"))
        XCTAssertTrue(f.exists("Android/avd/Official.avd/userdata-qemu.img"))
        XCTAssertTrue(f.exists("Android/sdk/emulator/emulator"))
        XCTAssertTrue(f.exists("Android/sdk/system-images/android-36/google_apis_playstore/arm64-v8a/system.img"))
    }

    func testSharedAndroidImageIsKeptIncludingOrphanProfileReferences() throws {
        let f = try Fixture()
        try f.android("First"); try f.android("Other")
        try f.fm.removeItem(at: f.storage.avd.appendingPathComponent("Other.ini"))
        let plan = try f.plan(.android("First"))
        XCTAssertTrue(plan.retainedAndroidImage); XCTAssertEqual(plan.paths.count, 2)
        _ = try f.execute(plan)
        XCTAssertTrue(f.exists("Android/sdk/system-images/android-36/google_apis_playstore/arm64-v8a/system.img"))
    }

    func testNewAndroidReferenceInvalidatesPreviouslyApprovedImageDeletion() throws {
        let f = try Fixture()
        try f.android("First")
        let plan = try f.plan(.android("First"))
        try f.android("New")
        XCTAssertThrowsError(try f.execute(plan))
        XCTAssertTrue(f.exists("Android/avd/First.avd/userdata-qemu.img"))
    }

    func testTrashFailureRollsBackEveryMovedPath() throws {
        let f = try Fixture()
        try f.android("First")
        let plan = try f.plan(.android("First"))
        XCTAssertThrowsError(try GuestRemoval.execute(plan, storage: f.storage, support: f.support) { _ in
            throw NSError(domain: "FixtureTrashFailure", code: 1)
        })
        XCTAssertTrue(f.exists("Android/avd/First.avd/userdata-qemu.img"))
        XCTAssertTrue(f.exists("Android/avd/First.ini"))
        XCTAssertTrue(f.exists("Android/sdk/system-images/android-36/google_apis_playstore/arm64-v8a/system.img"))
        XCTAssertFalse(try f.fm.contentsOfDirectory(atPath: f.storage.root).contains { $0.hasPrefix("Stratovo-Removed-") })
    }

    func testSymlinkAndTraversalAndExternalLocatorAreRejected() throws {
        let f = try Fixture()
        try f.file("Ubuntu/ubuntu.qcow2")
        try f.fm.createSymbolicLink(at: f.storage.windows, withDestinationURL: f.storage.url.appendingPathComponent("Ubuntu"))
        XCTAssertThrowsError(try f.plan(.windows))
        XCTAssertThrowsError(try f.plan(.android("../Ubuntu")))
        try f.android("First")
        try f.file("Android/avd/First.ini", "path=/elsewhere/First.avd\n")
        XCTAssertThrowsError(try f.plan(.android("First")))
        XCTAssertTrue(f.exists("Ubuntu/ubuntu.qcow2"))
    }

    func testDisconnectedStorageAndReplacedFolderInvalidateApproval() throws {
        let f = try Fixture()
        try f.file("Windows/windows.qcow2")
        let plan = try f.plan(.windows)
        try f.fm.moveItem(at: f.storage.windows, to: f.storage.url.appendingPathComponent("OriginalWindows"))
        try f.file("Windows/windows.qcow2", "different guest")
        XCTAssertThrowsError(try f.execute(plan))
        try Data("another volume".utf8).write(to: f.storage.url.appendingPathComponent(".openguest-storage-id"))
        XCTAssertThrowsError(try f.plan(.windows))
        XCTAssertTrue(f.exists("Windows/windows.qcow2"))
    }

    func testSSHKeysAreScopedToRemovedGuestAndRollbackIncludesThem() throws {
        let f = try Fixture()
        try f.file("Windows/windows.qcow2")
        let windowsHash = SHA256.hash(data: Data(f.storage.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let ubuntuHash = SHA256.hash(data: Data((f.storage.id + ".ubuntu").utf8)).map { String(format: "%02x", $0) }.joined()
        for hash in [windowsHash, ubuntuHash] {
            let folder = f.support.appendingPathComponent("SSH/" + hash)
            try f.fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("fixture-key".utf8).write(to: folder.appendingPathComponent("id_ed25519"))
        }
        let plan = try f.plan(.windows)
        XCTAssertTrue(plan.paths.contains { $0.hasSuffix(windowsHash) })
        XCTAssertFalse(plan.paths.contains { $0.hasSuffix(ubuntuHash) })
        XCTAssertThrowsError(try GuestRemoval.execute(plan, storage: f.storage, support: f.support) { _ in
            throw NSError(domain: "FixtureTrashFailure", code: 1)
        })
        XCTAssertTrue(f.fm.fileExists(atPath: f.support.appendingPathComponent("SSH/" + windowsHash + "/id_ed25519").path))
        _ = try f.execute(f.plan(.windows))
        XCTAssertFalse(f.fm.fileExists(atPath: f.support.appendingPathComponent("SSH/" + windowsHash).path))
        XCTAssertTrue(f.fm.fileExists(atPath: f.support.appendingPathComponent("SSH/" + ubuntuHash + "/id_ed25519").path))
    }

    func testIncompleteAndroidInstallationCanBeRemovedWithoutRemovingSDK() throws {
        let f = try Fixture()
        try f.file("Android/avd/Broken.avd/partial.img")
        try f.file("Android/sdk/emulator/emulator")
        let plan = try f.plan(.android("Broken"))
        XCTAssertEqual(plan.paths.count, 1)
        _ = try f.execute(plan)
        XCTAssertFalse(f.exists("Android/avd/Broken.avd"))
        XCTAssertTrue(f.exists("Android/sdk/emulator/emulator"))
    }

    #if os(macOS)
    func testRealMacTrashReceivesOnlyFixtureGuestData() throws {
        let f = try Fixture()
        try f.file("Ubuntu/ubuntu.qcow2", "fixture user account and files")
        let destination = try GuestRemoval.execute(f.plan(.ubuntu), storage: f.storage, support: f.support) { bundle in
            var result: NSURL?
            try FileManager.default.trashItem(at: bundle, resultingItemURL: &result)
            return try XCTUnwrap(result as URL?)
        }
        // This directory contains only the uniquely named test fixture created above.
        defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertFalse(f.exists("Ubuntu"))
        let folder = try XCTUnwrap(f.fm.contentsOfDirectory(atPath: destination.path).first { $0.hasSuffix("-Ubuntu") })
        let payload = try String(contentsOf: destination.appendingPathComponent(folder + "/ubuntu.qcow2"), encoding: .utf8)
        XCTAssertEqual(payload, "fixture user account and files")
    }
    #endif
}
