import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var serverMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text("Relay server"),
                    footer: Text(serverMessage ?? "Where internet requests are delivered. Use https://ntfy.sh or your own ntfy server. Changing it starts a new connection and only messages sent afterwards arrive.")
                ) {
                    TextField("https://ntfy.sh", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Button("Save") {
                        serverMessage = model.setRelayServer(server) ?? "Saved."
                    }
                }

                Section(
                    header: Text("History"),
                    footer: Text("How many past requests are kept. Lowering this deletes the oldest ones straight away.")
                ) {
                    Stepper(
                        value: Binding(
                            get: { model.historyLimit },
                            set: { model.setHistoryLimit($0) }
                        ),
                        in: 10...500,
                        step: 10
                    ) {
                        Text("Keep the last \(model.historyLimit) requests")
                    }
                }
            }
            .onAppear { server = model.relayServer }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
