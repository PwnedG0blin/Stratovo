import AppKit

enum GuestWindowFrame {
    static func constrained(_ frame: CGRect, to screens: [CGRect]) -> CGRect? {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width >= 100, frame.height >= 100, !screens.isEmpty else { return nil }
        var screen = screens[0], bestArea: CGFloat = 0
        for candidate in screens {
            let overlap = frame.intersection(candidate)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea { screen = candidate; bestArea = area }
        }
        let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return CGRect(x: max(screen.minX, min(frame.minX, screen.maxX - size.width)),
                      y: max(screen.minY, min(frame.minY, screen.maxY - size.height)),
                      width: size.width, height: size.height)
    }
}

@MainActor
final class GuestWindowState {
    private weak var window: NSWindow?
    private let defaults: UserDefaults
    private let key: String
    private var observers: [NSObjectProtocol] = []
    private var changingFullScreen = false

    init(window: NSWindow, key: String, legacyName: String? = nil, defaults: UserDefaults = .standard) {
        self.window = window
        self.defaults = defaults
        self.key = "Stratovo.window.frame.\(key)"
        if let saved = defaults.string(forKey: self.key),
           let frame = GuestWindowFrame.constrained(NSRectFromString(saved), to: NSScreen.screens.map(\.visibleFrame)) {
            window.setFrame(frame, display: false)
        } else if let legacyName {
            _ = window.setFrameUsingName(legacyName, force: true)
            if let frame = GuestWindowFrame.constrained(window.frame, to: NSScreen.screens.map(\.visibleFrame)) {
                window.setFrame(frame, display: false)
            }
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.save()
                self?.changingFullScreen = true
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changingFullScreen = true }
        })
        for name in [NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changingFullScreen = false; self?.save() }
            })
        }
    }

    func save() {
        guard let window, !changingFullScreen, !window.isMiniaturized,
              !window.styleMask.contains(.fullScreen),
              GuestWindowFrame.constrained(window.frame, to: NSScreen.screens.map(\.visibleFrame)) != nil else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: key)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
