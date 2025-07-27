# proxy_sh

An automated script to install and manage an Xray VLESS-XHTTP-Reality proxy server using Docker.

## Features
- **Automatic Docker installation** (if not present)
- **Supports Ubuntu, Debian, CentOS, Fedora** (and similar distros)
- **Interactive setup**: choose proxy type, number of UUIDs and shortIds
- **Generates secure configuration** with user-specified or default values
- **Blocks China (CN) IPs and domains** by default in the generated config
- **Easy update**: run the script and choose the update option

## Usage

1. **Download the script:**
   ```bash
   wget https://raw.githubusercontent.com/yourusername/proxy_sh/main/proxy.sh
   chmod +x proxy.sh
   ```

2. **Run the script (do NOT use sudo):**
   ```bash
   ./proxy.sh
   ```
   The script will prompt for sudo when needed.

3. **Follow the prompts:**
   - If Docker is not installed, you will be asked if you want to install it.
   - Choose the proxy type (currently only Xray VLESS-XHTTP-Reality is available).
   - Enter the number of UUIDs and shortIds (or press Enter for defaults).
   - Review the generated configuration and confirm to start the container.

4. **To update the Xray container:**
   - Run the script again and choose the update option.

## Configuration Details
- The generated `server.jsonc` **blocks all China (CN) IPs and domains** using Xray's routing rules.
- The config uses the Reality protocol with a random path and secure keys.
- All configuration files are created in a new `xray` directory in your current path.

## Notes
- Make sure to open port 443 (TCP & UDP) in your server's firewall.
- The script should not be run as root; use your normal user account.
- The `ss_2022` option is not yet available.

---

**This project is not affiliated with Xray or teddysun. Use at your own risk.**
