import AppKit
import ApplicationServices
import StratovoCore

@MainActor
final class DirectGuestWindowState {
    private var task: Task<Void, Never>?
    private var processID: Int32?

    func start(pid: Int32, executable: String, kind: String, profile: String = "") {
        guard pid > 0, pid != getpid(), processID != pid else { return }
        stop()
        processID = pid
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        let worker = DirectGuestWindowWorker(pid: pid, executable: executable, kind: kind, profile: profile)
        task = Task {
            while !Task.isCancelled {
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let screens = NSScreen.screens.map { screen in
                    let frame = screen.visibleFrame
                    return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
                }
                await worker.refresh(screens: screens)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        processID = nil
    }

    deinit { task?.cancel() }
}

private actor DirectGuestWindowWorker {
    private let pid: Int32
    private let executable: String
    private let kind: String
    private let profile: String
    private let key: String
    private var window: AXUIElement?
    private var previousFrame: CGRect?
    private var restored = false

    init(pid: Int32, executable: String, kind: String, profile: String) {
        self.pid = pid
        self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        self.kind = kind
        self.profile = profile
        key = "Stratovo.window.direct.\(kind).\(profile)"
    }

    func refresh(screens: [CGRect]) {
        guard !Task.isCancelled, AXIsProcessTrusted(), !screens.isEmpty else { return }
        if window == nil { window = findWindow() }
        guard let window else { return }
        guard let frame = frame(of: window) else { self.window = nil; previousFrame = nil; return }
        guard attribute(window, kAXMinimizedAttribute) as? Bool != true,
              attribute(window, "AXFullScreen") as? Bool != true else { previousFrame = nil; return }
        guard GuestWindowFrame.constrained(frame, to: screens) != nil else { return }
        defer { previousFrame = frame }
        // Qt and Cocoa both resize during startup and full-screen transitions.
        guard previousFrame == frame else { return }
        if !restored {
            if let saved = UserDefaults.standard.string(forKey: key),
               let target = GuestWindowFrame.constrained(NSRectFromString(saved), to: screens) {
                guard !Task.isCancelled else { return }
                var size = target.size, origin = target.origin
                guard let dimensions = AXValueCreate(.cgSize, &size), let position = AXValueCreate(.cgPoint, &origin),
                      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions) == .success,
                      AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success else { return }
                restored = true
                return
            }
            restored = true
        }
        guard !Task.isCancelled else { return }
        let value = NSStringFromRect(frame)
        if UserDefaults.standard.string(forKey: key) != value { UserDefaults.standard.set(value, forKey: key) }
    }

    private func findWindow() -> AXUIElement? {
        guard let result = try? CommandCapture.run(CommandSpec(executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid="]), timeout: 2) else { return nil }
        let runtime = URL(fileURLWithPath: executable).deletingLastPathComponent().path + "/"
        for owner in [pid] + AndroidProcessTree.descendants(of: pid, snapshot: result.output) {
            guard !Task.isCancelled,
                  let path = NSRunningApplication(processIdentifier: owner)?.executableURL?.resolvingSymlinksInPath().path,
                  path == executable || path.hasPrefix(runtime) else { continue }
            let application = AXUIElementCreateApplication(owner)
            _ = AXUIElementSetMessagingTimeout(application, 0.1)
            guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                _ = AXUIElementSetMessagingTimeout(window, 0.1)
                guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                      let title = attribute(window, kAXTitleAttribute) as? String,
                      Self.matches(title: title, kind: kind, profile: profile) else { continue }
                return window
            }
        }
        return nil
    }

    private static func matches(title: String, kind: String, profile: String) -> Bool {
        switch kind {
        case "android": return title.hasPrefix("Android Emulator") || (!profile.isEmpty && title == profile)
        case "windows": return title.hasPrefix("Windows Arm") || title.hasPrefix("QEMU Windows Arm")
        case "ubuntu": return title.hasPrefix("Ubuntu ARM") || title.hasPrefix("QEMU Ubuntu ARM")
        default: return false
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}
