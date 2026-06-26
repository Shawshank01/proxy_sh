# proxy_sh

**No need** to use your own domain name ;-)  
This is an automated shell script that effortlessly installs and manages Docker containers on GNU/Linux systems. It can be used to construct encrypted and obfuscated traffic proxy servers using Xray (VLESS-XHTTP-REALITY) and Shadowsocks (2022).  
Supports IPv6.  
For the freedom of the internet!

## Features
- **Automated Environment Check**: Installs Docker and Docker Compose if they are not present.
- **Wide Distro Support**: Works with Debian, Ubuntu, Fedora, CentOS, RHEL, and Linux Mint.
- **Interactive Installation**: Guides you through setting up an Xray VLESS-XHTTP-Reality proxy.
- **Xray Per-User Monthly Quotas**: Optional per-user MB limits with automatic suspension when a limit is reached.
- **Per-User Anniversary Billing Cycle**: Each user cycle starts from their account creation timestamp and rolls monthly (with end-of-month clamping).
- **Quota Management Menu**: Check/apply quotas, reset user usage, and change user limits later without recreating users.
- **Shadowsocks (2022) Install**: Deploys ssserver-rust (2022-blake3-chacha20-poly1305) with multi-user support.
- **IPv6 Support**: Optional dual-stack listening for both Xray and Shadowsocks.
- **Secure Key Generation**: Automatically generates a private/public key pair (`x25519`) and UUIDs for the configuration.
- **VLESS Link Generation**: Creates and saves shareable VLESS links based on your server settings.
- **Container Management**: Easy-to-use menu for updating, viewing links, or deleting the Xray container and its configuration.
- **Self-Updating**: The script can manually check for and pull the latest version of itself from GitHub.

## Usage

1.  **Download and execute the script:**
    ```bash
    wget https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh
    chmod +x proxy.sh
    ```

2.  **Run the script:**
    ```bash
    ./proxy.sh
    ```
    The script will request `sudo` permissions only when necessary.

3.  **Choose an option from the menu.**

## Root User Handling

This script is designed to run as a **non-root** user.

- If you run it as `root`, it will warn and offer to help you create or reuse a non-root account.
- If you accept, it can:
  - create the user (if needed),
  - prompt for that user's password,
  - add the user to `sudo` (or `wheel`) group when available,
  - relaunch the script as that non-root user automatically.
- If you decline, the script exits.

## Menu Options

-   **0) Update this script**: Checks for a new version on GitHub and updates itself.
-   **1) Environment Check**: Verifies the Linux distribution and installs Docker and Docker Compose if needed. Run this first if you are on a new server.
-   **2) Install Xray (VLESS-XHTTP-Reality)**: The main installation process. It will:
    -   Ask for the number of users and `shortIds`.
    -   Prompt for each user's label/email and optional monthly MB limit.
    -   Generate `docker-compose.yml`, `server.jsonc`, `user_limits.conf`, and `user_limits.db` in `xray/`.
    -   Ask for your server's IP/domain and a remarks name to generate VLESS links.
    -   Save the `vless://` links to `xray/vless_links.txt`.
    -   Start the Xray container.
-   **3) Install Shadowsocks (ssserver-rust)**: Sets up a multi-user Shadowsocks 2022 server. It will:
    -   Ask for the number of users and the listening port.
    -   Generate `docker-compose.yml` and `server.json` in a new `shadowsocks/` directory.
    -   Start the container and save `ss://` links to `shadowsocks/ss_links.txt`.
-   **4) Update existing container (Xray or Shadowsocks)**: Pulls the latest Docker image and restarts the selected container using Watchtower.
-   **5) Restore deployment from existing config**: Recreates and starts containers from existing config directories.
-   **6) Show VLESS links for current config**: Displays the contents of `xray/vless_links.txt`.
-   **7) Show SS links for current config**: Displays the contents of `shadowsocks/ss_links.txt`.
-   **8) Delete container and config (Xray or Shadowsocks)**: Stops the selected Docker container, and deletes the corresponding config directory and link files.
-   **9) Manage Xray per-user data quotas**:
    -   Show quota status
    -   Check/apply quota suspension and automatic re-enable on next user cycle
    -   Reset one user's current-cycle usage
    -   Change one user's monthly limit
-   **10) Exit**

## Recommended Clients

- **iOS / macOS**: [Shadowrocket](https://apps.apple.com/us/app/shadowrocket/id932747118)
- **Android**: [v2rayNG](https://github.com/2dust/v2rayNG), [v2RayTun](https://v2raytun.com)
- **Windows**: [v2rayN](https://github.com/2dust/v2rayN)

Just copy the vless:/ss: link and paste it into the client and enjoy!

## Configuration Details
- The generated `server.jsonc` **blocks all China (CN) IPs and domains** by default using Xray's routing rules.
- The configuration uses the Reality protocol for obfuscation.
- Xray per-user quota enforcement uses Xray user traffic stats (`StatsService`) and stores state in:
  - `xray/user_limits.conf` (timezone)
  - `xray/user_limits.db` (per-user limits, cycle window, and usage accumulator)
- Billing cycle is per-user **anniversary monthly** (from account creation timestamp to next month same local time, clamped to month-end when needed).
- Quota checks run when you execute menu option `9 -> 2` (recommended to automate with cron for timely suspension/re-enable).
- All configuration files are created in a new `xray` directory relative to the script's location.
- **Reality target & server names**:
    - Reality replaces a traditional TLS front, so the `target` (`realitySettings.target`) must be a real website outside the GFW that serves TLS 1.3 + HTTP/2 directly (no forced redirects). Pick one that makes sense for your server location; e.g., a Korean site if your VPS is in South Korea so packet routes look natural.  
    Example: `zum.com, www.ssg.com, www.jype.com`  
    - The installer probes your chosen domain with:
      ```bash
      sudo docker run --rm teddysun/xray:latest xray tls ping <target-domain>
      ```
      and uses the result to fill `target` and `serverNames` automatically.
    - **Domain validation**: The script automatically checks:
      - ⚠️ **Chinese domains**: Warns if the domain is `.cn`, `.com.cn`, or a known Chinese site (Baidu, QQ, Taobao, etc.)
      - ✓ **TLSv1.3**: Verifies the target supports TLS 1.3 (required for Reality)
      - ✓ **HTTP/2**: Checks for H2 support (recommended for best performance)
      - ✗ **Connection errors**: Detects timeouts or connection failures
    - Wildcards from the certificate are ignored (not supported by Xray). If only wildcards are present, the script will ask you for concrete hostnames.

## Notes
- Remember to open port **80 & 443 (TCP & UDP)** in your server's firewall.
- The script should not be run as the `root` user.

## Credits

-   [Xray](https://github.com/XTLS/Xray-core) — The core proxy software.
-   [Xray-examples](https://github.com/XTLS/Xray-examples) — Reference configurations and examples.
-   [teddysun/xray](https://hub.docker.com/r/teddysun/xray) — The Docker image used by this script.
-   [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) — Rust implementation for Shadowsocks 2022.
-   [containrrr/watchtower](https://github.com/containrrr/watchtower) — Used for safely updating the container.

Special thanks to them for their excellent work!

---

**This project is not affiliated with Xray or teddysun. Use at your own risk.**
