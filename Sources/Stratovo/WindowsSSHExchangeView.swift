import SwiftUI
import StratovoCore

@MainActor
struct GuestFileExchangeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: GuestFileExchangeController
    @State private var selection = Set<String>()
    private var available: Bool {
        model.running && model.activeGuest == controller.kind.rawValue &&
        (controller.kind != .windows || model.settings.windowsNetwork)
    }
    var body: some View {
        WorkspaceCard {
            Label(controller.kind.title, systemImage: "desktopcomputer").font(.headline)
            if !controller.connected {
                Text(L10n.text("Stratovo erkennt dein Konto und richtet die Verbindung automatisch ein. Eine Administratorabfrage bitte im Systemfenster bestätigen."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Dateiaustausch starten")) { selection = []; controller.start(model: model) }
                    .buttonStyle(.borderedProminent).disabled(!available || controller.busy || model.windowsPasteBusy)
            }
            if !available { Text(L10n.message("\(controller.kind.title) zuerst vollständig starten.")).font(.callout) }
            if controller.connected {
                HStack {
                    Button(L10n.text("Eine Ebene höher"), systemImage: "arrow.up") { selection = []; controller.parent() }
                        .disabled(controller.busy || controller.path == controller.kind.rootPath)
                    Text(controller.path == "." ? L10n.text("Benutzerordner") : controller.path)
                        .font(.callout.monospaced()).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(L10n.text("Aktualisieren"), systemImage: "arrow.clockwise") { selection = []; controller.open(controller.path) }
                        .disabled(controller.busy)
                }
                List(selection: $selection) {
                    ForEach(controller.files) { file in
                        HStack {
                            if file.directory {
                                Button { selection = []; controller.open(file) } label: { Label(file.name, systemImage: "folder") }.buttonStyle(.plain)
                            } else { Label(file.name, systemImage: "doc") }
                            Spacer()
                            if !file.directory { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)).foregroundStyle(.secondary) }
                        }.tag(file.id)
                    }
                }.frame(height: 280).scrollContentBackground(.hidden).disabled(controller.busy || !available)
                HStack {
                    Button(L10n.text("Dateien senden")) { controller.send(model: model) }.buttonStyle(.borderedProminent)
                    Button(L10n.text("Ausgewählte Dateien empfangen")) { controller.receive(selection, model: model) }
                        .disabled(!controller.files.contains { !$0.directory && selection.contains($0.id) })
                }.disabled(controller.busy || !available)
                Text(L10n.text("Gesendete Dateien erscheinen in einem neuen Unterordner. Nach dem Empfangen öffnet sich der Speicherort auf deinem Mac."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if controller.busy {
                HStack {
                    if let progress = controller.progress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
                    Button(L10n.text("Abbrechen")) { controller.cancel() }
                }
            }
            if !controller.status.isEmpty { Text(controller.status).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if controller.connected { Button(L10n.text("Trennen")) { controller.cancel(disconnect: true) }.disabled(controller.busy) }
                if controller.connected {
                    Button(L10n.text("Verbindung erneut einrichten")) { selection = []; controller.start(model: model, repair: true) }
                        .disabled(!available || controller.busy || model.windowsPasteBusy)
                }
            }.font(.caption)

        }
        .onAppear { controller.attach(storage: model.storage) }
        .onChange(of: model.storage?.id) { _, _ in selection = []; controller.attach(storage: model.storage) }
        .onChange(of: model.running) { _, running in if !running { controller.cancel(disconnect: true); selection = [] } }
    }
}

typealias WindowsSSHExchangeView = GuestFileExchangeView
