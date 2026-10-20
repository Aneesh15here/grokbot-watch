import GrokBotCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var presenter: AppPresenter
    @State private var apiKey = ""
    @State private var baseURL: String
    @State private var status: String?
    @State private var keyIsStored = false

    init(presenter: AppPresenter) {
        self.presenter = presenter
        _baseURL = State(initialValue: presenter.snapshot.settings.baseURLString)
        _keyIsStored = State(initialValue: Self.storedKey() != nil)
    }

    private static func storedKey() -> String? {
        let loaded = try? WatchRuntime.secrets.load(account: GrokBotAPI.credentialAccount)
        let value = loaded ?? nil
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    var body: some View {
        Form {
            Section("Account") {
                Toggle("Sample bots", isOn: sampleBinding)
                SecureField("Cursor API key", text: $apiKey)
                Text(keyIsStored ? "A key is in the Keychain on this watch." : "No key stored.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("API host", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") { save() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.save")
                Button("Forget key") { forget() }
                    .disabled(!keyIsStored)
            }
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                Text("The key is stored in the watch Keychain and is not written into the app. Revoke it from the Cursor dashboard if you lose the watch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }

    private var sampleBinding: Binding<Bool> {
        Binding(
            get: { presenter.snapshot.settings.useMockTransport },
            set: { useMock in
                Task { await apply(useMock: useMock) }
            }
        )
    }

    private func save() {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = ""
        do {
            try WatchRuntime.secrets.save(token, account: GrokBotAPI.credentialAccount)
            presenter.model.updateBaseURLString(baseURL)
            keyIsStored = true
            status = "Key saved in the Keychain."
            Task { await apply(useMock: false) }
        } catch {
            status = error.localizedDescription
        }
    }

    private func forget() {
        do {
            try WatchRuntime.secrets.delete(account: GrokBotAPI.credentialAccount)
            keyIsStored = false
            status = "Key removed."
            Task { await apply(useMock: true) }
        } catch {
            status = error.localizedDescription
        }
    }

    private func apply(useMock: Bool) async {
        if useMock {
            presenter.model.replaceTransport(MockBotTransport.demo())
            presenter.model.setUseMock(true)
            await presenter.model.seedDemoBots()
            return
        }
        presenter.model.updateBaseURLString(baseURL)
        do {
            let transport = try TransportFactory.liveTransport(
                secrets: WatchRuntime.secrets,
                settings: presenter.model.snapshot.settings,
                http: URLSessionHTTPClient(),
                makeRequestID: { UUID().uuidString }
            )
            presenter.model.replaceTransport(transport)
            presenter.model.setUseMock(false)
            status = "Talking to api.cursor.com."
        } catch {
            presenter.model.replaceTransport(MissingCredentialTransport())
            presenter.model.report(error.localizedDescription)
            status = error.localizedDescription
        }
    }
}
