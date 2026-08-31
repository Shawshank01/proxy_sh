# proxy_sh

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE)

**No need** to use your own domain name ;-)  
This is an automated shell script that installs and manages Docker containers on GNU/Linux systems. GNU `date` and `stat` are required. It can be used to construct encrypted and obfuscated traffic proxy servers using Xray (VLESS-XHTTP-REALITY) and Shadowsocks (2022).
Supports IPv6.  
For the freedom of the internet!

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
- **Secure Key Generation**: Automatically generates a private/public key pair (`x25519`) and UUIDs for the configuration.
- **VLESS Link Generation**: Creates and saves shareable VLESS links based on your server settings.
- **Container Management**: Easy-to-use menu for updating, changing/downgrading versions, viewing links, or deleting containers and configurations.
- **Self-Updating**: The script automatically checks for a new version on startup (interactive mode) and can also be updated manually from the menu.

## Usage

1. **Download and execute the script:**

    ```bash
    wget https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh && chmod +x proxy.sh
    ```

2. **Run the script:**

    ```bash
    ./proxy.sh
    ```

    The script will request `sudo` permissions only when necessary.

3. **Choose an option from the menu.**

### Release signing (for Fork)

Self-updates verify a detached OpenSSL signature before replacing the script. For a fork, add the PEM-encoded private key once as the repository Actions secret `RELEASE_PRIVATE_KEY`. The matching public key is pinned in `proxy.sh`, and the GitHub Actions workflow automatically regenerates `proxy.sh.sha256` and signs each pushed `proxy.sh` as `proxy.sh.sig`.
Using Actions to automate the signing process means you fully trust GitHub hosting, Actions runners, and secret handling, and you must keep strict control of your GitHub account and repository protections.

## Menu Options

- **0) Update this script**: Checks for a new version on GitHub and updates itself.
- **1) Environment Check**: Verifies the Linux distribution and installs Docker and Docker Compose if needed. Run this first if you are on a new server.
- **2) Install Xray (VLESS-XHTTP-Reality)**: The main installation process. It will:
  - Ask for the number of users and generate a shared server `shortId`.
  - Generate a random UUID and user ID for each user, then prompt for an optional monthly GB limit.
  - Generate `docker-compose.yml`, `server.jsonc`, `user_limits.conf`, and `user_limits.db` in `xray/`.
  - Ask for your server's IP/domain and a remarks name to generate VLESS links.
  - Save the `vless://` links to `xray/vless_links.txt`.
  - Start the Xray container.
- **3) Install Shadowsocks (ssserver-rust)**: Sets up a multi-user Shadowsocks 2022 server. It will:
  - Ask for the number of users and the listening port.
  - Generate `docker-compose.yml` and `server.json` in a new `shadowsocks/` directory.
  - Start the container and save `ss://` links to `shadowsocks/ss_links.txt`.
- **4) Update / Change version of existing container (Xray / Shadowsocks)**: Pulls and starts the latest container image, or pins/upgrades/downgrades to a specific version tag using Docker Compose. Version locks are released automatically when updating to latest.
- **5) Change Xray Reality target domain**: Re-runs the strict Reality target validation, updates the Tunnel destination while preserving users and keys, restarts the container, and updates saved VLESS links with the new SNI. On legacy configs, this also adds the loopback Tunnel. Failed restarts automatically roll back the previous configuration.
- **6) Restore deployment from existing config**: Recreates and starts containers from existing config directories.
- **7) Show VLESS links for current config**: Displays the contents of `xray/vless_links.txt`.
- **8) Show SS links for current config**: Displays the contents of `shadowsocks/ss_links.txt`.
- **9) Delete container and config (Xray or Shadowsocks)**: Stops the selected Docker container, and deletes the corresponding config directory and link files.
- **10) Manage Xray per-user data quotas**:
  - Show quota status
  - Check/apply quota suspension and automatic re-enable on next user cycle
  - Reset one user's current-cycle usage
  - Change one user's monthly limit
  - Change one user's billing cycle dates
  - Configure automatic quota checks via systemd timer (recommended for mainstream distributions) or cron fallback (1/2/5-minute intervals)
  - Show automatic quota check configuration status (method and interval/schedule)
  - Change quota billing timezone
- **11) Manage users (Add/Remove for Xray / Shadowsocks)**:
  - Add Xray users without recreating existing users
  - Remove specific Xray users without affecting others
  - Add Shadowsocks users without recreating existing users - Remove specific Shadowsocks users without affecting others
- **12) Exit**

## Recommended Clients

- **iOS / macOS** (US$ 2.99): [Shadowrocket](https://apps.apple.com/us/app/shadowrocket/id932747118)
- **Android**: [v2rayNG](https://github.com/2dust/v2rayNG)
- **Windows**: [Furious](https://github.com/LorenEteval/Furious)

Copy the `vless://` or `ss://` link and paste it into the client and enjoy!

> [!TIP]
> Some clients may require further configuration steps after pasting the link.

## Xray Configuration Details

> [!IMPORTANT]
> Temporary Compatibility Note (Xray Core):
> If your client app fails to connect with the latest Xray version, use **Option 4** in the script menu to change/downgrade the Xray container version tag to `26.6.27` until the client application updates.

- The generated `server.jsonc` **blocks all China (CN) IPs and domains** by default using Xray's routing rules.
- The configuration uses the Reality protocol for obfuscation.
- Failed REALITY handshakes are sent to `127.0.0.1:10086`, where a loopback-only `tunnel` (`dokodemo-door`) inbound rewrites the connection to the selected target on its configured port.
- Tunnel routing allows only the configured Reality `serverNames` to use the `direct` outbound, every other fallback SNI is sent to `block`. Continue to choose a direct-origin, non-CDN Reality target. This protects the fallback path, but does not restrict destinations chosen by authenticated VLESS users.
- Xray per-user quota enforcement uses Xray user traffic stats (`StatsService`) and stores state in:
  - `xray/user_limits.conf` (timezone)
  - `xray/user_limits.db` (per-user limits, cycle window, and usage accumulator)
- Billing cycle is per-user **anniversary monthly** (from account creation timestamp to next month same local time, clamped to month-end when needed).
- Quota checks run when you execute menu option `9 -> 2` (recommended to automate with a systemd timer on Ubuntu, or cron fallback, for timely suspension/re-enable). You can check the scheduler status using menu option `9 -> 7` or via CLI command `./proxy.sh --quota-check-status`.
- All configuration files are created in a new `xray` directory relative to the script's location.

>[!CAUTION]
> **Do NOT use CDN or SaaS domains**: Avoid using any domains hosted by major CDN providers (such as **Akamai**, **Fastly**, **Amazon CloudFront**, **Cloudflare**, **EdgeCast** / Edge networks) or SaaS platforms with built-in enterprise-grade CDNs (such as **Shopify**, **Wix**, **Squarespace**, **Vercel**, **Netlify**, and **GitHub Pages**). Using CDN or SaaS-backed targets makes your server vulnerable to REALITY fallback bandwidth leeching and traffic hijacking. You can read this [blog](https://zaku.eu.org/blog/2026-04-25-everyone-should-start-using-a-vpn-or-proxy/) for more setup guidance.

- **Reality target & server names**:

  - The generated `realitySettings.target` is the loopback Tunnel endpoint. The external fallback destination (`rewriteAddress`/`rewritePort` in the `reality-fallback` Tunnel) must be a real website outside the GFW that serves TLS 1.3 + HTTP/2 directly (no forced redirects). Pick a direct origin website that makes sense for your server location; e.g., `dl.google.com` or `swdist.apple.com`.

  - You can manually check the chosen domain by using:

      ```bash
      curl -I --http2 "https://<target-domain>"
      sudo docker run --rm teddysun/xray:latest xray tls ping <target-domain>
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

## Credits

- [Xray](https://github.com/XTLS/Xray-core) — The core proxy software.
- [Xray-examples](https://github.com/XTLS/Xray-examples) — Reference configurations and examples.
- [DeepWiki](https://deepwiki.com/XTLS/Xray-examples/2.3-vless-%2B-tcp-%2B-reality) - Solution for Traffic Theft Protection.
- [teddysun/xray](https://hub.docker.com/r/teddysun/xray) — The Docker image used by this script.
- [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) — Rust implementation for Shadowsocks 2022.

Special thanks to them for their excellent work!

## License

This project is licensed under the GNU General Public License v2.0 only, see the [LICENSE](LICENSE) file for details.
