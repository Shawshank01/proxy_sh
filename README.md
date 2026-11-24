# proxy_sh

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE)

**No need** to use your own domain name ;-)  
This shell script installs and manages Docker containers for Xray (VLESS-XHTTP-REALITY), Shadowsocks (2022), and Hysteria 2 on GNU/Linux.
> "These walls are funny. First you hate 'em, then you get used to 'em. Enough time passes, you get so you depend on 'em. That's institutionalized."

## Features

- **Automated Environment Check**: Installs Docker and Docker Compose if they are not present.
- **Wide Distro Support**: Works with Debian, Ubuntu, Fedora, CentOS, RHEL, and Linux Mint.
- **Interactive Installation**: Guides you through setting up an Xray VLESS-XHTTP-Reality proxy.
- **Xray Per-User Monthly Quotas**: Optional per-user GB limits with automatic suspension when a limit is reached.
- **Per-User Anniversary Billing Cycle**: Each user cycle starts from their account creation timestamp and rolls monthly (with end-of-month clamping).
- **Quota Management Menu**: Check/apply quotas, reset user usage, change user limits, and view automatic check scheduler status.
- **Shadowsocks (2022) Install**: Deploys ssserver-rust (2022-blake3-chacha20-poly1305) with multi-user support.
- **IPv6 Support**: Optional dual-stack listening for both Xray and Shadowsocks.
- **REALITY Fallback Hardening**: Routes failed REALITY handshakes through a loopback-only Xray Tunnel (`dokodemo-door`) with a fixed destination.
- **Outbound Safety & `finalRules`**: Complies with Xray's `FinalRuleObject` on the Freedom outbound, blocking SMTP port 25 to prevent abuse, enforcing socket-level IP blocks, and guaranteeing safe fallback and API tunnel access.
- **Secure Key Generation**: Automatically generates a private/public key pair (`x25519`) and UUIDs for the configuration.
- **VLESS Link Generation**: Creates and saves shareable VLESS links based on your server settings.
- **Container Management**: Easy-to-use menu for updating, changing/downgrading versions, viewing links, or deleting containers and configurations.
- **Self-Updating**: The script automatically checks for a new version on startup (interactive mode) and can also be updated manually from the menu.

## Usage

### Install on GNU/Linux

Run this command from your regular login account with `sudo` access.

```bash
curl -fsSL https://raw.githubusercontent.com/Shawshank01/proxy_sh/e288a923a58a66d158e89ec7f17127c900348551/install.sh | bash
```

The installer verifies the release signature and checksum before requesting `sudo`. It installs the script under `/opt/proxy-sh` and opens the menu when run from a terminal. To open it again, run `proxy.sh` from any directory.

## Menu Options

- **0) Update this script**: Checks for a new version on GitHub and updates itself.
- **1) Environment Check**: Verifies the Linux distribution and installs Docker and Docker Compose if needed. Run this first if you are on a new server.
- **2) Install Proxy Server**
  1. **Xray (VLESS-XHTTP-Reality)**. Generates user UUIDs and IDs, a shared server `shortId`, and optional monthly quotas. Starts Xray and saves `vless://` links to `xray/vless_links.txt`.
  2. **Hysteria 2**. Deploys `tobyxdd/hysteria` with multi-user credentials and saves client links to `hysteria/hysteria_links.txt`. Supports self-signed or Let's Encrypt (ACME) certificates for domains and public IPs, optional ECH and obfuscation (Salamander or experimental Gecko), Brutal bandwidth limits, and default Mainland China GeoSite/GeoIP blocking (customizable in `hysteria/config/hysteria.yaml`).
  3. **Shadowsocks (ss-2022)**. Sets up a multi-user Shadowsocks 2022 server on the selected port and saves `ss://` links to `shadowsocks/ss_links.txt`.
- **3) Update / Change version of existing container**. Update Xray, Hysteria 2, or Shadowsocks to the latest Docker image or select a version tag. Updating to latest releases any version lock. For Xray, the target image validates the existing server configuration before deployment. If startup or the readiness check fails, the script restores the previous Compose file and container image. **Update Hysteria 2 geodata** refreshes the managed XTLS lists, saves current quota usage before restarting a running container, and restores the previous lists if startup fails.
  - **Change Hysteria 2 bandwidth limits** edits the server’s per-client Brutal limits in Mbps. Press Enter to keep the current value for either direction. Server upload caps client download, and server download caps client upload. The script saves quota usage before restarting a running container and restores the previous config if startup fails.
- **4) Change Xray Reality target domain**. Re-runs the Reality target checks, updates the Tunnel destination while preserving users and keys, restarts the container, and updates saved VLESS links with the new SNI. Failed restarts automatically roll back the previous configuration.
- **5) Restore deployment from existing config**. Recreates and starts containers from existing config directories.
- **6) Show proxy links**. Select Xray, Hysteria 2, or Shadowsocks to display its saved client links.
- **7) Show proxy usage / Manage quotas**
  - Show current and previous billing cycle usage, limits, and account state for Xray and Hysteria 2. Hysteria 2 shows lifetime upload, download, and total in GB on a separate line under each user's quota.
  - Check/apply quota suspension and automatic re-enable on next user cycle
  - Reset one user's current-cycle usage
  - Change one user's monthly limit
  - Change one user's billing cycle dates
  - Configure automatic quota checks via the systemd daemon or cron (1/2/5-minute intervals)
  - Show automatic quota check configuration status (method and interval/schedule)
  - Change quota billing timezone
- **8) Manage users (Add/Remove for Xray / Shadowsocks / Hysteria 2)**
  - Add Xray users without recreating existing users
  - Remove specific Xray users without affecting others
  - Add Shadowsocks users without recreating existing users
  - Remove a selected Shadowsocks user without affecting others
  - Add a Hysteria 2 user with a generated password, saved client link, and optional monthly limit
  - Remove a Hysteria 2 user and revoke their credentials. If they are connected, the script restarts Hysteria 2 to end their session, briefly disconnecting other users.
- **9) Delete container and config**. Stops the selected Docker container and deletes the corresponding config directory and link files.
- **10) Exit**

## Recommended Clients

- **iOS / macOS** (US$ 2.99): [Shadowrocket](https://apps.apple.com/us/app/shadowrocket/id932747118)
- **Android**: [v2rayNG](https://github.com/2dust/v2rayNG)
- **Windows**: [Furious](https://github.com/LorenEteval/Furious)

Import the saved link in a client that supports its protocol.

## Xray Target Domain

>[!CAUTION]
> **Do NOT use CDN or SaaS domains**: Avoid using any domains hosted by major CDN providers (such as **Akamai**, **Fastly**, **Amazon CloudFront**, **Cloudflare**, **EdgeCast** / Edge networks) or SaaS platforms with built-in enterprise-grade CDNs (such as **Shopify**, **Wix**, **Squarespace**, **Vercel**, **Netlify**, and **GitHub Pages**). Using CDN or SaaS-backed targets makes your server vulnerable to REALITY fallback bandwidth leeching and traffic hijacking. You can read this [blog](https://zaku.eu.org/blog/2026-04-25-everyone-should-start-using-a-vpn-or-proxy/#xray) for more setup guidance.

- **Reality target & server names**:

  - The generated `realitySettings.target` is the loopback Tunnel endpoint. The external fallback destination (`rewriteAddress`/`rewritePort` in the `reality-fallback` Tunnel) must be a real website outside the GFW that serves TLS 1.3 + HTTP/2 directly (no forced redirects). Pick a direct origin website that makes sense for your server location; e.g., `dl.google.com` or `swdist.apple.com`.

  - You can manually check the chosen domain by using:

      ```bash
      curl -I --http2 "https://<target-domain>"
      sudo docker run --rm ghcr.io/xtls/xray-core:latest tls ping <target-domain>
      ```

    - **Domain validation**: The script automatically checks:
      - ✓ **TLSv1.3**: Verifies the target supports TLS 1.3 (required for Reality)
      - ✓ **HTTP/2**: Checks for H2 support (recommended for best performance)
      - ✗ **Chinese domains**: Warns if the domain is `.cn`, `.com.cn`, or a known Chinese site (Baidu, QQ, Taobao, etc.)
      - ✗ **Microsoft domains**: Blocks Microsoft-related domains (e.g., `microsoft.com`, `azure.com`, `office.com`, `bing.com`) as they are rejected for Reality target / SNI
      - ✗ **Connection errors**: Detects timeouts or connection failures

  - Wildcards from the certificate are ignored (not supported by Xray). If only wildcards are present, the script will ask you for concrete hostnames.

> [!TIP]
> Remember to open **443 (TCP & UDP)** for Xray and the configured Shadowsocks listening port (TCP & UDP) in your server's firewall.

## Troubleshooting

### 1. Checking Container Logs

If you cannot establish a proxy connection or services fail to start, check the Docker container logs:

- **View recent Xray logs:**

  ```bash
  sudo docker logs --tail 100 xray_server
  ```

- **Follow live Xray logs in real-time:**

  ```bash
  sudo docker logs -f xray_server
  ```
  
- **View Shadowsocks logs:**

  ```bash
  sudo docker logs --tail 100 ssserver
  ```

  ```bash
  sudo docker logs -f ssserver
  ```

- **View logs via Docker Compose:**

  ```bash
  cd xray && sudo docker compose logs -f
  ```
  
  ```bash
  cd shadowsocks && sudo docker compose logs -f
  ```

### 2. Checking Automatic Quota Check Logs

The systemd quota service is named `proxy-quota-check.service`.

- **View recent quota check logs:**

  ```bash
  sudo journalctl -u proxy-quota-check.service -n 50 --no-pager
  ```

- **Follow live quota check daemon logs:**

  ```bash
  sudo journalctl -u proxy-quota-check.service -f
  ```

### 3. Validating Xray Configuration

Test `xray/server.jsonc` syntax and schema compatibility without stopping your running container:

```bash
sudo docker run --rm -v "$(pwd)/xray/server.jsonc:/etc/xray/config.json:ro" ghcr.io/xtls/xray-core:latest run -test -c /etc/xray/config.json
```

### 4. Checking Port & Listening Status

Verify that Xray (port 443) or Shadowsocks ports are actively listening on host interfaces:

```bash
sudo ss -tulpn | grep -E ':(443|80)\b'
```

### 5. Rolling Back / Changing Core Version

If a newly released upstream Xray version introduces regressions or protocol handshake issues, you can pin or downgrade to a proven stable version (such as `26.7.28`):

1. Run `./proxy.sh`.
2. Select **`3) Update / Change version of existing container`**.
3. Select **`2) Downgrade / Change container version`**.
4. Choose **`1) Xray`** and input the target version tag (e.g., `26.7.28`).

## Credits

- [Xray](https://github.com/XTLS/Xray-core) — The core proxy software.
- [Xray-examples](https://github.com/XTLS/Xray-examples) — Reference configurations and examples.
- [DeepWiki](https://deepwiki.com/XTLS/Xray-examples/2.3-vless-%2B-tcp-%2B-reality) — Solution for Traffic Theft Protection.
- [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) — Rust implementation for Shadowsocks 2022.
