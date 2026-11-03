import DabbleKit
import SwiftUI

/// Optional self-hosted relay for syncing when devices aren't on the same network.
struct SyncServerView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var testing = false
    @State private var message: (text: String, ok: Bool)?

    var body: some View {
        let sync = model.sync
        Form {
            Section {
                TextField("https://sync.example.com", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .submitLabel(.done)
                    .onSubmit(save)
                Button(sync.serverURL == nil ? "Use This Server" : "Save", action: save)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || normalized == sync.serverURL?.absoluteString)
                Button {
                    test()
                } label: {
                    HStack {
                        Text("Test Connection")
                        if testing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                if let message {
                    Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(message.ok ? .green : .orange)
                        .font(.footnote)
                }
            } header: {
                Text("Server Address")
            } footer: {
                Text("For devices that are rarely on the same network. Run the small relay from the server/ folder of the Dabble repo on a computer you control, put it behind HTTPS, and enter its address on each device. It only ever stores encrypted data.")
            }

            if sync.serverURL != nil {
                Section {
                    LabeledContent("Status") { status(sync) }
                    if let last = sync.serverLastSync {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            LabeledContent("Last Synced", value: last.shortAgo.capitalizedFirst)
                        }
                    }
                    Button("Stop Using Server", role: .destructive) {
                        try? sync.setServer(nil)
                        address = ""
                        message = nil
                    }
                }
            }
        }
        .navigationTitle("Sync Server")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { address = sync.serverURL?.absoluteString ?? "" }
    }

    private var normalized: String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    @ViewBuilder
    private func status(_ sync: SyncEngine) -> some View {
        switch sync.serverStatus {
        case .off:
            Text(sync.isEnabled ? "Not connected" : "Sync is off").foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .connected:
            Label("Connected", systemImage: "checkmark.icloud.fill").foregroundStyle(.green)
        case .error(let error):
            Text(error).foregroundStyle(.orange).font(.footnote).multilineTextAlignment(.trailing)
        }
    }

    private func test() {
        testing = true
        message = nil
        let text = address
        Task {
            do {
                try await model.sync.testServer(text)
                message = ("That's a Dabble sync server.", true)
            } catch {
                message = (error.localizedDescription, false)
            }
            testing = false
        }
    }

    private func save() {
        do {
            try model.sync.setServer(address)
            address = model.sync.serverURL?.absoluteString ?? ""
            message = nil
        } catch {
            message = (error.localizedDescription, false)
        }
    }
}

/// Short status for the Sync Server row in Sync settings.
struct SyncServerSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        if sync.serverURL == nil {
            Text("Off").foregroundStyle(.secondary)
        } else {
            switch sync.serverStatus {
            case .connected: Text("Connected").foregroundStyle(.green)
            case .connecting: Text("Connecting…").foregroundStyle(.secondary)
            case .error: Text("Error").foregroundStyle(.orange)
            case .off: Text(sync.serverURL?.host() ?? "On").foregroundStyle(.secondary)
            }
        }
    }
}

/// Join a group by pasting its sync key — for devices that are never nearby.
struct JoinWithKeyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var server = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("DBL1-…", text: $key, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { key = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            } header: {
                Text("Sync Key")
            } footer: {
                Text("Copy the key from Settings → Sync → Advanced on one of your other devices. Your to-dos on this device are kept and merged with the group's.")
            }
            Section {
                TextField("https://sync.example.com", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("Sync Server (Optional)")
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section {
                Button("Join", action: join)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Join with Sync Key")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { server = model.sync.serverURL?.absoluteString ?? "" }
    }

    private func join() {
        guard model.sync.join(syncKey: key) else {
            error = "That doesn't look like a Dabble sync key. It starts with DBL1-."
            return
        }
        if !server.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                try model.sync.setServer(server)
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        dismiss()
    }
}

/// Copies the sync key after a warning.
struct CopySyncKeyButton: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    @State private var copied = false

    var body: some View {
        Button(copied ? "Sync Key Copied" : "Copy Sync Key…") { confirm = true }
            .disabled(!model.sync.hasGroup)
            .confirmationDialog("Copy your sync key?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Copy Sync Key") {
                    UIPasteboard.general.string = model.sync.syncKey
                    copied = true
                }
            } message: {
                Text("The key gives full access to everything you sync. Paste it only into Dabble on your own devices.")
            }
    }
}
