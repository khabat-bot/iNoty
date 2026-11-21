import SwiftUI
import UIKit

// MARK: - Liquid Glass helpers
// iOS 26 gets the real Liquid Glass effect. Older versions fall back to a blur material.

private struct GlassCard: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

private extension View {
    func glassCard(radius: CGFloat = 24) -> some View {
        modifier(GlassCard(radius: radius))
    }
}

private struct GlassButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            if prominent {
                Button(action: action) { label }
                    .buttonStyle(.glassProminent)
                    .tint(tint)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.glass)
                    .tint(tint)
            }
        } else {
            if prominent {
                Button(action: action) { label }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.bordered)
                    .tint(tint)
            }
        }
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
    }
}

private struct Card<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }
}

private struct StatusPill: View {
    let title: String
    let detail: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 20)
    }
}

// MARK: - Screen

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    private enum ActiveSheet: Identifiable {
        case history, picker
        var id: Int { self == .history ? 0 : 1 }
    }

    @State private var toast: String?
    @State private var sheet: ActiveSheet?

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        Text("iNoty")
                            .font(.largeTitle.bold())
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)

                    HStack(spacing: 12) {
                        StatusPill(
                            title: "Server",
                            detail: model.serverOK ? "Listening :\(AppModel.port)" : model.serverStatus,
                            ok: model.serverOK
                        )
                        StatusPill(
                            title: "Background audio",
                            detail: model.audioOK ? "Playing" : model.audioStatus,
                            ok: model.audioOK
                        )
                    }

                    Card("Secret token") {
                        Text(model.token)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            GlassButton(title: "Copy", systemImage: "doc.on.doc", prominent: true) {
                                UIPasteboard.general.string = model.token
                                flash("Token copied")
                            }
                            GlassButton(title: "Regenerate", systemImage: "arrow.triangle.2.circlepath", tint: .red) {
                                model.regenerateToken()
                                flash("New token generated")
                            }
                        }
                    }

                    Card("Network access") {
                        Toggle(isOn: Binding(
                            get: { model.allowNetwork },
                            set: { model.setAllowNetwork($0) }
                        )) {
                            Text("Allow other devices on my network")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(model.allowNetwork
                             ? "On: devices on your Wi-Fi or another private network can send requests if they have the token. Traffic is plain HTTP, so only use this on networks you trust."
                             : "Off: only this phone can send requests.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let url = model.networkURL {
                            Text(url)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    Card("Usage") {
                        Text(model.exampleURL)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            GlassButton(title: "Copy URL", systemImage: "link") {
                                UIPasteboard.general.string = model.exampleURL
                                flash("URL copied")
                            }
                            GlassButton(title: "Send test", systemImage: "bell.badge", prominent: true) {
                                model.sendTest()
                                flash("Test notification sent")
                            }
                        }
                    }

                    Card("History") {
                        if model.history.isEmpty {
                            Text("Nothing yet")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(model.history.prefix(5)) { entry in
                                    HistoryRow(entry: entry)
                                }
                            }
                            GlassButton(title: "Open full history", systemImage: "clock.arrow.circlepath") {
                                sheet = .history
                            }
                        }
                    }

                    Card("Notification sounds") {
                        if model.sounds.isEmpty {
                            Text("No custom sounds yet. Add an audio file (up to 30 seconds), then put its name in the sound field of a request.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(model.sounds, id: \.self) { name in
                                    HStack(spacing: 16) {
                                        Text(name)
                                            .font(.system(.subheadline, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Button { model.preview(name) } label: {
                                            Image(systemName: "play.fill")
                                        }
                                        .accessibilityLabel("Play \(name) in the app")
                                        Button {
                                            model.testSound(name)
                                            flash("Test notification sent")
                                        } label: {
                                            Image(systemName: "bell.fill")
                                        }
                                        .accessibilityLabel("Send a test notification with \(name)")
                                        Button(role: .destructive) { model.deleteSound(name) } label: {
                                            Image(systemName: "trash")
                                        }
                                        .accessibilityLabel("Delete \(name)")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            Text("Play previews inside the app. The bell sends a real notification, which is the real test of whether iOS plays the sound.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        GlassButton(title: "Add sound", systemImage: "plus", prominent: true) {
                            sheet = .picker
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassCard(radius: 22)
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .sheet(item: $sheet) { which in
            switch which {
            case .history:
                HistoryView().environmentObject(model)
            case .picker:
                SoundPicker { urls in
                    sheet = nil
                    model.importSounds(urls) { message in flash(message, seconds: 4) }
                }
            }
        }
    }

    private func flash(_ text: String, seconds: Double = 1.5) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if toast == text { toast = nil }
        }
    }
}
