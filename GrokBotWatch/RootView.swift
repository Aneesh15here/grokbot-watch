import GrokBotCore
import SwiftUI

struct RootView: View {
    @ObservedObject var presenter: AppPresenter
    @ObservedObject private var network = WatchRuntime.network
    @StateObject private var callRuntime = CallRuntime()
    @State private var bootstrapped = false

    var body: some View {
        Group {
            if presenter.snapshot.inCall {
                CallView(presenter: presenter)
            } else {
                RosterView(presenter: presenter)
            }
        }
        .onChange(of: presenter.snapshot.inCall) { _, inCall in
            if inCall {
                callRuntime.start()
            } else {
                callRuntime.stop()
            }
        }
        .task {
            guard !bootstrapped else { return }
            bootstrapped = true
            network.onChange = { online in
                Task { await presenter.model.setOnline(online) }
            }
            network.start()
            if let action = LaunchFlag.consume() {
                await presenter.model.consumeLaunch(action)
            }
            if presenter.snapshot.settings.useMockTransport && presenter.snapshot.rows.isEmpty {
                await presenter.model.seedDemoBots()
            }
            await presenter.model.setOnline(network.isOnline)
            await presenter.model.run()
        }
    }
}

struct RosterView: View {
    @ObservedObject var presenter: AppPresenter
    @State private var showingAdd = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                if presenter.snapshot.settings.useMockTransport {
                    Text("Sample bots are on. Add a Cursor API key to reach your account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let warning = presenter.snapshot.warning {
                    Button(warning) {
                        presenter.model.dismissWarning()
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
                if presenter.snapshot.queuedCount > 0 {
                    Text("\(presenter.snapshot.queuedCount) queued")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if presenter.snapshot.rows.isEmpty {
                    Text("Add a bot by the exact name shown in Grok Bot.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(presenter.snapshot.rows) { row in
                    Button {
                        Task { await presenter.model.startCall(named: row.name) }
                    } label: {
                        BotRowLabel(row: row)
                    }
                    .accessibilityIdentifier("roster.\(row.name)")
                }
            }
            .navigationTitle("Bots")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityIdentifier("roster.settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("roster.add")
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddBotView(presenter: presenter)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(presenter: presenter)
            }
        }
    }
}

struct BotRowLabel: View {
    var row: BotRow

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(ActivitySnapshot.detail(phase: row.phase, queuedCount: row.queuedCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if row.isLastUsed {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
    }

    private var color: Color {
        switch row.phase {
        case .working:
            return .orange
        case .queued:
            return .yellow
        case .idle:
            return .green
        case .settling:
            return .gray
        }
    }
}

struct AddBotView: View {
    @ObservedObject var presenter: AppPresenter
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bot name")
                    .font(.headline)
                TextField("Plan Keeper", text: $name)
                Text("Uses the exact name from the Grok Bot app. A name that does not exist creates an empty bot on the account.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(confirmed ? "Add anyway" : "Add bot") {
                    if confirmed || presenter.snapshot.settings.useMockTransport {
                        Task {
                            await presenter.model.addBot(named: name)
                            dismiss()
                        }
                    } else {
                        confirmed = true
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("add.confirm")
            }
            .padding(.horizontal, 4)
        }
    }
}
