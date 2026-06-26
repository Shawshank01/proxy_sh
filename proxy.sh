#!/bin/bash
set -euo pipefail
#
# proxy.sh: An automated script to install and manage an Xray proxy server.
#

# --- Configuration & Colors ---
SCRIPT_VERSION="3.3.4"
DEFAULT_UUIDS=1
DEFAULT_SHORTIDS=3
DEFAULT_SS_USERS=1
DEFAULT_SS_PORT=80
DEFAULT_QUOTA_TIMEZONE="UTC"
DEFAULT_USER_LIMIT_MB=204800
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
            # Install prerequisites
            sudo apt-get update
            if ! sudo apt-get install -y ca-certificates curl gnupg; then
                echo -e "${RED}Failed to install prerequisites. Please install them manually.${NC}"
                exit 1
            fi

            # Add Docker's official GPG key
            sudo install -m 0755 -d /etc/apt/keyrings

            # Determine the correct Docker repo based on distro
            if [ "$DISTRO" = "linuxmint" ]; then
                UBUNTU_CODENAME=$(grep -oP 'UBUNTU_CODENAME=\K[^"]+' /etc/os-release 2>/dev/null || echo "jammy")
                echo -e "${YELLOW}Linux Mint detected, using Ubuntu codename: $UBUNTU_CODENAME${NC}"
                REPO_URL="https://download.docker.com/linux/ubuntu"
                REPO_CODENAME="$UBUNTU_CODENAME"
            elif [ "$DISTRO" = "debian" ]; then
                REPO_URL="https://download.docker.com/linux/debian"
                REPO_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
            else
                # Ubuntu or compatible
                REPO_URL="https://download.docker.com/linux/ubuntu"
                REPO_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
            fi

            # Download and install Docker's GPG key
            curl -fsSL "${REPO_URL}/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg

            # Add the Docker repository
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $REPO_URL $REPO_CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

            # Update and install Docker
            sudo apt-get update
            if ! sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
                echo -e "${RED}Failed to install Docker. Please install it manually.${NC}"
                exit 1
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
                if [ "$DISTRO" = "linuxmint" ]; then
                    UBUNTU_CODENAME=$(grep -oP 'UBUNTU_CODENAME=\K[^"]+' /etc/os-release 2>/dev/null || echo "jammy")
                    echo -e "${YELLOW}Linux Mint detected, using Ubuntu codename: $UBUNTU_CODENAME${NC}"
                    REPO_URL="https://download.docker.com/linux/ubuntu"
                    REPO_CODENAME="$UBUNTU_CODENAME"
                elif [ "$DISTRO" = "debian" ]; then
                    VER_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
                    REPO_URL="https://download.docker.com/linux/debian"
                    REPO_CODENAME="$VER_CODENAME"
                else
                    # Assume Ubuntu or compatible
                    VER_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
                    REPO_URL="https://download.docker.com/linux/ubuntu"
                    REPO_CODENAME="$VER_CODENAME"
                fi

                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $REPO_URL $REPO_CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

                # Remove conflicting packages that might be installed from distro repos
                echo -e "${YELLOW}Removing conflicting packages to avoid installation errors...${NC}"
                sudo apt-get remove -y docker-buildx docker-compose docker-doc podman-docker || true

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
    cd xray || return 1

    # Pull Docker image
    echo "Pulling teddysun/xray image..."
    sudo docker pull teddysun/xray

    read -p "How many users do you need? [Default: $DEFAULT_UUIDS]: " num_uuids
    num_uuids=${num_uuids:-$DEFAULT_UUIDS}

    if ! [[ "$num_uuids" =~ ^[0-9]+$ ]] || [ "$num_uuids" -lt 1 ]; then
        echo -e "${RED}User count must be a positive integer.${NC}"
        cd ..
        return 1
    fi

    read -p "Timezone for quota billing cycles [Default: $DEFAULT_QUOTA_TIMEZONE]: " QUOTA_TIMEZONE
    QUOTA_TIMEZONE=${QUOTA_TIMEZONE:-$DEFAULT_QUOTA_TIMEZONE}
    if ! TZ="$QUOTA_TIMEZONE" date +%s >/dev/null 2>&1; then
        echo -e "${YELLOW}Invalid timezone. Falling back to ${DEFAULT_QUOTA_TIMEZONE}.${NC}"
        QUOTA_TIMEZONE="$DEFAULT_QUOTA_TIMEZONE"
    fi

    # Generate keys and IDs
    echo "Generating keys and IDs..."
    KEYS=$(sudo docker run --rm --entrypoint /usr/bin/xray teddysun/xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | awk -F': *' 'tolower($0) ~ /private[[:space:]]*key/ {gsub(/\r/, "", $2); print $2; exit}')
    PUBLIC_KEY=$(echo "$KEYS" | awk -F': *' 'tolower($0) ~ /(public[[:space:]]*key|password)/ {gsub(/\r/, "", $2); print $2; exit}')

    if [ -z "$PRIVATE_KEY" ]; then
        echo -e "${RED}Failed to parse x25519 private key. Command output:${NC}"
        echo "$KEYS"
        exit 1
    fi

    if [ -z "$PUBLIC_KEY" ]; then
        DERIVED=$(sudo docker run --rm --entrypoint /usr/bin/xray teddysun/xray x25519 -i "$PRIVATE_KEY")
        PUBLIC_KEY=$(echo "$DERIVED" | awk -F': *' 'tolower($0) ~ /(public[[:space:]]*key|password)/ {gsub(/\r/, "", $2); print $2; exit}')
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
    QUOTA_DB_LINES=""
    SHORTIDS_JSON=""
    declare -A USED_EMAILS
    declare -A USED_SHORTIDS
    USER_UUIDS=()
    USER_EMAILS=()
    USER_SHORTIDS=()

    for i in $(seq 1 $num_uuids); do
        uuid=$(sudo docker run --rm --entrypoint /usr/bin/xray teddysun/xray uuid)

        default_label="user${i}"
        read -p "Enter label/email for user ${i} [${default_label}]: " user_label
        user_label=${user_label:-$default_label}
        user_email=$(echo "$user_label" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/_/g; s/[^a-z0-9_.-]//g')
        if [ -z "$user_email" ]; then
            user_email="$default_label"
        fi

        base_email="$user_email"
        suffix=2
        while [ -n "${USED_EMAILS[$user_email]:-}" ]; do
            user_email="${base_email}_${suffix}"
            suffix=$((suffix + 1))
        done
        USED_EMAILS[$user_email]=1

        read -p "How many shortIds for generated links of ${user_email}? [Default: 1]: " user_shortids_count
        user_shortids_count=${user_shortids_count:-1}
        if ! [[ "$user_shortids_count" =~ ^[0-9]+$ ]] || [ "$user_shortids_count" -lt 1 ]; then
            echo -e "${RED}shortId count for ${user_email} must be a positive integer.${NC}"
            cd ..
            return 1
        fi

        user_shortids_csv=""
        for sid_idx in $(seq 1 $user_shortids_count); do
            while true; do
                shortid=$(openssl rand -hex 4) # Generates 8 characters
                if [ -z "${USED_SHORTIDS[$shortid]:-}" ]; then
                    USED_SHORTIDS[$shortid]=1
                    break
                fi
            done

            if [ -n "$SHORTIDS_JSON" ]; then
                SHORTIDS_JSON+=","
            fi
            SHORTIDS_JSON+="\"$shortid\""

            if [ -n "$user_shortids_csv" ]; then
                user_shortids_csv+=","
            fi
            user_shortids_csv+="$shortid"
        done

        read -p "Set monthly data limit for ${user_email}? [Y/n]: " set_limit
        user_limit_mb=0
        if [[ -z "$set_limit" || "$set_limit" == "y" || "$set_limit" == "Y" ]]; then
            while true; do
                read -p "Enter monthly limit for ${user_email} in MB [Default: ${DEFAULT_USER_LIMIT_MB}]: " user_limit_mb
                user_limit_mb=${user_limit_mb:-$DEFAULT_USER_LIMIT_MB}
                if [[ "$user_limit_mb" =~ ^[0-9]+$ ]] && [ "$user_limit_mb" -gt 0 ]; then
                    break
                fi
                echo -e "${RED}Please enter a positive integer MB value.${NC}"
            done
        fi

        user_anchor_now=$(date +%s)
        calculate_cycle_bounds "$user_anchor_now" "$user_anchor_now" "$QUOTA_TIMEZONE"

        CLIENTS_JSON+="{\"id\": \"$uuid\", \"flow\": \"\", \"email\": \"$user_email\"}"
        if [ "$i" -lt "$num_uuids" ]; then
            CLIENTS_JSON+=","
        fi

        QUOTA_DB_LINES+="${user_email}|${uuid}|${user_limit_mb}|${user_anchor_now}|${CYCLE_START_EPOCH}|${CYCLE_END_EPOCH}|0|0|active"
        if [ "$i" -lt "$num_uuids" ]; then
            QUOTA_DB_LINES+=$'\n'
        fi

        USER_UUIDS+=("$uuid")
        USER_EMAILS+=("$user_email")
        USER_SHORTIDS+=("$user_shortids_csv")
    done

    # Generate random XHTTP path for security
    XHTTP_PATH=$(openssl rand -hex 4)

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

        # Check for Chinese domains before probing
        DOMAIN_WARNING=""
        if [[ "$PING_HOST" == *.cn || "$PING_HOST" == *.com.cn || "$PING_HOST" == *.net.cn || "$PING_HOST" == *.org.cn || "$PING_HOST" == *.中国 || "$PING_HOST" == *.中國 ]]; then
            DOMAIN_WARNING="${RED}⚠ WARNING: This appears to be a Chinese domain (.cn). Reality target must be a foreign website outside China!${NC}"
        elif [[ "$PING_HOST" == *baidu.com || "$PING_HOST" == *qq.com || "$PING_HOST" == *taobao.com || "$PING_HOST" == *tmall.com || "$PING_HOST" == *jd.com || "$PING_HOST" == *163.com || "$PING_HOST" == *sina.com || "$PING_HOST" == *weibo.com || "$PING_HOST" == *alipay.com || "$PING_HOST" == *bilibili.com || "$PING_HOST" == *douyin.com || "$PING_HOST" == *tiktok.com ]]; then
            DOMAIN_WARNING="${RED}⚠ WARNING: This appears to be a Chinese website. Reality target must be a foreign website outside China!${NC}"
        fi

        if [ -n "$DOMAIN_WARNING" ]; then
            echo -e "$DOMAIN_WARNING"
            read -p "Are you sure you want to continue with this domain? [y/N]: " china_confirm
            if [[ "$china_confirm" != "y" && "$china_confirm" != "Y" ]]; then
                continue
            fi
        fi

        echo "Running xray tls ping for $PING_HOST..."
        PING_OUTPUT=$(sudo docker run --rm teddysun/xray:latest xray tls ping "$PING_HOST" 2>&1)
        echo "----- tls ping output -----"
        echo "$PING_OUTPUT"
        echo "---------------------------"

        # Validate TLS and HTTP/2 requirements
        VALIDATION_ERRORS=0

        # Check for TLSv1.3 support
        if echo "$PING_OUTPUT" | grep -qi "TLS 1.3\|TLSv1.3\|Version:.*303"; then
            echo -e "${GREEN}✓ TLSv1.3 supported${NC}"
        else
            echo -e "${RED}✗ TLSv1.3 NOT detected - Reality requires TLS 1.3${NC}"
            VALIDATION_ERRORS=1
        fi

        # Check for HTTP/2 (H2) support
        if echo "$PING_OUTPUT" | grep -qi "ALPN.*h2\|HTTP/2\|h2,"; then
            echo -e "${GREEN}✓ HTTP/2 (H2) supported${NC}"
        else
            echo -e "${YELLOW}⚠ HTTP/2 (H2) not detected - Reality works best with H2${NC}"
        fi

        # Check for connection errors
        if echo "$PING_OUTPUT" | grep -qi "error\|failed\|timeout\|refused"; then
            echo -e "${RED}✗ Connection error detected - domain may be unreachable${NC}"
            VALIDATION_ERRORS=1
        fi

        if [ "$VALIDATION_ERRORS" -eq 1 ]; then
            echo -e "${YELLOW}This domain may not be suitable as a Reality target.${NC}"
            read -p "Continue anyway? [y/N]: " force_continue
            if [[ "$force_continue" != "y" && "$force_continue" != "Y" ]]; then
                continue
            fi
        fi

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
    "stats": {},
    "api": {
        "tag": "api",
        "services": [
            "StatsService"
        ]
    },
    "policy": {
        "levels": {
            "0": {
                "statsUserUplink": true,
                "statsUserDownlink": true
            }
        },
        "system": {
            "statsInboundUplink": true,
            "statsInboundDownlink": true,
            "statsOutboundUplink": true,
            "statsOutboundDownlink": true
        }
    },
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "inboundTag": [
                    "api"
                ],
                "outboundTag": "api"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:google"
                ],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:cn"
                ],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "ip": [
                    "geoip:cn"
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
                    "path": "/$XHTTP_PATH"
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
        },
        {
            "listen": "127.0.0.1",
            "port": 10085,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "127.0.0.1"
            },
            "tag": "api"
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "freedom",
            "tag": "api"
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

    # Generate links using each user's assigned shortIds only
    echo -e "\n${GREEN}VLESS Links:${NC}"
    LINKS=""
    REMARKS_URL=${REMARKS// /%20}

    for idx in "${!USER_UUIDS[@]}"; do
        uuid=${USER_UUIDS[$idx]}
        user_email=${USER_EMAILS[$idx]}
        user_email_url=${user_email// /%20}

        IFS=',' read -r -a sid_list <<< "${USER_SHORTIDS[$idx]}"
        for shortid in "${sid_list[@]}"; do
            link="vless://$uuid@$SERVER_ADDR:443?security=reality&sni=$SNI_DOMAIN&pbk=$PUBLIC_KEY&sid=$shortid&type=xhttp&path=%2F$XHTTP_PATH#${REMARKS_URL}-${user_email_url}"
            echo "$link"
            LINKS+="$link\n"
        done
    done

    # Save links to file
    echo -e "\nSaving links to vless_links.txt..."
    echo -e "$LINKS" > vless_links.txt
    echo "Links saved successfully!"

    # Save per-user quota metadata
    cat > user_limits.conf << EOL
TIMEZONE=$QUOTA_TIMEZONE
EOL

    cat > user_limits.db << EOL
# email|uuid|limit_mb|anchor_epoch|cycle_start_epoch|cycle_end_epoch|cycle_usage_bytes|last_total_bytes|status
$QUOTA_DB_LINES
EOL

    echo -e "${GREEN}Saved quota metadata:${NC} xray/user_limits.conf, xray/user_limits.db"

    read -p "Is the configuration correct? Do you want to start the container? [Y/n]: " start_confirm
    if [[ -z "$start_confirm" || "$start_confirm" == "y" || "$start_confirm" == "Y" ]]; then
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
    cd shadowsocks || return 1

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

    read -p "Is the configuration correct? Do you want to start the container? [Y/n]: " start_confirm
    if [[ -z "$start_confirm" || "$start_confirm" == "y" || "$start_confirm" == "Y" ]]; then
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

# ----- Xray quota helpers -----

days_in_month() {
    local year=$1
    local month=$2
    date -d "${year}-$(printf "%02d" "$month")-01 +1 month -1 day" +%d
}

add_months_clamped_epoch() {
    local anchor_epoch=$1
    local add_months=$2
    local timezone=$3

    local ay am ad ah amin asec
    ay=$(TZ="$timezone" date -d "@$anchor_epoch" +%Y)
    am=$(TZ="$timezone" date -d "@$anchor_epoch" +%m)
    ad=$(TZ="$timezone" date -d "@$anchor_epoch" +%d)
    ah=$(TZ="$timezone" date -d "@$anchor_epoch" +%H)
    amin=$(TZ="$timezone" date -d "@$anchor_epoch" +%M)
    asec=$(TZ="$timezone" date -d "@$anchor_epoch" +%S)

    local total_months=$((10#$ay * 12 + 10#$am - 1 + add_months))
    local ny=$((total_months / 12))
    local nm=$((total_months % 12 + 1))

    local dim
    dim=$(days_in_month "$ny" "$nm")

    local nd=$((10#$ad))
    if [ "$nd" -gt "$dim" ]; then
        nd=$dim
    fi

    TZ="$timezone" date -d "$(printf "%04d-%02d-%02d %02d:%02d:%02d" "$ny" "$nm" "$nd" "$ah" "$amin" "$asec")" +%s
}

calculate_cycle_bounds() {
    local anchor_epoch=$1
    local now_epoch=$2
    local timezone=$3

    local month_offset=0
    local start_epoch next_epoch
    start_epoch=$(add_months_clamped_epoch "$anchor_epoch" "$month_offset" "$timezone")

    # Safety for unusual clock/timezone conditions
    if [ "$start_epoch" -gt "$now_epoch" ]; then
        CYCLE_START_EPOCH=$start_epoch
        CYCLE_END_EPOCH=$(add_months_clamped_epoch "$anchor_epoch" $((month_offset + 1)) "$timezone")
        return
    fi

    while true; do
        next_epoch=$(add_months_clamped_epoch "$anchor_epoch" $((month_offset + 1)) "$timezone")
        if [ "$now_epoch" -lt "$next_epoch" ]; then
            CYCLE_START_EPOCH=$start_epoch
            CYCLE_END_EPOCH=$next_epoch
            return
        fi
        month_offset=$((month_offset + 1))
        start_epoch=$next_epoch
    done
}

read_xray_quota_timezone() {
    local conf_file="xray/user_limits.conf"
    local tz="$DEFAULT_QUOTA_TIMEZONE"

    if [ -f "$conf_file" ]; then
        local parsed_tz
        parsed_tz=$(grep -E '^TIMEZONE=' "$conf_file" | tail -n1 | cut -d'=' -f2-)
        if [ -n "$parsed_tz" ]; then
            tz="$parsed_tz"
        fi
    fi

    if ! TZ="$tz" date +%s >/dev/null 2>&1; then
        tz="$DEFAULT_QUOTA_TIMEZONE"
    fi

    echo "$tz"
}

sync_xray_clients_from_quota_db() {
    local db_file="xray/user_limits.db"
    local config_file="xray/server.jsonc"

    if [ ! -f "$db_file" ] || [ ! -f "$config_file" ]; then
        echo -e "${RED}Quota database or Xray config not found.${NC}"
        return 1
    fi

    local clients_json=""
    while IFS='|' read -r email uuid limit_mb anchor_epoch cycle_start cycle_end cycle_usage last_total status; do
        [ -z "$email" ] && continue
        [ "$email" = "#" ] && continue
        if [ "$status" != "active" ]; then
            continue
        fi

        local entry="                    {\"id\": \"$uuid\", \"flow\": \"\", \"email\": \"$email\"}"
        if [ -n "$clients_json" ]; then
            clients_json+=$'\n'
            clients_json+="${entry},"
        else
            clients_json+="${entry},"
        fi
    done < <(grep -v '^[[:space:]]*$' "$db_file" | grep -v '^#')

    if [ -n "$clients_json" ]; then
        clients_json=${clients_json%,}
    else
        clients_json="                    "
    fi

    local tmp_file
    tmp_file=$(mktemp)

    awk -v clients="$clients_json" '
        BEGIN { in_clients = 0 }
        {
            if ($0 ~ /"clients"[[:space:]]*:[[:space:]]*\[/) {
                print
                print clients
                in_clients = 1
                next
            }
            if (in_clients == 1) {
                if ($0 ~ /^[[:space:]]*\][[:space:]]*,[[:space:]]*$/) {
                    print
                    in_clients = 0
                }
                next
            }
            print
        }
    ' "$config_file" > "$tmp_file"

    mv "$tmp_file" "$config_file"
    echo -e "${GREEN}Updated Xray clients list from quota database.${NC}"
}

reload_xray_container() {
    if [ ! -d "xray" ] || [ ! -f "xray/docker-compose.yml" ]; then
        echo -e "${RED}xray/docker-compose.yml not found.${NC}"
        return 1
    fi

    if [ -z "$DOCKER_COMPOSE_CMD" ]; then
        if ! check_xray_requirements; then
            return 1
        fi
    fi

    cd xray || return 1
    if sudo $DOCKER_COMPOSE_CMD restart xray; then
        cd .. || true
        echo -e "${GREEN}Xray container reloaded successfully.${NC}"
        return 0
    else
        cd .. || true
        echo -e "${RED}Failed to reload Xray container.${NC}"
        return 1
    fi
}

collect_xray_user_stats() {
    local map_file=$1

    : > "$map_file"

    if ! sudo docker ps -q -f name="^/xray_server$" | grep -q .; then
        return 0
    fi

    local raw_stats
    raw_stats=$(sudo docker exec xray_server xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>" 2>/dev/null || true)

    if [ -z "$raw_stats" ]; then
        return 0
    fi

    echo "$raw_stats" | awk '
        /name: "user>>>.*>>>traffic>>>(uplink|downlink)"/ {
            line = $0
            sub(/^.*name: "user>>>/, "", line)
            split(line, pair, ">>>traffic>>>")
            user = pair[1]
            dir = pair[2]
            sub(/".*$/, "", dir)

            if ($0 ~ /value:[[:space:]]*[0-9]+/) {
                val = $0
                sub(/^.*value:[[:space:]]*/, "", val)
                sub(/[^0-9].*$/, "", val)
                print user "|" dir "|" val
                pending_user = ""
                pending_dir = ""
            } else {
                pending_user = user
                pending_dir = dir
            }
            next
        }

        pending_user != "" && /value:[[:space:]]*[0-9]+/ {
            val = $0
            sub(/^.*value:[[:space:]]*/, "", val)
            sub(/[^0-9].*$/, "", val)
            print pending_user "|" pending_dir "|" val
            pending_user = ""
            pending_dir = ""
        }
    ' > "$map_file"
}

check_and_apply_xray_quotas() {
    local db_file="xray/user_limits.db"
    local conf_file="xray/user_limits.conf"

    if [ ! -f "$db_file" ] || [ ! -f "$conf_file" ]; then
        echo -e "${RED}Quota files not found. Install Xray with quotas first.${NC}"
        return 1
    fi

    local timezone
    timezone=$(read_xray_quota_timezone)

    local now_epoch
    now_epoch=$(date +%s)

    local stats_map_file
    stats_map_file=$(mktemp)
    collect_xray_user_stats "$stats_map_file"

    declare -A uplink_map
    declare -A downlink_map

    while IFS='|' read -r email dir value; do
        [ -z "$email" ] && continue
        value=${value:-0}
        if [ "$dir" = "uplink" ]; then
            uplink_map["$email"]=$value
        elif [ "$dir" = "downlink" ]; then
            downlink_map["$email"]=$value
        fi
    done < "$stats_map_file"

    rm -f "$stats_map_file"

    local tmp_db
    tmp_db=$(mktemp)
    echo "# email|uuid|limit_mb|anchor_epoch|cycle_start_epoch|cycle_end_epoch|cycle_usage_bytes|last_total_bytes|status" > "$tmp_db"

    local config_changed=0
    while IFS='|' read -r email uuid limit_mb anchor_epoch cycle_start cycle_end cycle_usage last_total status; do
        [ -z "$email" ] && continue

        calculate_cycle_bounds "$anchor_epoch" "$now_epoch" "$timezone"

        local cycle_rotated=0
        if [ "$cycle_start" != "$CYCLE_START_EPOCH" ] || [ "$cycle_end" != "$CYCLE_END_EPOCH" ]; then
            cycle_usage=0
            cycle_start=$CYCLE_START_EPOCH
            cycle_end=$CYCLE_END_EPOCH
            cycle_rotated=1
            if [ "$status" = "suspended" ]; then
                status="active"
                config_changed=1
                echo -e "${GREEN}Re-enabled user ${email} for new cycle.${NC}"
            fi
        fi

        local current_total=$last_total
        if [ -n "${uplink_map[$email]+set}" ] || [ -n "${downlink_map[$email]+set}" ]; then
            local current_uplink=${uplink_map["$email"]:-0}
            local current_downlink=${downlink_map["$email"]:-0}
            current_total=$((current_uplink + current_downlink))
        fi

        local delta
        if [ "$cycle_rotated" -eq 1 ]; then
            delta=0
        else
            delta=$((current_total - last_total))
            if [ "$delta" -lt 0 ]; then
                delta=$current_total
            fi
        fi

        cycle_usage=$((cycle_usage + delta))
        last_total=$current_total

        if [ "$limit_mb" -gt 0 ]; then
            local limit_bytes=$((limit_mb * 1024 * 1024))
            if [ "$cycle_usage" -ge "$limit_bytes" ] && [ "$status" != "suspended" ]; then
                status="suspended"
                config_changed=1
                echo -e "${YELLOW}User ${email} reached quota (${limit_mb} MB). Suspended.${NC}"
            fi
        fi

        echo "${email}|${uuid}|${limit_mb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}" >> "$tmp_db"
    done < <(grep -v '^[[:space:]]*$' "$db_file" | grep -v '^#')

    mv "$tmp_db" "$db_file"

    if [ "$config_changed" -eq 1 ]; then
        sync_xray_clients_from_quota_db
        reload_xray_container
    fi

    echo -e "${GREEN}Quota check complete.${NC}"
}

show_xray_quota_status() {
    local db_file="xray/user_limits.db"

    if [ ! -f "$db_file" ]; then
        echo -e "${RED}Quota database not found.${NC}"
        return 1
    fi

    local timezone
    timezone=$(read_xray_quota_timezone)

    echo -e "${YELLOW}Timezone:${NC} ${timezone}"
    echo -e "${YELLOW}User quota status (stored usage; run 'Check/apply quotas now' for fresh stats):${NC}"

    while IFS='|' read -r email uuid limit_mb anchor_epoch cycle_start cycle_end cycle_usage last_total status; do
        [ -z "$email" ] && continue

        local usage_mb=$((cycle_usage / 1024 / 1024))
        local cycle_start_h cycle_end_h
        cycle_start_h=$(TZ="$timezone" date -d "@${cycle_start}" "+%Y-%m-%d %H:%M:%S")
        cycle_end_h=$(TZ="$timezone" date -d "@${cycle_end}" "+%Y-%m-%d %H:%M:%S")

        if [ "$limit_mb" -gt 0 ]; then
            local percent=$((cycle_usage * 100 / (limit_mb * 1024 * 1024)))
            echo "- ${email} | status=${status} | usage=${usage_mb}MB / ${limit_mb}MB (${percent}%) | cycle=${cycle_start_h} -> ${cycle_end_h}"
        else
            echo "- ${email} | status=${status} | usage=${usage_mb}MB / unlimited | cycle=${cycle_start_h} -> ${cycle_end_h}"
        fi
    done < <(grep -v '^[[:space:]]*$' "$db_file" | grep -v '^#')
}

select_quota_user() {
    local db_file="xray/user_limits.db"
    if [ ! -f "$db_file" ]; then
        echo -e "${RED}Quota database not found.${NC}"
        return 1
    fi

    QUOTA_SELECTION_EMAIL=""

    local idx=1
    local lines=()
    while IFS='|' read -r email uuid limit_mb anchor_epoch cycle_start cycle_end cycle_usage last_total status; do
        [ -z "$email" ] && continue
        lines+=("$email|$uuid|$limit_mb|$anchor_epoch|$cycle_start|$cycle_end|$cycle_usage|$last_total|$status")
        echo "${idx}) ${email} (status: ${status}, limit: ${limit_mb} MB)"
        idx=$((idx + 1))
    done < <(grep -v '^[[:space:]]*$' "$db_file" | grep -v '^#')

    if [ ${#lines[@]} -eq 0 ]; then
        echo -e "${RED}No users found in quota database.${NC}"
        return 1
    fi

    read -p "Select user [1-${#lines[@]}]: " select_idx
    if ! [[ "$select_idx" =~ ^[0-9]+$ ]] || [ "$select_idx" -lt 1 ] || [ "$select_idx" -gt ${#lines[@]} ]; then
        echo -e "${RED}Invalid selection.${NC}"
        return 1
    fi

    local selected="${lines[$((select_idx - 1))]}"
    QUOTA_SELECTION_EMAIL=$(echo "$selected" | cut -d'|' -f1)
    return 0
}

reset_xray_user_usage() {
    if ! select_quota_user; then
        return 1
    fi

    local target_email="$QUOTA_SELECTION_EMAIL"
    local db_file="xray/user_limits.db"

    local stats_map_file
    stats_map_file=$(mktemp)
    collect_xray_user_stats "$stats_map_file"

    local current_total=0
    while IFS='|' read -r email dir value; do
        [ "$email" != "$target_email" ] && continue
        value=${value:-0}
        current_total=$((current_total + value))
    done < "$stats_map_file"
    rm -f "$stats_map_file"

    local tmp_db
    tmp_db=$(mktemp)
    echo "# email|uuid|limit_mb|anchor_epoch|cycle_start_epoch|cycle_end_epoch|cycle_usage_bytes|last_total_bytes|status" > "$tmp_db"

    local config_changed=0
    while IFS='|' read -r email uuid limit_mb anchor_epoch cycle_start cycle_end cycle_usage last_total status; do
        [ -z "$email" ] && continue

        if [ "$email" = "$target_email" ]; then
            cycle_usage=0
            last_total=$current_total
            if [ "$status" = "suspended" ]; then
                read -p "User is suspended. Re-enable now? [Y/n]: " reenable
                if [[ "$reenable" != "n" && "$reenable" != "N" ]]; then
                    status="active"
                    config_changed=1
                fi
            fi
            echo -e "${GREEN}Usage reset for ${email}.${NC}"
        fi

        echo "${email}|${uuid}|${limit_mb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}" >> "$tmp_db"
    done < <(grep -v '^[[:space:]]*$' "$db_file" | grep -v '^#')

    mv "$tmp_db" "$db_file"

    if [ "$config_changed" -eq 1 ]; then
        sync_xray_clients_from_quota_db
        reload_xray_container
    fi
}

change_xray_user_limit() {
    if ! select_quota_user; then
        return 1
    fi

    local target_email="$QUOTA_SELECTION_EMAIL"
    local db_file="xray/user_limits.db"

    read -p "Enter new monthly limit in MB (0 = unlimited): " new_limit_mb
    if ! [[ "$new_limit_mb" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Limit must be a non-negative integer.${NC}"
        return 1
    fi

    local tmp_db
    tmp_db=$(mktemp)
    echo "# email|uuid|limit_mb|anchor_epoch|cycle_start_epoch|cycle_end_epoch|cycle_usage_bytes|last_total_bytes|status" > "$tmp_db"

    local config_changed=0
    while IFS='|' read -r email uuid limit_mb anchor_epoch cycle_start cycle_end cycle_usage last_total status; do
        [ -z "$email" ] && continue

        if [ "$email" = "$target_email" ]; then
            limit_mb=$new_limit_mb
            if [ "$status" = "suspended" ]; then
                local should_reenable=0
                if [ "$limit_mb" -eq 0 ]; then
                    should_reenable=1
                else
                    local limit_bytes=$((limit_mb * 1024 * 1024))
                    if [ "$cycle_usage" -lt "$limit_bytes" ]; then
                        should_reenable=1
                    fi
                fi

                if [ "$should_reenable" -eq 1 ]; then
                    read -p "New limit allows usage. Re-enable now? [Y/n]: " reenable
                    if [[ "$reenable" != "n" && "$reenable" != "N" ]]; then
                        status="active"
                        config_changed=1
                    fi
                fi
            fi
            echo -e "${GREEN}Updated limit for ${email} to ${limit_mb} MB.${NC}"
        fi

        echo "${email}|${uuid}|${limit_mb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}" >> "$tmp_db"
    done < <(grep -v '^[[:space:]]*$' "$db_file" | grep -v '^#')

    mv "$tmp_db" "$db_file"

    if [ "$config_changed" -eq 1 ]; then
        sync_xray_clients_from_quota_db
        reload_xray_container
    fi
}

manage_xray_quotas() {
    while true; do
        echo ""
        echo -e "${YELLOW}--- Xray Per-User Quota Management ---${NC}"
        echo "1) Show quota status"
        echo "2) Check/apply quotas now"
        echo "3) Reset one user's current cycle usage"
        echo "4) Change one user's monthly limit"
        echo "0) Back"
        read -p "Enter your choice [0-4]: " quota_choice

        case $quota_choice in
            1)
                show_xray_quota_status
                ;;
            2)
                check_and_apply_xray_quotas
                ;;
            3)
                reset_xray_user_usage
                ;;
            4)
                change_xray_user_limit
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Invalid choice.${NC}"
                ;;
        esac
    done
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

show_ss_links() {
    LINKS_FILE="shadowsocks/ss_links.txt"
    if [ -f "shadowsocks/ss_links.txt" ]; then
        LINKS_FILE="shadowsocks/ss_links.txt"
    elif [ -f "ss_links.txt" ]; then
        LINKS_FILE="ss_links.txt"
    else
        echo -e "${RED}No saved SS links found. Please install Shadowsocks first to generate and save links.${NC}"
        return
    fi
    echo -e "\n${GREEN}Saved SS Links:${NC}"
    cat "$LINKS_FILE"
}

delete_xray() {
    echo -e "${YELLOW}Deleting Xray container and config...${NC}"

    # SAFETY CHECK: Only try to enter/delete if directory exists
    if [ ! -d "xray" ]; then
        echo -e "${RED}Directory 'xray' not found. Nothing to delete.${NC}"
        return
    fi

    cd xray || return 1
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

    cd shadowsocks || return 1
    sudo $DOCKER_COMPOSE_CMD down
    cd ..
    rm -rf shadowsocks
    echo -e "${GREEN}Shadowsocks container and config deleted successfully!${NC}"
}

update_script() {
    echo -e "${YELLOW}Checking for updates...${NC}"
    CACHE_BUST="?$(date +%s)"
    LATEST_VERSION=$(curl -s "https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh${CACHE_BUST}" | grep -oE "SCRIPT_VERSION=\"[0-9.]+\"" | cut -d'"' -f2)
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}Could not check for updates. Please check your internet connection or the repository URL.${NC}"
        return
    fi

    if [ "$SCRIPT_VERSION" == "$LATEST_VERSION" ]; then
        echo -e "${GREEN}You are already using the latest version of the script.${NC}"
        return
    fi

    echo -e "${YELLOW}A new version of the script is available: $LATEST_VERSION${NC}"
    read -p "Do you want to update? [Y/n]: " update_confirm
    if [[ "$update_confirm" == "n" || "$update_confirm" == "N" ]]; then
        echo -e "${RED}Update cancelled.${NC}"
        return
    fi

    echo -e "${YELLOW}Updating script...${NC}"
    curl -s "https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh${CACHE_BUST}" > proxy.sh
    echo -e "${GREEN}Script updated successfully! Restarting...${NC}"
    exec bash "$0" "$@"
}

# Function to restore deployment from existing config files
restore_deployment() {
    echo -e "${YELLOW}Restore Deployment - Re-deploy containers from existing config files${NC}"
    echo -e "${YELLOW}Use this when Docker was reinstalled or containers were accidentally deleted.${NC}\n"

    # Check for existing configurations
    XRAY_CONFIG_EXISTS=false
    SS_CONFIG_EXISTS=false

    if [ -d "xray" ] && [ -f "xray/docker-compose.yml" ] && [ -f "xray/server.jsonc" ]; then
        XRAY_CONFIG_EXISTS=true
        echo -e "${GREEN}✓ Xray configuration found${NC}"
        echo "  - xray/docker-compose.yml"
        echo "  - xray/server.jsonc"
        if [ -f "xray/vless_links.txt" ]; then
            echo "  - xray/vless_links.txt"
        fi
    else
        echo -e "${RED}✗ Xray configuration not found${NC}"
    fi

    if [ -d "shadowsocks" ] && [ -f "shadowsocks/docker-compose.yml" ] && [ -f "shadowsocks/server.json" ]; then
        SS_CONFIG_EXISTS=true
        echo -e "${GREEN}✓ Shadowsocks configuration found${NC}"
        echo "  - shadowsocks/docker-compose.yml"
        echo "  - shadowsocks/server.json"
        if [ -f "shadowsocks/ss_links.txt" ]; then
            echo "  - shadowsocks/ss_links.txt"
        fi
    else
        echo -e "${RED}✗ Shadowsocks configuration not found${NC}"
    fi

    echo ""

    if [ "$XRAY_CONFIG_EXISTS" = false ] && [ "$SS_CONFIG_EXISTS" = false ]; then
        echo -e "${RED}No existing configurations found. Please install using options 2 or 3.${NC}"
        return 1
    fi

    echo "Which deployment do you want to restore?"
    if [ "$XRAY_CONFIG_EXISTS" = true ]; then
        echo "1) Xray (VLESS-XHTTP-Reality)"
    fi
    if [ "$SS_CONFIG_EXISTS" = true ]; then
        echo "2) Shadowsocks (ssserver-rust)"
    fi
    if [ "$XRAY_CONFIG_EXISTS" = true ] && [ "$SS_CONFIG_EXISTS" = true ]; then
        echo "3) Both"
    fi
    echo "0) Cancel"
    read -p "Enter your choice: " restore_choice

    case $restore_choice in
        1)
            if [ "$XRAY_CONFIG_EXISTS" = true ]; then
                restore_xray
            else
                echo -e "${RED}Xray configuration not available.${NC}"
            fi
            ;;
        2)
            if [ "$SS_CONFIG_EXISTS" = true ]; then
                restore_shadowsocks
            else
                echo -e "${RED}Shadowsocks configuration not available.${NC}"
            fi
            ;;
        3)
            if [ "$XRAY_CONFIG_EXISTS" = true ] && [ "$SS_CONFIG_EXISTS" = true ]; then
                restore_xray
                restore_shadowsocks
            else
                echo -e "${RED}Both configurations are not available.${NC}"
            fi
            ;;
        0)
            echo -e "${YELLOW}Restore cancelled.${NC}"
            ;;
        *)
            echo -e "${RED}Invalid choice.${NC}"
            ;;
    esac
}

# Function to restore Xray container
restore_xray() {
    echo -e "\n${YELLOW}Restoring Xray deployment...${NC}"

    # Check if container already exists
    if sudo docker ps -a -q -f name="^/xray_server$" | grep -q .; then
        echo -e "${YELLOW}Xray container already exists. Checking status...${NC}"
        if sudo docker ps -q -f name="^/xray_server$" | grep -q .; then
            echo -e "${GREEN}Xray container is already running!${NC}"
            return 0
        else
            echo -e "${YELLOW}Container exists but is stopped. Starting...${NC}"
            cd xray || return 1
            sudo $DOCKER_COMPOSE_CMD start
            cd ..
            echo -e "${GREEN}Xray container started successfully!${NC}"
            return 0
        fi
    fi

    # Pull image and start container
    echo "Pulling teddysun/xray image..."
    sudo docker pull teddysun/xray

    cd xray || return 1

    echo -e "${YELLOW}Starting Xray container...${NC}"
    if sudo $DOCKER_COMPOSE_CMD up -d; then
        echo -e "${GREEN}Xray container has been restored and started!${NC}"
        echo "Your existing configuration and links are preserved."
        if [ -f "vless_links.txt" ]; then
            echo -e "\n${GREEN}Your VLESS links:${NC}"
            cat vless_links.txt
        fi
    else
        echo -e "${RED}Failed to start Xray container.${NC}"
        cd ..
        return 1
    fi

    cd ..
}

# Function to restore Shadowsocks container
restore_shadowsocks() {
    echo -e "\n${YELLOW}Restoring Shadowsocks deployment...${NC}"

    # Check if container already exists
    if sudo docker ps -a -q -f name="^/ssserver$" | grep -q .; then
        echo -e "${YELLOW}Shadowsocks container already exists. Checking status...${NC}"
        if sudo docker ps -q -f name="^/ssserver$" | grep -q .; then
            echo -e "${GREEN}Shadowsocks container is already running!${NC}"
            return 0
        else
            echo -e "${YELLOW}Container exists but is stopped. Starting...${NC}"
            cd shadowsocks || return 1
            sudo $DOCKER_COMPOSE_CMD start
            cd ..
            echo -e "${GREEN}Shadowsocks container started successfully!${NC}"
            return 0
        fi
    fi

    # Pull image and start container
    echo "Pulling ghcr.io/shadowsocks/ssserver-rust image..."
    sudo docker pull ghcr.io/shadowsocks/ssserver-rust:latest

    cd shadowsocks || return 1

    echo -e "${YELLOW}Starting Shadowsocks container...${NC}"
    if sudo $DOCKER_COMPOSE_CMD up -d; then
        echo -e "${GREEN}Shadowsocks container has been restored and started!${NC}"
        echo "Your existing configuration and links are preserved."
        if [ -f "ss_links.txt" ]; then
            echo -e "\n${GREEN}Your SS links:${NC}"
            cat ss_links.txt
        fi
    else
        echo -e "${RED}Failed to start Shadowsocks container.${NC}"
        cd ..
        return 1
    fi

    cd ..
}

# --- Main Script ---

handle_root_user_flow() {
    echo -e "${RED}Please do not run this script as root. Use sudo when prompted.${NC}"
    read -p "Do you want to create/use a non-root user now and relaunch the script? [y/N]: " root_flow_confirm
    if [[ "$root_flow_confirm" != "y" && "$root_flow_confirm" != "Y" ]]; then
        exit 1
    fi

    if ! command -v useradd >/dev/null 2>&1; then
        echo -e "${RED}'useradd' command not found. Please create a non-root user manually, then run this script as that user.${NC}"
        exit 1
    fi

    read -p "Enter non-root username to use/create: " new_username
    if [ -z "$new_username" ]; then
        echo -e "${RED}Username cannot be empty.${NC}"
        exit 1
    fi

    if ! [[ "$new_username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo -e "${RED}Invalid username. Use lowercase letters, numbers, '_' or '-' and start with a letter or '_'.${NC}"
        exit 1
    fi

    if id "$new_username" >/dev/null 2>&1; then
        echo -e "${YELLOW}User '$new_username' already exists. Reusing it.${NC}"
    else
        echo -e "${YELLOW}Creating user '$new_username'...${NC}"
        useradd -m -s /bin/bash "$new_username"
        echo -e "${YELLOW}Set a password for '$new_username':${NC}"
        passwd "$new_username"
    fi

    if getent group sudo >/dev/null 2>&1; then
        usermod -aG sudo "$new_username"
        echo -e "${GREEN}Added '$new_username' to sudo group.${NC}"
    elif getent group wheel >/dev/null 2>&1; then
        usermod -aG wheel "$new_username"
        echo -e "${GREEN}Added '$new_username' to wheel group.${NC}"
    else
        echo -e "${YELLOW}Could not detect sudo/wheel group automatically.${NC}"
        echo -e "${YELLOW}Please grant sudo privileges manually if needed.${NC}"
    fi

    local script_path target_home launch_script escaped_launch_script escaped_probe_path
    script_path="$0"

    if command -v realpath >/dev/null 2>&1; then
        script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    fi

    target_home=$(getent passwd "$new_username" | cut -d: -f6)
    if [ -z "$target_home" ]; then
        target_home="/home/$new_username"
    fi

    launch_script="$script_path"

    # If the target user cannot read the current script path (e.g. /root/proxy.sh),
    # copy it to the target user's home and run from there.
    printf -v escaped_probe_path '%q' "$script_path"
    if [ ! -r "$script_path" ] || ! su - "$new_username" -c "test -r $escaped_probe_path" >/dev/null 2>&1; then
        launch_script="$target_home/proxy.sh"
        cp "$script_path" "$launch_script"
        chown "$new_username":"$new_username" "$launch_script"
        chmod 700 "$launch_script"
        echo -e "${YELLOW}Current script path is not readable by '$new_username'. Copied launcher to ${launch_script}.${NC}"
    fi

    printf -v escaped_launch_script '%q' "$launch_script"

    echo -e "${GREEN}Relaunching as '$new_username'...${NC}"
    exec su - "$new_username" -c "bash $escaped_launch_script"
}

# Make sure the script is not run as root
if [ "$EUID" -eq 0 ]; then
  handle_root_user_flow
fi

# CHECK DEPENDENCIES NOW (Running as non-root, will use sudo inside)
check_dependencies

echo -e "${YELLOW}--- Proxy Installer v${SCRIPT_VERSION} ---${NC}"
echo "Please choose an option:"
echo "0) Update this script"
echo "1) Environment Check (Check distro and install Docker)"
echo "2) Install Xray (VLESS-XHTTP-Reality)"
echo "3) Install Shadowsocks (ssserver-rust)"
echo "4) Update existing container (Xray / Shadowsocks)"
echo "5) Restore deployment from existing config"
echo "6) Show VLESS links for current config"
echo "7) Show SS links for current config"
echo "8) Delete container and config (Xray / Shadowsocks)"
echo "9) Manage Xray per-user data quotas"
echo "10) Exit"
read -p "Enter your choice [0-10]: " choice

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
        if ! check_xray_requirements; then
            exit 1
        fi
        restore_deployment
        ;;
    6)
        show_links
        ;;
    7)
        show_ss_links
        ;;
    8)
        if ! check_xray_requirements; then
            exit 1
        fi
        echo "Which container do you want to delete?"
        echo "1) Xray"
        echo "2) Shadowsocks"
        echo "3) Both"
        read -p "Enter your choice [1-3]: " delete_choice
        case $delete_choice in
            1)
                delete_xray
                ;;
            2)
                delete_shadowsocks
                ;;
            3)
                delete_xray
                delete_shadowsocks
                ;;
            *)
                echo -e "${RED}Invalid choice. Exiting.${NC}"
                ;;
        esac
        ;;
    9)
        if ! check_xray_requirements; then
            exit 1
        fi
        manage_xray_quotas
        ;;
    10)
        echo -e "${GREEN}Goodbye!${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid choice. Exiting.${NC}"
        ;;
esac
