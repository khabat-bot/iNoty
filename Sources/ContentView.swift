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
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
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

/// Soft colored blobs so the glass has something to refract.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.20),
                    Color(red: 0.20, green: 0.08, blue: 0.35),
                    Color(red: 0.03, green: 0.20, blue: 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle().fill(Color.cyan.opacity(0.35))
                .frame(width: 300, height: 300).blur(radius: 70).offset(x: -140, y: -260)
            Circle().fill(Color.purple.opacity(0.40))
                .frame(width: 340, height: 340).blur(radius: 80).offset(x: 150, y: 120)
            Circle().fill(Color.pink.opacity(0.25))
                .frame(width: 260, height: 260).blur(radius: 70).offset(x: -120, y: 380)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Screen

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var toast: String?

    var body: some View {
        ZStack {
            Backdrop()

            ScrollView {
                VStack(spacing: 16) {
                    header

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

                    Card("Recent requests") {
                        if model.log.isEmpty {
                            Text("Nothing yet")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(.footnote, design: .monospaced))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
        }
        .preferredColorScheme(.dark)
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
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "bell.badge.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .glassCard(radius: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("iNoty")
                    .font(.largeTitle.bold())
                Text("Local notification server")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if toast == text { toast = nil }
        }
    }
}
