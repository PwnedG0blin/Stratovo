import SwiftUI
import AppKit
import Darwin
import StratovoCore

@MainActor
final class GuestRemovalController: ObservableObject {
    @Published private(set) var removing = false
    @Published private(set) var status = ""
    @Published private(set) var completed = false
    @Published private(set) var trashURL: URL?

    func remove(_ plan: GuestRemovalPlan, model: AppModel) async {
        guard !removing, !completed, model.canRemoveGuest,
              let storage = model.storage, storage.id == plan.storageID else {
            status = L10n.text("Zuerst alle Gastsysteme und laufenden Vorgänge beenden.")
            return
        }
        removing = true; model.setGraphicsLabBusy(true)
        defer { removing = false; model.setGraphicsLabBusy(false) }
        status = L10n.text("Installation wird in den Papierkorb verschoben …")
        do {
            let destination = try await Task.detached(priority: .userInitiated) {
                // Check external emulators too; a second app may own the guest.
                let processes = try CommandCapture.run(CommandSpec(executable: "/bin/ps", arguments: ["-axo", "comm="]), timeout: 10)
                guard processes.status == 0 else { throw StorageMigration.failure("Aktive Gastsysteme konnten nicht geprüft werden.") }
                let active = processes.output.components(separatedBy: .newlines).contains { line in
                    let command = line.trimmingCharacters(in: .whitespaces)
                    return command.contains("qemu-system-") || command.hasSuffix("/emulator") || command.hasSuffix("/swtpm")
                }
                guard !active else { throw StorageMigration.failure("Bitte alle QEMU- und Android-Emulatoren vollständig beenden und erneut versuchen.") }
                let lockRoot: URL?
                switch plan.target {
                case .windows: lockRoot = storage.windows
                case .ubuntu: lockRoot = storage.url.appendingPathComponent("Ubuntu")
                case .android: lockRoot = nil
                }
                var descriptor: Int32 = -1
                if let lockRoot {
                    let lock = lockRoot.appendingPathComponent("session.lock")
                    if FileManager.default.fileExists(atPath: lock.path) {
                        descriptor = Darwin.open(lock.path, O_RDWR | O_NOFOLLOW)
                        guard descriptor >= 0 else { throw StorageMigration.failure("Gastsperre konnte nicht geprüft werden.") }
                        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                            Darwin.close(descriptor)
                            throw StorageMigration.failure("Dieses Gastsystem wird noch verwendet.")
                        }
                    }
                }
                defer { if descriptor >= 0 { Darwin.close(descriptor) } }
                return try GuestRemoval.execute(plan, storage: storage) { bundle in
                    var destination: NSURL?
                    try FileManager.default.trashItem(at: bundle, resultingItemURL: &destination)
                    guard let url = destination as URL? else {
                        // trashItem succeeded: never attempt rollback from a now-moved path.
                        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                    }
                    return url
                }
            }.value
            trashURL = destination
            let warning = model.resetRemovedGuest(plan.target)
            completed = true
            model.setGraphicsLabBusy(false)
            await model.refresh()
            model.ubuntu.refresh(model: model)
            status = warning ?? L10n.text("Die Installation liegt im Papierkorb. Du kannst das System jetzt neu einrichten.")
        } catch { status = error.localizedDescription }
    }
}

@MainActor
struct GuestRemovalSection: View {
    @ObservedObject var model: AppModel
    let kind: String
    @State private var presented = false
    var body: some View {
        WorkspaceCard {
            Label(L10n.text("Installation verwalten"), systemImage: "externaldrive").font(.headline)
            Button(role: .destructive) { presented = true } label: {
                Label(L10n.text(kind == "android" ? "Android-Version entfernen …" : "System vollständig entfernen …"), systemImage: "trash")
            }
            .buttonStyle(.bordered).disabled(!model.canRemoveGuest)
            Text(L10n.text("Entfernt die ausgewählte Installation mit ihren lokalen Konten, Apps und Dateien. Vorher werden dir die betroffenen Ordner angezeigt."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $presented) { GuestRemovalSheet(model: model, kind: kind) }
    }
}

@MainActor
private struct GuestRemovalSheet: View {
    struct AndroidChoice: Identifiable {
        let id: String
        let title: String
    }
    @ObservedObject var model: AppModel
    let kind: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = GuestRemovalController()
    @State private var choices = [AndroidChoice]()
    @State private var selected = ""
    @State private var plan: GuestRemovalPlan?
    @State private var issue = ""
    @State private var acknowledged = false
    private var target: GuestRemovalTarget? {
        if kind == "windows" { return .windows }
        if kind == "ubuntu" { return .ubuntu }
        return selected.isEmpty ? nil : .android(selected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L10n.text("Installation entfernen"), systemImage: "trash").font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("Schließen")) { dismiss() }.disabled(controller.removing)
                    .keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !controller.completed {
                        if kind == "android" {
                            Picker(L10n.text("Welche Android-Installation möchtest du entfernen?"), selection: $selected) {
                                Text(L10n.text("Installation wählen …")).tag("")
                                ForEach(choices) { Text($0.title).tag($0.id) }
                            }.disabled(controller.removing)
                            if choices.isEmpty { Text(L10n.text("Keine verwaltete Android-Installation gefunden.")) }
                        } else { Text(kind == "windows" ? "Windows" : "Ubuntu").font(.headline) }
                        WorkspaceNotice(L10n.text("Alle Daten dieser Installation gehen verloren"),
                            L10n.text("Lokale Benutzerkonten, Anmeldungen, Apps, Spielstände und Dateien werden mit der Installation entfernt. Für die weitere Nutzung musst du das System neu einrichten. Die aufgeführten Dateien werden in den macOS-Papierkorb verschoben; nach dessen Leeren sind sie endgültig gelöscht."), color: .red)
                        if let plan {
                            Text(L10n.text("Diese Ordner und Dateien kommen in den Papierkorb:")).font(.headline)
                            ForEach(plan.paths, id: \.self) { path in
                                Text(path).font(.callout.monospaced()).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if kind == "windows" {
                                Text(L10n.text("Die von Stratovo gespeicherten Windows-Einrichtungsdaten im macOS-Schlüsselbund werden ebenfalls entfernt."))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if plan.retainedAndroidImage {
                                Text(L10n.text("Ein gemeinsam verwendetes oder nicht eindeutig zugeordnetes Android-Systemabbild bleibt erhalten. Die persönlichen Daten der ausgewählten Installation werden entfernt."))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Text(L10n.text("Gemeinsame Laufzeiten, andere Installationen, separat gesicherte Dateien und Online-Konten bleiben erhalten. Bei Android bleibt auch der gemeinsame Austauschordner erhalten."))
                                .font(.callout).foregroundStyle(.secondary)
                            Toggle(L10n.text("Ich habe meine benötigten Daten gesichert und möchte diese Installation entfernen."), isOn: $acknowledged)
                                .disabled(controller.removing)
                            Button(role: .destructive) {
                                Task { await controller.remove(plan, model: model) }
                            } label: { Label(L10n.text("Löschen"), systemImage: "trash") }
                                .buttonStyle(.borderedProminent)
                                .tint(acknowledged && model.canRemoveGuest ? Color.red : Color.gray)
                                .disabled(!acknowledged || !model.canRemoveGuest || controller.removing)
                        }
                        if !issue.isEmpty { Text(issue).foregroundStyle(.orange).textSelection(.enabled) }
                    }
                    if controller.removing { ProgressView().controlSize(.small) }
                    if !controller.status.isEmpty { Text(controller.status).textSelection(.enabled) }
                    if controller.completed, let url = controller.trashURL {
                        Button(L10n.text("Im Papierkorb anzeigen")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 540, idealHeight: 680)
        .modifier(WorkspaceDialogTheme())
        .interactiveDismissDisabled(controller.removing)
        .onAppear { loadChoices(); prepare() }
        .onChange(of: selected) { _, _ in prepare() }
    }

    private func loadChoices() {
        guard kind == "android", let storage = model.storage else { return }
        do {
            let folders = try FileManager.default.contentsOfDirectory(at: storage.avd, includingPropertiesForKeys: nil)
            let names = Set(folders.filter { ["avd", "ini"].contains($0.pathExtension) }.map { $0.deletingPathExtension().lastPathComponent })
            choices = names.map { name in
                let folder = storage.avd.appendingPathComponent(name + ".avd")
                // Labels are informational; the removal planner revalidates every path.
                guard folder.standardizedFileURL == folder.resolvingSymlinksInPath() else {
                    return AndroidChoice(id: name, title: name)
                }
                let config = RuntimeDiscovery.avdConfig(name: name, environment: storage.environment)
                let system = AndroidSystem.detect(config).map { "Android \($0.rawValue)" } ?? "Android"
                let preview = name.hasPrefix("Stratovo_Preview_") || config["stratovo.sdk", default: ""].contains("/Systems/Preview/") || AndroidSystem.detect(config) == .android17
                return AndroidChoice(id: name, title: "\(system) · \(L10n.text(preview ? "Beta / Vorschau" : "Offiziell")) · \(name)")
            }.sorted { $0.title < $1.title }
        } catch { issue = error.localizedDescription }
    }
    private func prepare() {
        plan = nil; acknowledged = false
        guard let target, let storage = model.storage else { return }
        do { plan = try GuestRemoval.plan(storage: storage, target: target); issue = "" }
        catch { issue = error.localizedDescription }
    }
}
