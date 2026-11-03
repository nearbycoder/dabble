import AppKit
import DabbleKit
import SwiftUI

/// Optional self-hosted relay for syncing when devices aren't on the same network.
struct SyncServerSection: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var testing = false
    @State private var message: (text: String, ok: Bool)?

    var body: some View {
        let sync = model.sync
        Section {
            HStack {
                TextField("", text: $address, prompt: Text(verbatim: "https://sync.example.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(save)
                Button("Test", action: test)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                Button(sync.serverURL == nil ? "Use Server" : "Save", action: save)
                    .disabled(normalized == sync.serverURL?.absoluteString)
            }
            if let message {
                Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(message.ok ? .green : .orange)
                    .font(.callout)
            }
            if sync.serverURL != nil {
                HStack {
                    statusLabel(sync)
                    Spacer()
                    Button("Stop Using Server") {
                        try? sync.setServer(nil)
                        address = ""
                        message = nil
                    }
                }
            }
        } header: {
            Text("Sync Server (Optional)")
        } footer: {
            Text("For devices that are rarely on the same network. Run the tiny relay in the repo's server/ folder on any machine you control, put it behind HTTPS, and enter its address on each device. It only ever stores encrypted data.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { address = sync.serverURL?.absoluteString ?? "" }
    }

    private var normalized: String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var text = trimmed.contains("://") ? trimmed : "https://" + trimmed
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    @ViewBuilder
    private func statusLabel(_ sync: SyncEngine) -> some View {
        switch sync.serverStatus {
        case .off:
            Label(sync.isEnabled ? "Not connected" : "Sync is off", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .connected:
            Label(connectedText(sync), systemImage: "checkmark.icloud.fill")
                .foregroundStyle(.green)
        case .error(let error):
            Label(error, systemImage: "exclamationmark.icloud.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    private func connectedText(_ sync: SyncEngine) -> String {
        guard let last = sync.serverLastSync else { return "Connected" }
        return "Connected · synced \(last.formatted(.relative(presentation: .named)))"
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

/// Copy this group's sync key, or join a group by pasting one. Useful when the
/// other device is never on the same network, e.g. when syncing only through a server.
struct SyncKeyRow: View {
    @Environment(AppModel.self) private var model
    @State private var showJoin = false
    @State private var confirmCopy = false
    @State private var copied = false

    var body: some View {
        let sync = model.sync
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync key")
                Text("Join from a device that's never nearby by pasting this key. Anyone with it can read and change your to-dos, so share it only with yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if sync.hasGroup {
                Button(copied ? "Copied" : "Copy Key…") { confirmCopy = true }
            }
            Button("Join with Key…") { showJoin = true }
        }
        .confirmationDialog("Copy your sync key?", isPresented: $confirmCopy) {
            Button("Copy Sync Key") {
                guard let key = sync.syncKey else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
                copied = true
            }
        } message: {
            Text("The key gives full access to everything you sync. Paste it only into Dabble on your own devices, and don't keep it anywhere others can see.")
        }
        .sheet(isPresented: $showJoin) { JoinWithKeySheet() }
    }
}

struct JoinWithKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var server = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join with a Sync Key").font(.title2.weight(.semibold))
            Text("Paste the key from Settings › Sync on one of your other devices. Your to-dos on this Mac are kept and merged with the group's.")
                .foregroundStyle(.secondary)
            TextField("", text: $key, prompt: Text(verbatim: "DBL1-…"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            TextField("", text: $server, prompt: Text("Sync server address (optional)"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Join", action: join)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
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
