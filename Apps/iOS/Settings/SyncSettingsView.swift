import DabbleKit
import SwiftUI

/// Device-to-device sync: this device, paired devices, pairing, and advanced options.
struct SyncSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var forgetting: SyncEngine.Peer?

    private var sync: SyncEngine { model.sync }

    var body: some View {
        @Bindable var sync = model.sync
        Form {
            Section {
                SyncStatusHeader()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Toggle(isOn: $sync.isEnabled) {
                    SettingsLabel(title: "Sync", systemImage: "arrow.triangle.2.circlepath", tint: .blue) { EmptyView() }
                }
                HStack {
                    SettingsLabel(title: "Device Name", systemImage: deviceIcon, tint: .gray) { EmptyView() }
                    TextField("Name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .submitLabel(.done)
                        .onSubmit(commitName)
                }
            } footer: {
                Text("Other devices see this name when pairing.")
            }

            Section {
                if sync.peers.isEmpty {
                    Text("No paired devices yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sync.peers) { peer in
                    PeerRow(peer: peer)
                        .swipeActions {
                            Button("Forget", role: .destructive) { forgetting = peer }
                        }
                        .contextMenu {
                            Button("Forget Device", systemImage: "minus.circle", role: .destructive) { forgetting = peer }
                        }
                }
            } header: {
                Text("Devices")
            }

            Section {
                NavigationLink {
                    PairHostView()
                } label: {
                    Label("Pair New Device", systemImage: "plus.circle.fill")
                }
                NavigationLink {
                    JoinDeviceView()
                } label: {
                    Label("Join a Device", systemImage: "link.circle.fill")
                }
            } footer: {
                Text("Devices sync directly with each other over your local network — there's no server and no account. Dabble needs to be open on both devices for them to sync.")
            }

            if sync.hasGroup {
                Section {
                    Button {
                        sync.syncNow()
                    } label: {
                        Label("Sync Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(!sync.isEnabled)
                    if let lastSync = sync.lastSync {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            LabeledContent("Last Synced", value: lastSync.shortAgo.capitalizedFirst)
                        }
                    }
                    if let groupID = sync.groupID {
                        LabeledContent("Group ID") {
                            Text(groupID.uppercased().chunked(4))
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Sync Group")
                } footer: {
                    Text("Devices in the same sync group show the same Group ID.")
                }
            }

            if let error = sync.lastError, sync.isEnabled {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            Section {
                NavigationLink("Advanced") { AdvancedSyncView() }
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = sync.deviceName }
        .onDisappear(perform: commitName)
        .confirmationDialog("Forget “\(forgetting?.name ?? "")”?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { peer in
            Button("Forget Device", role: .destructive) { sync.forget(peer: peer.id) }
        } message: { _ in
            Text("This device stops syncing with it. Pair again to reconnect.")
        }
    }

    private var deviceIcon: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != sync.deviceName { sync.deviceName = trimmed }
    }
}

/// Big status at the top of Sync settings.
private struct SyncStatusHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        let connected = sync.peers.filter(\.isConnected).count
        let (symbol, tint, title, detail): (String, Color, String, String) = {
            if !sync.isEnabled { return ("icloud.slash", .secondary, "Sync Is Off", "Turn it on to keep your devices up to date.") }
            if !sync.hasGroup || sync.peers.isEmpty { return ("arrow.triangle.2.circlepath", .blue, "Sync Your Devices", "Pair your iPhone, iPad and Mac to keep your to-dos in step.") }
            if connected > 0 { return ("checkmark.circle.fill", .green, "Connected", "Syncing with \(connected) device\(connected == 1 ? "" : "s").") }
            return ("wifi.exclamationmark", .orange, "Not Connected", "Open Dabble on your other devices to sync.")
        }()
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(.title3.bold())
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct PeerRow: View {
    let peer: SyncEngine.Peer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            content
        }
    }

    private var content: some View {
        HStack(spacing: 14) {
            Image(systemName: peer.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(peer.isConnected ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 9, height: 9)
                .accessibilityLabel(peer.isConnected ? "Connected" : "Not connected")
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        var parts = [peer.isConnected ? "Connected" : "Not connected"]
        if let lastSync = peer.lastSync { parts.append("Synced \(lastSync.shortAgo)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pairing (host)

/// Makes this device discoverable, then has the user compare codes with the joining device.
struct PairHostView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sync = model.sync
        ScrollView {
            VStack(spacing: 22) {
                switch sync.pairingStatus {
                case .hosting:
                    hosting(sync: sync)
                case .confirm(let device, let code):
                    ConfirmCodeView(device: device, code: code)
                case .waiting(let device):
                    WaitingForConfirmation(device: device)
                case .paired(let name):
                    PairingSuccess(name: name) { dismiss() }
                case .failed(let message):
                    PairingFailure(message: message) { sync.startHostingPairing() }
                case .idle, .joining:
                    ProgressView().padding(.top, 80)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: sync.pairingStatus)
        }
        .navigationTitle("Pair New Device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sync.startHostingPairing() }
        .onDisappear {
            sync.stopHostingPairing()
            sync.resetPairingStatus()
        }
        .sensoryFeedback(.success, trigger: sync.pairingStatus) { _, new in
            if case .paired = new { true } else { false }
        }
    }

    @ViewBuilder
    private func hosting(sync: SyncEngine) -> some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 46, weight: .medium))
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative, options: .repeating)
        VStack(spacing: 6) {
            Text("Ready to Pair")
                .font(.title2.bold())
            Text("On your other device, open Settings → Sync → Join a Device and choose “\(sync.deviceName)”. You'll then check that both devices show the same code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        HStack(spacing: 8) {
            ProgressView()
            Text("Waiting for the other device…")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        if let port = sync.pairingPort {
            let addresses = NetworkInfo.localAddresses()
            if !addresses.isEmpty {
                VStack(spacing: 4) {
                    Text("Not listed on the other device? Enter this address instead:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(addresses, id: \.self) { address in
                        Text("\(address):\(String(port))")
                            .font(.footnote.monospaced().weight(.medium))
                            .textSelection(.enabled)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            }
        }
        Text("This device stays discoverable for 5 minutes.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Pairing (join)

/// Finds a device that's ready to pair (or takes an address), joins it, and compares codes.
struct JoinDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host: SyncEngine.PairingHost?
    @State private var address = ""

    var body: some View {
        let sync = model.sync
        Group {
            if case .paired(let name) = sync.pairingStatus {
                ScrollView {
                    PairingSuccess(name: name) { dismiss() }
                        .padding(24)
                        .padding(.top, 20)
                }
            } else if let host {
                joinStatus(host: host, sync: sync)
            } else {
                hostList(sync: sync)
            }
        }
        .navigationTitle("Join a Device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sync.startBrowsingForPairing() }
        .onDisappear {
            sync.stopBrowsingForPairing()
            sync.resetPairingStatus()
        }
        .sensoryFeedback(.success, trigger: sync.pairingStatus) { _, new in
            if case .paired = new { true } else { false }
        }
        .sensoryFeedback(.error, trigger: sync.pairingStatus) { _, new in
            if case .failed = new { true } else { false }
        }
    }

    private func hostList(sync: SyncEngine) -> some View {
        Form {
            Section {
                if sync.pairingHosts.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for nearby devices…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(sync.pairingHosts) { candidate in
                    Button {
                        choose(candidate)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                            Text(candidate.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Nearby Devices")
            } footer: {
                Text("On the device you want to sync with, open Settings → Sync → Pair New Device. It appears here while it's ready to pair.")
            }

            Section {
                TextField("192.168.1.20:52390", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .submitLabel(.continue)
                    .onSubmit(chooseAddress)
                Button("Continue", action: chooseAddress)
                    .disabled(NetworkInfo.parse(address) == nil)
            } header: {
                Text("Enter an Address")
            } footer: {
                Text("If the device isn't listed — for example over Tailscale or another VPN — enter the address shown on its pairing screen.")
            }
        }
    }

    private func joinStatus(host: SyncEngine.PairingHost, sync: SyncEngine) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                switch sync.pairingStatus {
                case .confirm(let device, let code):
                    ConfirmCodeView(device: device, code: code)
                case .waiting(let device):
                    WaitingForConfirmation(device: device)
                case .failed(let message):
                    PairingFailure(message: message) { sync.join(host) }
                default:
                    ProgressView()
                        .controlSize(.large)
                        .padding(.top, 60)
                    Text("Connecting to “\(host.name)”…")
                        .foregroundStyle(.secondary)
                }

                Button("Choose a Different Device") {
                    sync.rejectPairing()
                    sync.resetPairingStatus()
                    self.host = nil
                }
                .font(.subheadline)
                .padding(.top, 8)
            }
            .padding(24)
            .padding(.top, 12)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: sync.pairingStatus)
        }
    }

    private func choose(_ candidate: SyncEngine.PairingHost) {
        model.sync.resetPairingStatus()
        host = candidate
        model.sync.join(candidate)
    }

    private func chooseAddress() {
        guard let parsed = NetworkInfo.parse(address) else { return }
        choose(.address(parsed.host, port: parsed.port))
    }
}

// MARK: - Shared pairing views

/// Six rounded boxes showing (or collecting) a pairing code.
struct CodeBoxes: View {
    enum Size { case regular, large }
    let code: String
    var size: Size = .regular
    var showsCursor = false

    var body: some View {
        let digits = Array(code.filter(\.isNumber))
        let width: CGFloat = size == .large ? 48 : 44
        let height: CGFloat = size == .large ? 66 : 58
        HStack(spacing: size == .large ? 8 : 7) {
            ForEach(0..<6, id: \.self) { index in
                let isCurrent = showsCursor && index == min(digits.count, 5)
                Text(index < digits.count ? String(digits[index]) : "")
                    .font(.system(size: size == .large ? 40 : 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: width, height: height)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isCurrent ? 2 : 1)
                    )
                if index == 2 { Spacer().frame(width: size == .large ? 10 : 8) }
            }
        }
    }
}

/// Both devices show this code; the user confirms they match before the group key is shared.
private struct ConfirmCodeView: View {
    @Environment(AppModel.self) private var model
    let device: String
    let code: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Does “\(device)” show this code?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            CodeBoxes(code: code, size: .large)
                .accessibilityLabel("Code \(code)")
            Text("Only continue if the codes match exactly. This makes sure you're pairing with your own device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button {
                    model.sync.confirmPairing()
                } label: {
                    Text("Codes Match").frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Codes Don't Match", role: .destructive) { model.sync.rejectPairing() }
            }
            .padding(.top, 4)
        }
        .padding(.top, 24)
    }
}

private struct WaitingForConfirmation: View {
    let device: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Confirm on “\(device)”")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Tap Codes Match on the other device to finish pairing.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }
}

private struct PairingSuccess: View {
    let name: String
    var done: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text("Paired with \(name)")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Your devices now sync automatically whenever Dabble is open on both.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: done) {
                Text("Done").frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(.top, 40)
    }
}

private struct PairingFailure: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("Pairing Didn't Work")
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }
}

// MARK: - Advanced

struct AdvancedSyncView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newPeer = ""
    @State private var confirmLeave = false

    var body: some View {
        let sync = model.sync
        Form {
            Section {
                LabeledContent("Listening Port", value: sync.listenerPort.map { String($0) } ?? "Not listening")
                if let port = sync.listenerPort {
                    ForEach(NetworkInfo.localAddresses(), id: \.self) { address in
                        LabeledContent("Address") {
                            Text("\(address):\(String(port))")
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("This Device")
            } footer: {
                Text("Other devices can add this address under Manual Peers.")
            }

            Section {
                ForEach(sync.manualPeers, id: \.self) { peer in
                    Text(peer).font(.body.monospaced())
                }
                .onDelete { offsets in
                    for offset in offsets { sync.removeManualPeer(sync.manualPeers[offset]) }
                }
                HStack {
                    TextField("host:port", text: $newPeer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onSubmit(addPeer)
                    Button("Add", action: addPeer)
                        .disabled(newPeer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Manual Peers")
            } footer: {
                Text("Add paired devices by address when they can't be found automatically — for example over Tailscale or another VPN. Use host:port, like my-mac.tailnet.ts.net:\(String(SyncEngine.defaultPort)).")
            }

            Section {
                Button("Sync Now") { sync.syncNow() }
                    .disabled(!sync.isEnabled)
            }

            if sync.hasGroup {
                Section {
                    Button("Leave Sync Group", role: .destructive) { confirmLeave = true }
                } footer: {
                    Text("This device stops syncing and forgets its paired devices. Your to-dos stay on this device.")
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Leave the sync group?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Sync Group", role: .destructive) {
                sync.leaveGroup()
                dismiss()
            }
        } message: {
            Text("To sync again, pair this device with another one.")
        }
    }

    private func addPeer() {
        let trimmed = newPeer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.sync.addManualPeer(trimmed)
        newPeer = ""
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }

    /// "a1b2c3d4" → "a1b2 c3d4".
    func chunked(_ size: Int) -> String {
        stride(from: 0, to: count, by: size).map { offset -> String in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }.joined(separator: " ")
    }
}
