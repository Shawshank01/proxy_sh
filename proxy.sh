#!/bin/bash
#
# proxy.sh - An automated script to install and manage an Xray proxy server.
#

# --- Configuration & Colors ---
SCRIPT_VERSION="0.9.8"
DEFAULT_UUIDS=1
DEFAULT_SHORTIDS=9
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Functions ---

# Function to detect the Linux distribution
check_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
    else
        echo -e "${RED}Cannot detect Linux distribution.${NC}"
        exit 1
    fi
}

# Function to check for and install Docker
install_docker() {
    if command -v docker &> /dev/null && command -v docker compose &> /dev/null; then
        echo -e "${GREEN}Docker and Docker Compose are already installed.${NC}"
        return
    fi

    read -p "$(echo -e ${YELLOW}Docker is not installed. Would you like to install it? [y/N]: ${NC})" install_confirm
    if [[ "$install_confirm" != "y" && "$install_confirm" != "Y" ]]; then
        echo -e "${RED}Docker installation cancelled. Exiting.${NC}"
        exit 1
    fi

    echo "Installing Docker for ${DISTRO}..."
    case "$DISTRO" in
        ubuntu|debian|linuxmint)
            sudo apt-get update
            # Install Docker
            if ! sudo apt-get install -y docker.io; then
                echo -e "${RED}Failed to install Docker. Please install it manually.${NC}"
                exit 1
            fi
            
            # Try to install docker-compose-plugin, fallback to docker-compose if not available
            if sudo apt-get install -y docker-compose-plugin 2>/dev/null; then
                echo -e "${GREEN}Docker Compose plugin installed successfully.${NC}"
            else
                echo -e "${YELLOW}Docker Compose plugin not available, installing docker-compose...${NC}"
                if ! sudo apt-get install -y docker-compose; then
                    echo -e "${RED}Failed to install Docker Compose. Please install it manually.${NC}"
                    exit 1
                fi
            fi
            ;;
        centos|rhel|fedora)
            sudo dnf -y install dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        *)
            echo -e "${RED}Unsupported distribution for automatic Docker installation. Please install Docker and Docker Compose manually.${NC}"
            exit 1
            ;;
    esac

    # Start and enable Docker service
    if sudo systemctl start docker 2>/dev/null; then
        echo -e "${GREEN}Docker service started successfully.${NC}"
    else
        echo -e "${YELLOW}Could not start Docker service. You may need to start it manually.${NC}"
    fi
    
    if sudo systemctl enable docker 2>/dev/null; then
        echo -e "${GREEN}Docker service enabled for auto-start.${NC}"
    else
        echo -e "${YELLOW}Could not enable Docker service. You may need to enable it manually.${NC}"
    fi
    
    # Verify Docker installation
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}Docker has been installed successfully.${NC}"
    else
        echo -e "${RED}Docker installation failed. Please install it manually.${NC}"
        exit 1
    fi
}

# Function to install Xray VLESS-XHTTP-Reality
install_xray() {
    echo -e "${YELLOW}Starting Xray VLESS-XHTTP-Reality installation...${NC}"

    # Create directory
    mkdir -p xray
    cd xray || exit

    # Pull Docker image
    echo "Pulling teddysun/xray image..."
    sudo docker pull teddysun/xray

    # Get user input for counts
    read -p "How many user UUIDs do you need? [Default: $DEFAULT_UUIDS]: " num_uuids
    num_uuids=${num_uuids:-$DEFAULT_UUIDS}

    read -p "How many shortIds do you need? [Default: $DEFAULT_SHORTIDS]: " num_shortids
    num_shortids=${num_shortids:-$DEFAULT_SHORTIDS}

    # Generate keys and IDs
    echo "Generating keys and IDs..."
    KEYS=$(sudo docker run --rm teddysun/xray xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | awk '/Private key:/ {print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | awk '/Public key:/ {print $3}')

    CLIENTS_JSON=""
    for i in $(seq 1 $num_uuids); do
        uuid=$(sudo docker run --rm teddysun/xray xray uuid)
        CLIENTS_JSON+="{\"id\": \"$uuid\", \"flow\": \"\"}"
        if [ "$i" -lt "$num_uuids" ]; then
            CLIENTS_JSON+="," 
        fi
    done

    SHORTIDS_JSON=""
    for i in $(seq 1 $num_shortids); do
        shortid=$(openssl rand -hex 2)
        SHORTIDS_JSON+="\"$shortid\""
        if [ "$i" -lt "$num_shortids" ]; then
            SHORTIDS_JSON+="," 
        fi
    done

    # Create docker-compose.yml (with logging options)
    cat > docker-compose.yml << EOL
services:
  xray:
    image: teddysun/xray
    container_name: xray_server
    restart: unless-stopped
    ports:
      - "443:443/tcp"
      - "443:443/udp"
    volumes:
      - ./server.jsonc:/etc/xray/config.json:ro
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOL

    # Create server.jsonc (with routing, sniffing, two outbounds, and all serverNames)
    cat > server.jsonc << EOL
{
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": [
                    "geoip:cn"
                ],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:cn"
                ],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    $CLIENTS_JSON
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "path": "/xrayxskvhqoiwe"
                },
                "security": "reality",
                "realitySettings": {
                    "target": "www.apple.com:443",
                    "serverNames": [
                        "images.apple.com",
                        "www.apple.com.cn",
                        "www.apple.com"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [
                        $SHORTIDS_JSON
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOL

    echo -e "${GREEN}Configuration files created successfully!${NC}"
    echo "--- docker-compose.yml ---"
    cat docker-compose.yml
    echo "--------------------------"
    echo "--- server.jsonc ---"
    cat server.jsonc
    echo "--------------------"
    echo -e "${YELLOW}Public Key: $PUBLIC_KEY${NC}"

    # Prompt for server IP/domain and remarks
    read -p "Enter your server IP address or domain: " SERVER_ADDR
    read -p "Enter a remarks name for this server: " REMARKS

    # Parse UUIDs for vless link generation (one link per UUID)
    echo -e "\n${GREEN}VLESS Links:${NC}"
    # Get the first shortId
    SHORTID=$(echo -e "$SHORTIDS_JSON" | grep -oE '"[a-f0-9]+"' | head -n1 | tr -d '"')
    # Extract UUIDs from CLIENTS_JSON and print one link per UUID (split by comma)
    LINKS=""
    for uuid in $(echo "$CLIENTS_JSON" | tr ',' '\n' | grep -oE '"id": "[a-f0-9\-]{36}"' | sed 's/"id": "\([a-f0-9\-]\{36\}\)"/\1/'); do
        link="vless://$uuid@$SERVER_ADDR:443?security=reality&sni=www.apple.com&pbk=$PUBLIC_KEY&sid=$SHORTID&type=xhttp&path=%2Fxrayxskvhqoiwe#$REMARKS"
        echo "$link"
        LINKS+="$link\n"
    done

    # Save links to file
    echo -e "\nSaving links to vless_links.txt..."
    echo -e "$LINKS" > vless_links.txt
    echo "Links saved successfully!"

    read -p "Is the configuration correct? Do you want to start the container? [y/N]: " start_confirm
    if [[ "$start_confirm" == "y" || "$start_confirm" == "Y" ]]; then
        sudo docker compose up -d
        echo -e "${GREEN}Xray container has been started!${NC}"
        echo "Remember to open port 443 (TCP & UDP) in your server's firewall."
    else
        echo -e "${RED}Container start cancelled.${NC}"
    fi
}

# Function to update Xray
update_xray() {
    if ! sudo docker ps -q -f name=xray_server | grep -q .; then
        echo -e "${RED}Container 'xray_server' not found. Cannot update.${NC}"
        exit 1
    fi
    echo "Updating xray_server..."
    sudo docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      containrrr/watchtower \
      --run-once \
      xray_server
    echo -e "${GREEN}Update process finished.${NC}"
}

# Function to check environment (distro and Docker)
check_environment() {
    echo -e "${YELLOW}Checking environment...${NC}"
    check_distro
    install_docker
    echo -e "${GREEN}Environment check completed!${NC}"
}

# Function to check if environment is ready for Xray installation
check_xray_requirements() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker is not installed. Please run option 1 (Environment Check) first.${NC}"
        return 1
    fi
    if ! command -v docker compose &> /dev/null; then
        echo -e "${RED}Docker Compose is not installed. Please run option 1 (Environment Check) first.${NC}"
        return 1
    fi
    return 0
}

show_links() {
    LINKS_FILE="xray/vless_links.txt"
    if [ -f "xray/vless_links.txt" ]; then
        LINKS_FILE="xray/vless_links.txt"
    elif [ -f "xray/vless_links.txt" ]; then
        LINKS_FILE="xray/vless_links.txt"
    elif [ -f "vless_links.txt" ]; then
        LINKS_FILE="vless_links.txt"
    else
        echo -e "${RED}No saved VLESS links found. Please install Xray first to generate and save links.${NC}"
        return
    fi
    echo -e "\n${GREEN}Saved VLESS Links:${NC}"
    cat "$LINKS_FILE"
}

save_links() {
    LINKS_FILE="xray/vless_links.txt"
    echo -e "\n${YELLOW}Saving links to $LINKS_FILE...${NC}"
    echo -e "$1" > "$LINKS_FILE"
    echo -e "${GREEN}Links saved successfully!${NC}"
}

delete_xray() {
    echo -e "${YELLOW}Deleting Xray container and config...${NC}"
    cd xray || exit
    sudo docker compose down
    cd ..
    rm -rf xray
    echo -e "${GREEN}Xray container and config deleted successfully!${NC}"
}

update_script() {
    echo -e "${YELLOW}Checking for updates...${NC}"
    LATEST_VERSION=$(curl -s https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh | grep -oE "SCRIPT_VERSION=\"[0-9.]+\"" | cut -d'"' -f2)
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}Could not check for updates. Please check your internet connection or the repository URL.${NC}"
        return
    fi

    if [ "$SCRIPT_VERSION" == "$LATEST_VERSION" ]; then
        echo -e "${GREEN}You are already using the latest version of the script.${NC}"
        return
    fi

    echo -e "${YELLOW}A new version of the script is available: $LATEST_VERSION${NC}"
    read -p "Do you want to update? [y/N]: " update_confirm
    if [[ "$update_confirm" != "y" && "$update_confirm" != "Y" ]]; then
        echo -e "${RED}Update cancelled.${NC}"
        return
    fi

    echo -e "${YELLOW}Updating script...${NC}"
    curl -s https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh > proxy.sh
    echo -e "${GREEN}Script updated successfully! Please run the script again.${NC}"
    exit 0
}

# --- Main Script ---

# Make sure the script is not run as root
if [ "$EUID" -eq 0 ]; then
  echo -e "${RED}Please do not run this script as root. Use sudo when prompted.${NC}"
  exit 1
fi

echo -e "${YELLOW}--- Xray Proxy Installer ---${NC}"
echo "Please choose an option:"
echo "0) Update this script"
echo "1) Environment Check (Check distro and install Docker)"
echo "2) Install Xray (VLESS-XHTTP-Reality)"
echo "3) ss_2022 (coming soon)"
echo "4) Update existing Xray container"
echo "5) Show VLESS links for current config"
echo "6) Delete Xray container and config"
read -p "Enter your choice [0-6]: " choice

case $choice in
    0)
        update_script
        ;;
    1)
        check_environment
        ;;
    2)
        if ! check_xray_requirements; then
            exit 1
        fi
        install_xray
        ;;
    3)
        echo "This option is not yet available."
        ;;
    4)
        if ! check_xray_requirements; then
            exit 1
        fi
        update_xray
        ;;
    5)
        show_links
        ;;
    6)
        if ! check_xray_requirements; then
            exit 1
        fi
        delete_xray
        ;;
    *)
        echo -e "${RED}Invalid choice. Exiting.${NC}"
        ;;
esac
