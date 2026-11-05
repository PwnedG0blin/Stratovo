import AppKit
import XCTest
@testable import Stratovo

@MainActor
final class GuestWindowStateTests: XCTestCase {
    func testResizeSurvivesRecreatingEachPlayer() throws {
        let suite = "Stratovo.WindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        for (index, key) in ["player.android", "player.windows", "player.ubuntu", "controls.android", "controls.ubuntu"].enumerated() {
            let frame = NSRect(x: CGFloat(35 + index * 10), y: 45, width: CGFloat(520 + index * 30), height: 500)
            var state: GuestWindowState?
            let first = makeWindow()
            state = GuestWindowState(window: first, key: key, defaults: defaults)
            first.setFrame(frame, display: false)
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)
            first.close()
            state = nil
            let second = makeWindow()
            state = GuestWindowState(window: second, key: key, defaults: defaults)
            let expected = try XCTUnwrap(GuestWindowFrame.constrained(frame, to: NSScreen.screens.map(\.visibleFrame)))
            XCTAssertEqual(second.frame, expected, key)
            withExtendedLifetime(state) { second.close() }
        }
    }

    func testFullScreenTransitionKeepsNormalSize() throws {
        let suite = "Stratovo.WindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = makeWindow()
        let state = GuestWindowState(window: window, key: "player.android", defaults: defaults)
        window.setFrame(NSRect(x: 40, y: 60, width: 540, height: 500), display: false)
        state.save()
        let key = "Stratovo.window.frame.player.android"
        let normal = defaults.string(forKey: key)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        XCTAssertEqual(defaults.string(forKey: key), normal)
        window.setFrame(NSRectFromString(try XCTUnwrap(normal)), display: false)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        withExtendedLifetime(state) { window.close() }
    }

    func testDisconnectedMonitorAndInvalidFrames() {
        let main = CGRect(x: 0, y: 30, width: 1440, height: 850)
        let external = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let saved = CGRect(x: -1800, y: 50, width: 1000, height: 700)
        XCTAssertEqual(GuestWindowFrame.constrained(saved, to: [main, external]), saved)
        let recovered = GuestWindowFrame.constrained(saved, to: [main])!
        XCTAssertTrue(main.contains(recovered))
        XCTAssertEqual(recovered.size, saved.size)
        let oversized = GuestWindowFrame.constrained(CGRect(x: 90000, y: -90000, width: 9000, height: 9000), to: [main])!
        XCTAssertEqual(oversized, main)
        XCTAssertNil(GuestWindowFrame.constrained(.zero, to: [main]))
        XCTAssertNil(GuestWindowFrame.constrained(CGRect(x: CGFloat.nan, y: 0, width: 500, height: 400), to: [main]))
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
