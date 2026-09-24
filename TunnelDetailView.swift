import SwiftUI
import AppKit

struct TunnelDetailView: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel
    @Binding var pendingDelete: Tunnel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !tunnel.config.isComplete && !tunnel.isUp {
                    incompleteHint
                }
                stats
                interfaceCard
                peersCard
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Edit") {
                    model.editingTunnel = tunnel
                    model.showEditor = true
                }
                Button("Delete", role: .destructive) {
                    pendingDelete = tunnel
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tunnel.displayName)
                    .font(.largeTitle.bold())
                HStack(spacing: 8) {
                    Label(tunnel.iface, systemImage: "cable.connector")
                    if let live = tunnel.runtime?.liveInterface {
                        Text("·")
                        Label(live, systemImage: "network")
                    }
                    if let port = tunnel.runtime?.listenPort, !port.isEmpty, port != "0" {
                        Text(":\(port)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Toggle(
                    model.isEnabled(tunnel) ? "Connected" : "Disconnected",
                    isOn: model.connectionBinding(for: tunnel)
                )
                .toggleStyle(.switch)
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(tunnel.isUp ? Color.green : Color.secondary)
            }
        }
    }

    private var statusCaption: String {
        if model.busyIDs.contains(tunnel.id) { return model.isEnabled(tunnel) ? "Starting…" : "Stopping…" }
        if model.isEnabled(tunnel) { return "Up · handshake \(ByteFormat.ago(tunnel.runtime?.latestHandshake))" }
        if !tunnel.config.isComplete { return "No Address or peer yet — the interface can still start" }
        return "Ready to connect"
    }

    private var incompleteHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
            Text("This file only has a private key. You can still start it. Add Address and a [Peer] with Edit if you need traffic to flow.")
                .font(.callout)
            Spacer(minLength: 0)
            Button("Edit") {
                model.editingTunnel = tunnel
                model.showEditor = true
            }
        }
        .padding(12)
        .foregroundStyle(Color(nsColor: .labelColor))
        .background(Color.yellow.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var stats: some View {
        HStack(spacing: 12) {
            StatCard(title: "Received", value: ByteFormat.bytes(tunnel.runtime?.rx ?? 0), detail: ByteFormat.rate(tunnel.rxRate), systemImage: "arrow.down")
            StatCard(title: "Sent", value: ByteFormat.bytes(tunnel.runtime?.tx ?? 0), detail: ByteFormat.rate(tunnel.txRate), systemImage: "arrow.up")
            StatCard(title: "Handshake", value: ByteFormat.ago(tunnel.runtime?.latestHandshake), detail: tunnel.runtime?.endpoint ?? tunnel.config.primaryEndpoint, systemImage: "clock")
        }
    }

    private var interfaceCard: some View {
        GroupBox("Interface") {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "Address", value: empty(tunnel.config.address))
                InfoRow(label: "DNS", value: empty(tunnel.config.dns))
                InfoRow(label: "Listen port", value: empty(tunnel.config.listenPort.isEmpty ? tunnel.runtime?.listenPort : tunnel.config.listenPort))
                InfoRow(label: "MTU", value: empty(tunnel.config.mtu))
                if let pub = tunnel.runtime?.publicKey, !pub.isEmpty {
                    InfoRow(label: "Public key", value: pub, monospaced: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var peersCard: some View {
        GroupBox("Peers") {
            if tunnel.config.peers.isEmpty {
                Text("No peers yet. Edit this tunnel to add a server.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(tunnel.config.peers.enumerated()), id: \.element.id) { index, peer in
                        let live = livePeer(for: peer)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Peer \(index + 1)")
                                .font(.headline)
                            InfoRow(label: "Public key", value: empty(peer.publicKey), monospaced: true)
                            InfoRow(label: "Endpoint", value: empty(live?.endpoint ?? peer.endpoint))
                            InfoRow(label: "Allowed IPs", value: empty(peer.allowedIPs))
                            if !peer.persistentKeepalive.isEmpty {
                                InfoRow(label: "Keepalive", value: "\(peer.persistentKeepalive)s")
                            }
                            if let live {
                                InfoRow(label: "Handshake", value: ByteFormat.ago(live.handshake))
                                InfoRow(label: "Transfer", value: "↓ \(ByteFormat.bytes(live.rx))   ↑ \(ByteFormat.bytes(live.tx))")
                            }
                        }
                        if index < tunnel.config.peers.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func livePeer(for peer: PeerConfig) -> PeerRuntime? {
        tunnel.runtime?.peers.first { $0.publicKey == peer.publicKey }
    }

    private func empty(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "—" : trimmed
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.monospacedDigit())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
