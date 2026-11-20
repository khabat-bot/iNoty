import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationView {
            List {
                Section("Status") {
                    row("Server", model.serverStatus)
                    row("Background audio", model.audioStatus)
                }

                Section("Secret token") {
                    Text(model.token)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy token") { UIPasteboard.general.string = model.token }
                    Button("Regenerate token", role: .destructive) { model.regenerateToken() }
                }

                Section("Usage") {
                    Text(model.exampleURL)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy example URL") { UIPasteboard.general.string = model.exampleURL }
                    Button("Send test notification") { model.sendTest() }
                }

                Section("Recent requests") {
                    if model.log.isEmpty {
                        Text("Nothing yet").foregroundColor(.secondary)
                    } else {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("iNoty")
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
