import AppKit
import DabbleKit
import SwiftUI

/// Device-to-device sync: this Mac, paired devices, pairing, and advanced options.
struct SyncSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var deviceName = ""
    @State private var showPair = false
    @State private var showJoin = false
    @State private var newAddress = ""
    @State private var confirmLeave = false

    var body: some View {
        let sync = model.sync
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Device name", text: $deviceName, prompt: Text("Device name"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.leading)
                            .help("This Mac's name, as your other devices see it. Press Return to save.")
                            .font(.system(size: 15, weight: .semibold))
                            .onSubmit(commitName)
                        Text(statusLine(sync))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Sync", isOn: Binding(get: { sync.isEnabled }, set: { sync.isEnabled = $0 }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Dabble syncs directly between your devices over the local network — no account, and no server unless you add your own. Changes are end-to-end encrypted with your group's key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Devices") {
                if sync.peers.isEmpty {
                    Text(sync.hasGroup ? "No other devices yet." : "This Mac isn't paired with any devices.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sync.peers) { peer in
                    PeerRow(peer: peer)
                }
                HStack {
                    Button("Pair New Device…") { showPair = true }
                        .disabled(!sync.isEnabled)
                    Button("Join Another Device…") { showJoin = true }
                        .disabled(!sync.isEnabled)
                    Spacer()
                    Button {
                        sync.syncNow()
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!sync.isEnabled || !sync.hasGroup)
                }
            }

            SyncServerSection()

            if let error = sync.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Section("Advanced") {
                if let groupID = sync.groupID {
                    LabeledContent("Sync group") {
                        Text(groupID)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .help("Devices in the same group show the same fingerprint.")
                }
                LabeledContent("Listening on") {
                    Text(listeningText(sync))
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Manual addresses")
                    Text("Reach devices Bonjour can't see — for example over Tailscale or another VPN. Use host:port.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(sync.manualPeers, id: \.self) { address in
                        HStack {
                            Image(systemName: "network").foregroundStyle(.secondary)
                            Text(address).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button { sync.removeManualPeer(address) } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Remove address")
                        }
                    }
                    HStack {
                        TextField("", text: $newAddress, prompt: Text(verbatim: "my-mac.tailnet.ts.net:\(SyncEngine.defaultPort)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addAddress)
                        Button("Add", action: addAddress)
                            .disabled(newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.vertical, 2)
                SyncKeyRow()
                if sync.hasGroup {
                    HStack {
                        Text("Stop syncing this Mac and forget paired devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Leave Sync Group…", role: .destructive) { confirmLeave = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 680)
        .onAppear { deviceName = sync.deviceName }
        .sheet(isPresented: $showPair) { PairDeviceSheet() }
        .sheet(isPresented: $showJoin) { JoinDeviceSheet() }
        .confirmationDialog("Leave the sync group?", isPresented: $confirmLeave) {
            Button("Leave Sync Group", role: .destructive) { sync.leaveGroup() }
        } message: {
            Text("This Mac stops syncing, forgets its paired devices and its sync server. Your to-dos stay on this Mac.")
        }
    }

    private func statusLine(_ sync: SyncEngine) -> String {
        if !sync.isEnabled { return "Sync is off" }
        let connected = sync.peers.filter(\.isConnected).count
        if !sync.hasGroup { return "Not paired yet" }
        var text = connected == 0 ? "No devices connected" : "Connected to \(connected) device\(connected == 1 ? "" : "s")"
        if let last = sync.lastSync { text += " · synced \(last.formatted(.relative(presentation: .named)))" }
        return text
    }

    private func listeningText(_ sync: SyncEngine) -> String {
        guard let port = sync.listenerPort else {
            if !sync.isEnabled { return "Off" }
            return sync.isRunning ? "Starting…" : "Not running"
        }
        let addresses = localIPAddresses()
        return addresses.isEmpty ? "port \(port)" : addresses.map { "\($0):\(port)" }.joined(separator: "\n")
    }

    private func commitName() {
        let trimmed = deviceName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            deviceName = model.sync.deviceName
        } else if trimmed != model.sync.deviceName {
            model.sync.deviceName = trimmed
        }
    }

    private func addAddress() {
        let trimmed = newAddress.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.sync.addManualPeer(trimmed)
        newAddress = ""
    }
}

struct PeerRow: View {
    let peer: SyncEngine.Peer
    @Environment(AppModel.self) private var model
    @State private var confirmForget = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                HStack(spacing: 5) {
                    Circle().fill(peer.isConnected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Forget…") { confirmForget = true }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .confirmationDialog("Forget \(peer.name)?", isPresented: $confirmForget) {
            Button("Forget Device", role: .destructive) { model.sync.forget(peer: peer.id) }
        } message: {
            Text("It may reconnect while it still has your group key. To remove it for good, leave the group on that device.")
        }
    }

    private var icon: String {
        switch peer.platform {
        case "iOS": "iphone"
        case "iPadOS": "ipad"
        case "macOS": "laptopcomputer"
        default: "desktopcomputer"
        }
    }

    private var detail: String {
        var parts = [peer.platform, peer.isConnected ? "Connected" : "Not connected"]
        if let last = peer.lastSync { parts.append("Synced \(last.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

/// Makes this Mac discoverable, then has the user compare codes with the joining device.
struct PairDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sync = model.sync
        VStack(spacing: 18) {
            switch sync.pairingStatus {
            case .paired(let name):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text("Paired with \(name)")
                    .font(.title2.weight(.semibold))
                Text("Your to-dos will now sync between these devices whenever they're on the same network.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Pairing didn't work").font(.title2.weight(.semibold))
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Cancel") { dismiss() }
                    Button("Try Again") { sync.startHostingPairing() }
                        .keyboardShortcut(.defaultAction)
                }
            case .confirm(let device, let code):
                ConfirmCodeView(device: device, code: code)
            case .waiting(let device):
                WaitingForConfirmation(device: device)
            case .hosting:
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("Pair a New Device")
                    .font(.title2.weight(.semibold))
                Text("On your other device, open Dabble › Settings › Sync, choose **Join Another Device** and pick “\(sync.deviceName)”. You'll then check that both devices show the same code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the other device…").foregroundStyle(.secondary)
                }
                if let port = sync.pairingPort {
                    let addresses = localIPAddresses()
                    if !addresses.isEmpty {
                        Text("Not showing up? Enter \(addresses.map { "\($0):\(port)" }.joined(separator: " or ")) on the other device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            default:
                ProgressView()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(30)
        .frame(width: 440)
        .onAppear { sync.startHostingPairing() }
        .onDisappear {
            sync.stopHostingPairing()
            sync.resetPairingStatus()
        }
    }
}

struct CodeDisplay: View {
    let code: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(code.filter(\.isNumber).enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 40, height: 54)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
                if index == 2 { Spacer().frame(width: 8) }
            }
        }
        .textSelection(.enabled)
        .accessibilityLabel("Code \(code)")
    }
}

/// Both devices show this code; the user confirms they match before the group key is shared.
struct ConfirmCodeView: View {
    @Environment(AppModel.self) private var model
    let device: String
    let code: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("Does “\(device)” show this code?")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            CodeDisplay(code: code)
            Text("Only continue if the codes match exactly. This makes sure you're pairing with your own device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Codes Don't Match", role: .destructive) { model.sync.rejectPairing() }
                    .keyboardShortcut(.cancelAction)
                Button("Codes Match") { model.sync.confirmPairing() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct WaitingForConfirmation: View {
    @Environment(AppModel.self) private var model
    let device: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Confirm on “\(device)”")
                .font(.title2.weight(.semibold))
            Text("Tap **Codes Match** on the other device to finish pairing.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel") { model.sync.rejectPairing() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Finds a device that's ready to pair (or takes an address) and joins its group.
struct JoinDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedHost: String?
    @State private var address = ""

    var body: some View {
        let sync = model.sync
        VStack(alignment: .leading, spacing: 14) {
            if case .confirm(let device, let code) = sync.pairingStatus {
                ConfirmCodeView(device: device, code: code)
            } else if case .waiting(let device) = sync.pairingStatus {
                WaitingForConfirmation(device: device)
            } else if case .paired(let name) = sync.pairingStatus {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
                    Text("Joined \(name)'s sync group").font(.title2.weight(.semibold))
                    Text("Your to-dos are merging now. Nothing on this Mac was replaced.")
                        .foregroundStyle(.secondary)
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("Join Another Device").font(.title2.weight(.semibold))
                Text("On the other device, choose **Pair New Device** in Settings › Sync. It appears below; pick it, then compare the codes both devices show.")
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        if sync.pairingHosts.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Looking for devices…").foregroundStyle(.secondary)
                            }
                            .padding(8)
                        }
                        ForEach(sync.pairingHosts) { host in
                            Button {
                                selectedHost = host.id
                                address = ""
                            } label: {
                                HStack {
                                    Image(systemName: selectedHost == host.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selectedHost == host.id ? Color.accentColor : .secondary)
                                    Image(systemName: "desktopcomputer")
                                    Text(host.name)
                                    Spacer()
                                }
                                .padding(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Text("Or address:")
                    TextField("192.168.1.20:52390", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: address) { _, value in if !value.isEmpty { selectedHost = nil } }
                }

                switch sync.pairingStatus {
                case .joining:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Joining…").foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                default:
                    EmptyView()
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Join", action: join)
                        .keyboardShortcut(.defaultAction)
                        .disabled(host == nil || sync.pairingStatus == .joining)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            sync.resetPairingStatus()
            sync.startBrowsingForPairing()
        }
        .onDisappear {
            sync.stopBrowsingForPairing()
            sync.resetPairingStatus()
        }
        .onChange(of: sync.pairingHosts) { _, hosts in
            if selectedHost == nil, address.isEmpty, hosts.count == 1 { selectedHost = hosts[0].id }
        }
    }

    private var host: SyncEngine.PairingHost? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            if let colon = trimmed.lastIndex(of: ":"), let port = UInt16(trimmed[trimmed.index(after: colon)...]), port > 0 {
                let name = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                return name.isEmpty ? nil : .address(name, port: port)
            }
            return nil
        }
        return model.sync.pairingHosts.first { $0.id == selectedHost }
    }

    private func join() {
        guard let host else { return }
        model.sync.join(host)
    }
}
