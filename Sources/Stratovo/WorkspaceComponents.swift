import SwiftUI
import StratovoCore

/// Shared presentation only. Guest actions and their availability stay in AppModel.
struct WorkspaceCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content() }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background { WorkspaceCardSurface().clipShape(RoundedRectangle(cornerRadius: 14)) }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct WorkspaceStatusBadge: View {
    let text: String
    let ready: Bool
    init(_ text: String, ready: Bool) { self.text = text; self.ready = ready }
    var body: some View {
        Label(text, systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption.weight(.medium)).foregroundStyle(ready ? Color.teal : Color.orange)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((ready ? Color.teal : Color.orange).opacity(0.1), in: Capsule())
    }
}

struct WorkspaceFileRow: View {
    let title: String
    let value: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title)).font(.subheadline.weight(.medium))
                Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    .help(value)
            }
            Spacer(minLength: 10)
            Button(L10n.text("Auswählen …"), action: action)
        }
    }
}

struct WorkspaceNotice: View {
    let title: String
    let message: String
    var color: Color = .orange
    init(_ title: String, _ message: String, color: Color = .orange) {
        self.title = title; self.message = message; self.color = color
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}

/// A single, scrollable help presentation works at small window sizes and with
/// long translations. Help never changes settings or starts a guest process.
struct ContextHelpButton<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var presented = false
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        Button { presented = true } label: {
            Label(L10n.text(title), systemImage: "questionmark.circle")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .accessibilityHint(L10n.text("Öffnet eine Erklärung ohne Einstellungen zu ändern."))
        .sheet(isPresented: $presented) {
            WorkspaceHelpSheet(title: title, content: content)
        }
    }
}

struct WorkspaceHelpSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L10n.text(title), systemImage: "questionmark.circle")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24).modifier(WorkspaceChromeSurface(cornerRadius: 0))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
        }.frame(minWidth: 520, idealWidth: 640, maxWidth: 760, minHeight: 360, idealHeight: 540)
            .modifier(WorkspaceDialogTheme())
    }
}

/// Section controls share the app's labeled button appearance. Expansion stays
/// owned by DisclosureGroup, including callers with an explicit binding.
struct WorkspaceButtonDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").accessibilityHidden(true)
                    configuration.label.font(.callout.weight(.semibold))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(configuration.isExpanded ? MidnightPalette.turquoise : Color.secondary)
            .accessibilityAddTraits(configuration.isExpanded ? [.isSelected] : [])
            if configuration.isExpanded {
                configuration.content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
