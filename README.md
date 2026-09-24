# wireguard-muti

**wireguard-muti** is a macOS WireGuard client that can keep **several tunnels connected at the same time**.

Download the Mac app from:

[https://security.arielaia.com/#/intro/wgmu](https://security.arielaia.com/#/intro/wgmu)

The current package is **wgmu-1.1.zip**. Unzip it, then open `wireguard-muti.app`.

**WireGuard** is the VPN protocol this app uses: [https://www.wireguard.com/](https://www.wireguard.com/)

The official WireGuard app on Mac only allows one tunnel. This app talks to Homebrew `wg` / `wg-quick` instead, so each config becomes its own `utun` interface and more than one can stay up.

Keys and configs live in the same place as `wgshell`:

`/opt/homebrew/etc/wireguard`

## What it does

- First launch asks you to confirm **WireGuard** (with the WireGuard icon)
- Checks this Mac for `wireguard-tools`. If `wg` and `wg-quick` are missing, it can install them with Homebrew
- Installs a one-time administrator helper so start/stop does not ask for a password every time
- Lists every `wgN.conf` / key pair, start and stop each one, or connect/disconnect all
- Create a new key, import a `.conf`, edit Address / DNS / peers, or drop a config onto the window
- Menu bar extra with live rates while a tunnel is up
- Warns if two connected tunnels both claim `0.0.0.0/0`

A tunnel that only has a private key can still be started. Traffic flows after you add an Address and a `[Peer]` with PublicKey and AllowedIPs.

## Requirements

- macOS 14 or later
- [Homebrew](https://brew.sh)
- [wireguard-tools](https://formulae.brew.sh/formula/wireguard-tools) (`brew install wireguard-tools`)

The app is unsandboxed on purpose: it needs to call `wg-quick` and install the helper at `/Library/PrivilegedHelperTools/wgmulti-helper`.

This Mac GUI is **not** a substitute for those command-line tools. Without `wg` and `wg-quick`, it cannot reach a server. The App Store WireGuard app is also not a substitute; this client does not talk to that GUI.

## First run

1. Open **wireguard-muti**.
2. Confirm WireGuard and continue.
3. If tools are missing, use **Install wireguard-tools** (needs Homebrew).
4. Install the helper when the banner asks (one administrator prompt).
5. Add or import a tunnel, then use the switch to connect.

Change the confirmed VPN later in **Settings**.


## Local network

Turning a tunnel on or off does not change the Mac’s Wi-Fi or LAN address. Same-subnet devices usually stay reachable.

Internet routing and DNS **can** change, depending on the config:

- `AllowedIPs` for a tunnel subnet only (for example `10.8.0.0/24`) leaves the LAN alone
- `AllowedIPs = 0.0.0.0/0` sends internet through the tunnel
- `AllowedIPs` that overlap your LAN can capture local traffic
- `DNS =` in the conf is applied to the Mac’s network service by `wg-quick`
