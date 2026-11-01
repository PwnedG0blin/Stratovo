import SwiftUI
import StratovoCore

@MainActor
struct SetupWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var section: String
    init(model: AppModel, initialSection: String = "general") {
        self.model = model
        _section = State(initialValue: initialSection)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                ForEach(["general", "storage", "downloads", "advanced"], id: \.self) { key in
                    Button { section = key } label: {
                        Text(L10n.text(["general": "Allgemein", "storage": "Speicher",
                                        "downloads": "Downloads", "advanced": "Erweitert"][key] ?? key))
                            .font(.callout.weight(section == key ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(section == key ? MidnightPalette.turquoise : Color.secondary)
                    .accessibilityAddTraits(section == key ? [.isSelected] : [])
                }
            }
            switch section {
            case "storage": storageCard
            case "downloads": SetupDownloadsView(model: model, installer: model.installer)
            case "advanced": enginesCard
            default:
                LanguageSettingsView(model: model)
                WorkspaceAppearanceSettings()
                hostCard
                ContextHelpButton("Datenschutz") {
                    Text(L10n.text("Stratovo enthält keine Telemetrie. Android, QEMU und das Gastbetriebssystem haben eigene Netzwerk- und Datenschutzeinstellungen. Protokolle und Einstellungen liegen lokal auf diesem Mac."))
                }
            }
        }
    }
    private var enginesCard: some View {
        WorkspaceCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.text("Lokale Engines")).font(.title2.bold())
                    Text(L10n.text("Vorhandene Engines und eigene Firmware auswählen. Downloads und Lizenzen werden im Bereich Downloads verwaltet."))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Android SDK").font(.subheadline.bold())
                        Text(model.sdk ?? model.storage?.sdk.path ?? L10n.text("Zuerst Speicherort wählen")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Text(model.sdk == nil ? L10n.text("Die Download-Auswahl richtet Android-Werkzeuge und Emulator im gewählten Datenordner ein.") : L10n.text("SDK gefunden")).font(.caption).foregroundStyle(.secondary)
                    }
                    WorkspaceFileRow(title: "qemu-system-aarch64", value: model.qemu ?? L10n.text("Nicht gefunden")) {
                        if let path = model.chooseFile(title: L10n.text("qemu-system-aarch64 auswählen")) { model.settings.qemu = path; Task { await model.refresh() } }
                    }
                    WorkspaceFileRow(title: "ARM64-UEFI-Firmware", value: model.firmware ?? L10n.text("Nicht gefunden")) {
                        if let path = model.chooseFile(title: L10n.text("edk2-aarch64-code.fd auswählen")) { model.settings.firmware = path; Task { await model.refresh() } }
                    }
                    WorkspaceFileRow(title: "swtpm · virtuelles TPM 2.0", value: model.swtpm ?? L10n.text("Nicht gefunden")) {
                        if let path = model.chooseFile(title: L10n.text("swtpm auswählen")) { model.settings.swtpm = path; Task { await model.refresh() } }
                    }
                    Button(L10n.text("Standardpfade verwenden")) {
                        model.settings.qemu = ""; model.settings.firmware = ""; model.settings.swtpm = ""
                        Task { await model.refresh() }
                    }
                }
            }.disabled(model.running || model.busy)
    }
    private var hostCard: some View {
        WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("Dein Mac")).font(.headline)
                    LabeledContent(L10n.text("Arbeitsspeicher"), value: "\(model.totalMemoryGB) GB")
                    LabeledContent(L10n.text("CPU-Kerne"), value: "\(model.hostCores)")
                    LabeledContent("Hypervisor", value: model.hypervisorAvailable ? L10n.text("Verfügbar") : L10n.text("Nicht verfügbar"))
                    Text(L10n.text("Für einen Mac mit 16 GB empfehlen wir zunächst 4 GB und 4 Kerne. In dieser Version läuft jeweils ein Gastprozess."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
    }
    private var storageCard: some View {
        WorkspaceCard {
            VStack(alignment: .leading, spacing: 14) {
                Label(L10n.text("Daten und Speicherplatz"), systemImage: "externaldrive.fill").font(.title2.bold())
                Text(model.storage?.root ?? L10n.text("Noch kein Speicherort gewählt")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Text(model.storageFree).foregroundStyle(model.storageReady ? Color.teal : Color.orange)
                ContextHelpButton("Daten und Speicherplatz") {
                    Text(L10n.text("SDK, Android-Geräte, Windows-Festplatte, TPM, Streaming und neue Protokolle verwenden diesen Ordner. Die App und Homebrew-Werkzeuge können intern bleiben.")).font(.body).foregroundStyle(.secondary)
                }
                Text(model.storageStatus).font(.caption).textSelection(.enabled)
                HStack {
                    if model.storage == nil { Button(L10n.text("Speicherort wählen …")) { model.showStorageSetup = true } }
                    Button(L10n.text("Datenordner öffnen"), action: model.revealStorage).disabled(!model.storageReady)
                }
                if !model.backupPaths.isEmpty {
                    Divider()
                    Text(L10n.text("Diese internen Kopien können nach dem Test entfernt werden:")).font(.subheadline.bold())
                    ForEach(model.backupPaths, id: \.self) { path in
                        Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                    Toggle(L10n.text("Android/Windows mit dem neuen Speicherort geprüft; interne Sicherungen dürfen entfernt werden"), isOn: $model.storageTested)
                        .font(.caption)
                    Button(L10n.text("Geprüfte interne Kopien endgültig entfernen …"), role: .destructive, action: model.confirmStorageCleanup)
                        .disabled(!model.storageTested || !model.storageReady)
                    ContextHelpButton("Details und Anleitung") {
                        Text(L10n.text("Entfernt ausschließlich die oben gelisteten Sicherungen. Aktive Daten auf der SSD, andere Downloads, Xcode und Homebrew werden nicht gelöscht.")).font(.body).foregroundStyle(.secondary)
                    }
                }
            }
        }.disabled(model.running || model.busy)
    }
}

