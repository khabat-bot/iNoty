import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
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
