import SwiftUI
import StratovoCore

@MainActor
struct GuestPlayerSummary: View {
    @ObservedObject var model: AppModel
    let kind: String
    let title: String
    var body: some View {
        let active = model.activeGuest == kind
        let hidden = active && model.running && model.guestPlayerIsHidden(kind: kind)
        return WorkspaceCard {
            HStack(spacing: 16) {
                Image(systemName: kind == "android" ? "apps.iphone" : "desktopcomputer")
                    .font(.title).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(hidden ? L10n.text("Läuft im Hintergrund") : active ? model.playerStatus : L10n.text("Eigenes Fenster · frei skalierbar · Vollbild möglich"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if active && model.androidUsesDirectDisplay && kind == "android" {
                        Text(L10n.text("Kein Videostream · Spiel-FPS hier nicht gemessen"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if active && kind == "android" && !model.androidUsesDirectDisplay {
                        Text(L10n.message("Stream: \(Int(model.streamFPS.rounded())) FPS · Decoder-Zuführung: \(Int(model.decoderFPS.rounded())) FPS · Aktives Limit \(model.appliedAndroidTargetFPS ?? model.androidTargetFPS)"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text("\(Int(model.playerSize.width)) × \(Int(model.playerSize.height)) px")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(L10n.text("Empfangene und an den Decoder übergebene Bilder; keine Messung der Spiel-FPS."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if kind == "android" && !model.running {
                    Button(L10n.text("Android starten"), action: model.startAndroid)
                        .buttonStyle(.borderedProminent).disabled(!model.canStartAndroid)
                } else {
                    Button(hidden ? L10n.text("Fenster wieder öffnen") : model.guestWindowButtonTitle(kind: kind)) { model.showPlayer(kind: kind) }
                        .disabled(!active || !model.running)
                }
            }
        }
    }

}
