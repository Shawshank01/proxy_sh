# proxy_sh

An automated script to install and manage an Xray VLESS-XHTTP-Reality proxy server using Docker.

## Features
- **Automated Environment Check**: Installs Docker and Docker Compose if they are not present.
- **Wide Distro Support**: Works with Debian, Ubuntu, Fedora, CentOS, RHEL, and Linux Mint.
- **Interactive Installation**: Guides you through setting up an Xray VLESS-XHTTP-Reality proxy.
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

2.  **Run the script (do NOT use `sudo`):**
    ```bash
    ./proxy.sh
    ```
    The script will request `sudo` permissions only when necessary.

3.  **Choose an option from the menu.**

## Menu Options

-   **0) Update this script**: Checks for a new version on GitHub and updates itself.
-   **1) Environment Check**: Verifies the Linux distribution and installs Docker and Docker Compose if needed. Run this first if you are on a new server.
-   **2) Install Xray (VLESS-XHTTP-Reality)**: The main installation process. It will:
    -   Ask for the number of users (UUIDs) and `shortIds`.
    -   Generate `docker-compose.yml` and `server.jsonc` in a new `xray/` directory.
    -   Ask for your server's IP/domain and a remarks name to generate VLESS links.
    -   Save the links to `xray/vless_links.txt`.
    -   Start the Xray container.
-   **3) ss_2022**: (Coming soon)
-   **4) Update existing Xray container**: Pulls the latest `teddysun/xray` Docker image and restarts the container using Watchtower.
-   **5) Show VLESS links for current config**: Displays the contents of `xray/vless_links.txt`.
-   **6) Delete Xray container and config**: Stops the Docker container, and deletes the `xray/` directory, including all configurations and link files.

## Configuration Details
- The generated `server.jsonc` **blocks all China (CN) IPs and domains** by default using Xray's routing rules.
- The configuration uses the Reality protocol for obfuscation.
- All configuration files are created in a new `xray` directory relative to the script's location.

## Notes
- Remember to open port **443 (TCP & UDP)** in your server's firewall.
- The script should not be run as the `root` user.

## Credits

-   [Xray](https://github.com/XTLS/Xray-core) — The core proxy software.
-   [teddysun/xray](https://hub.docker.com/r/teddysun/xray) — The Docker image used by this script.
-   [containrrr/watchtower](https://github.com/containrrr/watchtower) — Used for safely updating the container.

Special thanks to the Xray and teddysun teams for their excellent work!

---

**This project is not affiliated with Xray or teddysun. Use at your own risk.**
