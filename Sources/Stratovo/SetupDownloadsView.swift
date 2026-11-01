import SwiftUI
import StratovoCore

@MainActor
struct SetupDownloadsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var installer: SetupInstaller
    @State private var selection: Set<SetupComponent> = []
    @State private var sdkConsent = false
    @State private var microsoftLink = ""
    @State private var showUpdates = false

    var body: some View {
        WorkspaceCard {
            HStack {
                Label(L10n.text("Downloads und Einrichtung"), systemImage: "arrow.down.circle.fill").font(.headline)
                Spacer()
                ContextHelpButton("Hilfe") {
                    Text(L10n.text("Downloads, Entpackdateien und Gastsysteme bleiben auf diesem Datenträger. Vorhandene Komponenten werden wiederverwendet. Ohne den Datenträger startet kein Ersatzdownload intern."))
                }
            }
            HStack(spacing: 8) {
                Button(L10n.text("Komponenten")) { showUpdates = false }
                    .tint(!showUpdates ? MidnightPalette.turquoise : Color.secondary)
                Button(L10n.text("Android-Updates")) { showUpdates = true }
                    .tint(showUpdates ? MidnightPalette.turquoise : Color.secondary)
            }.buttonStyle(.bordered)
            if showUpdates { androidUpdates } else { components }
            activity
        }
    }

    private var components: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SetupComponent.allCases) { component in
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { selection.contains(component) }, set: { enabled in
                        if enabled { selection.insert(component) } else { selection.remove(component) }
                    })) { Text(component.title).font(.callout) }
                        .disabled(model.busy || model.running || !model.storageReady)
                        .help(detail(component))
                    Spacer(minLength: 8)
                    if model.setupReady.contains(component) {
                        Label(L10n.text("Vorhanden"), systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.teal)
                    }
                }
            }
            if (selection.contains(.android) && !model.setupReady.contains(.android) || selection.contains(.android17) && !model.setupReady.contains(.android17)) {
                Link("Google SDK-Lizenz lesen ↗", destination: URL(string: "https://developer.android.com/studio#terms-and-conditions")!)
                Toggle(L10n.text("Ich habe die Google SDK-Lizenz gelesen und akzeptiere sie für den Download der Werkzeuge."), isOn: $sdkConsent)
                    .disabled(model.busy)
                Text(L10n.text("Weitere SDK-Lizenzen werden während der Einrichtung hier angezeigt und einzeln von dir bestätigt."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if selection.contains(.windowsISO) && !model.setupReady.contains(.windowsISO) && model.settings.iso.isEmpty {
                Link(L10n.text("Offizielle Microsoft-Seite · ARM64 wählen ↗"), destination: URL(string: "https://www.microsoft.com/de-de/software-download/windows11arm64")!)
                TextField(L10n.text("Direkten Microsoft-Downloadlink der ARM64-ISO einfügen"), text: $microsoftLink)
                    .textFieldStyle(.roundedBorder).disabled(model.busy)
                ContextHelpButton("Details und Anleitung") {
                    Text(L10n.text("Auf der Microsoft-Seite die Sprache wählen und den erzeugten Downloadlink kopieren. Stratovo lädt ihn direkt auf den eingestellten Datenträger. Alternativ eine vorhandene ISO im Windows-Bereich auswählen."))
                        .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                Task { await model.installComponents(selection, microsoftLink: microsoftLink) }
            } label: {
                Label(installer.running ? L10n.text("Einrichtung läuft …") : L10n.text("Auswahl laden und einrichten"), systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.running || model.busy || !model.storageReady || selection.isEmpty ||
                      ((selection.contains(.android) && !model.setupReady.contains(.android) || selection.contains(.android17) && !model.setupReady.contains(.android17)) && !sdkConsent))
            Text(model.storage?.root ?? L10n.text("Zuerst einen Datenordner wählen"))
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(model.storage?.root ?? "")
        }
    }

    private var androidUpdates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L10n.text("Android-SDK-Kanal"), selection: $model.androidSDKChannel) {
                Text(L10n.text("Stable · empfohlen")).tag(0)
                Text(L10n.text("Beta einschließen")).tag(1)
                Text(L10n.text("Dev einschließen")).tag(2)
                Text(L10n.text("Canary · alle Vorschaukanäle")).tag(3)
            }.disabled(!model.canManageAndroid)
            Toggle(L10n.text("Beim Öffnen täglich nach SDK-Updates suchen"), isOn: $model.androidCheckUpdatesOnOpen)
                .disabled(!model.canManageAndroid)
            Toggle(L10n.text("Gewähltes Systemabbild vor jedem Android-Start aktualisieren"), isOn: $model.androidAutoUpdateBeforeStart)
                .disabled(!model.canManageAndroid)
            HStack {
                Button(L10n.text("Android-Updates prüfen")) { Task { await model.manageAndroidUpdates(install: false) } }
                Button(L10n.text("Gewähltes Android-Abbild aktualisieren")) { Task { await model.manageAndroidUpdates(install: true) } }
            }.disabled(!model.canManageAndroid || model.selectedAndroidSystem == nil)
            ContextHelpButton("Android-Updates") {
                Text(L10n.text("Updates werden bei ausgeschaltetem Android auf den gewählten Datenträger geladen. Die Prüfung allein installiert nichts. Ein Abbildupdate ist kein garantierter Versionssprung; Android 16 und 17 bleiben getrennte Profile."))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            if installer.running { ProgressView().controlSize(.small) }
            if installer.running || !installer.output.isEmpty {
                Text(installer.status).font(.callout.weight(.medium)).textSelection(.enabled)
            }
            if !installer.output.isEmpty {
                if installer.licensePrompt {
                    installationLog
                } else {
                    DisclosureGroup(L10n.text("Einrichtungsprotokoll")) { installationLog }
                }
            }
            if installer.licensePrompt {
                Text(L10n.text("Die Android-Werkzeuge warten auf deine Antwort zur oben angezeigten Lizenz.")).font(.headline)
                HStack {
                    Button(L10n.text("Angezeigte Lizenz akzeptieren")) { installer.answerLicense(accept: true) }.buttonStyle(.borderedProminent)
                    Button(L10n.text("Ablehnen")) { installer.answerLicense(accept: false) }
                }
            }
        }
    }

    private var installationLog: some View {
                ScrollView {
                    Text(installer.output).font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 240)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detail(_ item: SetupComponent) -> String {
        switch item {
        case .android: return "Android 16 · ARM64 · Google Play · neues Profil mit 64 GB; vorhandenes Android 16 wird wiederverwendet"
        case .android17: return "Android 17 · ARM64 · Google Play · optionales eigenes Profil mit 64 GB"
        case .streaming: return "scrcpy 4.0 · Genymobile · mit SHA-256-Prüfung"
        case .windowsDrivers: return "UTM Guest Tools · ISO mit ARM64-Treibern"
        case .windowsISO: return model.settings.iso.isEmpty ? "Direktdownload von Microsoft oder eigene ISO auswählen" : "Vorhandene ISO wird auf den gewählten Datenträger übernommen"
        }
    }
}
