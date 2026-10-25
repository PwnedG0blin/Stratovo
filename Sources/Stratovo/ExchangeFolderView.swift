import SwiftUI
import StratovoCore

@MainActor
struct ExchangeFolderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: ExchangeController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkspaceCard {
                Label(L10n.text("Dateiaustausch"), systemImage: "folder.badge.person.crop").font(.headline)
                Text(model.storage?.url.appendingPathComponent("Austausch").path ?? L10n.text("Zuerst einen Datenordner wählen"))
                    .font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Button(L10n.text("Austausch im Finder öffnen")) { controller.openFinder(model: model) }
                        .buttonStyle(.borderedProminent).disabled(!model.storageReady)
                }
                Text(L10n.text("Windows und Ubuntu: Dateien über die geschützte SSH-Verbindung senden und empfangen. Keine macOS-Dateifreigabe nötig."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            GuestFileExchangeView(model: model, controller: controller.windowsSSH)
            GuestFileExchangeView(model: model, controller: controller.ubuntuSSH)
            WorkspaceCard {
                Label(L10n.text("Android"), systemImage: "apps.iphone").font(.headline)
                HStack {
                    Button(L10n.text("Datei zu Android senden")) { controller.sendAndroid(model: model) }
                        .disabled(controller.transferring || !model.canInstallAPK)
                    Button(L10n.text("Android-Dateien abholen")) { controller.receiveAndroid(model: model) }
                        .disabled(controller.transferring || !model.canInstallAPK)
                }
                ContextHelpButton("Anleitung für Android") { androidSteps }
            }
            if controller.transferring { ProgressView().controlSize(.small) }
            if !controller.status.isEmpty { Text(controller.status).font(.callout).textSelection(.enabled) }
        }
    }
    private var androidSteps: some View {
        GroupBox(L10n.text("Android · Dateien senden und abholen")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Vom Mac zu Android")).font(.headline)
                step(1, "Android in Stratovo starten und warten, bis der Start abgeschlossen ist. Für diese Übertragung ist keine SMB-Freigabe erforderlich.")
                step(2, "Datei zu Android senden anklicken und eine Datei auf dem Mac auswählen.")
                Button(L10n.text("Datei zu Android senden")) { controller.sendAndroid(model: model) }
                    .disabled(controller.transferring || !model.canInstallAPK)
                step(3, "In Android die Dateien-App öffnen: Downloads → Stratovo-Austausch. Jede gesendete Datei liegt in einem neuen Unterordner.")
                Divider()
                Text(L10n.text("Von Android zum Mac")).font(.headline)
                step(1, "In Android die gewünschten Dateien nach Downloads → Stratovo-Austausch kopieren oder verschieben.")
                step(2, "In Stratovo Android-Dateien abholen anklicken. Der gesamte Inhalt dieses Android-Ordners wird zum Mac kopiert.")
                Button(L10n.text("Android-Dateien abholen")) { controller.receiveAndroid(model: model) }
                    .disabled(controller.transferring || !model.canInstallAPK)
                step(3, "Der Finder öffnet einen neuen Importordner unter Austausch → Android. Frühere Importe und Dateien bleiben erhalten.")
                Text(L10n.text("Android-Übertragungen erstellen Kopien. Es gibt keinen automatischen Abgleich und keine automatische Löschung. Für direkten SMB-Zugriff kann zusätzlich ein Android-Dateimanager mit SMB-Unterstützung verwendet werden."))
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number)).font(.headline).frame(width: 28, height: 28)
                .background(Color.teal.opacity(0.16), in: Circle())
            Text(L10n.text(text)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

