import AppKit
import SwiftUI
import StratovoCore

/// One retained window per player. Closing the display never terminates a guest.
@MainActor
final class GuestPlayerWindows: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var windowStates: [String: GuestWindowState] = [:]
    private weak var model: AppModel?

    func show(kind: String, model: AppModel) {
        guard ["android", "windows", "ubuntu"].contains(kind) else { return }
        let window: NSWindow
        if let existing = windows[kind] {
            window = existing
        } else {
            let android = kind == "android"
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: android ? 520 : 1100, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            window.title = android ? "Android Player · Stratovo" : (kind == "ubuntu" ? "Ubuntu Player · Stratovo" : "Windows Arm Player · Stratovo")
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentMinSize = NSSize(width: 360, height: 480)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.delegate = self
            window.contentView = NSHostingView(rootView: GuestPlayerView(model: model, kind: kind)
                .environment(\.locale, Locale(identifier: L10n.code))
                .environment(\.layoutDirection, L10n.code == "ar" ? .rightToLeft : .leftToRight))
            window.center()
            windowStates[kind] = GuestWindowState(window: window, key: "player.\(kind)", legacyName: "OpenGuest.player.\(kind)")
            windows[kind] = window
        }
        self.model = model
        model.setGuestPlayerVisible(true, kind: kind)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func hide(kind: String) {
        guard let window = windows[kind] else { return }
        windowStates[kind]?.save()
        window.orderOut(nil)
        model?.setGuestPlayerVisible(false, kind: kind)
    }

    func toggleFullScreen(kind: String) { windows[kind]?.toggleFullScreen(nil) }

    func fitAndroid(model: AppModel) {
        show(kind: "android", model: model)
        guard let window = windows["android"], !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let source = model.playerSize == .zero ? CGSize(width: 1440, height: 3120) : model.playerSize
        func viewport(in view: NSView?) -> GuestViewport? {
            guard let view else { return nil }
            if let result = view as? GuestViewport { return result }
            for child in view.subviews { if let found = viewport(in: child) { return found } }
            return nil
        }
        // Re-measure wrapped controls after each width adjustment.
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            let area = viewport(in: window.contentView)?.contentSize ?? NSSize(width: window.frame.width, height: max(1, window.frame.height - 300))
            let chrome = NSSize(width: max(0, window.frame.width - area.width), height: max(0, window.frame.height - area.height))
            let size = AndroidPhoneWindow.size(source: source, available: visible.size, chrome: chrome)
            window.setFrame(NSRect(x: max(visible.minX, min(window.frame.midX - size.width / 2, visible.maxX - size.width)),
                y: visible.maxY - size.height, width: size.width, height: size.height), display: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.makeFirstResponder(nil)
        if let kind = windows.first(where: { $0.value === window })?.key {
            model?.setGuestPlayerVisible(false, kind: kind)
        }
    }
}

@MainActor
struct GuestPlayerView: View {
    @ObservedObject var model: AppModel
    let kind: String
    private var active: Bool { model.activeGuest == kind }
    @State private var pastePresented = false
    @State private var pasteDraft = ""
    @AppStorage private var fitsWindow: Bool
    @AppStorage private var androidTouchScroll: Bool
    @AppStorage private var scrollMomentum: Bool
    @AppStorage private var zoomPercent: Double
    @State private var androidDisplayPresented = false
    @State private var exchangePresented = false
    private var safeZoom: Double { zoomPercent.isFinite ? max(25, min(300, zoomPercent)) : 100 }

    init(model: AppModel, kind: String) {
        self.model = model; self.kind = kind
        _fitsWindow = AppStorage(wrappedValue: true, "Pixelkoje.playerFit.\(kind)")
        _zoomPercent = AppStorage(wrappedValue: 100, "Pixelkoje.playerZoom.\(kind)")
        _scrollMomentum = AppStorage(wrappedValue: false, "Pixelkoje.scrollMomentum.\(kind)")
        _androidTouchScroll = AppStorage(wrappedValue: true, "Pixelkoje.androidTouchScroll")
    }

    private func beginPaste() {
        guard active, !model.windowsPasteBusy else { return }
        pasteDraft = NSPasteboard.general.string(forType: .string) ?? ""
        pastePresented = true
    }

    var body: some View {
        VStack(spacing: 0) {
            playerHeader
                .padding(12).modifier(WorkspaceChromeSurface())
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
            ZStack {
                Color.black
                // Only the active guest owns the video layer and receives input.
                if active {
                    PlayerSurface(image: kind != "android" ? model.playerImage : nil,
                                  videoLayer: kind == "android" ? model.h264Player.layer : nil,
                                  sourceSize: model.playerSize,
                                  pointer: { model.pointer(x: $0, y: $1, mask: $2) },
                                  key: { model.keyboard(code: $0, text: $1, down: $2) },
                                  paste: { beginPaste() },
                                  scroll: { model.scroll(x: $0, y: $1, horizontal: $2, vertical: $3, mask: $4) },
                                  resetScroll: { model.resetScroll() }, zoomPercent: fitsWindow ? nil : safeZoom,
                                  allowsScrollMomentum: scrollMomentum,
                                  touchScroll: kind == "android" && androidTouchScroll ? { x,y,h,v,phase in
                                      model.swipeAndroid(x: x, y: y, horizontal: h, vertical: v, phase: phase)
                                  } : nil, windowsFrames: kind != "android" ? model.windowsFrames : nil)
                }
                if !active || model.playerSize == .zero {
                    VStack(spacing: 12) {
                        Image(systemName: kind == "android" ? "apps.iphone" : "desktopcomputer")
                            .font(.system(size: 42))
                        Text(active ? (kind != "android" ? model.playerStatus : "System startet …") : L10n.text("Gastsystem ist ausgeschaltet"))
                            .multilineTextAlignment(.center)
                        if active && kind == "windows" {
                            Text(model.windowsBootMediaStatus).font(.caption).multilineTextAlignment(.center)
                                .textSelection(.enabled)
                        }
                    }.padding(24).frame(maxWidth: 650).foregroundStyle(.white.opacity(0.85)).allowsHitTesting(false)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MidnightPalette.turquoise.opacity(0.20)))
                .padding(.horizontal, 10)
            VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Player-Steuerung"), systemImage: "slider.horizontal.3").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                    .help(L10n.text("Weitere Optionen: hier scrollen"))
            }.padding(.horizontal, 14).padding(.top, 10)
            ScrollView {
              VStack(alignment: .leading, spacing: 10) {
                GuestAudioControls(audio: model.audio, kind: kind)
                Divider()
                if kind == "android" {
                    AndroidStreamQualityControls(model: model)
                    DisclosureGroup(L10n.text("Bildrate · bis 90 FPS")) { AndroidFrameRateControls(model: model).padding(.vertical, 8) }
                    HStack {
                        Button(L10n.text("Bild einpassen")) { fitsWindow = true }
                        Button(L10n.text("Telefonfenster")) { fitsWindow = true; model.fitAndroidPlayerWindow() }
                    }
                    Button(L10n.text("Anzeige neu verbinden")) { Task { await model.reconnectAndroidDisplay() } }
                        .disabled(!model.canReconnectAndroidDisplay)
                    Button(L10n.text("Text einfügen …"), action: beginPaste).disabled(!active || model.playerSize == .zero)
                        .help(L10n.text("Text vom Mac nach Android übertragen. Auch mit ⌘V im Gastbild."))
                    if !model.androidPasteStatus.isEmpty { Text(model.androidPasteStatus).font(.system(size: 13)) }
                }
                ViewThatFits(in: .horizontal) {
                  HStack {
                    Toggle(L10n.text("An Fenster anpassen"), isOn: $fitsWindow).toggleStyle(.checkbox)
                    Spacer(minLength: 4)
                    displaySettingsButton
                  }
                  VStack(alignment: .leading, spacing: 10) {
                    Toggle(L10n.text("An Fenster anpassen"), isOn: $fitsWindow).toggleStyle(.checkbox)
                    displaySettingsButton
                  }
                }
                if !fitsWindow {
                    HStack {
                        Text(L10n.text("Ansicht"))
                        Slider(value: $zoomPercent, in: 25...300, step: 5)
                        Text("\(Int(safeZoom)) %").monospacedDigit().frame(width: 50, alignment: .trailing)
                        Button("100 %") { zoomPercent = 100 }
                    }
                }
                HStack {
                    Text(L10n.text("Scrolltempo")).font(.system(size: 13))
                    Slider(value: Binding(get: {
                        kind == "android" ? model.androidScrollSpeed : (kind == "ubuntu" ? model.ubuntuScrollSpeed : model.windowsScrollSpeed)
                    }, set: { value in
                        if kind == "android" { model.androidScrollSpeed = value }
                        else if kind == "ubuntu" { model.ubuntuScrollSpeed = value }
                        else { model.windowsScrollSpeed = value }
                    }), in: 10...200, step: 5)
                    Text("\(Int(kind == "android" ? model.androidScrollSpeed : (kind == "ubuntu" ? model.ubuntuScrollSpeed : model.windowsScrollSpeed))) %")
                        .font(.system(size: 13, weight: .medium).monospacedDigit()).frame(width: 44, alignment: .trailing)
                    Button("100 %") {
                        if kind == "android" { model.androidScrollSpeed = 100 }
                        else if kind == "ubuntu" { model.ubuntuScrollSpeed = 100 }
                        else { model.windowsScrollSpeed = 100 }
                    }.controlSize(.small)
                }.help(L10n.text("Trackpad und Mausrad · 50 % = halbes bisheriges Tempo. Pro Gastsystem gespeichert; wirkt sofort."))
                if kind == "android" {
                    Toggle(L10n.text("Wischen wie am Handy"), isOn: $androidTouchScroll).toggleStyle(.checkbox)
                        .help(L10n.text("Zwei Finger auf dem Trackpad ziehen als ein Finger in Android. Aus: Scrollrad-Ereignisse. Die Scrollrichtung folgt macOS; Apps können eigene Wischgesten erkennen."))
                }
                Toggle(L10n.text("Trackpad-Nachlauf"), isOn: $scrollMomentum).toggleStyle(.checkbox)
                    .help(L10n.text("Aus: keinen Mac-Nachlauf übertragen. Ein: Mac-Schwung weitergeben. Android-Apps können nach einer Wischgeste zusätzlich eigenen Nachlauf erzeugen. Pro Gastsystem gespeichert."))
                Text(fitsWindow
                    ? L10n.text("Zwei Finger: im Gast scrollen. Bild passt sich der Fenstergröße an.")
                    : L10n.text("100 % = ein Gast-Bildpixel pro Mac-Bildpixel. Bild über Scrollleisten verschieben; zwei Finger scrollen im Gast."))
                    .font(.system(size: 13)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if kind == "windows" {
                    Text(L10n.text("Auflösung und Textgröße in Windows: System → Anzeige. Die verfügbaren Modi hängen vom Gasttreiber ab; „Ansicht“ vergrößert nur das Playerbild."))
                        .font(.system(size: 13)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                }
                if kind == "ubuntu" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], alignment: .leading, spacing: 8) {
                        Button(L10n.text("Anzeige neu verbinden")) { Task { await model.reconnectWindowsDisplay() } }
                        Button(L10n.text("Text einfügen …"), action: beginPaste)
                        Button(L10n.text("UEFI / BIOS · Esc"), action: model.openWindowsFirmwareMenu)
                    }.disabled(!active || model.windowsPasteBusy)
                    Text(L10n.text("Ubuntu: Auflösung und Skalierung unter Einstellungen → Anzeigegeräte ändern."))
                }
                if kind == "windows" {
                    Text(L10n.text("Esc beim Einschalten: UEFI / BIOS")).font(.system(size: 14, weight: .semibold))
                    HStack {
                        Button(L10n.text("Anzeige neu verbinden")) { Task { await model.reconnectWindowsDisplay() } }
                            .disabled(!active || !model.canReconnectWindowsDisplay)
                        Button(L10n.text("UEFI-Startmenü · Esc"), action: model.openWindowsFirmwareMenu)
                            .disabled(!active || model.playerSize == .zero || model.windowsPasteBusy)
                    }
                    Text(L10n.text("Bei Display output is not active ist die Verbindung möglicherweise bereits bereit, während die virtuelle Grafikkarte noch kein Bild liefert. Neu verbinden startet Windows nicht neu. Das UEFI-Menü lässt sich während des frühen Starts mit Esc öffnen."))
                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.text("Einrichtungskonsole öffnen"), action: model.openWindowsSetupConsole)
                            .disabled(!active || model.playerSize == .zero || model.windowsPasteBusy)
                            .help(L10n.text("Sendet Shift + F10 direkt an Windows, ohne eine Funktionstaste auf dem Mac zu drücken."))
                        Spacer(minLength: 0)
                    }
                    Text(L10n.text("Sendet Shift + F10. In Windows Setup öffnet das normalerweise eine Konsole."))
                        .font(.system(size: 13)).foregroundStyle(.primary)
                    HStack {
                        Button(L10n.text("Text einfügen …"), action: beginPaste)
                            .disabled(!active || model.playerSize == .zero || model.windowsPasteBusy)
                            .help("Text aus der Mac-Zwischenablage in Windows eingeben. Auch mit ⌘V im Windows-Bild.")
                        if model.windowsPasteBusy {
                            ProgressView().controlSize(.small)
                            Button(L10n.text("Abbrechen"), action: model.cancelWindowsPaste)
                        }
                        Spacer(minLength: 0)
                    }
                    if !model.windowsPasteStatus.isEmpty {
                        Text(model.windowsPasteStatus).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 12) {
                    if kind == "android" {
                        Button { model.androidNavigation(4) } label: { Image(systemName: "chevron.left") }
                            .help(L10n.text("Zurück")).disabled(!active)
                        Button { model.androidNavigation(3) } label: { Image(systemName: "house") }
                            .help("Startbildschirm").disabled(!active)
                        Button { model.androidNavigation(187) } label: { Image(systemName: "square.on.square") }
                            .help("Letzte Apps").disabled(!active)
                    }
                    Spacer(minLength: 0)
                    Button(L10n.text("Herunterfahren"), action: model.shutdownGuest).disabled(!active)
                }
              }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 225)
            }.modifier(WorkspaceChromeSurface())
                .padding(.horizontal, 10).padding(.top, 8)
            VStack(alignment: .leading, spacing: 7) {
                Label(active ? model.playerStatus : L10n.text("Apps, Dateien und Einstellungen bleiben gespeichert."),
                      systemImage: active ? "info.circle.fill" : "externaldrive.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if kind != "android" { Text(L10n.text("Esc beim Einschalten: UEFI / BIOS")).font(.system(size: 14, weight: .semibold)) }
                Text(L10n.text("Fenster schließen: Das Gastsystem läuft weiter."))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(WorkspaceChromeSurface(cornerRadius: 14, selected: true))
            .padding(10)
        }
        .frame(minWidth: 360, minHeight: 480)
        .controlSize(.small)
        .modifier(WorkspaceActionStyle())
        .modifier(WorkspaceWindowTheme())
        .onAppear { zoomPercent = safeZoom }
        .sheet(isPresented: $pastePresented, onDismiss: { pasteDraft = "" }) {
            if kind == "android" { AndroidPasteSheet(model: model, text: $pasteDraft) }
            else { WindowsPasteSheet(model: model, text: $pasteDraft) }
        }
        .sheet(isPresented: $androidDisplayPresented) { AndroidDisplaySheet(model: model) }
        .sheet(isPresented: $exchangePresented) {
            VStack(alignment: .trailing) {
                Button(L10n.text("Fertig")) { exchangePresented = false }
                ScrollView { ExchangeFolderView(model: model, controller: model.exchange) }
            }.padding(18).frame(width: 700, height: 720).modifier(WorkspaceDialogTheme())
        }
    }

    private var systemTitle: some View {
        HStack(spacing: 9) {
            GuestSystemSymbol(kind: kind).frame(width: 22, height: 22)
            Text(kind == "android" ? "Android" : kind == "ubuntu" ? "Ubuntu ARM" : "Windows Arm")
                .font(.headline)
        }
    }

    private var playerHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                systemTitle
                Spacer(minLength: 8)
                streamStatus
                windowActions
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack { systemTitle; Spacer(minLength: 8); windowActions }
                streamStatus
            }
        }
    }

    @ViewBuilder private var streamStatus: some View {
        if active && kind == "android" {
            Text("\(Int(model.playerSize.width)) × \(Int(model.playerSize.height)) px · Stream \(Int(model.streamFPS.rounded())) · Decoder \(Int(model.decoderFPS.rounded())) FPS")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary).fixedSize()
                .help(L10n.text("Empfangene Bilder / Decoder-Zuführung. Keine Messung der Spiel-FPS."))
        }
    }

    private var windowActions: some View {
        HStack(spacing: 8) {
            Button { exchangePresented = true } label: {
                Label(L10n.text("Dateiaustausch"), systemImage: "folder")
            }.disabled(!model.storageReady)
            Button { model.togglePlayerFullScreen(kind: kind) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }.help(L10n.text("Player als Vollbild anzeigen"))
                .accessibilityLabel(L10n.text("Player als Vollbild anzeigen"))
        }.fixedSize()
    }

    @ViewBuilder private var displaySettingsButton: some View {
        if kind == "android" {
            Button(L10n.text("Android-Auflösung …")) { androidDisplayPresented = true }
        } else if kind == "windows" {
            Button(L10n.text("Windows-Einstellungen …"), action: model.openWindowsDisplaySettings)
                .disabled(!active || model.playerSize == .zero || model.windowsPasteBusy)
                .help(L10n.text("Windows + I; danach System → Anzeige für die vom Gast unterstützten Auflösungen und Skalierungen."))
        }
    }
}
