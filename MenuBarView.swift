import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("wireguard-muti", image: "MenuBarIcon")
                    .font(.headline)
                Spacer()
                Text(menuStatus)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if model.vpnKind == nil {
                Text("Choose WireGuard in the main window")
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.needsToolsSetup {
                Text("Install \(VPNKind.wireguard.brewFormula) before connecting")
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.tunnels.isEmpty {
                Text("No tunnels yet")
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.tunnels) { tunnel in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(model.isEnabled(tunnel) ? Color.green : Color.secondary.opacity(0.35))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tunnel.displayName)
                            if model.isEnabled(tunnel) {
                                Text("↓ \(ByteFormat.rate(tunnel.rxRate))  ↑ \(ByteFormat.rate(tunnel.txRate))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(tunnel.config.isComplete ? tunnel.iface : "\(tunnel.iface) · no address/peer")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle(
                            "Connected",
                            isOn: model.connectionBinding(for: tunnel)
                        )
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            HStack {
                Button("Open") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Disconnect All") {
                    Task { await model.disconnectAll() }
                }
                .disabled(model.vpnKind != .wireguard || model.connectedCount == 0)
            }
            .padding(10)
        }
        .frame(width: 300)
    }

    private var menuStatus: String {
        if model.vpnKind == nil { return "Setup" }
        if model.needsToolsSetup { return "Tools missing" }
        return model.connectedCount == 0 ? "Idle" : "\(model.connectedCount) up"
    }
}
