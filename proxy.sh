#!/bin/bash
#
# proxy.sh: An automated script to install and manage an Xray proxy server.
#

# --- Configuration & Colors ---
SCRIPT_VERSION="2.5.1"
DEFAULT_UUIDS=1
DEFAULT_SHORTIDS=3
DEFAULT_SS_USERS=1
DEFAULT_SS_PORT=80
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Global variable for Docker Compose command
DOCKER_COMPOSE_CMD=""

# --- Functions ---

# Check and install dependencies
check_dependencies() {
    # Only check for tools we might need to install.
    local dependencies=("curl" "openssl")
    local missing_deps=()

    for cmd in "${dependencies[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}Missing dependencies: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}Attempting to install them...${NC}"
        
        # Detect package manager
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y "${missing_deps[@]}"
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y "${missing_deps[@]}"
        elif command -v yum &> /dev/null; then
            sudo yum install -y "${missing_deps[@]}"
        else
            echo -e "${RED}Could not detect package manager. Please install manually: ${missing_deps[*]}${NC}"
            exit 1
        fi
        
        # Verify installation
        for cmd in "${missing_deps[@]}"; do
            if ! command -v $cmd &> /dev/null; then
                 echo -e "${RED}Failed to install $cmd. Please install manually.${NC}"
                 exit 1
            fi
        done
        echo -e "${GREEN}Dependencies installed successfully!${NC}"
    fi
}

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
    # Check if Docker is installed
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}Docker is already installed.${NC}"
    else
        echo -e "${YELLOW}Docker is not installed.${NC}"
        read -p "$(echo -e ${YELLOW}Would you like to install Docker? [y/N]: ${NC})" install_confirm
        if [[ "$install_confirm" != "y" && "$install_confirm" != "Y" ]]; then
            echo -e "${RED}Docker installation cancelled. Exiting.${NC}"
            exit 1
        fi
        install_docker_packages
        return
    fi

    # Check if Docker Compose is working
    if docker compose version &> /dev/null 2>&1; then
        echo -e "${GREEN}Docker Compose is working properly.${NC}"
        return
    elif command -v docker-compose &> /dev/null; then
        if docker-compose version &> /dev/null 2>&1; then
            echo -e "${GREEN}Docker Compose is working properly.${NC}"
            return
        else
            echo -e "${YELLOW}Docker Compose is installed but not working (broken on newer Python versions).${NC}"
            read -p "$(echo -e ${YELLOW}Would you like to upgrade to a working Docker Compose version? [y/N]: ${NC})" upgrade_confirm
            if [[ "$upgrade_confirm" == "y" || "$upgrade_confirm" == "Y" ]]; then
                echo -e "${YELLOW}Upgrading Docker Compose...${NC}"
                install_docker_compose
            else
                echo -e "${RED}Docker Compose upgrade cancelled. Some features may not work.${NC}"
            fi
            return
        fi
    else
        echo -e "${YELLOW}Docker Compose is not installed.${NC}"
        read -p "$(echo -e ${YELLOW}Would you like to install Docker Compose? [y/N]: ${NC})" install_confirm
        if [[ "$install_confirm" == "y" || "$install_confirm" == "Y" ]]; then
            install_docker_compose
        else
            echo -e "${RED}Docker Compose installation cancelled. Some features may not work.${NC}"
        fi
        return
    fi
}

# Function to install Docker packages
install_docker_packages() {
    echo "Installing Docker for ${DISTRO}..."
    case "$DISTRO" in
        ubuntu|debian|linuxmint)
            sudo apt-get update
            # Install Docker
            if ! sudo apt-get install -y docker.io; then
                echo -e "${RED}Failed to install Docker. Please install it manually.${NC}"
                exit 1
            fi
            
            # Install Docker Compose
            install_docker_compose
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

# Function to install Docker Compose
install_docker_compose() {
    echo -e "${YELLOW}Installing Docker Compose...${NC}"
    case "$DISTRO" in
        ubuntu|debian|linuxmint)
            # Try to install docker-compose-plugin (newer version)
            if sudo apt-get install -y docker-compose-plugin 2>/dev/null; then
                echo -e "${GREEN}Docker Compose plugin installed successfully.${NC}"
            else
                echo -e "${YELLOW}Docker Compose plugin not available, trying alternative installation...${NC}"
                # Try installing docker-compose-plugin from Docker's official repository
                if ! sudo apt-get install -y ca-certificates curl gnupg; then
                    echo -e "${RED}Failed to install prerequisites for Docker Compose.${NC}"
                    exit 1
                fi
                
                # Add Docker's official GPG key
                sudo install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                sudo chmod a+r /etc/apt/keyrings/docker.gpg
                
                # Add the repository to Apt sources
                # For Linux Mint, get the Ubuntu codename it's based on
                if [ "$DISTRO" = "linuxmint" ]; then
                    UBUNTU_CODENAME=$(grep -oP 'UBUNTU_CODENAME=\K[^"]+' /etc/os-release 2>/dev/null || echo "jammy")
                    echo -e "${YELLOW}Linux Mint detected, using Ubuntu codename: $UBUNTU_CODENAME${NC}"
                else
                    UBUNTU_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
                fi
                
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                
                sudo apt-get update
                if sudo apt-get install -y docker-compose-plugin; then
                    echo -e "${GREEN}Docker Compose plugin installed successfully from Docker repository.${NC}"
                else
                    echo -e "${RED}Failed to install Docker Compose. Please install it manually.${NC}"
                    exit 1
                fi
            fi
            ;;
        centos|rhel|fedora)
            sudo dnf install -y docker-compose-plugin
            ;;
        *)
            echo -e "${RED}Unsupported distribution for automatic Docker Compose installation. Please install it manually.${NC}"
            exit 1
            ;;
    esac
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

    # Generate a single user UUID
    num_uuids=$DEFAULT_UUIDS

    read -p "How many shortIds do you need? [Default: $DEFAULT_SHORTIDS]: " num_shortids
    num_shortids=${num_shortids:-$DEFAULT_SHORTIDS}

    # Generate keys and IDs
    echo "Generating keys and IDs..."
    KEYS=$(sudo docker run --rm --entrypoint /usr/bin/xray teddysun/xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | awk -F': *' 'BEGIN{IGNORECASE=1} /private[[:space:]]*key/ {gsub(/\r/, "", $2); print $2; exit}')
    PUBLIC_KEY=$(echo "$KEYS" | awk -F': *' 'BEGIN{IGNORECASE=1} /(public[[:space:]]*key|password)/ {gsub(/\r/, "", $2); print $2; exit}')

    if [ -z "$PRIVATE_KEY" ]; then
        echo -e "${RED}Failed to parse x25519 private key. Command output:${NC}"
        echo "$KEYS"
        exit 1
    fi

    if [ -z "$PUBLIC_KEY" ]; then
        DERIVED=$(sudo docker run --rm --entrypoint /usr/bin/xray teddysun/xray x25519 -i "$PRIVATE_KEY")
        PUBLIC_KEY=$(echo "$DERIVED" | awk -F': *' 'BEGIN{IGNORECASE=1} /(public[[:space:]]*key|password)/ {gsub(/\r/, "", $2); print $2; exit}')
    fi

    if [ -z "$PUBLIC_KEY" ]; then
        echo -e "${RED}Failed to derive x25519 public key. Command output:${NC}"
        if [ -n "$DERIVED" ]; then
            echo "$DERIVED"
        else
            echo "$KEYS"
        fi
        exit 1
    fi

    CLIENTS_JSON=""
    for i in $(seq 1 $num_uuids); do
        uuid=$(sudo docker run --rm --entrypoint /usr/bin/xray teddysun/xray uuid)
        CLIENTS_JSON+="{\"id\": \"$uuid\", \"flow\": \"\"}"
        if [ "$i" -lt "$num_uuids" ]; then
            CLIENTS_JSON+="," 
        fi
    done

    SHORTIDS_JSON=""
    for i in $(seq 1 $num_shortids); do
        shortid=$(openssl rand -hex 4) # Generates 8 characters
        SHORTIDS_JSON+="\"$shortid\""
        if [ "$i" -lt "$num_shortids" ]; then
            SHORTIDS_JSON+="," 
        fi
    done

    REALITY_TARGET_DEFAULT="zum.com:443"
    REALITY_SERVER_NAMES_DEFAULT="\"m.zum.com\",\"www.zum.com\",\"zum.com\""
    REALITY_TARGET="$REALITY_TARGET_DEFAULT"
    REALITY_SERVER_NAMES="$REALITY_SERVER_NAMES_DEFAULT"

    while true; do
        read -p "Enter a domain to probe with 'xray tls ping' (leave empty to keep defaults): " REALITY_DOMAIN
        if [ -z "$REALITY_DOMAIN" ]; then
            break
        fi

        REALITY_DOMAIN_CLEAN=${REALITY_DOMAIN#http://}
        REALITY_DOMAIN_CLEAN=${REALITY_DOMAIN_CLEAN#https://}
        REALITY_DOMAIN_CLEAN=${REALITY_DOMAIN_CLEAN%%/*}
        if [ -z "$REALITY_DOMAIN_CLEAN" ]; then
            REALITY_DOMAIN_CLEAN="$REALITY_DOMAIN"
        fi

        PING_HOST=${REALITY_DOMAIN_CLEAN%%:*}
        echo "Running xray tls ping for $PING_HOST..."
        PING_OUTPUT=$(sudo docker run --rm teddysun/xray:latest xray tls ping "$PING_HOST" 2>&1)
        echo "----- tls ping output -----"
        echo "$PING_OUTPUT"
        echo "---------------------------"

        read -p "Use this domain and output? [Y/n]: " use_domain
        if [[ "$use_domain" == "n" || "$use_domain" == "N" ]]; then
            continue
        fi

        if [[ "$REALITY_DOMAIN_CLEAN" == *":"* ]]; then
            REALITY_TARGET="$REALITY_DOMAIN_CLEAN"
        else
            REALITY_TARGET="${REALITY_DOMAIN_CLEAN}:443"
        fi

        PARSED_SERVER_NAMES=""
        ALLOWED_DOMAINS=$(echo "$PING_OUTPUT" | sed -nE "s/.*Cert's allowed domains: *\\[([^]]*)\\].*/\\1/p")
        if [ -n "$ALLOWED_DOMAINS" ]; then
            DROPPED_WILDCARDS=0
            SEEN_DOMAINS=""
            for domain in $ALLOWED_DOMAINS; do
                if [[ "$domain" == *"*"* ]]; then
                    DROPPED_WILDCARDS=1
                    continue
                fi
                if [[ " $SEEN_DOMAINS " == *" $domain "* ]]; then
                    continue
                fi
                SEEN_DOMAINS+=" $domain"
                if [ -n "$PARSED_SERVER_NAMES" ]; then
                    PARSED_SERVER_NAMES+=","
                fi
                PARSED_SERVER_NAMES+="\"$domain\""
            done
            if [ "$DROPPED_WILDCARDS" -eq 1 ]; then
                echo -e "${YELLOW}Wildcard domains were omitted from serverNames (not supported).${NC}"
            fi
        fi

        if [ -n "$PARSED_SERVER_NAMES" ]; then
            REALITY_SERVER_NAMES="$PARSED_SERVER_NAMES"
        else
            read -p "Enter serverNames (comma-separated, no * wildcards) [Default: $PING_HOST]: " SERVER_NAMES_INPUT
            if [ -n "$SERVER_NAMES_INPUT" ]; then
                REALITY_SERVER_NAMES=$(echo "$SERVER_NAMES_INPUT" | awk -F',' '{
                    for (i=1; i<=NF; i++) {
                        gsub(/^[ \t]+|[ \t]+$/, "", $i)
                        if ($i == "" || $i ~ /\*/) { continue }
                        if (out != "") { out=out"," }
                        out=out"\"" $i "\""
                    }
                    print out
                }')
                if [ -z "$REALITY_SERVER_NAMES" ]; then
                    REALITY_SERVER_NAMES="\"$PING_HOST\""
                fi
            else
                REALITY_SERVER_NAMES="\"$PING_HOST\""
            fi
        fi
        break
    done

    # Ask whether to enable IPv6 (dual-stack) listen
    read -p "Enable IPv6 listening (dual-stack)? [y/N]: " enable_ipv6
    if [[ "$enable_ipv6" == "y" || "$enable_ipv6" == "Y" ]]; then
        LISTEN_ADDR="::"
    else
        LISTEN_ADDR="0.0.0.0"
    fi

    # Create docker-compose.yml (with logging options)
    cat > docker-compose.yml << 'EOL'
services:
  xray:
    image: teddysun/xray
    container_name: xray_server
    restart: unless-stopped
    network_mode: host
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
                "ip": [
                    "geoip:cn"
                ],
                "outboundTag": "block"
            },
            {
                "domain": [
                    "geosite:cn"
                ],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "$LISTEN_ADDR",
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
                    "target": "$REALITY_TARGET",
                    "serverNames": [
                        $REALITY_SERVER_NAMES
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

    # Determine the SNI domain (first serverName, fallback to target host if list empty)
    SNI_DOMAIN=$(awk '
        /"serverNames": *\[/ {flag=1; next}
        flag {
            if (match($0, /"([^"]+)"/, m)) {
                print m[1]
                exit
            }
            if ($0 ~ /\]/) {
                exit
            }
        }
    ' server.jsonc)

    if [ -z "$SNI_DOMAIN" ]; then
        TARGET_VALUE=$(sed -nE 's/.*"target": *"([^"]+)".*/\1/p' server.jsonc | head -n1)
        SNI_DOMAIN=${TARGET_VALUE%%:*}
    fi

    if [ -z "$SNI_DOMAIN" ]; then
        echo -e "${RED}Unable to determine Reality SNI from server.jsonc. Please set serverNames or a valid target (host:port).${NC}"
        exit 1
    fi

    # Parse UUIDs/shortIds for vless link generation (one link per shortId)
    echo -e "\n${GREEN}VLESS Links:${NC}"
    SHORTIDS=$(echo -e "$SHORTIDS_JSON" | grep -oE '"[a-f0-9]+"' | tr -d '"')
    UUIDS=$(echo "$CLIENTS_JSON" | tr ',' '\n' | grep -oE '"id": "[a-f0-9\-]{36}"' | sed 's/"id": "\([a-f0-9\-]\{36\}\)"/\1/')
    LINKS=""
    for uuid in $UUIDS; do
        for shortid in $SHORTIDS; do
            link="vless://$uuid@$SERVER_ADDR:443?security=reality&sni=$SNI_DOMAIN&pbk=$PUBLIC_KEY&sid=$shortid&type=xhttp&path=%2Fxrayxskvhqoiwe#$REMARKS"
            echo "$link"
            LINKS+="$link\n"
        done
    done

    # Save links to file
    echo -e "\nSaving links to vless_links.txt..."
    echo -e "$LINKS" > vless_links.txt
    echo "Links saved successfully!"

    read -p "Is the configuration correct? Do you want to start the container? [y/N]: " start_confirm
    if [[ "$start_confirm" == "y" || "$start_confirm" == "Y" ]]; then
        sudo $DOCKER_COMPOSE_CMD up -d
        echo -e "${GREEN}Xray container has been started!${NC}"
        echo "Remember to open port 443 (TCP & UDP) in your server's firewall."
    else
        echo -e "${RED}Container start cancelled.${NC}"
    fi

    # RETURN TO MAIN DIRECTORY
    cd ..
}

# Function to install Shadowsocks (ssserver-rust)
install_shadowsocks() {
    echo -e "${YELLOW}Starting Shadowsocks (ssserver-rust) installation...${NC}"

    # Create directory
    mkdir -p shadowsocks
    cd shadowsocks || exit

    # Pull Docker image
    echo "Pulling ghcr.io/shadowsocks/ssserver-rust image..."
    sudo docker pull ghcr.io/shadowsocks/ssserver-rust:latest

    # Get user input for counts and port
    read -p "How many users do you need? [Default: $DEFAULT_SS_USERS]: " num_users
    num_users=${num_users:-$DEFAULT_SS_USERS}

    read -p "Which port should Shadowsocks listen on? [Default: $DEFAULT_SS_PORT]: " ss_port
    ss_port=${ss_port:-$DEFAULT_SS_PORT}

    read -p "Enable IPv6 listening (dual-stack)? [y/N]: " enable_ss_ipv6
    if [[ "$enable_ss_ipv6" == "y" || "$enable_ss_ipv6" == "Y" ]]; then
        SS_LISTEN_ADDR="::"
    else
        SS_LISTEN_ADDR="0.0.0.0"
    fi

    SS_METHOD="2022-blake3-chacha20-poly1305"
    SERVER_PSK=$(openssl rand -base64 32)

    CLIENTS_JSON=""
    USER_PSKS=()
    USER_LABELS=()
    for i in $(seq 1 $num_users); do
        user_psk=$(openssl rand -base64 32)
        default_label="user${i}"
        read -p "Enter a label for user ${i} [${default_label}]: " user_label
        user_label=${user_label:-$default_label}
        user_label=${user_label//\"/}

        CLIENTS_JSON+="{\"name\": \"$user_label\", \"password\": \"$user_psk\"}"
        if [ "$i" -lt "$num_users" ]; then
            CLIENTS_JSON+=","
        fi
        USER_PSKS+=("$user_psk")
        USER_LABELS+=("$user_label")
    done

    # Create docker-compose.yml (with logging options)
    cat > docker-compose.yml << EOL
services:
  ssserver:
    image: ghcr.io/shadowsocks/ssserver-rust:latest
    container_name: ssserver
    restart: unless-stopped
    entrypoint: ["ssserver"]
    network_mode: host
    ports:
      - "${ss_port}:${ss_port}/tcp"
      - "${ss_port}:${ss_port}/udp"
    volumes:
      - ./server.json:/etc/shadowsocks-rust/config.json:ro
    command: ["-c", "/etc/shadowsocks-rust/config.json"]
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOL

    # Create server.json
    cat > server.json << EOL
{
  "server": "$SS_LISTEN_ADDR",
  "server_port": $ss_port,
  "password": "$SERVER_PSK",
  "method": "$SS_METHOD",
  "mode": "tcp_and_udp",
  "users": [
    $CLIENTS_JSON
  ]
}
EOL

    echo -e "${GREEN}Configuration files created successfully!${NC}"
    echo "--- docker-compose.yml ---"
    cat docker-compose.yml
    echo "--------------------------"
    echo "--- server.json ---"
    cat server.json
    echo "-------------------"

    # Prompt for server IP/domain and remarks
    read -p "Enter your server IP address or domain: " SERVER_ADDR
    read -p "Enter a remarks name for this server: " REMARKS
    REMARKS=${REMARKS:-shadowsocks_rust}

    read -p "Is the configuration correct? Do you want to start the container? [y/N]: " start_confirm
    if [[ "$start_confirm" == "y" || "$start_confirm" == "Y" ]]; then
        if sudo $DOCKER_COMPOSE_CMD up -d; then
            echo -e "${GREEN}Shadowsocks container has been started!${NC}"
            echo "Remember to open port ${ss_port} (TCP & UDP) in your server's firewall."

            echo -e "\n${GREEN}SS Links:${NC}"
            LINKS=""
            REMARKS_URL=${REMARKS// /%20}
            for i in "${!USER_PSKS[@]}"; do
                user_psk=${USER_PSKS[$i]}
                user_label=${USER_LABELS[$i]}
                user_label_url=${user_label// /%20}
                PASSWORD="${SERVER_PSK}:${user_psk}"
                BASE64=$(printf "%s" "${SS_METHOD}:${PASSWORD}" | base64 | tr -d '\n')
                link="ss://${BASE64}@${SERVER_ADDR}:${ss_port}#${REMARKS_URL}-${user_label_url}"
                echo "$link"
                LINKS+="$link\n"
            done

            echo -e "\nSaving links to ss_links.txt..."
            echo -e "$LINKS" > ss_links.txt
            echo "Links saved successfully!"
        else
            echo -e "${RED}Failed to start Shadowsocks container.${NC}"
        fi
    else
        echo -e "${RED}Container start cancelled.${NC}"
    fi

    # RETURN TO MAIN DIRECTORY
    cd ..
}

# Function to update Xray
update_xray() {
    local CONTAINER_NAME="xray_server"

    # Check if container exists (running or stopped)
    # Using -a ensures we find it even if it happens to be stopped currently
    if ! sudo docker ps -a -q -f name="^/${CONTAINER_NAME}$" | grep -q .; then
        echo -e "${RED}Container '${CONTAINER_NAME}' not found. Cannot update.${NC}"
        return 1
    fi

    echo "Updating ${CONTAINER_NAME}..."

    # Run Watchtower with the API Fix
    if sudo docker run --rm \
      -e DOCKER_API_VERSION=1.44 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      containrrr/watchtower \
      --run-once \
      -c \
      "$CONTAINER_NAME"; then
        echo -e "${GREEN}Update process finished successfully.${NC}"
    else
        echo -e "${RED}Watchtower failed to run.${NC}"
        return 1
    fi
}

# Function to update Shadowsocks
update_shadowsocks() {
    local CONTAINER_NAME="ssserver"

    if ! sudo docker ps -a -q -f name="^/${CONTAINER_NAME}$" | grep -q .; then
        echo -e "${RED}Container '${CONTAINER_NAME}' not found. Cannot update.${NC}"
        return 1
    fi

    echo "Updating ${CONTAINER_NAME}..."

    if sudo docker run --rm \
      -e DOCKER_API_VERSION=1.44 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      containrrr/watchtower \
      --run-once \
      -c \
      "$CONTAINER_NAME"; then
        echo -e "${GREEN}Update process finished successfully.${NC}"
    else
        echo -e "${RED}Watchtower failed to run.${NC}"
        return 1
    fi
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
    echo -e "${YELLOW}Checking Docker Compose availability...${NC}"
    
    # Check for both docker-compose (hyphen) and docker compose (space) versions
    # Prioritize the newer 'docker compose' version (with space)
    if docker compose version &> /dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
        echo -e "${GREEN}Using Docker Compose: $DOCKER_COMPOSE_CMD${NC}"
    elif command -v docker-compose &> /dev/null; then
        echo -e "${YELLOW}Found docker-compose (old version), testing if it works...${NC}"
        if docker-compose version &> /dev/null 2>&1; then
            DOCKER_COMPOSE_CMD="docker-compose"
            echo -e "${GREEN}Using Docker Compose: $DOCKER_COMPOSE_CMD${NC}"
        else
            echo -e "${RED}Docker Compose is installed but not working. Please install the newer version.${NC}"
            return 1
        fi
    else
        echo -e "${RED}Docker Compose is not installed. Please run option 1 (Environment Check) first.${NC}"
        return 1
    fi
    return 0
}

show_links() {
    LINKS_FILE="xray/vless_links.txt"
    if [ -f "xray/vless_links.txt" ]; then
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

delete_xray() {
    echo -e "${YELLOW}Deleting Xray container and config...${NC}"
    
    # SAFETY CHECK: Only try to enter/delete if directory exists
    if [ ! -d "xray" ]; then
        echo -e "${RED}Directory 'xray' not found. Nothing to delete.${NC}"
        return
    fi

    cd xray || exit
    sudo $DOCKER_COMPOSE_CMD down
    cd ..
    rm -rf xray
    echo -e "${GREEN}Xray container and config deleted successfully!${NC}"
}

delete_shadowsocks() {
    echo -e "${YELLOW}Deleting Shadowsocks container and config...${NC}"

    if [ ! -d "shadowsocks" ]; then
        echo -e "${RED}Directory 'shadowsocks' not found. Nothing to delete.${NC}"
        return
    fi

    cd shadowsocks || exit
    sudo $DOCKER_COMPOSE_CMD down
    cd ..
    rm -rf shadowsocks
    echo -e "${GREEN}Shadowsocks container and config deleted successfully!${NC}"
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

# CHECK DEPENDENCIES NOW (Running as non-root, will use sudo inside)
check_dependencies

echo -e "${YELLOW}--- VLESS Proxy Installer v${SCRIPT_VERSION} ---${NC}"
echo "Please choose an option:"
echo "0) Update this script"
echo "1) Environment Check (Check distro and install Docker)"
echo "2) Install Xray (VLESS-XHTTP-Reality)"
echo "3) Install Shadowsocks (ssserver-rust)"
echo "4) Update existing container (Xray / Shadowsocks)"
echo "5) Show VLESS links for current config"
echo "6) Delete container and config (Xray / Shadowsocks)"
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
        if ! check_xray_requirements; then
            exit 1
        fi
        install_shadowsocks
        ;;
    4)
        if ! check_xray_requirements; then
            exit 1
        fi
        echo "Which container do you want to update?"
        echo "1) Xray"
        echo "2) Shadowsocks"
        echo "3) Both"
        read -p "Enter your choice [1-3]: " update_choice
        case $update_choice in
            1)
                update_xray
                ;;
            2)
                update_shadowsocks
                ;;
            3)
                update_xray
                update_shadowsocks
                ;;
            *)
                echo -e "${RED}Invalid choice. Exiting.${NC}"
                ;;
        esac
        ;;
    5)
        show_links
        ;;
    6)
        if ! check_xray_requirements; then
            exit 1
        fi
        echo "Which container do you want to delete?"
        echo "1) Xray"
        echo "2) Shadowsocks"
        read -p "Enter your choice [1-2]: " delete_choice
        case $delete_choice in
            1)
                delete_xray
                ;;
            2)
                delete_shadowsocks
                ;;
            *)
                echo -e "${RED}Invalid choice. Exiting.${NC}"
                ;;
        esac
        ;;
    *)
        echo -e "${RED}Invalid choice. Exiting.${NC}"
        ;;
esac
