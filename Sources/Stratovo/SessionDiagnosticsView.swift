import SwiftUI
import StratovoCore

@MainActor
struct SessionDiagnosticsView: View {
    @ObservedObject var model: AppModel
    @State private var showStopConfirmation = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.text("Diagnose"), systemImage: "waveform.path.ecg").font(.title2.bold())
                    Spacer()
                    Button(L10n.text("Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Divider()
                HStack {
                    Circle().fill(model.running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(model.sessionName).font(.headline)
                    Spacer()
                    if model.running {
                        Button(L10n.text("Herunterfahren"), action: model.shutdownGuest)
                        Button(L10n.text("Prozess beenden"), role: .destructive) { showStopConfirmation = true }
                    }
                    Button(L10n.text("Sitzungslog zeigen"), action: model.revealLogs).disabled(model.lastCommand.isEmpty)
                }
                HStack {
                    Button {
                        Task { await model.exportDiagnostics() }
                    } label: { Label(L10n.text("Gesamtprotokoll exportieren"), systemImage: "doc.badge.arrow.up") }
                        .disabled(model.diagnosticBusy || !model.storageReady)
                    if model.diagnosticBusy { ProgressView().controlSize(.small) }
                    Text(L10n.text("Windows + Android + Ubuntu + Einrichtung in einer Datei")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L10n.text("Android-Diagnose kopieren")) {
                        Task { await model.copyAndroidDiagnostics() }
                    }.disabled(model.diagnosticBusy)
                    Button(L10n.text("Speicherbelegung messen")) {
                        Task { await model.measureGuestStorage() }
                    }.disabled(!model.storageReady || model.guestStorageUsageBusy)
                }
                if !model.guestStorageUsage.isEmpty {
                    Text(model.guestStorageUsage).font(.caption).textSelection(.enabled)
                }
                if !model.diagnosticStatus.isEmpty { Text(model.diagnosticStatus).font(.caption).textSelection(.enabled) }
                ScrollView([.horizontal, .vertical]) {
                    Text(model.log).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, idealHeight: 320)
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 780, minHeight: 420, idealHeight: 520)
        .modifier(WorkspaceDialogTheme())
        .confirmationDialog(L10n.text("Gastprozess beenden?"), isPresented: $showStopConfirmation) {
            Button(L10n.text("Prozess beenden"), role: .destructive) { model.terminateGuest() }
            Button(L10n.text("Abbrechen"), role: .cancel) { }
        } message: {
            Text(L10n.text("Fahre das Gastsystem möglichst zuerst im Gastfenster herunter. Das Beenden des Prozesses kann nicht gespeicherte Änderungen verlieren oder das Gastdateisystem beschädigen."))
        }
    }

}
