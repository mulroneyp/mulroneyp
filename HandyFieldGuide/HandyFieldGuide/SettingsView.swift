import SwiftUI

/// Scarce / flagged list filters plus eBird API key (Keychain).
struct SettingsView: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyDraft = ""
    @State private var keyStored = EBirdAPIKeyStore.hasKey
    @State private var keyMessage: String?
    @State private var keyError: String?
    @State private var showingClearConfirm = false
    @State private var isValidatingKey = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(
                        "Hide scarce / near-zero for \(model.selectedMonthName)",
                        isOn: Binding(
                            get: { model.hideNearZero },
                            set: { model.setHideNearZero($0) }
                        )
                    )
                    Toggle("Show flagged sp. / slash taxa", isOn: $model.showFlaggedTaxa)
                } footer: {
                    Text(
                        "Near-zero rows are below \(Int(EBirdBarchartParser.nearZeroThreshold * 1000) / 10)% mean frequency for the selected month. Flagged “sp.” and slash taxa stay off the main list unless you turn them on."
                    )
                }

                Section {
                    if keyStored {
                        Label("API key saved on this device", systemImage: "checkmark.shield")
                            .foregroundStyle(GuideColor.green)
                    } else {
                        Text("No API key stored")
                            .foregroundStyle(GuideColor.muted)
                    }

                    // Plain field (not SecureField) so paste from keygen is reliable.
                    TextField("Paste eBird API key", text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .font(.body.monospaced())

                    Button {
                        Task { await saveKey() }
                    } label: {
                        if isValidatingKey {
                            Text(keyStored ? "Checking key…" : "Saving…")
                        } else {
                            Text(keyStored ? "Replace key" : "Save key")
                        }
                    }
                    .disabled(
                        isValidatingKey
                            || EBirdAPIKeyStore.sanitize(apiKeyDraft).isEmpty
                    )

                    if keyStored {
                        Button("Clear key", role: .destructive) {
                            showingClearConfirm = true
                        }
                        .disabled(isValidatingKey)
                    }

                    Link(
                        "Get a free key at ebird.org/api/keygen",
                        destination: URL(string: "https://ebird.org/api/keygen")!
                    )

                    if let keyError {
                        Text(keyError)
                            .font(.footnote)
                            .foregroundStyle(GuideColor.rust)
                    } else if let keyMessage {
                        Text(keyMessage)
                            .font(.footnote)
                            .foregroundStyle(GuideColor.green)
                    }
                } header: {
                    Text("eBird API")
                } footer: {
                    Text(
                        "Required for searching hotspots and importing frequency data over the network. The key is stored in the Keychain on this device only — never in iCloud Birdlists or the project repo. Clear or replace it anytime. Saving checks the key against api.ebird.org."
                    )
                }
            }
            .guideBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Clear eBird API key?", isPresented: $showingClearConfirm) {
                Button("Clear", role: .destructive) {
                    EBirdAPIKeyStore.delete()
                    keyStored = false
                    apiKeyDraft = ""
                    keyError = nil
                    keyMessage = "API key cleared."
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Hotspot search and API import will need a new key from ebird.org/api/keygen.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func saveKey() async {
        keyError = nil
        keyMessage = nil
        let sanitized = EBirdAPIKeyStore.sanitize(apiKeyDraft)
        guard !sanitized.isEmpty else {
            keyError = EBirdAPIKeyStore.KeyStoreError.empty.localizedDescription
            return
        }

        isValidatingKey = true
        defer { isValidatingKey = false }

        do {
            try await EBirdAPIClient.shared.validateAPIKey(sanitized)
            try EBirdAPIKeyStore.save(sanitized)
            keyStored = true
            apiKeyDraft = ""
            keyMessage = "API key saved and verified with eBird."
        } catch let error as EBirdAPIError {
            switch error {
            case .unauthorized:
                keyError = error.localizedDescription
            case .network:
                // Still store so offline paste works; user can retry search later.
                do {
                    try EBirdAPIKeyStore.save(sanitized)
                    keyStored = true
                    apiKeyDraft = ""
                    keyMessage = "API key saved. Couldn’t verify online — check your connection."
                } catch {
                    keyError = error.localizedDescription
                }
            default:
                keyError = error.localizedDescription
            }
        } catch {
            keyError = error.localizedDescription
        }
    }
}
