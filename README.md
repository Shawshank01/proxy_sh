# proxy_sh

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE)

**No need** to use your own domain name ;-)  
This is an automated shell script that installs and manages Docker containers on GNU/Linux systems. It can be used to construct encrypted and obfuscated traffic proxy servers using Xray (VLESS-XHTTP-REALITY) and Shadowsocks (2022).
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

Run the installer from your regular login account with `sudo` access. It verifies the release signature and checksum before requesting administrative privileges. It installs the script under `/opt/proxy-sh` and puts the `proxy.sh` command in `/usr/local/bin`.

```bash
installer_url=https://raw.githubusercontent.com/Shawshank01/proxy_sh/33dc3443a54be36d6fd00455166036f9bddc6f97/install.sh
curl -q -fsSL --proto '=https' "$installer_url" | bash
proxy.sh
```

The release workflow fills in the installer commit above. Use the published README on GitHub for the pinned URL. To review the bootstrap before executing it, set `installer_url` to the URL above, then download and open the file.

```bash
curl -q -fsSL --proto '=https' "$installer_url" -o install.sh
less install.sh
```

Run `bash install.sh` after reviewing it. The installed command works from any directory. Use menu option **1** to set up Docker if needed, then **2** or **3** to configure your proxy. The launcher uses `sudo` for administration, and scheduled checks can run from the root-owned deployment. Re-running the installer preserves the installed version and deployment files. Use menu option **0** for a signed update.

### Migrate an existing deployment

1. Keep a backup and review the original Compose files, overrides, and `.env` before importing them into a root-owned deployment. For Xray quotas, note the existing schedule, disable it through menu **10 → 6**, and run a final check through **10 → 2**.
2. Run `sudo docker compose down` from each original service directory that you are moving. This stops those proxy services during the cutover.
3. Run `bash install.sh --migrate-from /path/to/old/deployment`. The directory you pass should contain `xray/` or `shadowsocks/`. The installer copies service files into `/opt/proxy-sh` and leaves the originals available for recovery.
4. Run `proxy.sh` and choose menu **6** to restore the services from their new paths. Reconfigure automatic quotas through **10 → 6** if needed.

### Release signing (for Fork)

The installer and self-updater verify a detached OpenSSL signature. For a fork, add the PEM-encoded private key as the repository Actions secret `RELEASE_PRIVATE_KEY`. Pin the matching public key in both `install.sh` and `proxy.sh`, and update their repository URLs. The **Update Release Artifacts** workflow checks the pinned keys, commits the checksum and signature together, and publishes the installer URL at a specific commit. If `main` moves during signing, rerun the workflow on `main`.

Protect `main` and review installer and workflow changes before publishing. A GitHub environment with approval requirements can restrict access to the signing key. The first downloaded bootstrap still runs on the trust you place in the pinned installer URL.

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
- **4) Update / Change version of existing container (Xray / Shadowsocks)**: Pulls and starts the latest container image, or pins/upgrades/downgrades to a specific version tag using Docker Compose. Updating to latest releases any version lock. For Xray, the target image validates the configuration, including any staged `finalRules` or `minClientVer` changes, before deployment. If startup or the readiness check fails, the script restores both configuration files and the previous container image.
- **5) Change Xray Reality target domain**: Re-runs the Reality target checks, updates the Tunnel destination while preserving users and keys, restarts the container, and updates saved VLESS links with the new SNI. On legacy configs, this also adds the loopback Tunnel. Failed restarts automatically roll back the previous configuration.
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
  - Configure automatic quota checks via the systemd daemon or cron (1/2/5-minute intervals)
  - Show automatic quota check configuration status (method and interval/schedule)
  - Change quota billing timezone
- **11) Manage users (Add/Remove for Xray / Shadowsocks)**:
  - Add Xray users without recreating existing users
  - Remove specific Xray users without affecting others
  - Add Shadowsocks users without recreating existing users
  - Remove a selected Shadowsocks user without affecting others
- **12) Exit**

## Recommended Clients

- **iOS / macOS** (US$ 2.99): [Shadowrocket](https://apps.apple.com/us/app/shadowrocket/id932747118)
- **Android**: [v2rayNG](https://github.com/2dust/v2rayNG)
- **Windows**: [Furious](https://github.com/LorenEteval/Furious)

Copy the `vless://` or `ss://` link and paste it into the client and enjoy!

> [!TIP]
> Some clients may require further configuration steps after pasting the link.

## Xray Configuration Details

- During installation, you can optionally enable built-in routing rules to block mainland China domains and IPs (`geosite:cn`, `geoip:cn`), or use lightweight direct routing to minimize memory usage on low-RAM VPS instances.
- **Freedom Outbound & `finalRules`**: Configured in compliance with Xray's `FinalRuleObject` specification. The `direct` outbound blocks port 25 (SMTP) to protect VPS IP reputation, applies `geoip:cn` at the socket egress layer when China rules are active, and includes an explicit `allow` fallback to prevent Xray's default safe policy from blocking legitimate proxy connections or loopback tunnels.
- The configuration uses the Reality protocol for obfuscation.
- Failed REALITY handshakes are sent to `127.0.0.1:10086`, where a loopback-only `tunnel` (`dokodemo-door`) inbound rewrites the connection to the selected target on its configured port.
- Tunnel routing allows only the configured Reality `serverNames` to use the `direct` outbound, every other fallback SNI is sent to `block`. Continue to choose a direct-origin, non-CDN Reality target. This protects the fallback path, but does not restrict destinations chosen by authenticated VLESS users.
- Xray per-user quota enforcement uses Xray user traffic stats (`StatsService`) and stores state in:
  - `xray/user_limits.conf` (timezone)
  - `xray/user_limits.db` (per-user limits, cycle window, and usage accumulator)
- Quota sync manages VLESS clients by UUID and preserves manual clients. When it suspends a managed client, it saves the full client entry in the quota database for reactivation. Quota counters use the database email. Configure user traffic stats for the managed client's Xray policy level and give each client a distinct email label.
- A user's monthly cycle can begin at account creation or on a configured calendar day. The billing date is clamped to the last day of shorter months.
- Usage is checkpointed before Xray restarts managed by this script. Each counter sample records the container and its start time, so a restart starts a fresh counter baseline. Traffic the old process never reported before an unexpected stop cannot be recovered.
- The quota daemon wakes at the next billing cutoff if it falls before the regular poll. Cron checks use their configured cadence. If a counter sample spans a cutoff, its unsplittable delta is counted in the closing cycle, which appears in the quota status.
- Quota timezones use installed IANA timezone names or whole-hour UTC offsets. If a billing time falls in a daylight-saving gap, it shifts forward by the size of the gap. If the time occurs twice, the first occurrence is used.
- Quota checks run when you execute menu option `10 -> 2` (recommended to automate with a systemd daemon on Ubuntu, or cron fallback, for timely suspension/re-enable). You can check the scheduler status using menu option `10 -> 7` or via CLI command `./proxy.sh --quota-check-status`.
- Scheduler status is read-only. To migrate a legacy timer or cron job, choose the scheduler through menu option `10 -> 6`. Press Enter at the interval prompt to keep the existing interval when the selected scheduler can represent it.
- Both schedulers run the root-owned copy at `/usr/local/lib/proxy-sh/quota-check.sh`. An admin-controlled deployment can run quota checks as root. For a user-owned deployment, the scheduler uses its owner, who needs access to the quota files and Docker without an interactive sudo prompt. Setup checks that `xray_server` uses the deployment's configuration before enabling the job.
- Explicit scheduler setup and verified script updates refresh the installed runner. Legacy jobs keep their existing configuration until you reconfigure them from the quota menu.
- All configuration files are created in a new `xray` directory relative to the script's location.

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

If per-user quota checking is automated via systemd, inspect the daemon logs:

- **View recent quota check logs:**

  ```bash
  sudo journalctl -u xray-quota-check.service -n 50 --no-pager
  ```

- **Follow live quota check daemon logs:**

  ```bash
  sudo journalctl -u xray-quota-check.service -f
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
2. Select **`4) Update / Change version of existing container`**.
3. Select **`2) Downgrade / Change container version`**.
4. Choose **`1) Xray`** and input the target version tag (e.g., `26.7.28`).

## Credits

- [Xray](https://github.com/XTLS/Xray-core) — The core proxy software.
- [Xray-examples](https://github.com/XTLS/Xray-examples) — Reference configurations and examples.
- [DeepWiki](https://deepwiki.com/XTLS/Xray-examples/2.3-vless-%2B-tcp-%2B-reality) — Solution for Traffic Theft Protection.
- [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) — Rust implementation for Shadowsocks 2022.
