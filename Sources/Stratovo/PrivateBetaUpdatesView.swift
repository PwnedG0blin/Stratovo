import SwiftUI
import StratovoCore

@MainActor
struct PrivateBetaUpdatesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: PrivateUpdateController
    @StateObject private var installer = AppUpdateInstaller()
    @AppStorage("Stratovo.privateUpdates.automatic") private var automatic = true
    @State private var connecting = false
    @State private var confirming = false
    @State private var credential = ""
    private let downloads = URL(string: "https://github.com/PwnedG0blin/Stratovo-Private/actions/workflows/private-macos.yml")!

    var body: some View {
        WorkspaceCard {
            Label(L10n.text("Private Beta aktualisieren"), systemImage: "lock.shield").font(.title2.bold())
            Text(AppPresentation.releaseLabel).font(.callout).foregroundStyle(.secondary)
            Text(updates.status).font(.callout).textSelection(.enabled)
            HStack {
                if updates.connected {
                    Button(L10n.text("Auf Updates prüfen")) { Task { await updates.check() } }
                    Button(L10n.text("GitHub trennen")) { updates.disconnect() }.buttonStyle(.borderless)
                } else {
                    if updates.needsUnlock {
                        Button(L10n.text(CredentialVault.touchIDAvailable ? "Mit Touch ID freigeben" : "Gespeicherten Zugang freigeben")) { Task { await updates.unlockSavedCredential() } }
                    }
                    Button(L10n.text("GitHub verbinden …")) { connecting = true }
                }
                if updates.busy || installer.busy { ProgressView().controlSize(.small) }
            }.disabled(updates.busy || installer.busy)
            if updates.available != nil {
                Button(L10n.text("Update laden und installieren …")) { confirming = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(updates.busy || installer.busy || model.busy || model.running || model.graphicsLab.active || !model.storageReady)
                if model.running || model.busy {
                    Text(L10n.text("Bitte zuerst alle Gäste und den Grafikbau beenden.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !installer.status.isEmpty { Text(installer.status).font(.callout).textSelection(.enabled) }
            if updates.connected {
                Toggle(L10n.text("Beim Start und stündlich automatisch prüfen"), isOn: $automatic)
                    .onChange(of: automatic) { _, enabled in
                        if enabled { Task { await updates.checkIfDue() } }
                    }
            }
            HStack {
                ContextHelpButton("Private Updates einrichten") { connectionHelp }
                Spacer()
                Link(L10n.text("DMG manuell laden ↗"), destination: downloads).font(.caption)
            }
        }
        .task { updates.restore(); if automatic { await updates.checkIfDue() } }
        .sheet(isPresented: $connecting, onDismiss: { credential = "" }) {
            VStack(alignment: .leading, spacing: 18) {
                Label(L10n.text("Privates GitHub verbinden"), systemImage: "lock.shield").font(.title2.bold())
                connectionHelp
                SecureField(L10n.text("GitHub-Zugangstoken"), text: $credential).textFieldStyle(.roundedBorder)
                    .disabled(updates.busy)
                Text(updates.status).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text("Abbrechen")) { credential = ""; connecting = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L10n.text("Verbinden und prüfen")) {
                        Task {
                            if await updates.connect(credential) { credential = ""; connecting = false }
                        }
                    }.buttonStyle(.borderedProminent).disabled(credential.isEmpty || updates.busy)
                }
            }.padding(24).frame(width: 570)
                .modifier(WorkspaceDialogTheme())
                .interactiveDismissDisabled(updates.busy)
        }
        .confirmationDialog(L10n.text("Stratovo aktualisieren und neu starten?"), isPresented: $confirming) {
            Button(L10n.text("Update installieren")) { Task { await updates.install(using: installer, model: model) } }
            Button(L10n.text("Abbrechen"), role: .cancel) { }
        } message: {
            Text(L10n.text("Die private App wird geladen, geprüft und ersetzt. Die bisherige App bleibt als Rückkehrkopie erhalten. Deine Systeme bleiben im bisherigen Datenordner."))
        }
    }

    private var connectionHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CredentialVault.availabilityMessage).foregroundStyle(.secondary)
            Text(L10n.text("Einmalig auf GitHub einen Fine-grained Personal Access Token erstellen: Resource owner PwnedG0blin, Only select repositories → Stratovo-Private, Repository permissions → Actions: Read-only. Keine Schreibrechte nötig."))
            Link(L10n.text("GitHub-Zugang erstellen ↗"), destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            Text(L10n.text("Den Token ausschließlich hier in Stratovo eingeben. Er wird im macOS-Schlüsselbund gespeichert. Danach private Updates direkt über diese Ansicht prüfen und installieren. Bei Ablauf erneut verbinden; mit GitHub trennen wird der gespeicherte Zugang entfernt."))
                .foregroundStyle(.secondary)
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}
