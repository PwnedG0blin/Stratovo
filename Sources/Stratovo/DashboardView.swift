import SwiftUI
import StratovoCore

/// A single launch action per system; existing launch guards remain authoritative.
@MainActor
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var graphicsLab: WindowsGraphicsLabController
    @ObservedObject private var ubuntu: UbuntuController
    var navigate: (WorkspaceTab) -> Void
    @AppStorage("Stratovo.ubuntu.memoryMiB") private var memory = 6144
    @AppStorage("Stratovo.ubuntu.cores") private var cores = 4

    init(model: AppModel, navigate: @escaping (WorkspaceTab) -> Void) {
        self.model = model
        self.graphicsLab = model.graphicsLab
        self.ubuntu = model.ubuntu
        self.navigate = navigate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 0) {
                system("Windows 11", kind: "windows", tab: .windows,
                       installed: graphicsLab.runtimeReady && model.windowsDiskBytes != nil,
                       canStart: model.canResumeWindows && graphicsLab.runtimeReady,
                       action: model.startExistingWindows)
                Divider().padding(.horizontal, 22)
                system("Android", kind: "android", tab: .android,
                       installed: model.androidReady && !model.devices.isEmpty, canStart: model.canStartAndroid,
                       action: model.startAndroid)
                Divider().padding(.horizontal, 22)
                system("Ubuntu", kind: "ubuntu", tab: .ubuntu,
                       installed: ubuntu.diskReady,
                       canStart: !model.running && !model.busy && model.storageReady && ubuntu.diskReady && !ubuntu.downloading) {
                    model.startUbuntu(installing: false, memory: memory, cores: cores)
                }
            }
            .background { WorkspaceCardSurface() }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                Image(systemName: "externaldrive").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(model.storageReady ? "Datenordner verbunden" : "Speicherort auswählen"))
                        .font(.callout)
                    if let storage = model.storage {
                        Text(storage.root).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(storage.root)
                    }
                }
                Spacer()
                Button(L10n.text("Speicher verwalten")) {
                    if model.storage == nil { model.showStorageSetup = true }
                    else { navigate(.setup) }
                }.disabled(model.busy || model.running)
            }.padding(.horizontal, 4)
        }
        .onAppear(perform: refreshAvailability)
        .onChange(of: model.storageReady) { _, _ in refreshAvailability() }
        .onChange(of: model.running) { _, _ in refreshAvailability() }
    }

    private func system(_ title: String, kind: String, tab: WorkspaceTab,
                        installed: Bool, canStart: Bool, action: @escaping () -> Void) -> some View {
        let active = model.running && model.activeGuest == kind
        return HStack(spacing: 18) {
            GuestSystemSymbol(kind: kind).frame(width: 44, height: 44)
                .padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.title3.weight(.semibold))
                HStack(spacing: 7) {
                    Circle().fill(active ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(L10n.text(active ? "Läuft" : installed ? "Bereit" : "Noch nicht eingerichtet"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button {
                if active { model.showPlayer(kind: kind) }
                else if canStart { action() }
                else { navigate(tab) }
            } label: {
                Label(L10n.text(active ? "Öffnen" : installed ? "Starten" : "Einrichten"),
                      systemImage: active ? "macwindow" : installed ? "play.fill" : "plus")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!active && (model.running || model.busy || (installed && !canStart)))
            Button { navigate(tab) } label: {
                Label(L10n.text("Einstellungen"), systemImage: "slider.horizontal.3")
            }.buttonStyle(.bordered)
                .accessibilityLabel(L10n.text("Einstellungen") + " · " + title)
                .help(L10n.text("Einstellungen") + " · " + title)
        }.padding(22).accessibilityElement(children: .contain)
    }

    private func refreshAvailability() {
        graphicsLab.refresh(model: model)
        ubuntu.refresh(model: model)
    }
}
