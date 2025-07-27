#!/bin/bash
#
# proxy.sh - An automated script to install and manage an Xray proxy server.
#

# --- Configuration & Colors ---
DEFAULT_UUIDS=3
DEFAULT_SHORTIDS=3
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
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y docker.io docker-compose-plugin
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

    sudo systemctl start docker
    sudo systemctl enable docker
    echo -e "${GREEN}Docker has been installed and started.${NC}"
}

# Function to install Xray VLESS-XHTTP-Reality
install_xray() {
    echo -e "${YELLOW}Starting Xray VLESS-XHTTP-Reality installation...${NC}"

    # Create directory
    mkdir -p xray
    cd xray || exit

    # Pull Docker image
    echo "Pulling teddysun/xray image..."
    docker pull teddysun/xray

    # Get user input for counts
    read -p "How many user UUIDs do you need? [Default: $DEFAULT_UUIDS]: " num_uuids
    num_uuids=${num_uuids:-$DEFAULT_UUIDS}

    read -p "How many shortIds do you need? [Default: $DEFAULT_SHORTIDS]: " num_shortids
    num_shortids=${num_shortids:-$DEFAULT_SHORTIDS}

    # Generate keys and IDs
    echo "Generating keys and IDs..."
    KEYS=$(docker run --rm teddysun/xray xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | awk '/Private key:/ {print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | awk '/Public key:/ {print $3}')

    CLIENTS_JSON=""
    for i in $(seq 1 $num_uuids); do
        uuid=$(docker run --rm teddysun/xray xray uuid)
        CLIENTS_JSON+="{\n            \"id\": \"$uuid\",\n            \"flow\": \"\"\n        }"
        if [ "$i" -lt "$num_uuids" ]; then
            CLIENTS_JSON+=",\n        "
        fi
    done

    SHORTIDS_JSON=""
    for i in $(seq 1 $num_shortids); do
        shortid=$(openssl rand -hex 2)
        SHORTIDS_JSON+="\"$shortid\""
        if [ "$i" -lt "$num_shortids" ]; then
            SHORTIDS_JSON+=",\n            "
        fi
    done

    # Create docker-compose.yml
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
EOL

    # Create server.jsonc
    cat > server.jsonc << EOL
{
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
                        "www.apple.com",
                        "images.apple.com"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [
                        $SHORTIDS_JSON
                    ]
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
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

    read -p "Is the configuration correct? Do you want to start the container? [y/N]: " start_confirm
    if [[ "$start_confirm" == "y" || "$start_confirm" == "Y" ]]; then
        docker compose up -d
        echo -e "${GREEN}Xray container has been started!${NC}"
        echo "Remember to open port 443 (TCP & UDP) in your server's firewall."
    else
        echo -e "${RED}Container start cancelled.${NC}"
    fi
}

# Function to update Xray
update_xray() {
    if ! docker ps -q -f name=xray_server | grep -q .; then
        echo -e "${RED}Container 'xray_server' not found. Cannot update.${NC}"
        exit 1
    fi
    echo "Updating xray_server..."
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      containrrr/watchtower \
      --run-once \
      xray_server
    echo -e "${GREEN}Update process finished.${NC}"
}


# --- Main Script ---

# Make sure the script is not run as root
if [ "$EUID" -eq 0 ]; then
  echo -e "${RED}Please do not run this script as root. Use sudo when prompted.${NC}"
  exit 1
fi

check_distro
install_docker

echo -e "${YELLOW}--- Xray Proxy Installer ---${NC}"
echo "Please choose an option:"
echo "1) Install Xray (VLESS-XHTTP-Reality)"
echo "2) ss_2022 (coming soon)"
echo "3) Update existing Xray container"
read -p "Enter your choice [1-3]: " choice

case $choice in
    1)
        install_xray
        ;;
    2)
        echo "This option is not yet available."
        ;;
    3)
        update_xray
        ;;
    *)
        echo -e "${RED}Invalid choice. Exiting.${NC}"
        ;;
esac
