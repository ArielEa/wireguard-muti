import SwiftUI
import AppKit

struct TunnelEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let tunnel: Tunnel
    @State private var name: String
    @State private var config: WireGuardConfig
    @State private var revealPrivateKey = false

    init(tunnel: Tunnel) {
        self.tunnel = tunnel
        _name = State(initialValue: tunnel.keyName)
        _config = State(initialValue: tunnel.config)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tunnel") {
                    TextField("Name", text: $name)
                    TextField("Address", text: $config.address, prompt: Text("10.8.0.2/32"))
                    TextField("DNS", text: $config.dns, prompt: Text("optional"))
                    TextField("Listen port", text: $config.listenPort, prompt: Text("optional"))
                    TextField("MTU", text: $config.mtu, prompt: Text("optional"))
                    HStack(alignment: .top) {
                        if revealPrivateKey {
                            TextField("Private key", text: $config.privateKey)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField("Private key", text: $config.privateKey)
                        }
                        Button(revealPrivateKey ? "Hide" : "Show") {
                            revealPrivateKey.toggle()
                        }
                        .controlSize(.small)
                    }
                }

                ForEach($config.peers) { $peer in
                    Section("Peer") {
                        TextField("Public key", text: $peer.publicKey)
                            .font(.system(.body, design: .monospaced))
                        TextField("Endpoint", text: $peer.endpoint, prompt: Text("host:51820"))
                        TextField("Allowed IPs", text: $peer.allowedIPs, prompt: Text("10.8.0.0/24"))
                        TextField("Preshared key", text: $peer.presharedKey)
                            .font(.system(.body, design: .monospaced))
                        TextField("Persistent keepalive", text: $peer.persistentKeepalive, prompt: Text("25"))
                        Button("Remove Peer", role: .destructive) {
                            config.peers.removeAll { $0.id == peer.id }
                        }
                    }
                }

                Section {
                    Button("Add Peer") {
                        config.peers.append(PeerConfig())
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 560, minHeight: 480)
            .navigationTitle("Edit \(tunnel.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.saveEditor(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                config: config,
                                original: tunnel
                            )
                            if model.lastError == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!nameIsValid)
                }
            }
        }
    }

    private var nameIsValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

struct NewTunnelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var name = ""
    @State private var privateKey = ""
    @State private var paste = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Method", selection: $tab) {
                    Text("Generate").tag(0)
                    Text("Existing keys").tag(1)
                    Text("Paste config").tag(2)
                }
                .pickerStyle(.segmented)

                TextField("Tunnel name", text: $name, prompt: Text("dev"))
                    .textFieldStyle(.roundedBorder)

                if tab == 1 {
                    SecureField("Private key", text: $privateKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Public key is derived with wg pubkey, same as wgshell exist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if tab == 2 {
                    TextEditor(text: $paste)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator)
                        )
                } else {
                    Text("Writes name-privatekey, name-publickey, and wgN.conf into /opt/homebrew/etc/wireguard. Add Address and a peer after that — several keys can be connected at once.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(20)
            .frame(width: 480, height: 360)
            .navigationTitle("New Tunnel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(!nameIsValid || (tab == 1 && privateKey.trimmingCharacters(in: .whitespaces).isEmpty) || (tab == 2 && paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }

    private var nameIsValid: Bool {
        name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    private func create() async {
        switch tab {
        case 1:
            await model.registerExisting(name: name, privateKey: privateKey)
        case 2:
            await model.importConfig(name: name, text: paste)
        default:
            await model.createGenerated(name: name)
        }
        if model.lastError == nil {
            model.showNewTunnel = false
            dismiss()
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("VPN") {
                if let kind = model.vpnKind {
                    HStack {
                        Image(kind.assetName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        LabeledContent("Current", value: kind.title)
                    }
                } else {
                    LabeledContent("Current", value: "Not chosen")
                }
                Button("Change VPN…") {
                    model.changeVPN()
                }
            }
            if model.vpnKind == .wireguard {
                Section("Helper") {
                    LabeledContent("Status") {
                        Text(model.helperInstalled ? "Installed" : "Not installed")
                            .foregroundStyle(model.helperInstalled ? .green : .orange)
                    }
                    LabeledContent("Path", value: PrivilegedRunner.installedHelperPath)
                    Button(model.isInstallingHelper ? "Installing…" : (model.helperInstalled ? "Reinstall Helper" : "Install Helper")) {
                        Task { await model.installHelper() }
                    }
                    .disabled(model.isInstallingHelper)
                }
                Section("WireGuard") {
                    LabeledContent("Tools") {
                        Text(model.localToolsAvailable ? "Found" : "Missing")
                            .foregroundStyle(model.localToolsAvailable ? .green : .red)
                    }
                    LabeledContent("wg", value: empty(model.wgPath))
                    LabeledContent("wg-quick", value: empty(model.wgQuickPath))
                    LabeledContent("Keys folder", value: WireGuardPaths.keysDirectory)
                    Button("Open Keys Folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: WireGuardPaths.keysDirectory))
                    }
                    if !model.localToolsAvailable {
                        Button(model.isInstallingTools ? "Installing…" : "Install wireguard-tools") {
                            Task { await model.installSelectedTools() }
                        }
                        .disabled(model.isInstallingTools || !model.brewAvailable)
                    }
                }
            }
            Section("About") {
                Text("First launch asks you to confirm WireGuard. Keys stay in /opt/homebrew/etc/wireguard, and several tunnels can stay up at once.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .padding()
    }

    private func empty(_ value: String) -> String {
        value.isEmpty ? "—" : value
    }
}
