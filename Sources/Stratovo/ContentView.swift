import SwiftUI
import StratovoCore

@MainActor
struct ContentView: View {
    @ObservedObject var model: AppModel
    var releaseLabel = AppPresentation.releaseLabel
    @State private var selection: WorkspaceTab = .dashboard
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var settingsSection = "general"
    @AppStorage(WorkspaceAppearance.preferenceKey) private var appearance = WorkspaceAppearance.automatic

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
                .modifier(WorkspaceChromeSurface(cornerRadius: 0))
                .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.13)).frame(width: 1) }
            VStack(spacing: 0) {
                header.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !model.supportedHost || !model.hypervisorAvailable {
                            WorkspaceNotice(L10n.text("Apple Silicon und Hardwarevirtualisierung benötigt"),
                                L10n.text("Starte die native ARM64-Version auf einem Mac mit M-Chip. Intel-Macs und Rosetta werden nicht unterstützt."))
                        }
                        if !model.storageReady && model.storage != nil {
                            WorkspaceNotice(L10n.text("Datenordner nicht erreichbar"),
                                L10n.text("Bitte die gewählte SSD anschließen. Android, Windows und Downloads bleiben bis dahin gesperrt."))
                        }
                        workspace
                    }.padding(28).frame(maxWidth: 1180, alignment: .leading).frame(maxWidth: .infinity)
                }
                if model.running { sessionBar }
            }
        }
        .disclosureGroupStyle(WorkspaceButtonDisclosureStyle())
        .modifier(WorkspaceWindowTheme())
        .frame(minWidth: 860, minHeight: 650).tint(MidnightPalette.turquoise)
        .onChange(of: model.settings.iso) { _, _ in model.refreshWindowsISO() }
        .sheet(isPresented: $model.showStorageSetup) { StorageSetupSheet(model: model).interactiveDismissDisabled() }
        .sheet(isPresented: $showDiagnostics) { SessionDiagnosticsView(model: model) }
        .alert("Stratovo", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder private var workspace: some View {
        switch selection {
        case .dashboard: DashboardView(model: model) {
            if $0 == .setup { settingsSection = "storage" }
            selection = $0
        }
        case .updates: GitHubUpdatesView(model: model)
        case .android:
            VStack(alignment: .leading, spacing: 18) {
                AndroidWorkspaceView(model: model)
            }
        case .windows:
            VStack(alignment: .leading, spacing: 18) {
                WindowsWorkspaceView(model: model)
                GuestRemovalSection(model: model, kind: "windows")
            }
        case .ubuntu:
            VStack(alignment: .leading, spacing: 18) {
                UbuntuView(model: model, controller: model.ubuntu)
                GuestRemovalSection(model: model, kind: "ubuntu")
            }
        case .exchange: ExchangeFolderView(model: model, controller: model.exchange)
        case .setup: SetupWorkspaceView(model: model, initialSection: settingsSection).id(settingsSection)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                StratovoBrandMark().frame(width: 32, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stratovo").font(.system(size: 25, weight: .bold))
                    Text(releaseLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 28)
            ScrollView {
                VStack(spacing: 9) {
                    navigationButton(.dashboard)
                    Divider().padding(.vertical, 8)
                    ForEach([WorkspaceTab.windows, .android, .ubuntu]) { tab in
                        navigationButton(tab)
                    }
                    Divider().padding(.vertical, 8)
                    ForEach([WorkspaceTab.exchange, .updates, .setup]) { tab in
                        navigationButton(tab)
                    }
                }.padding(.horizontal, 12)
            }
            Divider().padding(.horizontal, 22).padding(.top, 12)
            Button { showAbout = true } label: {
                Label(L10n.text("Über Stratovo"), systemImage: "info.circle")
                    .font(.callout).padding(.vertical, 16)
            }.buttonStyle(.plain).padding(.horizontal, 22)
            .popover(isPresented: $showAbout) {
                DeveloperCredits().padding(24).frame(width: 300)
            }
        }
    }

    private func navigationButton(_ tab: WorkspaceTab) -> some View {
        Button {
            if tab == .setup { settingsSection = "general" }
            selection = tab
        } label: {
            HStack(spacing: 13) {
                if tab == .windows || tab == .android || tab == .ubuntu {
                    GuestSystemSymbol(kind: tab == .windows ? "windows" : tab == .android ? "android" : "ubuntu")
                        .frame(width: 23, height: 23)
                } else {
                    Image(systemName: tab.icon).font(.system(size: 20, weight: .medium)).frame(width: 23)
                }
                Text(tab == .dashboard ? L10n.text("Meine Systeme") : tab.title).font(.system(size: 15, weight: selection == tab ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 17).padding(.vertical, 14)
            .foregroundStyle(selection == tab && appearance != .classic ? Color.white : Color.primary.opacity(0.86))
            .background {
                if selection == tab { Color.clear.modifier(WorkspaceChromeSurface(cornerRadius: 11, selected: true)) }
            }
            .overlay(alignment: .leading) {
                if selection == tab { Capsule().fill(MidnightPalette.turquoise).frame(width: 4).padding(.vertical, 8) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).accessibilityAddTraits(selection == tab ? [.isSelected] : [])
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selection == .dashboard ? L10n.text("Meine Systeme") : selection.title)
                    .font(.system(size: 28, weight: .semibold))
                Text(L10n.text(selection == .dashboard ? "System auswählen und starten." : selection.subtitle))
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button(L10n.text("Aktualisieren")) { Task { await model.refresh() } }
                    .disabled(model.busy || model.running)
                Button(L10n.text("Diagnose")) { showDiagnostics = true }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize().accessibilityLabel(L10n.text("Weitere Aktionen"))
        }
    }

    private var sessionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
            Text(model.sessionName).font(.callout.weight(.medium)).lineLimit(1)
            Spacer()
            if !model.activeGuest.isEmpty {
                Button(model.guestWindowButtonTitle(kind: model.activeGuest)) { model.showPlayer(kind: model.activeGuest) }
            }
            Button(L10n.text("Herunterfahren"), action: model.shutdownGuest)
        }.padding(.horizontal, 18).padding(.vertical, 12)
            .modifier(WorkspaceChromeSurface()).padding(.horizontal, 20).padding(.bottom, 12)
    }
}

enum AppPresentation {
    static var releaseLabel: String {
        releaseLabel(info: Bundle.main.infoDictionary ?? [:])
    }
    static func releaseLabel(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "dev"
        let flavor = info["StratovoBuildFlavor"] as? String == "private" ? "Private Beta" : "Beta"
        let parts = (info["StratovoReleaseVersion"] as? String ?? "").components(separatedBy: "-beta.")
        let suffix = parts.count == 2 ? " " + parts[1] : ""
        return "\(version) · \(flavor)\(suffix) · \(build)"
    }
}

