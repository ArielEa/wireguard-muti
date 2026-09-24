import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.vpnKind == nil {
                VPNOnboardingView()
            } else if model.needsToolsSetup {
                VPNToolsSetupView()
            } else {
                ContentView()
            }
        }
    }
}

struct VPNOnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("Choose a VPN")
                    .font(.largeTitle.bold())
                Text("This app uses WireGuard. Confirm to continue. You can change this later in Settings.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VPNKindCard(kind: .wireguard, selected: true, action: {})
                .frame(maxWidth: 320)
                .allowsHitTesting(false)

            Button("Continue") {
                model.selectVPN(.wireguard)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct VPNKindCard: View {
    let kind: VPNKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(kind.assetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

                Text(kind.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))

                Text(kind.summary)
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct VPNToolsSetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(VPNKind.wireguard.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install \(VPNKind.wireguard.brewFormula)")
                        .font(.largeTitle.bold())
                    Text(statusLine)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("This Mac") {
                VStack(alignment: .leading, spacing: 10) {
                    labeled("Homebrew", model.brewAvailable ? (Homebrew.brewPath ?? "Found") : "Not installed")
                    labeled("Command-line tools", model.localToolsAvailable ? "Installed" : "Missing")
                    labeled("Needed for", VPNKind.wireguard.title)
                }
                .padding(.vertical, 4)
            }

            Text("WireGuard connections use the wg and wg-quick commands. Without them, this app cannot reach a server.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !model.toolsInstallLog.isEmpty {
                ScrollView {
                    Text(model.toolsInstallLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack {
                Button("Back") {
                    model.changeVPN()
                }
                Spacer()
                if !model.brewAvailable {
                    Button("Open brew.sh") {
                        if let url = URL(string: "https://brew.sh") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button(model.isInstallingTools ? "Installing…" : "Install \(VPNKind.wireguard.brewFormula)") {
                    Task { await model.installSelectedTools() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInstallingTools || !model.brewAvailable)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var statusLine: String {
        if model.isInstallingTools {
            return "Homebrew is installing. This can take a minute."
        }
        if !model.brewAvailable {
            return "Install Homebrew first, then this app can install the VPN tools."
        }
        return "This Mac does not have \(VPNKind.wireguard.brewFormula) yet. The app will install it with Homebrew."
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }
}
