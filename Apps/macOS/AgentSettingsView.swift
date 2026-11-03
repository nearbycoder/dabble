import AppKit
import DabbleKit
import SwiftUI

/// Setting up AI agents (Claude, Cursor, scripts…) to work with your to-dos
/// through the bundled `dabble` command-line tool and its MCP server.
struct AgentSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var client = AgentClient.claudeCode
    @State private var revealKey = false

    enum AgentClient: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case claudeDesktop = "Claude Desktop"
        case other = "Other MCP apps"
        var id: Self { self }
    }

    /// The CLI inside this app bundle.
    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dabble").path
    }

    private var isTranslocated: Bool {
        cliPath.contains("/AppTranslocation/") || !cliPath.hasPrefix("/Applications/")
    }

    var body: some View {
        let sync = model.sync
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Let AI agents work with your to-dos", systemImage: "sparkles")
                        .font(.headline)
                    Text("The **dabble** command-line tool lets Claude, Cursor or your own scripts read, add, schedule, complete and organize anything you can in the app. It joins your sync group as its own device, so there's still no server. Changes show up here within a second or two.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("1 · Install the command-line tool") {
                if isTranslocated {
                    Label("Move Dabble to your Applications folder first, then come back here.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                CommandRow(command: "sudo mkdir -p /usr/local/bin && sudo ln -sf '\(cliPath)' /usr/local/bin/dabble", note: "Run this in Terminal. It links the tool that ships inside Dabble, so it updates with the app.")
            }

            Section("2 · Connect it to your to-dos") {
                if let key = sync.syncKey {
                    let server = sync.serverURL.map { " --server \($0.absoluteString)" } ?? ""
                    CommandRow(command: "dabble join \(revealKey ? key : "DBL1-••••••••")\(server)",
                               copyText: "dabble join \(key)\(server)",
                               note: "Includes your sync key, which gives full access to your to-dos. Run it only on your own computer.")
                    Toggle("Show key", isOn: $revealKey)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                } else {
                    HStack {
                        Text("Agents join your sync group, so you need one first.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Set Up Sync") { sync.createGroupIfNeeded() }
                    }
                }
            }

            Section("3 · Add it to your agent") {
                Picker("App", selection: $client) {
                    ForEach(AgentClient.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch client {
                case .claudeCode:
                    CommandRow(command: "claude plugin marketplace add nearbycoder/dabble && claude plugin install dabble@dabble",
                               note: "Installs the Dabble plugin: the MCP server plus a skill that teaches Claude how Dabble works.")
                    CommandRow(command: "claude mcp add --scope user dabble -- dabble mcp", note: "Or just the MCP server.")
                case .claudeDesktop:
                    CommandRow(command: Self.mcpJSON(command: "/usr/local/bin/dabble"),
                               note: "Add this to ~/Library/Application Support/Claude/claude_desktop_config.json (Settings → Developer → Edit Config), then restart Claude.")
                case .other:
                    CommandRow(command: Self.mcpJSON(command: "/usr/local/bin/dabble"),
                               note: "Most MCP apps (Cursor, Windsurf, Zed, VS Code…) take this stdio server config.")
                    CommandRow(command: "dabble skill install --dir ~/.claude/skills", note: "Installs the Agent Skill (SKILL.md). Point --dir at your agent's skills folder.")
                }
            }

            Section("Agents on your devices") {
                let agents = sync.peers.filter { $0.platform == "Agent" }
                if agents.isEmpty {
                    Text("No agents have joined yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(agents) { agent in
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        Text(agent.name)
                        Spacer()
                        Text(agent.isConnected ? "Connected" : agent.lastSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not connected")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Button("Forget") { sync.forget(peer: agent.id) }
                            .buttonStyle(.borderless)
                    }
                }
                Text("Try asking: “What's on my plate today?”, “Plan my week from my Anytime list” or “Turn these meeting notes into to-dos in the Launch project.”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
    }

    static func mcpJSON(command: String) -> String {
        """
        {
          "mcpServers": {
            "dabble": { "command": "\(command)", "args": ["mcp"] }
          }
        }
        """
    }
}

/// A command in monospace with a copy button.
private struct CommandRow: View {
    let command: String
    var copyText: String?
    var note: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText ?? command, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
