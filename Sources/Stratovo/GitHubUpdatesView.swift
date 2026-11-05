import SwiftUI
import StratovoCore

@MainActor
struct GitHubUpdatesView: View {
    @ObservedObject var model: AppModel
    var compact = false
    @StateObject private var installer = AppUpdateInstaller()
    @State private var confirmInstall = false
    @State private var showSettings = false
    @ObservedObject var checker: GitHubUpdateChecker
    @ObservedObject var privateUpdates: PrivateUpdateController
    @AppStorage("Pixelkoje.GitHubUpdates.automatic") private var automaticChecks = true
    @AppStorage("Pixelkoje.GitHubUpdates.prereleases") private var includePrereleases = true

    init(model: AppModel, compact: Bool = false, checker: GitHubUpdateChecker? = nil,
         privateUpdates: PrivateUpdateController? = nil) {
        self.model = model
        self.compact = compact
        self.checker = checker ?? GitHubUpdateChecker()
        self.privateUpdates = privateUpdates ?? PrivateUpdateController()
    }

    private var privateBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "StratovoBuildFlavor") as? String == "private"
    }

    var body: some View {
        if privateBuild {
            PrivateBetaUpdatesView(model: model, updates: privateUpdates)
        } else {
            publicUpdates
        }
    }

    private var publicUpdates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("Stratovo-Updates über GitHub"), systemImage: "arrow.triangle.2.circlepath")
                .font(.title2.bold())

            Text(L10n.text("Updates über GitHub"))
                .foregroundStyle(.secondary)

            HStack {
                Text(L10n.message("Installiert: \(checker.installedVersion)"))
                Spacer()
                Button {
                    Task { await checker.check(includePrereleases: includePrereleases) }
                } label: {
                    Label(L10n.text("Auf Updates prüfen"), systemImage: "arrow.clockwise")
                }
                .disabled(checker.isChecking || installer.busy)
                if checker.isChecking { ProgressView().controlSize(.small) }
            }
            DisclosureGroup(L10n.text("Update-Einstellungen und Hinweise"), isExpanded: $showSettings) {
            Toggle(L10n.text("Beim Start und stündlich automatisch prüfen"), isOn: $automaticChecks)
                .onChange(of: automaticChecks) { _, enabled in
                    if enabled { Task { await checker.checkIfDue(includePrereleases: includePrereleases) } }
                }
            Toggle(L10n.text("Vorabversionen berücksichtigen"), isOn: $includePrereleases)

            }
            switch checker.state {
            case .idle:
                Text(L10n.text("Noch keine Versionsprüfung in dieser Sitzung durchgeführt."))
                    .foregroundStyle(.secondary)
            case .noReleases:
                Label(L10n.text("Noch keine GitHub Releases veröffentlicht. Test-Builds stehen gegebenenfalls über GitHub Actions bereit."), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            case .upToDate(let latest):
                Label(latest.map { L10n.message("Keine neuere Veröffentlichung gefunden (neueste: \($0)).") }
                      ?? L10n.text("Keine passende Veröffentlichung gefunden."), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .available(let release):
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.message("Neue Version gefunden: \(release.name.flatMap { $0.isEmpty ? nil : $0 } ?? release.tagName)"), systemImage: "arrow.down.circle")
                        .font(.headline)
                    if let notes = release.body, !notes.isEmpty {
                        Text(notes).lineLimit(6).textSelection(.enabled)
                            .font(.subheadline)
                    }
                    Button(L10n.text("Update laden und installieren …")) { confirmInstall = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(installer.busy || model.busy || model.running || model.graphicsLab.active || !(release.assets?.contains(where: { $0.isTrusted(for: release) }) ?? false))
                        .confirmationDialog(L10n.text("Stratovo aktualisieren und neu starten?"), isPresented: $confirmInstall) {
                            Button(L10n.text("Update installieren")) { Task { await installer.install(release, model: model) } }
                            Button(L10n.text("Abbrechen"), role: .cancel) { }
                        } message: { Text(L10n.text("Die App wird nach Prüfsummen- und Versionsprüfung ersetzt. Deine VMs bleiben im gewählten Datenordner. Eine Kopie der bisherigen App bleibt für die Rückkehr neben der App erhalten.")) }
                    Link(L10n.text("Veröffentlichung und Downloads öffnen ↗"), destination: release.htmlURL)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if !installer.status.isEmpty { Text(installer.status).textSelection(.enabled) }
            if installer.busy { ProgressView() }
            if let checked = checker.lastChecked {
                Text(L10n.message("Zuletzt geprüft: \(checked.formatted(date: .abbreviated, time: .shortened))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Link("Releases ↗", destination: StratovoReleaseCatalog.releasesURL)
                Link("Aktuelle Test-Builds ↗", destination: StratovoReleaseCatalog.buildsURL)
            }
            .font(.subheadline)
            if !compact { Text(L10n.text("Ein Klick prüft die Version. Installiert wird erst nach deiner Auswahl und Bestätigung, wenn alle Gäste beendet sind. Downloads und Prüfung liegen im gewählten Datenordner. Öffentliche GitHub Releases benötigen keinen API-Schlüssel; Actions-Artefakte sind keine Releases."))
                .font(.caption).foregroundStyle(.secondary) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .task {
            if automaticChecks { await checker.checkIfDue(includePrereleases: includePrereleases) }
        }
    }
}
