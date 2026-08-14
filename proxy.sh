#!/bin/bash
set -euo pipefail
#
# proxy.sh: An automated script to install and manage a proxy server.
#

# --- Configuration & Colors ---
SCRIPT_VERSION="3.16.0"
DEFAULT_UUIDS=1
DEFAULT_SHORTIDS=3
DEFAULT_SS_USERS=1
DEFAULT_SS_PORT=80
DEFAULT_QUOTA_TIMEZONE="UTC"
DEFAULT_USER_LIMIT_GB=300
XRAY_QUOTA_CRON_MARKER="# proxy-sh:xray-quota-check"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Privilege check & sudo helper
SUDO=""
if [[ "$EUID" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo -e "${RED}This script requires root privileges or sudo.${NC}" >&2
        exit 1
    fi
fi

# Global variable for Docker Compose command
DOCKER_COMPOSE_CMD=()
XRAY_DOCKER_IMAGE="teddysun/xray:latest"
SS_DOCKER_IMAGE="ghcr.io/shadowsocks/ssserver-rust:latest"

# Global scratch directory & cleanup trap for temporary files
SCRIPT_TMP_DIR=""
init_script_tmp_dir() {
    if [[ -z "$SCRIPT_TMP_DIR" || ! -d "$SCRIPT_TMP_DIR" ]]; then
        SCRIPT_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/proxy-sh.XXXXXX") || {
            echo -e "${RED}Failed to create temporary directory.${NC}" >&2
            exit 1
        }
    fi
}
init_script_tmp_dir

cleanup_script_tmp_dir() {
    if [[ -n "${SCRIPT_TMP_DIR:-}" && -d "$SCRIPT_TMP_DIR" ]]; then
        rm -rf "$SCRIPT_TMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup_script_tmp_dir EXIT INT TERM

# --- Generic utilities ---

generate_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        local hex
        hex=$(openssl rand -hex 16)
        printf '%s-%s-4%s-%s%s-%s\n' \
            "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
            "$(printf '%x' $(( (0x${hex:16:2} & 0x3f) | 0x80 )))" "${hex:18:2}" "${hex:20:12}"
    fi
}

make_temp_file() {
    local result_var=$1
    local template=${2:-}
    local tmp

    init_script_tmp_dir

    if [[ -n "$template" ]]; then
        if [[ "$template" != /* ]]; then
            tmp=$(mktemp "${SCRIPT_TMP_DIR}/${template}") || return 1
        else
            tmp=$(mktemp "$template") || return 1
        fi
    else
        tmp=$(mktemp "${SCRIPT_TMP_DIR}/tmp.XXXXXX") || return 1
    fi

    printf -v "$result_var" '%s' "$tmp"
}

url_encode_component() {
    local input=$1
    local output="" char hex
    local LC_ALL=C
    local i

    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        case "$char" in
            [a-zA-Z0-9.~_-]) output+="$char" ;;
            *)
                printf -v hex '%02X' "'$char"
                output+="%${hex}"
                ;;
        esac
    done

    printf '%s' "$output"
}

format_uri_host() {
    local host=$1
    if [[ "$host" == \[*\] ]]; then
        printf '%s' "$host"
    elif [[ "$host" == *:* ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

base64url_encode() {
    printf '%s' "$1" | base64 | tr -d '\n=' | tr '/+' '_-'
}

apply_preserved_file_metadata() {
    local target_file="$1"
    local temp_file="$2"

    if [[ -e "$target_file" ]]; then
        local uid gid mode
        uid=$(stat -c %u "$target_file" 2>/dev/null || true)
        gid=$(stat -c %g "$target_file" 2>/dev/null || true)
        mode=$(stat -c %a "$target_file" 2>/dev/null || true)

        if [[ -n "$uid" ]] && [[ -n "$gid" ]]; then
            chown "$uid:$gid" "$temp_file" 2>/dev/null || true
        fi
        if [[ -n "$mode" ]]; then
            chmod "$mode" "$temp_file" 2>/dev/null || true
        fi
    fi
}

resolve_script_path() {
    local path="$0"
    if command -v realpath >/dev/null 2>&1; then
        path=$(realpath "$0" 2>/dev/null || echo "$0")
    elif [[ "$path" != /* ]]; then
        local script_dir
        script_dir=$(cd -- "$(dirname -- "$path")" && pwd -P) || return 1
        path="${script_dir}/$(basename -- "$path")"
    fi
    echo "$path"
}

# --- System and dependency helpers ---

install_system_packages() {
    if command -v apt-get &> /dev/null; then
        $SUDO apt-get update && $SUDO apt-get install -y "$@"
    elif command -v dnf &> /dev/null; then
        $SUDO dnf install -y "$@"
    elif command -v yum &> /dev/null; then
        $SUDO yum install -y "$@"
    else
        return 1
    fi
}

check_dependencies() {
    local dependencies=("curl" "openssl" "jq")
    local missing_deps=()

    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        echo -e "${YELLOW}Missing dependencies: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}Attempting to install them...${NC}"

        if ! install_system_packages "${missing_deps[@]}"; then
            echo -e "${RED}Could not detect package manager. Please install manually: ${missing_deps[*]}${NC}"
            return 1
        fi

        # Verify installation
        for cmd in "${missing_deps[@]}"; do
            if ! command -v "$cmd" &> /dev/null; then
                 echo -e "${RED}Failed to install $cmd. Please install manually.${NC}"
                 return 1
            fi
        done
        echo -e "${GREEN}Dependencies installed successfully!${NC}"
    fi
}

ensure_jq() {
    if command -v jq &> /dev/null; then
        return 0
    fi

    echo -e "${YELLOW}This feature requires 'jq' to read/edit JSON configs. Installing it now...${NC}"

    if ! install_system_packages jq; then
        echo -e "${RED}Could not detect package manager. Please install 'jq' manually.${NC}"
        return 1
    fi

    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Failed to install 'jq'. Please install it manually.${NC}"
        return 1
    fi

    echo -e "${GREEN}'jq' installed successfully!${NC}"
    return 0
}

check_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO=$ID
    else
        echo -e "${RED}Cannot detect Linux distribution.${NC}"
        return 1
    fi
}

# --- Docker and Compose infrastructure ---

setup_docker_apt_repo() {
    if [[ -z "${DISTRO:-}" ]]; then
        check_distro || return 1
    fi

    $SUDO install -m 0755 -d /etc/apt/keyrings

    local repo_url repo_codename
    if [[ "$DISTRO" = "linuxmint" ]]; then
        local ubuntu_codename=""
        if [[ -f /etc/os-release ]]; then
            ubuntu_codename=$(grep -E '^UBUNTU_CODENAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"\r\n' || true)
        fi
        if [[ -z "$ubuntu_codename" && -f /etc/upstream-release/lsb-release ]]; then
            ubuntu_codename=$(grep -E '^DISTRIB_CODENAME=' /etc/upstream-release/lsb-release | cut -d'=' -f2 | tr -d '"\r\n' || true)
        fi
        if [[ -z "$ubuntu_codename" ]]; then
            echo -e "${RED}Could not determine underlying Ubuntu codename for Linux Mint.${NC}" >&2
            return 1
        fi
        echo -e "${YELLOW}Linux Mint detected, using Ubuntu codename: $ubuntu_codename${NC}"
        repo_url="https://download.docker.com/linux/ubuntu"
        repo_codename="$ubuntu_codename"
    elif [[ "$DISTRO" = "debian" ]]; then
        repo_url="https://download.docker.com/linux/debian"
        repo_codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    else
        repo_url="https://download.docker.com/linux/ubuntu"
        repo_codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    fi

    if [[ -z "$repo_codename" ]]; then
        echo -e "${RED}Could not determine distribution codename from /etc/os-release.${NC}" >&2
        return 1
    fi

    curl -fsSL "${repo_url}/gpg" | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $repo_url $repo_codename stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
}

install_docker_packages() {
    if [[ -z "${DISTRO:-}" ]]; then
        check_distro || return 1
    fi

    echo "Installing Docker for ${DISTRO}..."
    case "$DISTRO" in
        ubuntu|debian|linuxmint)

            $SUDO apt-get update
            if ! $SUDO apt-get install -y ca-certificates curl gnupg; then
                echo -e "${RED}Failed to install prerequisites. Please install them manually.${NC}"
                return 1
            fi

            setup_docker_apt_repo

            # Update and install Docker
            $SUDO apt-get update
            if ! $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
                echo -e "${RED}Failed to install Docker. Please install it manually.${NC}"
                return 1
            fi
            ;;
        centos|rhel|fedora)
            $SUDO dnf -y install dnf-plugins-core
            $SUDO dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            $SUDO dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        *)
            echo -e "${RED}Unsupported distribution for automatic Docker installation. Please install Docker and Docker Compose manually.${NC}"
            return 1
            ;;
    esac

    # Start and enable Docker service
    if $SUDO systemctl start docker 2>/dev/null; then
        echo -e "${GREEN}Docker service started successfully.${NC}"
    else
        echo -e "${YELLOW}Could not start Docker service. You may need to start it manually.${NC}"
    fi

    if $SUDO systemctl enable docker 2>/dev/null; then
        echo -e "${GREEN}Docker service enabled for auto-start.${NC}"
    else
        echo -e "${YELLOW}Could not enable Docker service. You may need to enable it manually.${NC}"
    fi

    # Verify Docker installation
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}Docker has been installed successfully.${NC}"
    else
        echo -e "${RED}Docker installation failed. Please install it manually.${NC}"
        return 1
    fi
}

install_docker_compose() {
    if [[ -z "${DISTRO:-}" ]]; then
        check_distro || return 1
    fi

    echo -e "${YELLOW}Installing Docker Compose...${NC}"
    case "$DISTRO" in
        ubuntu|debian|linuxmint)
            # Try to install docker-compose-plugin
            if $SUDO apt-get install -y docker-compose-plugin 2>/dev/null; then
                echo -e "${GREEN}Docker Compose plugin installed successfully.${NC}"
            else
                echo -e "${YELLOW}Docker Compose plugin not available, trying alternative installation...${NC}"
                if ! $SUDO apt-get install -y ca-certificates curl gnupg; then
                    echo -e "${RED}Failed to install prerequisites for Docker Compose.${NC}"
                    return 1
                fi

                setup_docker_apt_repo

                # Remove conflicting packages that might be installed from distro repos
                echo -e "${YELLOW}Removing conflicting packages to avoid installation errors...${NC}"
                $SUDO apt-get remove -y docker-buildx docker-compose docker-doc podman-docker || true

                $SUDO apt-get update
                if $SUDO apt-get install -y docker-compose-plugin; then
                    echo -e "${GREEN}Docker Compose plugin installed successfully from Docker repository.${NC}"
                else
                    echo -e "${RED}Failed to install Docker Compose. Please install it manually.${NC}"
                    return 1
                fi
            fi
            ;;
        centos|rhel|fedora)
            $SUDO dnf install -y docker-compose-plugin
            ;;
        *)
            echo -e "${RED}Unsupported distribution for automatic Docker Compose installation. Please install it manually.${NC}"
            return 1
            ;;
    esac
}

install_docker() {
    # Check if Docker is installed
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}Docker is already installed.${NC}"
    else
        echo -e "${YELLOW}Docker is not installed.${NC}"
        read -p "$(echo -e ${YELLOW}Would you like to install Docker? [y/N]: ${NC})" install_confirm
        if [[ "$install_confirm" != "y" && "$install_confirm" != "Y" ]]; then
            echo -e "${RED}Docker installation cancelled.${NC}"
            return 1
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

ensure_docker_compose() {
    if [[ ${#DOCKER_COMPOSE_CMD[@]} -gt 0 ]]; then
        return 0
    fi

    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker is not installed. Please run option 1 (Environment Check) first.${NC}"
        return 1
    fi
    echo -e "${YELLOW}Checking Docker Compose availability...${NC}"

    # Check for both docker-compose (hyphen) and docker compose (space) versions
    # Prioritise the newer 'docker compose' version (with space)
    if docker compose version &> /dev/null 2>&1; then
        DOCKER_COMPOSE_CMD=(docker compose)
        echo -e "${GREEN}Using Docker Compose: ${DOCKER_COMPOSE_CMD[*]}${NC}"
    elif command -v docker-compose &> /dev/null; then
        echo -e "${YELLOW}Found docker-compose (old version), testing if it works...${NC}"
        if docker-compose version &> /dev/null 2>&1; then
            DOCKER_COMPOSE_CMD=(docker-compose)
            echo -e "${GREEN}Using Docker Compose: ${DOCKER_COMPOSE_CMD[*]}${NC}"
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

check_environment() {
    echo -e "${YELLOW}Checking environment...${NC}"
    check_distro
    install_docker
    echo -e "${GREEN}Environment check completed!${NC}"
}

# --- Shared container lifecycle ---

reload_xray_container() {
    if [[ ! -d "xray" ]] || [[ ! -f "xray/docker-compose.yml" ]]; then
        echo -e "${RED}xray/docker-compose.yml not found.${NC}"
        return 1
    fi

    if ! ensure_docker_compose; then
        return 1
    fi

    if ( cd xray && $SUDO "${DOCKER_COMPOSE_CMD[@]}" restart xray ); then
        echo -e "${GREEN}Xray container reloaded successfully.${NC}"
        return 0
    else
        echo -e "${RED}Failed to reload Xray container.${NC}"
        return 1
    fi
}

reload_shadowsocks_container() {
    if [[ ! -d "shadowsocks" ]] || [[ ! -f "shadowsocks/docker-compose.yml" ]]; then
        echo -e "${RED}shadowsocks/docker-compose.yml not found.${NC}"
        return 1
    fi

    if ! ensure_docker_compose; then
        return 1
    fi

    if (cd shadowsocks && $SUDO "${DOCKER_COMPOSE_CMD[@]}" restart ssserver); then
        echo -e "${GREEN}Shadowsocks container reloaded successfully.${NC}"
        return 0
    else
        echo -e "${RED}Failed to reload Shadowsocks container.${NC}"
        return 1
    fi
}

restore_compose_and_restart() {
    local dir=$1
    local backup_file=$2

    if ! cp -p "$backup_file" "$dir/docker-compose.yml"; then
        echo -e "${RED}Failed to restore the previous docker-compose.yml.${NC}" >&2
        return 1
    fi

    if ( cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d ); then
        echo -e "${YELLOW}Previous container configuration restored.${NC}"
        return 0
    fi

    echo -e "${RED}Previous compose file was restored, but the container could not be restarted. Manual recovery is required.${NC}" >&2
    return 1
}

release_version_lock_if_needed() {
    local dir=$1
    local base_image=$2
    local default_tag=$3

    if [[ ! -f "$dir/docker-compose.yml" ]]; then
        return 0
    fi

    local current_image
    current_image=$(grep -E '^\s*image:' "$dir/docker-compose.yml" | awk '{print $2}' || true)
    if [[ -z "$current_image" ]]; then
        return 0
    fi

    local expected_default="$base_image"
    if [[ -n "$default_tag" ]]; then
        expected_default="${base_image}:${default_tag}"
    fi

    if [[ "$current_image" != "$expected_default" ]] && [[ "$current_image" != "$base_image" ]]; then
        if ! ensure_docker_compose; then
            return 1
        fi

        echo -e "${YELLOW}Releasing version lock ($current_image) and resetting to latest...${NC}"
        local tmp_file backup_file
        make_temp_file tmp_file
        make_temp_file backup_file
        cp -p "$dir/docker-compose.yml" "$backup_file"

        if ! awk -v new_img="$expected_default" '/^[[:space:]]*image:[[:space:]]*/ { sub(/image:[[:space:]]*.*/, "image: " new_img) } { print }' "$dir/docker-compose.yml" > "$tmp_file"; then
            rm -f "$tmp_file" "$backup_file"
            echo -e "${RED}Failed to update docker-compose.yml to release lock.${NC}"
            return 1
        fi
        apply_preserved_file_metadata "$dir/docker-compose.yml" "$tmp_file"
        mv "$tmp_file" "$dir/docker-compose.yml"

        echo "Recreating container with latest image..."
        if ( cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" pull && $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d ); then
            rm -f "$backup_file"
            echo -e "${GREEN}Reset to latest version successfully.${NC}"
            return 2
        fi

        echo -e "${RED}Failed to recreate container with latest image. Rolling back...${NC}"
        restore_compose_and_restart "$dir" "$backup_file" || true
        rm -f "$backup_file"
        return 1
    fi
    return 0
}

update_container() {
    local container_name=$1
    local compose_dir=$2
    local base_image=$3
    local default_tag=${4:-}

    if ! ensure_docker_compose; then
        return 1
    fi

    if ! $SUDO docker ps -a -q -f name="^/${container_name}$" | grep -q .; then
        echo -e "${RED}Container '${container_name}' not found. Cannot update.${NC}"
        return 1
    fi

    # Release version lock if present
    local lock_status=0
    release_version_lock_if_needed "$compose_dir" "$base_image" "$default_tag" || lock_status=$?
    if [[ "$lock_status" -eq 1 ]]; then
        return 1
    elif [[ "$lock_status" -eq 2 ]]; then
        return 0
    fi

    echo "Updating ${container_name} to latest image..."

    if ( cd "$compose_dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" pull && $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d ); then
        echo -e "${GREEN}${container_name} updated successfully.${NC}"
        return 0
    else
        echo -e "${RED}Failed to update ${container_name}.${NC}"
        return 1
    fi
}

update_xray() {
    update_container "xray_server" "xray" "${XRAY_DOCKER_IMAGE%%:*}" ""
}

update_shadowsocks() {
    update_container "ssserver" "shadowsocks" "${SS_DOCKER_IMAGE%%:*}" "latest"
}

change_container_version() {
    echo ""
    echo -e "${YELLOW}--- Change Container Version (Downgrade/Upgrade) ---${NC}"
    echo "1) Xray"
    echo "2) Shadowsocks"
    echo "0) Back"
    read -p "Select the container [0-2]: " container_choice

    local dir=""
    local container_name=""
    local base_image=""

    case $container_choice in
        1)
            dir="xray"
            container_name="xray_server"
            base_image="${XRAY_DOCKER_IMAGE%%:*}"
            ;;
        2)
            dir="shadowsocks"
            container_name="ssserver"
            base_image="${SS_DOCKER_IMAGE%%:*}"
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}Invalid choice.${NC}"
            return 1
            ;;
    esac

    if [[ ! -d "$dir" ]] || [[ ! -f "$dir/docker-compose.yml" ]]; then
        echo -e "${RED}Container directory or docker-compose.yml for ${dir} not found.${NC}"
        return 1
    fi

    # Read current image configuration
    local current_image
    current_image=$(grep -E '^\s*image:' "$dir/docker-compose.yml" | awk '{print $2}' || true)
    if [[ -z "$current_image" ]]; then
        echo -e "${RED}Could not find 'image:' configuration in $dir/docker-compose.yml.${NC}" >&2
        return 1
    fi
    echo -e "Current image in docker-compose.yml: ${GREEN}${current_image}${NC}"

    echo ""
    echo "Enter the specific version tag you want to downgrade/upgrade to:"
    read -p "Target version tag: " target_version

    target_version=$(echo "$target_version" | xargs)
    if [[ -z "$target_version" ]]; then
        echo -e "${RED}Version tag cannot be empty.${NC}"
        return 1
    fi
    if ! [[ "$target_version" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
        echo -e "${RED}Invalid container version tag.${NC}"
        return 1
    fi

    local new_image="$base_image"
    if [[ "$target_version" != "latest" ]]; then
        new_image="${base_image}:${target_version}"
    fi

    echo -e "Changing image to: ${YELLOW}${new_image}${NC}..."

    if ! ensure_docker_compose; then
        return 1
    fi

    local tmp_file backup_file
    make_temp_file tmp_file
    make_temp_file backup_file
    cp -p "$dir/docker-compose.yml" "$backup_file"

    if ! awk -v new_img="$new_image" '/^[[:space:]]*image:[[:space:]]*/ { sub(/image:[[:space:]]*.*/, "image: " new_img) } { print }' "$dir/docker-compose.yml" > "$tmp_file"; then
        rm -f "$tmp_file" "$backup_file"
        echo -e "${RED}Failed to update docker-compose.yml.${NC}"
        return 1
    fi
    apply_preserved_file_metadata "$dir/docker-compose.yml" "$tmp_file"
    mv "$tmp_file" "$dir/docker-compose.yml"

    echo "Pulling new image version..."
    if ( cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" pull && $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d ); then
        rm -f "$backup_file"
        echo -e "${GREEN}Successfully changed version to: ${target_version}${NC}"
        return 0
    fi

    echo -e "${RED}Failed to apply new version. Rolling back...${NC}"
    restore_compose_and_restart "$dir" "$backup_file" || true
    rm -f "$backup_file"
    return 1
}

restore_container() {
    local service_name=$1
    local container_name=$2
    local dir=$3
    local docker_image=$4
    local links_file=$5
    local link_type=$6

    echo -e "\n${YELLOW}Restoring ${service_name} deployment...${NC}"

    # Check if container already exists
    if $SUDO docker ps -a -q -f name="^/${container_name}$" | grep -q .; then
        echo -e "${YELLOW}${service_name} container already exists. Checking status...${NC}"
        if $SUDO docker ps -q -f name="^/${container_name}$" | grep -q .; then
            echo -e "${GREEN}${service_name} container is already running!${NC}"
            return 0
        else
            echo -e "${YELLOW}Container exists but is stopped. Starting...${NC}"
            ( cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" start ) || return 1
            echo -e "${GREEN}${service_name} container started successfully!${NC}"
            return 0
        fi
    fi

    echo "Pulling ${docker_image} image..."
    $SUDO docker pull "$docker_image"

    ( cd "$dir" || return 1

    echo -e "${YELLOW}Starting ${service_name} container...${NC}"
    if $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d; then
        echo -e "${GREEN}${service_name} container has been restored and started!${NC}"
        echo "Your existing configuration and links are preserved."
        if [[ -f "$links_file" ]]; then
            echo -e "\n${GREEN}Your ${link_type} links:${NC}"
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                echo "$line"
                echo
            done < "$links_file"
        fi
    else
        echo -e "${RED}Failed to start ${service_name} container.${NC}"
        return 1
    fi

    ) || return 1
}

restore_xray() {
    restore_container "Xray" "xray_server" "xray" "$XRAY_DOCKER_IMAGE" "vless_links.txt" "VLESS"
}

restore_shadowsocks() {
    restore_container "Shadowsocks" "ssserver" "shadowsocks" "$SS_DOCKER_IMAGE" "ss_links.txt" "SS"
}

restore_deployment() {
    echo -e "${YELLOW}Restore Deployment - Re-deploy containers from existing config files${NC}"
    echo -e "${YELLOW}Use this when Docker was reinstalled or containers were accidentally deleted.${NC}\n"

    local XRAY_CONFIG_EXISTS=0
    local SS_CONFIG_EXISTS=0
    local restore_choice

    if [[ -d "xray" ]] && [[ -f "xray/docker-compose.yml" ]] && [[ -f "xray/server.jsonc" ]]; then
        XRAY_CONFIG_EXISTS=1
        echo -e "${GREEN}✓ Xray configuration found${NC}"
        echo "  - xray/docker-compose.yml"
        echo "  - xray/server.jsonc"
        if [[ -f "xray/vless_links.txt" ]]; then
            echo "  - xray/vless_links.txt"
        fi
    else
        echo -e "${RED}✗ Xray configuration not found${NC}"
    fi

    if [[ -d "shadowsocks" ]] && [[ -f "shadowsocks/docker-compose.yml" ]] && [[ -f "shadowsocks/server.json" ]]; then
        SS_CONFIG_EXISTS=1
        echo -e "${GREEN}✓ Shadowsocks configuration found${NC}"
        echo "  - shadowsocks/docker-compose.yml"
        echo "  - shadowsocks/server.json"
        if [[ -f "shadowsocks/ss_links.txt" ]]; then
            echo "  - shadowsocks/ss_links.txt"
        fi
    else
        echo -e "${RED}✗ Shadowsocks configuration not found${NC}"
    fi

    echo ""

    if [[ "$XRAY_CONFIG_EXISTS" -eq 0 ]] && [[ "$SS_CONFIG_EXISTS" -eq 0 ]]; then
        echo -e "${RED}No existing configurations found. Please install using options 2 or 3.${NC}"
        return 1
    fi

    echo "Which deployment do you want to restore?"
    if [[ "$XRAY_CONFIG_EXISTS" -eq 1 ]]; then
        echo "1) Xray (VLESS-XHTTP-Reality)"
    fi
    if [[ "$SS_CONFIG_EXISTS" -eq 1 ]]; then
        echo "2) Shadowsocks (ssserver-rust)"
    fi
    if [[ "$XRAY_CONFIG_EXISTS" -eq 1 ]] && [[ "$SS_CONFIG_EXISTS" -eq 1 ]]; then
        echo "3) Both"
    fi
    echo "0) Cancel"
    read -p "Enter your choice: " restore_choice

    case $restore_choice in
        1)
            if [[ "$XRAY_CONFIG_EXISTS" -eq 1 ]]; then
                restore_xray
            else
                echo -e "${RED}Xray configuration not available.${NC}"
            fi
            ;;
        2)
            if [[ "$SS_CONFIG_EXISTS" -eq 1 ]]; then
                restore_shadowsocks
            else
                echo -e "${RED}Shadowsocks configuration not available.${NC}"
            fi
            ;;
        3)
            if [[ "$XRAY_CONFIG_EXISTS" -eq 1 ]] && [[ "$SS_CONFIG_EXISTS" -eq 1 ]]; then
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

delete_container() {
    local service_name=$1
    local dir=$2

    echo -e "${YELLOW}Deleting ${service_name} container and config...${NC}"

    if [[ ! -d "$dir" ]]; then
        echo -e "${RED}Directory '${dir}' not found. Nothing to delete.${NC}"
        return
    fi

    if ! ensure_docker_compose; then
        echo -e "${RED}Cannot safely delete ${service_name} without Docker Compose. Configuration was retained.${NC}"
        return 1
    fi

    if ! ( cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" down ); then
        echo -e "${RED}Failed to stop ${service_name}. Configuration was retained.${NC}"
        return 1
    fi

    local remaining_containers
    if ! remaining_containers=$(cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" ps -q); then
        echo -e "${RED}Could not verify ${service_name} shutdown. Configuration was retained.${NC}"
        return 1
    fi
    if [[ -n "$remaining_containers" ]]; then
        echo -e "${RED}${service_name} still has running containers. Configuration was retained.${NC}"
        return 1
    fi

    if ! rm -rf -- "$dir"; then
        echo -e "${RED}Failed to remove ${dir}.${NC}"
        return 1
    fi
    echo -e "${GREEN}${service_name} container and config deleted successfully!${NC}"
}

delete_xray() {
    delete_container "Xray" "xray"
}

delete_shadowsocks() {
    delete_container "Shadowsocks" "shadowsocks"
}

# --- Xray installation ---

is_microsoft_domain() {
    local domain_lower
    domain_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    local blocked_roots=(
        "microsoft.com"
        "microsoftonline.com"
        "azure.com"
        "azure.net"
        "azureedge.net"
        "office.com"
        "office.net"
        "office365.com"
        "live.com"
        "msn.com"
        "bing.com"
        "outlook.com"
        "windows.com"
        "windows.net"
        "skype.com"
        "xbox.com"
        "msftncsi.com"
        "msftconnecttest.com"
        "sharepoint.com"
        "onedrive.com"
    )

    for root in "${blocked_roots[@]}"; do
        if [[ "$domain_lower" == "$root" || "$domain_lower" == *."$root" ]]; then
            return 0
        fi
    done
    return 1
}

is_chinese_domain() {
    local domain_lower
    domain_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    local cn_tlds=(".cn" ".com.cn" ".net.cn" ".org.cn" ".中国" ".中國")
    local cn_roots=(
        "baidu.com"
        "qq.com"
        "taobao.com"
        "tmall.com"
        "jd.com"
        "163.com"
        "sina.com"
        "weibo.com"
        "alipay.com"
        "bilibili.com"
        "douyin.com"
        "tiktok.com"
    )

    for tld in "${cn_tlds[@]}"; do
        if [[ "$domain_lower" == *"$tld" ]]; then
            return 0
        fi
    done

    for root in "${cn_roots[@]}"; do
        if [[ "$domain_lower" == "$root" || "$domain_lower" == *."$root" ]]; then
            return 0
        fi
    done
    return 1
}

install_xray() {
    local num_uuids QUOTA_TIMEZONE KEYS PRIVATE_KEY PUBLIC_KEY DERIVED
    local SERVER_SHORTIDS USED_SHORTIDS sid_idx shortid
    local QUOTA_DB_LINES USED_EMAILS USER_UUIDS USER_EMAILS
    local i uuid user_email set_limit user_limit_gb user_anchor_now cycle_bounds user_cycle_start user_cycle_end
    local XHTTP_PATH REALITY_TARGET REALITY_SERVER_NAMES
    local REALITY_DOMAIN REALITY_DOMAIN_CLEAN PING_HOST DOMAIN_WARNING china_confirm PING_OUTPUT VALIDATION_ERRORS CURL_H2_HEADERS force_continue use_domain
    local ALLOWED_DOMAINS DROPPED_WILDCARDS SEEN_DOMAINS domain SERVER_NAMES_INPUT sni_input_arr sni_entry
    local enable_ipv6 LISTEN_ADDR client_pairs idx shortids_json server_names_json clients_json
    local SERVER_ADDR REMARKS SNI_DOMAIN TARGET_VALUE LINKS link server_uri_host sni_url public_key_url xhttp_path_url fragment_url start_confirm

    echo -e "${YELLOW}Starting Xray VLESS-XHTTP-Reality installation...${NC}"

    local orig_dir="$PWD"
    trap 'cd "$orig_dir" 2>/dev/null || true' RETURN
    mkdir -p xray
    cd xray || return 1

    echo "Pulling $XRAY_DOCKER_IMAGE image..."
    $SUDO docker pull "$XRAY_DOCKER_IMAGE"

    read -p "How many users do you need? [Default: $DEFAULT_UUIDS]: " num_uuids
    num_uuids=${num_uuids:-$DEFAULT_UUIDS}

    if ! [[ "$num_uuids" =~ ^[0-9]+$ ]] || [ "$num_uuids" -lt 1 ]]; then
        echo -e "${RED}User count must be a positive integer.${NC}"
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
    KEYS=$($SUDO docker run --rm --entrypoint /usr/bin/xray "$XRAY_DOCKER_IMAGE" x25519)
    PRIVATE_KEY=$(echo "$KEYS" | awk -F': *' 'tolower($0) ~ /private[[:space:]]*key/ {gsub(/\r/, "", $2); print $2; exit}')
    PUBLIC_KEY=$(echo "$KEYS" | awk -F': *' 'tolower($0) ~ /(public[[:space:]]*key|password)/ {gsub(/\r/, "", $2); print $2; exit}')

    if [[ -z "$PRIVATE_KEY" ]]; then
        echo -e "${RED}Failed to parse x25519 private key. Command output:${NC}"
        echo "$KEYS"
        return 1
    fi

    if [[ -z "$PUBLIC_KEY" ]]; then
        DERIVED=$($SUDO docker run --rm --entrypoint /usr/bin/xray "$XRAY_DOCKER_IMAGE" x25519 -i "$PRIVATE_KEY")
        PUBLIC_KEY=$(echo "$DERIVED" | awk -F': *' 'tolower($0) ~ /(public[[:space:]]*key|password)/ {gsub(/\r/, "", $2); print $2; exit}')
    fi

    if [[ -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}Failed to derive x25519 public key. Command output:${NC}"
        if [[ -n "$DERIVED" ]]; then
            echo "$DERIVED"
        else
            echo "$KEYS"
        fi
        return 1
    fi

    # Generate server-level shared shortIds
    SERVER_SHORTIDS=()
    declare -A USED_SHORTIDS
    for sid_idx in $(seq 1 $DEFAULT_SHORTIDS); do
        while true; do
            shortid=$(openssl rand -hex 4) # Generates 8 characters
            if [[ -z "${USED_SHORTIDS[$shortid]:-}" ]]; then
                USED_SHORTIDS[$shortid]=1
                break
            fi
        done
        SERVER_SHORTIDS+=("$shortid")
    done

    QUOTA_DB_LINES=""
    declare -A USED_EMAILS
    USER_UUIDS=()
    USER_EMAILS=()

    for i in $(seq 1 $num_uuids); do
        uuid=$(generate_uuid)

        while true; do
            user_email="u$(openssl rand -hex 8)"
            if [[ -z "${USED_EMAILS[$user_email]:-}" ]]; then
                USED_EMAILS[$user_email]=1
                break
            fi
        done
        echo "Generated user ID for user ${i}: ${user_email}"

        read -p "Set monthly data limit for ${user_email}? [Y/n]: " set_limit
        user_limit_gb=0
        if [[ -z "$set_limit" || "$set_limit" == "y" || "$set_limit" == "Y" ]]; then
            while true; do
                read -p "Enter monthly limit for ${user_email} in GB [Default: ${DEFAULT_USER_LIMIT_GB}]: " user_limit_gb
                user_limit_gb=${user_limit_gb:-$DEFAULT_USER_LIMIT_GB}
                if [[ "$user_limit_gb" =~ ^[0-9]+$ ]] && [ "$user_limit_gb" -gt 0 ]]; then
                    break
                fi
                echo -e "${RED}Please enter a positive integer GB value.${NC}"
            done
        fi

        user_anchor_now=$(date +%s)
        local cycle_bounds
        cycle_bounds=$(calculate_cycle_bounds "$user_anchor_now" "$user_anchor_now" "$QUOTA_TIMEZONE")
        local user_cycle_start="${cycle_bounds%%|*}"
        local user_cycle_end="${cycle_bounds##*|}"

        QUOTA_DB_LINES+="${user_email}|${uuid}|${user_limit_gb}|${user_anchor_now}|${user_cycle_start}|${user_cycle_end}|0|0|active"
        if [[ "$i" -lt "$num_uuids" ]]; then
            QUOTA_DB_LINES+=$'\n'
        fi

        USER_UUIDS+=("$uuid")
        USER_EMAILS+=("$user_email")
    done

    # Generate random XHTTP path for security
    XHTTP_PATH=$(openssl rand -hex 4)

    REALITY_TARGET=""
    REALITY_SERVER_NAMES=""

    while true; do
        read -p "Enter a domain to probe with 'xray tls ping': " REALITY_DOMAIN
        if [[ -z "$REALITY_DOMAIN" ]]; then
            echo -e "${RED}A domain is required. Please enter a domain.${NC}"
            continue
        fi

        REALITY_DOMAIN_CLEAN=${REALITY_DOMAIN#http://}
        REALITY_DOMAIN_CLEAN=${REALITY_DOMAIN_CLEAN#https://}
        REALITY_DOMAIN_CLEAN=${REALITY_DOMAIN_CLEAN%%/*}
        if [[ -z "$REALITY_DOMAIN_CLEAN" ]]; then
            REALITY_DOMAIN_CLEAN="$REALITY_DOMAIN"
        fi

        PING_HOST=${REALITY_DOMAIN_CLEAN%%:*}

        # Reject Microsoft domains for Reality target / SNI
        if is_microsoft_domain "$PING_HOST"; then
            echo -e "${RED}Error: Microsoft domains (e.g., microsoft.com, azure.com, office.com, bing.com, etc.) are not accepted for Reality SNI. Please enter a different domain.${NC}"
            continue
        fi

        # Check for Chinese domains before probing
        DOMAIN_WARNING=""
        if is_chinese_domain "$PING_HOST"; then
            DOMAIN_WARNING="${RED}⚠ WARNING: '$PING_HOST' appears to be a Chinese website/domain. Reality target must be a foreign website outside China!${NC}"
        fi

        if [[ -n "$DOMAIN_WARNING" ]]; then
            echo -e "$DOMAIN_WARNING"
            read -p "Are you sure you want to continue with this domain? [y/N]: " china_confirm
            if [[ "$china_confirm" != "y" && "$china_confirm" != "Y" ]]; then
                continue
            fi
        fi

        echo "Running xray tls ping for $PING_HOST..."
        PING_OUTPUT=$($SUDO docker run --rm "$XRAY_DOCKER_IMAGE" xray tls ping "$PING_HOST" 2>&1)
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

        # Check for HTTP/2 (H2) support using curl
        CURL_H2_HEADERS=$(curl -I --http2 --max-time 10 -sS "https://${PING_HOST}" 2>&1 || true)
        if echo "$CURL_H2_HEADERS" | grep -qiE '^HTTP/2'; then
            echo -e "${GREEN}✓ HTTP/2 (H2) supported (curl)${NC}"
        else
            echo -e "${YELLOW}⚠ HTTP/2 (H2) not detected by curl - Reality works best with H2${NC}"
            if [[ -n "$CURL_H2_HEADERS" ]]; then
                echo "----- curl --http2 output -----"
                echo "$CURL_H2_HEADERS"
                echo "-------------------------------"
            fi
        fi

        # Check for connection errors
        if echo "$PING_OUTPUT" | grep -qi "error\|failed\|timeout\|refused"; then
            echo -e "${RED}✗ Connection error detected - domain may be unreachable${NC}"
            VALIDATION_ERRORS=1
        fi

        if [[ "$VALIDATION_ERRORS" -eq 1 ]]; then
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

        REALITY_SERVER_NAMES=()
        ALLOWED_DOMAINS=$(echo "$PING_OUTPUT" | sed -nE "s/.*Cert's allowed domains: *\\[([^]]*)\\].*/\\1/p")
        if [[ -n "$ALLOWED_DOMAINS" ]]; then
            DROPPED_WILDCARDS=0
            SEEN_DOMAINS=""
            for domain in $ALLOWED_DOMAINS; do
                if [[ "$domain" == *"*"* ]]; then
                    DROPPED_WILDCARDS=1
                    continue
                fi
                if is_microsoft_domain "$domain"; then
                    continue
                fi
                if [[ " $SEEN_DOMAINS " == *" $domain "* ]]; then
                    continue
                fi
                SEEN_DOMAINS+=" $domain"
                REALITY_SERVER_NAMES+=("$domain")
            done
            if [[ "$DROPPED_WILDCARDS" -eq 1 ]]; then
                echo -e "${YELLOW}Wildcard domains were omitted from serverNames (not supported).${NC}"
            fi
        fi

        if [[ ${#REALITY_SERVER_NAMES[@]} -eq 0 ]]; then
            read -p "Enter serverNames (comma-separated, no * wildcards) [Default: $PING_HOST]: " SERVER_NAMES_INPUT
            if [[ -n "$SERVER_NAMES_INPUT" ]]; then
                IFS=',' read -r -a sni_input_arr <<< "$SERVER_NAMES_INPUT"
                for sni_entry in "${sni_input_arr[@]}"; do
                    sni_entry=$(echo "$sni_entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    [[ -z "$sni_entry" || "$sni_entry" == *"*"* ]] && continue
                    is_microsoft_domain "$sni_entry" && continue
                    REALITY_SERVER_NAMES+=("$sni_entry")
                done
            fi
            if [[ ${#REALITY_SERVER_NAMES[@]} -eq 0 ]]; then
                REALITY_SERVER_NAMES+=("$PING_HOST")
            fi
        fi
        break
    done

    read -p "Enable IPv6 listening (dual-stack)? [y/N]: " enable_ipv6
    if [[ "$enable_ipv6" == "y" || "$enable_ipv6" == "Y" ]]; then
        LISTEN_ADDR="::"
    else
        LISTEN_ADDR="0.0.0.0"
    fi

    cat > docker-compose.yml << EOL
services:
  xray:
    image: $XRAY_DOCKER_IMAGE
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

    # Create server.jsonc safely using jq
    local client_pairs=()
    for idx in "${!USER_UUIDS[@]}"; do
        client_pairs+=("${USER_UUIDS[$idx]}" "${USER_EMAILS[$idx]}")
    done

    local clients_json shortids_json server_names_json
    clients_json=$(jq -nc '$ARGS.positional | [range(0; length; 2) as $i | {id: .[$i], flow: "", email: .[$i+1]}]' --args "${client_pairs[@]}")
    shortids_json=$(jq -nc '$ARGS.positional' --args "${SERVER_SHORTIDS[@]}")
    server_names_json=$(jq -nc '$ARGS.positional' --args "${REALITY_SERVER_NAMES[@]}")

    jq -n \
      --arg listen "$LISTEN_ADDR" \
      --arg xhttp_path "/$XHTTP_PATH" \
      --arg target "$REALITY_TARGET" \
      --arg private_key "$PRIVATE_KEY" \
      --argjson clients "$clients_json" \
      --argjson server_names "$server_names_json" \
      --argjson shortids "$shortids_json" \
      '{
        "stats": {},
        "api": {
            "tag": "api",
            "services": ["StatsService"]
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
                    "inboundTag": ["api"],
                    "outboundTag": "api"
                },
                {
                    "type": "field",
                    "domain": ["geosite:google"],
                    "outboundTag": "direct"
                },
                {
                    "type": "field",
                    "domain": ["geosite:cn"],
                    "outboundTag": "block"
                },
                {
                    "type": "field",
                    "ip": ["geoip:cn"],
                    "outboundTag": "block"
                }
            ]
        },
        "inbounds": [
            {
                "listen": $listen,
                "port": 443,
                "protocol": "vless",
                "settings": {
                    "clients": $clients,
                    "decryption": "none"
                },
                "streamSettings": {
                    "network": "xhttp",
                    "xhttpSettings": {
                        "path": $xhttp_path
                    },
                    "security": "reality",
                    "realitySettings": {
                        "target": $target,
                        "serverNames": $server_names,
                        "privateKey": $private_key,
                        "shortIds": $shortids
                    }
                },
                "sniffing": {
                    "enabled": true,
                    "destOverride": ["http", "tls", "quic"]
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
      }' > server.jsonc

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
    SNI_DOMAIN=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames[0] // empty' server.jsonc 2>/dev/null | head -n1)

    if [[ -z "$SNI_DOMAIN" ]]; then
        TARGET_VALUE=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.target // empty' server.jsonc 2>/dev/null | head -n1)
        SNI_DOMAIN=${TARGET_VALUE%%:*}
    fi

    if [[ -z "$SNI_DOMAIN" ]]; then
        echo -e "${RED}Unable to determine Reality SNI from server.jsonc. Please set serverNames or a valid target (host:port).${NC}"
        return 1
    fi

    # Generate links using the shared server shortIds
    echo -e "\n${GREEN}VLESS Links:${NC}"
    LINKS=""
    local server_uri_host sni_url public_key_url xhttp_path_url
    server_uri_host=$(format_uri_host "$SERVER_ADDR")
    sni_url=$(url_encode_component "$SNI_DOMAIN")
    public_key_url=$(url_encode_component "$PUBLIC_KEY")
    xhttp_path_url=$(url_encode_component "/$XHTTP_PATH")

    for idx in "${!USER_UUIDS[@]}"; do
        uuid=${USER_UUIDS[$idx]}
        user_email=${USER_EMAILS[$idx]}
        local fragment_url
        fragment_url=$(url_encode_component "${REMARKS}-${user_email}")

        for shortid in "${SERVER_SHORTIDS[@]}"; do
            link="vless://$uuid@$server_uri_host:443?security=reality&sni=$sni_url&pbk=$public_key_url&sid=$shortid&type=xhttp&path=$xhttp_path_url#${fragment_url}"
            echo "$link"
            echo
            if [[ -n "$LINKS" ]]; then
                LINKS+="\n"
            fi
            LINKS+="$link\n"
        done
    done

    echo -e "\nSaving links to vless_links.txt..."
    printf "%b" "$LINKS" > vless_links.txt
    echo "Links saved successfully!"

    cat > user_limits.conf << EOL
TIMEZONE=$QUOTA_TIMEZONE
EOL

    cat > user_limits.db << EOL
# email|uuid|limit_gb|anchor_epoch|cycle_start_epoch|cycle_end_epoch|cycle_usage_bytes|last_total_bytes|status
$QUOTA_DB_LINES
EOL

    echo -e "${GREEN}Saved quota metadata:${NC} xray/user_limits.conf, xray/user_limits.db"

    read -p "Is the configuration correct? Do you want to start the container? [Y/n]: " start_confirm
    if [[ -z "$start_confirm" || "$start_confirm" == "y" || "$start_confirm" == "Y" ]]; then
        $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d
        echo -e "${GREEN}Xray container has been started!${NC}"
        echo "Remember to open port 443 (TCP & UDP) in your server's firewall."
    else
        echo -e "${RED}Container start cancelled.${NC}"
    fi

    cd "$orig_dir" 2>/dev/null || true
}

# --- Shadowsocks installation ---

install_shadowsocks() {
    local num_users ss_port enable_ss_ipv6 SS_LISTEN_ADDR SS_METHOD SERVER_PSK
    local ss_users_args USER_PSKS USER_LABELS i user_psk default_label user_label ss_users_json
    local SERVER_ADDR REMARKS start_confirm LINKS server_uri_host fragment_url PASSWORD BASE64 link

    echo -e "${YELLOW}Starting Shadowsocks (ssserver-rust) installation...${NC}"

    local orig_dir="$PWD"
    trap 'cd "$orig_dir" 2>/dev/null || true' RETURN
    mkdir -p shadowsocks
    cd shadowsocks || return 1

    echo "Pulling $SS_DOCKER_IMAGE image..."
    $SUDO docker pull "$SS_DOCKER_IMAGE"

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

    local ss_users_args=()
    USER_PSKS=()
    USER_LABELS=()
    for i in $(seq 1 $num_users); do
        local user_psk default_label user_label
        user_psk=$(openssl rand -base64 32)
        default_label="user${i}"
        read -p "Enter a label for user ${i} [${default_label}]: " user_label
        user_label=${user_label:-$default_label}

        USER_PSKS+=("$user_psk")
        USER_LABELS+=("$user_label")
        ss_users_args+=("$user_label" "$user_psk")
    done

    cat > docker-compose.yml << EOL
services:
  ssserver:
    image: $SS_DOCKER_IMAGE
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

    local ss_users_json
    ss_users_json=$(jq -nc '$ARGS.positional | [range(0; length; 2) as $i | {name: .[$i], password: .[$i+1]}]' --args "${ss_users_args[@]}")

    jq -n \
      --arg server "$SS_LISTEN_ADDR" \
      --argjson server_port "$ss_port" \
      --arg password "$SERVER_PSK" \
      --arg method "$SS_METHOD" \
      --arg mode "tcp_and_udp" \
      --argjson users "$ss_users_json" \
      '{
        "server": $server,
        "server_port": $server_port,
        "password": $password,
        "method": $method,
        "mode": $mode,
        "users": $users
      }' > server.json

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
        if $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d; then
            echo -e "${GREEN}Shadowsocks container has been started!${NC}"
            echo "Remember to open port ${ss_port} (TCP & UDP) in your server's firewall."

            echo -e "\n${GREEN}SS Links:${NC}"
            LINKS=""
            local server_uri_host
            server_uri_host=$(format_uri_host "$SERVER_ADDR")
            for i in "${!USER_PSKS[@]}"; do
                user_psk=${USER_PSKS[$i]}
                user_label=${USER_LABELS[$i]}
                local fragment_url
                fragment_url=$(url_encode_component "${REMARKS}-${user_label}")
                PASSWORD="${SERVER_PSK}:${user_psk}"
                BASE64=$(base64url_encode "${SS_METHOD}:${PASSWORD}")
                link="ss://${BASE64}@${server_uri_host}:${ss_port}#${fragment_url}"
                echo "$link"
                LINKS+="$link\n"
            done

            echo -e "\nSaving links to ss_links.txt..."
            printf "%b" "$LINKS" > ss_links.txt
            echo "Links saved successfully!"
        else
            echo -e "${RED}Failed to start Shadowsocks container.${NC}"
        fi
    else
        echo -e "${RED}Container start cancelled.${NC}"
    fi
}

# --- Quota subsystem ---

days_in_month() {
    local year=$((10#$1))
    local month=$((10#$2))
    case $month in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11) echo 30 ;;
        2)
            if (( (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0) )); then
                echo 29
            else
                echo 28
            fi
            ;;
        *) echo 30 ;;
    esac
}

add_months_clamped_epoch() {
    local anchor_epoch=$1
    local add_months=$2
    local timezone=$3

    local ay am ad ah amin asec
    read -r ay am ad ah amin asec < <(TZ="$timezone" date -d "@$anchor_epoch" +'%Y %m %d %H %M %S')

    local total_months=$((10#$ay * 12 + 10#$am - 1 + add_months))
    local ny=$((total_months / 12))
    local nm=$((total_months % 12 + 1))

    local dim
    dim=$(days_in_month "$ny" "$nm")

    local nd=$((10#$ad))
    if [[ "$nd" -gt "$dim" ]]; then
        nd=$dim
    fi

    TZ="$timezone" date -d "$(printf "%04d-%02d-%02d %02d:%02d:%02d" "$ny" "$nm" "$nd" "$ah" "$amin" "$asec")" +%s
}

calculate_cycle_bounds() {
    local anchor_epoch=$1
    local now_epoch=$2
    local timezone=$3

    local ay am ny nm
    read -r ay am < <(TZ="$timezone" date -d "@$anchor_epoch" +'%Y %m')
    read -r ny nm < <(TZ="$timezone" date -d "@$now_epoch"    +'%Y %m')

    local elapsed_months=$(( (10#$ny * 12 + 10#$nm) - (10#$ay * 12 + 10#$am) ))
    if [[ "$elapsed_months" -lt 0 ]]; then
        elapsed_months=0
    fi

    local start_epoch
    start_epoch=$(add_months_clamped_epoch "$anchor_epoch" "$elapsed_months" "$timezone")

    if [[ "$start_epoch" -gt "$now_epoch" ]]; then
        elapsed_months=$(( elapsed_months - 1 ))
        if [[ "$elapsed_months" -lt 0 ]]; then
            elapsed_months=0
        fi
        start_epoch=$(add_months_clamped_epoch "$anchor_epoch" "$elapsed_months" "$timezone")
    fi

    local end_epoch
    end_epoch=$(add_months_clamped_epoch "$anchor_epoch" $(( elapsed_months + 1 )) "$timezone")
    echo "${start_epoch}|${end_epoch}"
}

read_xray_quota_timezone() {
    local conf_file="xray/user_limits.conf"
    local tz="$DEFAULT_QUOTA_TIMEZONE"

    if [[ -f "$conf_file" ]]; then
        local parsed_tz
        parsed_tz=$(grep -E '^TIMEZONE=' "$conf_file" | tail -n1 | cut -d'=' -f2-)
        if [[ -n "$parsed_tz" ]]; then
            tz="$parsed_tz"
        fi
    fi

    if ! TZ="$tz" date +%s >/dev/null 2>&1; then
        tz="$DEFAULT_QUOTA_TIMEZONE"
    fi

    echo "$tz"
}

with_xray_quota_lock() {
    # Re-entrant lock check: if this process already holds the lock, execute directly
    if [[ "${_XRAY_QUOTA_LOCK_HELD:-0}" -eq 1 ]]; then
        "$@"
        return $?
    fi

    local lock_file="xray/.user_limits.lock"
    local lock_dir="xray/.user_limits.lock.d"
    local max_wait=10

    [[ -d "xray" ]] || mkdir -p "xray"

    _XRAY_QUOTA_LOCK_HELD=1

    if command -v flock >/dev/null 2>&1; then
        local lock_fd
        exec {lock_fd}>"$lock_file"
        if flock -x -w "$max_wait" "$lock_fd"; then
            "$@"
            local ret=$?
            flock -u "$lock_fd" 2>/dev/null || true
            exec {lock_fd}>&-
            _XRAY_QUOTA_LOCK_HELD=0
            return $ret
        else
            _XRAY_QUOTA_LOCK_HELD=0
            echo -e "${RED}Error: Quota database is locked by another process (timed out).${NC}" >&2
            exec {lock_fd}>&-
            return 1
        fi
    else
        local waited=0
        while ! mkdir "$lock_dir" 2>/dev/null; do
            if [[ -d "$lock_dir" ]]; then
                local lock_age=$(( $(date +%s) - $(date -r "$lock_dir" +%s 2>/dev/null || date +%s) ))
                if [[ "$lock_age" -gt 60 ]]; then
                    rm -rf "$lock_dir" 2>/dev/null || true
                fi
            fi
            sleep 0.1
            waited=$((waited + 1))
            if [[ "$waited" -ge $((max_wait * 10)) ]]; then
                _XRAY_QUOTA_LOCK_HELD=0
                echo -e "${RED}Error: Quota database is locked by another process (timed out).${NC}" >&2
                return 1
            fi
        done
        "$@"
        local ret=$?
        rm -rf "$lock_dir" 2>/dev/null || true
        _XRAY_QUOTA_LOCK_HELD=0
        return $ret
    fi
}

get_quota_db_records() {
    local db_file="xray/user_limits.db"
    if [[ -f "$db_file" ]]; then
        grep -v '^[[:space:]]*$' "$db_file" | grep -v '^[[:space:]]*#' || true
    fi
}

parse_quota_db_line() {
    local line=$1
    IFS='|' read -r email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status <<< "$line"

    if [[ -z "$email" || -z "$uuid" || -z "$status" ]]; then
        return 1
    fi
    if ! [[ "$limit_gb" =~ ^[0-9]+$ && "$anchor_epoch" =~ ^[0-9]+$ && "$cycle_start" =~ ^[0-9]+$ && "$cycle_end" =~ ^[0-9]+$ && "$cycle_usage" =~ ^[0-9]+$ && "$last_total" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [[ "$status" != "active" && "$status" != "suspended" ]]; then
        return 1
    fi
    return 0
}

save_quota_db_content() {
    local content="$1"
    local db_file="xray/user_limits.db"
    local tmp_db
    make_temp_file tmp_db
    echo "# email|uuid|limit_gb|anchor_epoch|cycle_start_epoch|cycle_end_epoch|cycle_usage_bytes|last_total_bytes|status" > "$tmp_db"
    if [[ -n "$content" ]]; then
        printf "%s\n" "$content" >> "$tmp_db"
    fi
    apply_preserved_file_metadata "$db_file" "$tmp_db"
    mv "$tmp_db" "$db_file"
}

sync_xray_clients_from_quota_db() {
    local db_file="xray/user_limits.db"
    local config_file="xray/server.jsonc"

    if [[ ! -f "$db_file" ]] || [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Quota database or Xray config not found.${NC}"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}Cannot safely update Xray clients because 'jq' is not installed.${NC}" >&2
        return 1
    fi

    local clients_json
    if ! clients_json=$(jq -Rn '
        [
            inputs
            | select(length > 0)
            | select(startswith("#") | not)
            | split("|")
            | select(length >= 9 and .[8] == "active")
            | {id: .[1], flow: "", email: .[0]}
        ]
    ' < "$db_file"); then
        echo -e "${RED}Failed to build the Xray client list from the quota database.${NC}" >&2
        return 1
    fi

    local target_count
    if ! target_count=$(jq -er '
        [
            .inbounds[]?
            | select(
                .protocol == "vless"
                and ((.settings.clients? | type) == "array")
            )
        ]
        | length
    ' "$config_file" 2>/dev/null); then
        echo -e "${RED}Xray config must be valid JSON before clients can be synchronized.${NC}" >&2
        return 1
    fi

    if [[ "$target_count" -ne 1 ]]; then
        echo -e "${RED}Expected exactly one VLESS inbound with a clients array; found ${target_count}. No changes were made.${NC}" >&2
        return 1
    fi

    local tmp_file
    make_temp_file tmp_file
    if ! jq --argjson clients "$clients_json" '
        (
            .inbounds[]
            | select(
                .protocol == "vless"
                and ((.settings.clients? | type) == "array")
            )
            | .settings.clients
        ) = $clients
    ' "$config_file" > "$tmp_file"; then
        echo -e "${RED}Failed to update the VLESS clients array. No changes were made.${NC}" >&2
        rm -f "$tmp_file"
        return 1
    fi

    if ! jq -e empty "$tmp_file" >/dev/null 2>&1; then
        echo -e "${RED}Generated Xray config failed JSON validation. No changes were made.${NC}" >&2
        rm -f "$tmp_file"
        return 1
    fi

    apply_preserved_file_metadata "$config_file" "$tmp_file"
    mv "$tmp_file" "$config_file"
    echo -e "${GREEN}Updated the VLESS clients list from the quota database.${NC}"
}

finalize_quota_db_update() {
    with_xray_quota_lock _finalize_quota_db_update_internal "$@"
}

_finalize_quota_db_update_internal() {
    local db_lines="$1"
    local config_changed="$2"
    local db_file="xray/user_limits.db"
    local config_file="xray/server.jsonc"

    # Safety Guard: Prevent overwriting populated DB with empty content
    local existing_records
    existing_records=$(get_quota_db_records)
    if [[ -z "$db_lines" ]] && [[ -n "$existing_records" ]]; then
        echo -e "${RED}CRITICAL: Quota update produced empty database while records exist on disk. Aborting update to protect data.${NC}" >&2
        return 1
    fi

    if [[ "$config_changed" -ne 1 ]]; then
        save_quota_db_content "$db_lines"
        return 0
    fi

    if [[ ! -f "$db_file" ]] || [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Cannot apply quota changes: database or Xray config not found.${NC}" >&2
        return 1
    fi

    local db_backup config_backup
    make_temp_file db_backup
    make_temp_file config_backup
    cp -p "$db_file" "$db_backup"
    cp -p "$config_file" "$config_backup"

    if ! save_quota_db_content "$db_lines" || ! sync_xray_clients_from_quota_db; then
        echo -e "${RED}Failed to prepare quota enforcement. Restoring previous state.${NC}" >&2
        cp -p "$db_backup" "$db_file"
        cp -p "$config_backup" "$config_file"
        return 1
    fi

    if ! reload_xray_container; then
        echo -e "${RED}Quota reload failed. Restoring previous database and config.${NC}" >&2
        cp -p "$db_backup" "$db_file"
        cp -p "$config_backup" "$config_file"
        if ! reload_xray_container; then
            echo -e "${RED}Failed to reload the restored Xray configuration; manual recovery is required.${NC}" >&2
        fi
        return 1
    fi

    rm -f "$db_backup" "$config_backup"
    return 0
}

collect_xray_user_stats() {
    local map_file=$1

    : > "$map_file"
    local stats_count=0
    local stats_error=""

    if ! $SUDO docker ps -q -f name="^/xray_server$" | grep -q .; then
        echo "${stats_count}|${stats_error}"
        return 0
    fi

    local raw_stats
    raw_stats=$($SUDO docker exec xray_server xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>" 2>&1 || true)

    if [[ -z "$raw_stats" ]]; then
        stats_error="empty statsquery output"
        echo "${stats_count}|${stats_error}"
        return 0
    fi

    if echo "$raw_stats" | grep -qiE "failed|error|unavailable|connection refused"; then
        stats_error=$(echo "$raw_stats" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')
    fi

    if [[ -z "$stats_error" ]]; then
        awk '
            /user>>>.*>>>traffic>>>(uplink|downlink)/ {
                line = $0
                match(line, /user>>>([^>"]+)>>>traffic>>>(uplink|downlink)/)
                s = substr(line, RSTART, RLENGTH)
                split(s, parts, ">>>")
                user = parts[2]
                dir = parts[4]

                if (match(line, /"value":[[:space:]]*"?([0-9]+)"?/)) {
                    val_str = substr(line, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", val_str)
                    if (val_str != "") {
                        print user "|" dir "|" val_str
                        user = ""; dir = ""
                    }
                } else if (match(line, /value:[[:space:]]*([0-9]+)/)) {
                    val_str = substr(line, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", val_str)
                    if (val_str != "") {
                        print user "|" dir "|" val_str
                        user = ""; dir = ""
                    }
                }
                next
            }
            user != "" && /"value":/ {
                val_str = $0
                gsub(/[^0-9]/, "", val_str)
                if (val_str != "") {
                    print user "|" dir "|" val_str
                    user = ""; dir = ""
                }
                next
            }
            user != "" && /value:[[:space:]]*[0-9]+/ {
                val_str = $0
                gsub(/[^0-9]/, "", val_str)
                if (val_str != "") {
                    print user "|" dir "|" val_str
                    user = ""; dir = ""
                }
                next
            }
        ' <<< "$raw_stats" > "$map_file"
    fi

    if [[ -s "$map_file" ]]; then
        stats_count=$(wc -l < "$map_file" | tr -d ' ')
    fi

    echo "${stats_count}|${stats_error}"
}

check_and_apply_xray_quotas() {
    with_xray_quota_lock _check_and_apply_xray_quotas_internal
}

_check_and_apply_xray_quotas_internal() {
    local db_file="xray/user_limits.db"
    local conf_file="xray/user_limits.conf"

    if [[ ! -f "$db_file" ]] || [[ ! -f "$conf_file" ]]; then
        echo -e "${RED}Quota files not found. Install Xray with quotas first.${NC}"
        return 1
    fi

    local timezone
    timezone=$(read_xray_quota_timezone)

    local now_epoch
    now_epoch=$(date +%s)

    local stats_map_file
    make_temp_file stats_map_file
    local stats_result
    stats_result=$(collect_xray_user_stats "$stats_map_file")
    local collected_stats_count="${stats_result%%|*}"
    local xray_stats_last_error="${stats_result##*|}"

    if [[ "${collected_stats_count:-0}" -eq 0 ]]; then
        echo -e "${YELLOW}Warning: no per-user traffic stats were collected from Xray.${NC}"
        if [[ -n "${xray_stats_last_error:-}" ]]; then
            echo -e "${YELLOW}Xray stats response:${NC} ${xray_stats_last_error}"
        fi
        echo -e "${YELLOW}Usage values may remain unchanged until stats become available.${NC}"
    fi

    declare -A uplink_map
    declare -A downlink_map

    while IFS='|' read -r email dir value; do
        [ -z "$email" ] && continue
        value=${value:-0}
        if [[ "$dir" = "uplink" ]]; then
            uplink_map["$email"]=$value
        elif [[ "$dir" = "downlink" ]]; then
            downlink_map["$email"]=$value
        fi
    done < "$stats_map_file"

    rm -f "$stats_map_file"

    local db_records
    db_records=$(get_quota_db_records)
    if [[ -z "$db_records" ]] && grep -q '^[^#[:space:]]' "$db_file" 2>/dev/null; then
        echo -e "${RED}CRITICAL: Failed to read existing records from ${db_file}. Aborting to protect data.${NC}" >&2
        return 1
    fi

    local db_lines=""
    local config_changed=0
    local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status

    while IFS= read -r raw_line; do
        [ -z "$raw_line" ] && continue
        if ! parse_quota_db_line "$raw_line"; then
            echo -e "${YELLOW}Warning: Skipping malformed quota database line: ${raw_line}${NC}" >&2
            continue
        fi

        local cycle_rotated=0
        if [[ -z "$cycle_start" || -z "$cycle_end" || "$now_epoch" -ge "$cycle_end" || "$now_epoch" -lt "$cycle_start" ]]; then
            local cycle_bounds
            cycle_bounds=$(calculate_cycle_bounds "$anchor_epoch" "$now_epoch" "$timezone")
            local new_cycle_start="${cycle_bounds%%|*}"
            local new_cycle_end="${cycle_bounds##*|}"

            if [[ "$cycle_start" != "$new_cycle_start" ]] || [[ "$cycle_end" != "$new_cycle_end" ]]; then
                cycle_usage=0
                cycle_start=$new_cycle_start
                cycle_end=$new_cycle_end
                cycle_rotated=1
                if [[ "$status" = "suspended" ]]; then
                    status="active"
                    config_changed=1
                    echo -e "${GREEN}Re-enabled user ${email} for new cycle.${NC}"
                fi
            fi
        fi

        local current_total=$last_total
        if [[ -n "${uplink_map[$email]+set}" ]] || [[ -n "${downlink_map[$email]+set}" ]]; then
            local current_uplink=${uplink_map["$email"]:-0}
            local current_downlink=${downlink_map["$email"]:-0}
            current_total=$((current_uplink + current_downlink))
        fi

        local delta
        if [[ "$cycle_rotated" -eq 1 ]]; then
            delta=0
        else
            delta=$((current_total - last_total))
            if [[ "$delta" -lt 0 ]]; then
                delta=$current_total
            fi
        fi

        cycle_usage=$((cycle_usage + delta))
        last_total=$current_total

        if [[ "$limit_gb" -gt 0 ]]; then
            local limit_bytes=$((limit_gb * 1024 * 1024 * 1024))
            if [[ "$cycle_usage" -ge "$limit_bytes" ]] && [[ "$status" != "suspended" ]]; then
                status="suspended"
                config_changed=1
                echo -e "${YELLOW}User ${email} reached quota (${limit_gb} GB). Suspended.${NC}"
            fi
        fi

        if [[ -n "$db_lines" ]]; then
            db_lines+=$'\n'
        fi
        db_lines+="${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
    done <<< "$db_records"

    finalize_quota_db_update "$db_lines" "$config_changed"

    echo -e "${GREEN}Quota check complete.${NC}"
}

show_xray_quota_status() {
    local db_file="xray/user_limits.db"

    if [[ ! -f "$db_file" ]]; then
        echo -e "${RED}Quota database not found.${NC}"
        return 1
    fi

    local timezone
    timezone=$(read_xray_quota_timezone)

    echo -e "${YELLOW}Timezone:${NC} ${timezone}"
    echo -e "${YELLOW}User quota status (stored usage; run 'Check/apply quotas now' for fresh stats):${NC}"

    local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status
    while IFS= read -r raw_line; do
        [ -z "$raw_line" ] && continue
        parse_quota_db_line "$raw_line" || continue

        local usage_gb
        usage_gb=$(awk -v b="$cycle_usage" 'BEGIN { printf "%.2f", b/1024/1024/1024 }')
        local cycle_start_h cycle_end_h
        cycle_start_h=$(TZ="$timezone" date -d "@${cycle_start}" "+%Y-%m-%d %H:%M:%S")
        cycle_end_h=$(TZ="$timezone" date -d "@${cycle_end}" "+%Y-%m-%d %H:%M:%S")

        if [[ "$limit_gb" -gt 0 ]]; then
            local percent=$((cycle_usage * 100 / (limit_gb * 1024 * 1024 * 1024)))
            echo "- ${email} | status=${status} | usage=${usage_gb}GB / ${limit_gb}GB (${percent}%) | cycle=${cycle_start_h} -> ${cycle_end_h}"
        else
            echo "- ${email} | status=${status} | usage=${usage_gb}GB / unlimited | cycle=${cycle_start_h} -> ${cycle_end_h}"
        fi
    done < <(get_quota_db_records)
}

select_quota_user() {
    local db_file="xray/user_limits.db"
    if [[ ! -f "$db_file" ]]; then
        echo -e "${RED}Quota database not found.${NC}" >&2
        return 1
    fi

    local idx=1
    local lines=()
    local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status
    while IFS= read -r raw_line; do
        [ -z "$raw_line" ] && continue
        parse_quota_db_line "$raw_line" || continue

        lines+=("$email|$uuid|$limit_gb|$anchor_epoch|$cycle_start|$cycle_end|$cycle_usage|$last_total|$status")
        echo "${idx}) ${email} (status: ${status}, limit: ${limit_gb} GB)" >&2
        idx=$((idx + 1))
    done < <(get_quota_db_records)

    if [[ ${#lines[@]} -eq 0 ]]; then
        echo -e "${RED}No users found in quota database.${NC}" >&2
        return 1
    fi

    echo "0) Cancel & Go Back" >&2
    read -p "Select user [0-${#lines[@]}]: " select_idx </dev/tty
    if [[ "$select_idx" = "0" ]]; then
        return 1
    fi
    if ! [[ "$select_idx" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid selection.${NC}" >&2
        return 1
    fi
    local sel_val=$((10#$select_idx))
    if [[ "$sel_val" -lt 1 ]] || [[ "$sel_val" -gt ${#lines[@]} ]]; then
        echo -e "${RED}Invalid selection.${NC}" >&2
        return 1
    fi

    local selected="${lines[$((sel_val - 1))]}"
    echo "$selected" | cut -d'|' -f1
}

reset_xray_user_usage() {
    read -p "Do you want to reset usage for ALL users? [y/N]: " reset_all
    local target_email=""

    if [[ "$reset_all" == "y" || "$reset_all" == "Y" ]]; then
        target_email="ALL"
    else
        target_email=$(select_quota_user) || return 0
    fi

    local db_file="xray/user_limits.db"

    local stats_map_file
    make_temp_file stats_map_file
    collect_xray_user_stats "$stats_map_file"

    local db_records
    db_records=$(get_quota_db_records)
    if [[ -z "$db_records" ]] && grep -q '^[^#[:space:]]' "$db_file" 2>/dev/null; then
        echo -e "${RED}CRITICAL: Failed to read existing records from ${db_file}. Aborting to protect data.${NC}" >&2
        return 1
    fi

    local db_lines=""
    local config_changed=0
    local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status

    while IFS= read -r raw_line; do
        [ -z "$raw_line" ] && continue
        if ! parse_quota_db_line "$raw_line"; then
            echo -e "${YELLOW}Warning: Skipping malformed quota database line: ${raw_line}${NC}" >&2
            continue
        fi

        if [[ "$target_email" = "ALL" ]] || [[ "$email" = "$target_email" ]]; then
            local current_total=0
            while IFS='|' read -r s_email s_dir s_value; do
                if [[ "$s_email" = "$email" ]]; then
                    current_total=$((current_total + ${s_value:-0}))
                fi
            done < "$stats_map_file"

            cycle_usage=0
            last_total=$current_total
            if [[ "$status" = "suspended" ]]; then
                if [[ "$target_email" = "ALL" ]]; then
                    status="active"
                    config_changed=1
                else
                    read -p "User is suspended. Re-enable now? [Y/n]: " reenable
                    if [[ "$reenable" != "n" && "$reenable" != "N" ]]; then
                        status="active"
                        config_changed=1
                    fi
                fi
            fi
            echo -e "${GREEN}Usage reset for ${email}.${NC}"
        fi

        if [[ -n "$db_lines" ]]; then
            db_lines+=$'\n'
        fi
        db_lines+="${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
    done <<< "$db_records"

    finalize_quota_db_update "$db_lines" "$config_changed"
}

change_xray_user_limit() {
    local target_email
    target_email=$(select_quota_user) || return 0
    local db_file="xray/user_limits.db"

    read -p "Enter new monthly limit in GB (0 = unlimited): " new_limit_gb
    if ! [[ "$new_limit_gb" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Limit must be a non-negative integer.${NC}"
        return 1
    fi
    new_limit_gb=$((10#$new_limit_gb))

    local db_records
    db_records=$(get_quota_db_records)
    if [[ -z "$db_records" ]] && grep -q '^[^#[:space:]]' "$db_file" 2>/dev/null; then
        echo -e "${RED}CRITICAL: Failed to read existing records from ${db_file}. Aborting to protect data.${NC}" >&2
        return 1
    fi

    local db_lines=""
    local config_changed=0
    local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status

    while IFS= read -r raw_line; do
        [ -z "$raw_line" ] && continue
        if ! parse_quota_db_line "$raw_line"; then
            echo -e "${YELLOW}Warning: Skipping malformed quota database line: ${raw_line}${NC}" >&2
            continue
        fi

        if [[ "$email" = "$target_email" ]]; then
            limit_gb=$new_limit_gb
            if [[ "$status" = "suspended" ]]; then
                local should_reenable=0
                if [[ "$limit_gb" -eq 0 ]]; then
                    should_reenable=1
                else
                    local limit_bytes=$((limit_gb * 1024 * 1024 * 1024))
                    if [[ "$cycle_usage" -lt "$limit_bytes" ]]; then
                        should_reenable=1
                    fi
                fi

                if [[ "$should_reenable" -eq 1 ]]; then
                    read -p "New limit allows usage. Re-enable now? [Y/n]: " reenable
                    if [[ "$reenable" != "n" && "$reenable" != "N" ]]; then
                        status="active"
                        config_changed=1
                    fi
                fi
            fi
            echo -e "${GREEN}Updated limit for ${email} to ${limit_gb} GB.${NC}"
        fi

        if [[ -n "$db_lines" ]]; then
            db_lines+=$'\n'
        fi
        db_lines+="${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
    done <<< "$db_records"

    finalize_quota_db_update "$db_lines" "$config_changed"
}

change_xray_user_billing_cycle() {
    read -p "Do you want to change the billing cycle for ALL users? [y/N]: " change_all
    local target_email=""

    if [[ "$change_all" == "y" || "$change_all" == "Y" ]]; then
        target_email="ALL"
    else
        target_email=$(select_quota_user) || return 0
    fi

    local db_file="xray/user_limits.db"

    echo ""
    if [[ "$target_email" = "ALL" ]]; then
        echo "How would you like to change the billing cycle for ALL users?"
    else
        echo "How would you like to change the billing cycle for ${target_email}?"
    fi
    echo "1) Restart cycle today (resets exactly 1 month from right now)"
    echo "2) Set a specific day of the month (e.g., the 1st or 15th)"
    echo "0) Cancel"
    read -p "Enter choice [0-2]: " cycle_choice

    local new_anchor_epoch
    local timezone
    timezone=$(read_xray_quota_timezone)

    if [[ "$cycle_choice" = "1" ]]; then
        new_anchor_epoch=$(date +%s)
    elif [[ "$cycle_choice" = "2" ]]; then
        read -p "Enter the day of the month [1-28]: " cycle_day
        if ! [[ "$cycle_day" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid day. Must be between 1 and 28.${NC}"
            return 1
        fi
        local clean_day=$((10#$cycle_day))
        if [[ "$clean_day" -lt 1 ]] || [[ "$clean_day" -gt 28 ]]; then
            echo -e "${RED}Invalid day. Must be between 1 and 28.${NC}"
            return 1
        fi
        new_anchor_epoch=$(TZ="$timezone" date -d "2000-01-$(printf "%02d" "$clean_day") 00:00:00" +%s)
    else
        return 0
    fi

    read -p "Do you also want to wipe their current traffic usage back to 0 GB? [y/N]: " reset_usage

    local stats_map_file
    make_temp_file stats_map_file
    collect_xray_user_stats "$stats_map_file"

    local db_records
    db_records=$(get_quota_db_records)
    if [[ -z "$db_records" ]] && grep -q '^[^#[:space:]]' "$db_file" 2>/dev/null; then
        echo -e "${RED}CRITICAL: Failed to read existing records from ${db_file}. Aborting to protect data.${NC}" >&2
        return 1
    fi

    local db_lines=""
    local config_changed=0
    local now_epoch
    now_epoch=$(date +%s)

    local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status
    while IFS= read -r raw_line; do
        [ -z "$raw_line" ] && continue
        if ! parse_quota_db_line "$raw_line"; then
            continue
        fi

        if [[ "$target_email" = "ALL" ]] || [[ "$email" = "$target_email" ]]; then
            anchor_epoch="$new_anchor_epoch"
            local cycle_bounds
            cycle_bounds=$(calculate_cycle_bounds "$anchor_epoch" "$now_epoch" "$timezone")
            cycle_start="${cycle_bounds%%|*}"
            cycle_end="${cycle_bounds##*|}"

            if [[ "$reset_usage" == "y" || "$reset_usage" == "Y" ]]; then
                local current_total=0
                while IFS='|' read -r s_email s_dir s_value; do
                    if [[ "$s_email" = "$email" ]]; then
                        current_total=$((current_total + ${s_value:-0}))
                    fi
                done < "$stats_map_file"

                cycle_usage=0
                last_total=$current_total

                if [[ "$status" = "suspended" ]]; then
                    if [[ "$target_email" = "ALL" ]]; then
                        status="active"
                        config_changed=1
                    else
                        read -p "User is suspended. Re-enable now? [Y/n]: " reenable
                        if [[ "$reenable" != "n" && "$reenable" != "N" ]]; then
                            status="active"
                            config_changed=1
                        fi
                    fi
                fi
                echo -e "${GREEN}Billing cycle dates updated and usage reset to 0 GB for ${email}.${NC}"
            else
                echo -e "${GREEN}Billing cycle dates updated for ${email}.${NC}"
            fi
        fi

        if [[ -n "$db_lines" ]]; then
            db_lines+=$'\n'
        fi
        db_lines+="${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
    done <<< "$db_records"

    finalize_quota_db_update "$db_lines" "$config_changed"
}

manage_xray_quotas() {
    local quota_choice
    while true; do
        echo ""
        echo -e "${YELLOW}--- Xray Per-User Quota Management ---${NC}"
        echo "1) Show quota status"
        echo "2) Check/apply quotas now"
        echo "3) Reset one user's current cycle usage"
        echo "4) Change one user's monthly limit"
        echo "5) Change one user's billing cycle dates"
        echo "6) Configure automatic quota checks (systemd timer / cron)"
        echo "7) Show automatic quota check configuration status"
        echo "0) Back"
        read -p "Enter your choice [0-7]: " quota_choice

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
            5)
                change_xray_user_billing_cycle
                ;;
            6)
                configure_xray_quota_auto_check
                ;;
            7)
                show_xray_quota_auto_check_status
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

# --- Scheduler subsystem ---

systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

disable_xray_quota_cron_silent() {
    local cron_file="/etc/cron.d/xray-quota-check"
    if [[ -f "$cron_file" ]]; then
        $SUDO rm -f "$cron_file" >/dev/null 2>&1 || true
    fi

    if command -v crontab >/dev/null 2>&1; then
        local script_path script_dir cron_cmd current_cron
        script_path=$(resolve_script_path) || script_path="$0"
        script_dir=$(dirname "$script_path")
        cron_cmd="cd $(printf '%q' "$script_dir") && bash $(printf '%q' "$script_path") --quota-check"
        current_cron=$(crontab -l 2>/dev/null || true)
        current_cron=$(printf '%s\n' "$current_cron" | grep -Fv -- "$XRAY_QUOTA_CRON_MARKER" | grep -Fv -- "$cron_cmd" || true)

        if [[ -n "$current_cron" ]]; then
            printf "%s\n" "$current_cron" | crontab -
        else
            crontab -r 2>/dev/null || true
        fi
    fi
}

disable_xray_quota_systemd_silent() {
    if ! systemd_available; then
        return 0
    fi

    $SUDO systemctl disable --now xray-quota-check.timer >/dev/null 2>&1 || true
    $SUDO rm -f /etc/systemd/system/xray-quota-check.timer /etc/systemd/system/xray-quota-check.service >/dev/null 2>&1 || true
    $SUDO rm -f /usr/local/lib/proxy-sh/quota-check.sh >/dev/null 2>&1 || true
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
}

ensure_crontab_available() {
    if command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}crontab command not found. Automatic quota checks require cron.${NC}"
    read -p "Install cron automatically now? [Y/n]: " install_cron_confirm
    if [[ "$install_cron_confirm" == "n" || "$install_cron_confirm" == "N" ]]; then
        return 1
    fi

    # Package and service names differ per distro family
    local cron_pkg cron_svc
    if command -v apt-get >/dev/null 2>&1; then
        cron_pkg="cron"
        cron_svc="cron"
    elif command -v dnf >/dev/null 2>&1; then
        cron_pkg="cronie"
        cron_svc="crond"
    elif command -v yum >/dev/null 2>&1; then
        cron_pkg="cronie"
        cron_svc="crond"
    else
        echo -e "${RED}Unsupported package manager. Please install cron manually, then retry.${NC}"
        return 1
    fi

    if ! install_system_packages "$cron_pkg"; then
        echo -e "${RED}Failed to install ${cron_pkg}.${NC}"
        return 1
    fi
    $SUDO systemctl enable --now "$cron_svc" 2>/dev/null || true

    if command -v crontab >/dev/null 2>&1; then
        echo -e "${GREEN}Cron installed successfully.${NC}"
        return 0
    fi

    echo -e "${RED}Cron installation finished but 'crontab' is still unavailable.${NC}"
    return 1
}

configure_xray_quota_auto_check_cron() {
    local script_path
    script_path=$(resolve_script_path)

    if [[ ! -f "$script_path" ]]; then
        echo -e "${RED}Cannot determine script path for cron setup.${NC}"
        return 1
    fi

    local script_dir cron_cmd cron_expr cron_file
    script_dir=$(dirname "$script_path")
    cron_file="/etc/cron.d/xray-quota-check"

    echo ""
    echo "Set automatic quota check interval (cron):"
    echo "1) Every 1 minute"
    echo "2) Every 2 minutes"
    echo "3) Every 5 minutes"
    echo "4) Disable cron auto quota check"
    read -p "Enter your choice [1-4]: " auto_choice

    case $auto_choice in
        1)
            cron_expr="* * * * *"
            ;;
        2)
            cron_expr="*/2 * * * *"
            ;;
        3)
            cron_expr="*/5 * * * *"
            ;;
        4)
            disable_xray_quota_cron_silent
            echo -e "${GREEN}Cron automatic quota check disabled.${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}Invalid choice.${NC}"
            return 1
            ;;
    esac

    # Prefer system /etc/cron.d/ to run cleanly as root without sudo password prompts
    if [[ -d "/etc/cron.d" ]]; then
        disable_xray_quota_cron_silent
        local cron_content="# proxy-sh:xray-quota-check\n${cron_expr} root cd $(printf '%q' "$script_dir") && /bin/bash $(printf '%q' "$script_path") --quota-check >/dev/null 2>&1\n"
        printf "%b" "$cron_content" | $SUDO tee "$cron_file" > /dev/null
        $SUDO chmod 0644 "$cron_file"
        echo -e "${GREEN}System cron automatic quota check enabled:${NC} ${cron_expr}"
        echo -e "${YELLOW}When a user exceeds quota, they will be suspended on the next check interval.${NC}"
        return 0
    fi

    if ! ensure_crontab_available; then
        echo -e "${RED}Cannot configure automatic checks without crontab or /etc/cron.d.${NC}"
        return 1
    fi

    cron_cmd="cd $(printf '%q' "$script_dir") && bash $(printf '%q' "$script_path") --quota-check"
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || true)
    current_cron=$(printf '%s\n' "$current_cron" | grep -Fv -- "$XRAY_QUOTA_CRON_MARKER" | grep -Fv -- "$cron_cmd" || true)

    local new_entry="${cron_expr} ${cron_cmd} >/dev/null 2>&1 ${XRAY_QUOTA_CRON_MARKER}"
    if [[ -n "$current_cron" ]]; then
        printf "%s\n%s\n" "$current_cron" "$new_entry" | crontab -
    else
        printf "%s\n" "$new_entry" | crontab -
    fi

    echo -e "${GREEN}Cron automatic quota check enabled:${NC} ${cron_expr}"
    echo -e "${YELLOW}When a user exceeds quota, they will be suspended on the next check interval.${NC}"
}

configure_xray_quota_auto_check_systemd() {
    if ! systemd_available; then
        echo -e "${RED}Systemd is not available on this host.${NC}"
        return 1
    fi

    local script_path script_dir unit_interval escaped_dir
    local quota_runner="/usr/local/lib/proxy-sh/quota-check.sh"
    script_path=$(resolve_script_path)
    script_dir=$(dirname "$script_path")
    printf -v escaped_dir '%q' "$script_dir"

    if [[ ! -f "$script_path" ]]; then
        echo -e "${RED}Cannot determine script path for systemd timer setup.${NC}"
        return 1
    fi

    echo ""
    echo "Set automatic quota check interval (systemd timer):"
    echo "1) Every 1 minute"
    echo "2) Every 2 minutes"
    echo "3) Every 5 minutes"
    echo "4) Disable systemd timer auto quota check"
    read -p "Enter your choice [1-4]: " auto_choice

    case $auto_choice in
        1)
            unit_interval="1min"
            ;;
        2)
            unit_interval="2min"
            ;;
        3)
            unit_interval="5min"
            ;;
        4)
            disable_xray_quota_systemd_silent
            echo -e "${GREEN}Systemd timer automatic quota check disabled.${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}Invalid choice.${NC}"
            return 1
            ;;
    esac

    # The timer runs as root, so execute a root-owned copy rather than the
    # potentially user-writable interactive script.
    $SUDO install -d -o root -g root -m 0755 /usr/local/lib/proxy-sh
    $SUDO install -o root -g root -m 0755 "$script_path" "$quota_runner"

    $SUDO tee /etc/systemd/system/xray-quota-check.service >/dev/null << EOL
[Unit]
Description=Xray per-user quota check
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc "cd $escaped_dir && exec /bin/bash $quota_runner --quota-check"
EOL

    $SUDO tee /etc/systemd/system/xray-quota-check.timer >/dev/null << EOL
[Unit]
Description=Run Xray quota check periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=$unit_interval
AccuracySec=10s
Persistent=true
Unit=xray-quota-check.service

[Install]
WantedBy=timers.target
EOL

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now xray-quota-check.timer

    # Avoid duplicate checks from cron if systemd timer is enabled.
    disable_xray_quota_cron_silent

    echo -e "${GREEN}Systemd timer automatic quota check enabled:${NC} every $unit_interval"
    echo -e "${YELLOW}Check status: sudo systemctl status xray-quota-check.timer${NC}"
    echo -e "${YELLOW}Logs: sudo journalctl -u xray-quota-check.service -n 50 --no-pager${NC}"
}

configure_xray_quota_auto_check() {
    local scheduler_choice
    echo ""
    echo "Choose scheduler for automatic quota checks:"
    if systemd_available; then
        echo "1) Systemd timer (recommended)"
        echo "2) Cron"
        echo "3) Disable all automatic quota checks"
        read -p "Enter your choice [1-3]: " scheduler_choice

        case $scheduler_choice in
            1)
                configure_xray_quota_auto_check_systemd
                ;;
            2)
                configure_xray_quota_auto_check_cron
                ;;
            3)
                disable_xray_quota_systemd_silent
                disable_xray_quota_cron_silent
                echo -e "${GREEN}Disabled all automatic quota checks.${NC}"
                ;;
            *)
                echo -e "${RED}Invalid choice.${NC}"
                ;;
        esac
    else
        echo -e "${YELLOW}Systemd not detected. Falling back to cron configuration.${NC}"
        configure_xray_quota_auto_check_cron
    fi
}

show_xray_quota_auto_check_status() {
    local systemd_enabled=0
    local systemd_interval=""
    local cron_enabled=0
    local cron_schedule=""

    # Check systemd timer
    if systemd_available; then
        if [[ -f "/etc/systemd/system/xray-quota-check.timer" ]]; then
            if systemctl is-active xray-quota-check.timer >/dev/null 2>&1 || systemctl is-enabled xray-quota-check.timer >/dev/null 2>&1; then
                systemd_enabled=1
                systemd_interval=$(grep "^OnUnitActiveSec=" "/etc/systemd/system/xray-quota-check.timer" | cut -d'=' -f2 || true)
            fi
        fi
    fi

    # Check cron job
    if [[ -f "/etc/cron.d/xray-quota-check" ]]; then
        local cron_line
        cron_line=$(grep -v '^#' "/etc/cron.d/xray-quota-check" 2>/dev/null | head -n 1 || true)
        if [[ -n "$cron_line" ]]; then
            cron_enabled=1
            cron_schedule=$(echo "$cron_line" | awk '{print $1" "$2" "$3" "$4" "$5}')
        fi
    elif command -v crontab >/dev/null 2>&1; then
        local cron_line
        cron_line=$(crontab -l 2>/dev/null | grep -F -- "$XRAY_QUOTA_CRON_MARKER" | head -n 1 || true)
        if [[ -n "$cron_line" ]]; then
            cron_enabled=1
            cron_schedule=$(echo "$cron_line" | awk '{print $1" "$2" "$3" "$4" "$5}')
        fi
    fi

    echo ""
    echo -e "${YELLOW}--- Automatic Quota Check Configuration Status ---${NC}"
    if [[ "$systemd_enabled" -eq 1 ]]; then
        echo -e "${GREEN}Status:${NC} Enabled"
        echo -e "${GREEN}Method:${NC} Systemd Timer"
        case "$systemd_interval" in
            "1min") echo -e "${GREEN}Time Period:${NC} Every 1 minute" ;;
            "2min") echo -e "${GREEN}Time Period:${NC} Every 2 minutes" ;;
            "5min") echo -e "${GREEN}Time Period:${NC} Every 5 minutes" ;;
            *) echo -e "${GREEN}Time Period:${NC} ${systemd_interval:-Unknown}" ;;
        esac
    elif [[ "$cron_enabled" -eq 1 ]]; then
        echo -e "${GREEN}Status:${NC} Enabled"
        echo -e "${GREEN}Method:${NC} Cron Job"
        case "$cron_schedule" in
            "* * * * *") echo -e "${GREEN}Time Period:${NC} Every 1 minute" ;;
            "*/2 * * * *") echo -e "${GREEN}Time Period:${NC} Every 2 minutes" ;;
            "*/5 * * * *") echo -e "${GREEN}Time Period:${NC} Every 5 minutes" ;;
            *) echo -e "${GREEN}Time Period:${NC} Custom schedule (${cron_schedule})" ;;
        esac
    else
        echo -e "${RED}Status:${NC} Disabled"
        echo -e "Automatic quota checks are not scheduled."
    fi
}

# --- User management ---

add_xray_user() {
    local db_file="xray/user_limits.db"
    local config_file="xray/server.jsonc"

    if [[ ! -f "$db_file" ]] || [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Xray quota/config files not found. Install Xray first.${NC}"
        return 1
    fi

    local user_id
    while true; do
        user_id="u$(openssl rand -hex 8)"
        if ! grep -q "^${user_id}|" "$db_file"; then
            break
        fi
    done

    local uuid
    uuid=$(generate_uuid)

    read -p "Set monthly data limit for ${user_id}? [Y/n]: " set_limit
    local user_limit_gb=0
    if [[ -z "$set_limit" || "$set_limit" == "y" || "$set_limit" == "Y" ]]; then
        while true; do
            read -p "Enter monthly limit for ${user_id} in GB [Default: ${DEFAULT_USER_LIMIT_GB}]: " user_limit_gb
            user_limit_gb=${user_limit_gb:-$DEFAULT_USER_LIMIT_GB}
            if [[ "$user_limit_gb" =~ ^[0-9]+$ ]] && [ "$((10#$user_limit_gb))" -gt 0 ]]; then
                user_limit_gb=$((10#$user_limit_gb))
                break
            fi
            echo -e "${RED}Please enter a positive integer GB value.${NC}"
        done
    fi

    local timezone now_epoch
    timezone=$(read_xray_quota_timezone)
    now_epoch=$(date +%s)
    local cycle_bounds
    cycle_bounds=$(calculate_cycle_bounds "$now_epoch" "$now_epoch" "$timezone")
    local cycle_start="${cycle_bounds%%|*}"
    local cycle_end="${cycle_bounds##*|}"

    apply_add_user() {
        local existing_db
        existing_db=$(grep -v '^[[:space:]]*$' "$db_file" | grep -v '^#' || true)
        if [[ -n "$existing_db" ]]; then
            existing_db+=$'\n'
        fi
        existing_db+="${user_id}|${uuid}|${user_limit_gb}|${now_epoch}|${cycle_start}|${cycle_end}|0|0|active"
        save_quota_db_content "$existing_db"
        sync_xray_clients_from_quota_db
        reload_xray_container
    }
    with_xray_quota_lock apply_add_user

    local server_addr remarks sni_domain xhttp_path private_key public_key
    read -p "Enter server IP/domain for new user's links (leave empty to skip link output): " server_addr

    if [[ -n "$server_addr" ]]; then
        if ensure_jq; then
            read -p "Enter remarks prefix [Default: xray]: " remarks
            remarks=${remarks:-xray}

            sni_domain=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames[0] // empty' "$config_file" | head -n1)
            xhttp_path=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.xhttpSettings.path // empty' "$config_file" | head -n1)
            xhttp_path=${xhttp_path#/}
            private_key=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.privateKey // empty' "$config_file" | head -n1)

            local server_shortids=()
            while IFS= read -r sid; do
                [[ -n "$sid" ]] && server_shortids+=("$sid")
            done < <(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.shortIds[] // empty' "$config_file" 2>/dev/null || true)

            if [[ ${#server_shortids[@]} -eq 0 ]]; then
                server_shortids+=("")
            fi

            if [[ -n "$private_key" ]]; then
                local derived
                if $SUDO docker ps -q -f name="^/xray_server$" | grep -q .; then
                    derived=$($SUDO docker exec xray_server xray x25519 -i "$private_key")
                else
                    derived=$($SUDO docker run --rm --entrypoint /usr/bin/xray "$XRAY_DOCKER_IMAGE" x25519 -i "$private_key")
                fi
                public_key=$(echo "$derived" | awk -F': *' 'tolower($0) ~ /(public[[:space:]]*key|password)/ {gsub(/\r/, "", $2); print $2; exit}')
            fi

            if [[ -n "$sni_domain" ]] && [[ -n "$xhttp_path" ]] && [[ ${#server_shortids[@]} -gt 0 ]] && [[ -n "$public_key" ]]; then
                local server_uri_host sni_url public_key_url xhttp_path_url fragment_url
                server_uri_host=$(format_uri_host "$server_addr")
                sni_url=$(url_encode_component "$sni_domain")
                public_key_url=$(url_encode_component "$public_key")
                xhttp_path_url=$(url_encode_component "/$xhttp_path")
                fragment_url=$(url_encode_component "${remarks}-${user_id}")

                echo -e "\n${GREEN}New user link(s):${NC}"
                for shortid in "${server_shortids[@]}"; do
                    local link
                    link="vless://${uuid}@${server_uri_host}:443?security=reality&sni=${sni_url}&pbk=${public_key_url}&sid=${shortid}&type=xhttp&path=${xhttp_path_url}#${fragment_url}"
                    echo "$link"
                    echo "" >> xray/vless_links.txt
                    echo "$link" >> xray/vless_links.txt
                done
            else
                echo -e "${YELLOW}Added user, but could not generate a link automatically from current config.${NC}"
            fi
        else
            echo -e "${YELLOW}Added user, but 'jq' is unavailable so a link could not be generated automatically.${NC}"
        fi
    fi

    echo -e "${GREEN}Added Xray user: ${user_id} (UUID: ${uuid})${NC}"
}

remove_xray_user() {
    local db_file="xray/user_limits.db"

    if [[ ! -f "$db_file" ]]; then
        echo -e "${RED}Xray quota database not found.${NC}"
        return 1
    fi

    local target_email
    target_email=$(select_quota_user) || return 0
    local target_uuid
    target_uuid=$(grep "^${target_email}|" "$db_file" | head -n1 | cut -d'|' -f2)

    apply_remove_user() {
        local filtered_db
        filtered_db=$(grep -v '^[[:space:]]*$' "$db_file" | grep -v '^#' | grep -v "^${target_email}|" || true)
        save_quota_db_content "$filtered_db"
        sync_xray_clients_from_quota_db
        reload_xray_container
    }
    with_xray_quota_lock apply_remove_user

    if [[ -f "xray/vless_links.txt" ]] && [[ -n "$target_uuid" ]]; then
        local tmp_links
        make_temp_file tmp_links
        grep -v -- "$target_uuid" xray/vless_links.txt > "$tmp_links" || true
        apply_preserved_file_metadata "xray/vless_links.txt" "$tmp_links"
        mv "$tmp_links" xray/vless_links.txt
    fi

    echo -e "${GREEN}Removed Xray user: ${target_email}${NC}"
}

add_shadowsocks_user() {
    local ss_config="shadowsocks/server.json"

    if [[ ! -f "$ss_config" ]]; then
        echo -e "${RED}Shadowsocks config not found. Install Shadowsocks first.${NC}"
        return 1
    fi

    if ! ensure_jq; then
        echo -e "${RED}Cannot manage Shadowsocks users without 'jq'.${NC}"
        return 1
    fi

    local user_name
    while true; do
        user_name="u$(openssl rand -hex 6)"
        if ! jq -e --arg n "$user_name" '.users[] | select(.name == $n)' "$ss_config" >/dev/null 2>&1; then
            break
        fi
    done

    local user_psk
    user_psk=$(openssl rand -base64 32)

    local tmp_ss
    make_temp_file tmp_ss
    jq --arg n "$user_name" --arg p "$user_psk" '.users += [{"name": $n, "password": $p}]' "$ss_config" > "$tmp_ss"

    apply_preserved_file_metadata "$ss_config" "$tmp_ss"
    mv "$tmp_ss" "$ss_config"

    reload_shadowsocks_container

    local server_psk method ss_port server_addr remarks password base64 link
    server_psk=$(jq -r '.password' "$ss_config")
    method=$(jq -r '.method' "$ss_config")
    ss_port=$(jq -r '.server_port' "$ss_config")

    read -p "Enter server IP/domain for new user's SS link (leave empty to skip link output): " server_addr
    if [[ -n "$server_addr" ]]; then
        read -p "Enter remarks prefix [Default: shadowsocks_rust]: " remarks
        remarks=${remarks:-shadowsocks_rust}
        local server_uri_host fragment_url
        server_uri_host=$(format_uri_host "$server_addr")
        fragment_url=$(url_encode_component "${remarks}-${user_name}")
        password="${server_psk}:${user_psk}"
        base64=$(base64url_encode "${method}:${password}")
        link="ss://${base64}@${server_uri_host}:${ss_port}#${fragment_url}"
        echo -e "\n${GREEN}New SS user link:${NC}"
        echo "$link"
        echo "$link" >> shadowsocks/ss_links.txt
    fi

    echo -e "${GREEN}Added Shadowsocks user: ${user_name}${NC}"
}

remove_shadowsocks_user() {
    local ss_config="shadowsocks/server.json"

    if [[ ! -f "$ss_config" ]]; then
        echo -e "${RED}Shadowsocks config not found.${NC}"
        return 1
    fi

    if ! ensure_jq; then
        echo -e "${RED}Cannot manage Shadowsocks users without 'jq'.${NC}"
        return 1
    fi

    local users=()
    local idx=1
    while IFS= read -r uname; do
        [ -z "$uname" ] && continue
        users+=("$uname")
        echo "${idx}) ${uname}"
        idx=$((idx + 1))
    done < <(jq -r '.users[].name' "$ss_config")

    if [[ ${#users[@]} -eq 0 ]]; then
        echo -e "${RED}No Shadowsocks users found.${NC}"
        return 1
    fi

    read -p "Select user to remove [1-${#users[@]}]: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#users[@]} ]]; then
        echo -e "${RED}Invalid selection.${NC}"
        return 1
    fi

    local target_user="${users[$((sel - 1))]}"
    local tmp_ss
    make_temp_file tmp_ss
    jq --arg n "$target_user" '.users |= map(select(.name != $n))' "$ss_config" > "$tmp_ss"

    apply_preserved_file_metadata "$ss_config" "$tmp_ss"
    mv "$tmp_ss" "$ss_config"

    reload_shadowsocks_container

    echo -e "${GREEN}Removed Shadowsocks user: ${target_user}${NC}"
}

manage_proxy_users() {
    local user_mgmt_choice
    while true; do
        echo ""
        echo -e "${YELLOW}--- User Management (Add/Remove) ---${NC}"
        echo "1) Add Xray user"
        echo "2) Remove Xray user"
        echo "3) Add Shadowsocks user"
        echo "4) Remove Shadowsocks user"
        echo "0) Back"
        read -p "Enter your choice [0-4]: " user_mgmt_choice

        case $user_mgmt_choice in
            1)
                add_xray_user
                ;;
            2)
                remove_xray_user
                ;;
            3)
                add_shadowsocks_user
                ;;
            4)
                remove_shadowsocks_user
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

# --- Display helpers ---

show_saved_links() {
    local primary_path=$1
    local fallback_path=$2
    local link_type=$3

    local links_file=""
    if [[ -f "$primary_path" ]]; then
        links_file="$primary_path"
    elif [[ -f "$fallback_path" ]]; then
        links_file="$fallback_path"
    else
        echo -e "${RED}No saved ${link_type} links found. Please install the service first to generate and save links.${NC}"
        return
    fi
    echo -e "\n${GREEN}Saved ${link_type} Links:${NC}"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "$line"
        echo
    done < "$links_file"
}

show_links() {
    show_saved_links "xray/vless_links.txt" "vless_links.txt" "VLESS"
}

show_ss_links() {
    show_saved_links "shadowsocks/ss_links.txt" "ss_links.txt" "SS"
}

# --- Self-update subsystem ---

fetch_latest_script_version() {
    local cache_bust latest_version
    cache_bust="?$(date +%s)"
    latest_version=$(curl -fsSL --max-time 10 "https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh${cache_bust}" 2>/dev/null | grep -oE "SCRIPT_VERSION=\"[0-9.]+\"" | cut -d'"' -f2)
    echo "$latest_version"
}

perform_script_update() {
    local cache_bust script_path script_dir tmp_script tmp_sha
    cache_bust="?$(date +%s)"
    script_path=$(resolve_script_path) || return 1
    script_dir=$(dirname "$script_path")

    tmp_script=$(mktemp "${script_dir}/.proxy.sh.update.XXXXXX") || {
        echo -e "${RED}Cannot create an update file beside ${script_path}.${NC}"
        return 1
    }
    tmp_sha=$(mktemp "${script_dir}/.proxy.sh.sha.XXXXXX") || {
        rm -f "$tmp_script"
        echo -e "${RED}Cannot create a temporary checksum file beside ${script_path}.${NC}"
        return 1
    }
    echo -e "${YELLOW}Downloading update and verifying checksum...${NC}"
    if ! curl -fsSL --max-time 20 "https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh${cache_bust}" > "$tmp_script"; then
        rm -f "$tmp_script" "$tmp_sha"
        echo -e "${RED}Failed to download update; the current script was not changed.${NC}"
        return 1
    fi

    if ! curl -fsSL --max-time 10 "https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh.sha256${cache_bust}" > "$tmp_sha"; then
        rm -f "$tmp_script" "$tmp_sha"
        echo -e "${RED}Failed to download checksum file (proxy.sh.sha256); update aborted for safety.${NC}"
        return 1
    fi

    local expected_hash actual_hash
    expected_hash=$(awk '{print $1}' "$tmp_sha" | tr -d ' \r\n')

    if command -v sha256sum >/dev/null 2>&1; then
        actual_hash=$(sha256sum "$tmp_script" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual_hash=$(shasum -a 256 "$tmp_script" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        actual_hash=$(openssl dgst -sha256 "$tmp_script" | awk '{print $NF}')
    else
        rm -f "$tmp_script" "$tmp_sha"
        echo -e "${RED}Cannot verify update integrity: sha256sum/shasum/openssl not found.${NC}"
        return 1
    fi

    if [[ -z "$expected_hash" || "$expected_hash" != "$actual_hash" ]]; then
        rm -f "$tmp_script" "$tmp_sha"
        echo -e "${RED}Checksum verification failed!${NC}"
        echo -e "${RED}Expected: ${expected_hash:-None}${NC}"
        echo -e "${RED}Actual:   ${actual_hash:-None}${NC}"
        return 1
    fi

    if ! bash -n "$tmp_script"; then
        rm -f "$tmp_script" "$tmp_sha"
        echo -e "${RED}Downloaded update failed syntax validation; the current script was not changed.${NC}"
        return 1
    fi

    apply_preserved_file_metadata "$script_path" "$tmp_script"
    chmod u+x "$tmp_script"
    if ! mv -f "$tmp_script" "$script_path"; then
        rm -f "$tmp_script" "$tmp_sha"
        echo -e "${RED}Failed to replace ${script_path}; the current script was not changed.${NC}"
        return 1
    fi
    rm -f "$tmp_sha"

    echo -e "${GREEN}Script updated and checksum verified successfully! Restarting...${NC}"
    exec bash "$script_path"
}

auto_check_script_update() {
    local latest_version
    latest_version=$(fetch_latest_script_version)

    if [[ -z "$latest_version" ]]; then
        return
    fi

    if [[ "$SCRIPT_VERSION" != "$latest_version" ]]; then
        echo -e "${YELLOW}A new version of this script is available: $latest_version (current: $SCRIPT_VERSION).${NC}"
        read -p "Do you want to update now? [Y/n]: " auto_update_confirm
        if [[ "$auto_update_confirm" == "n" || "$auto_update_confirm" == "N" ]]; then
            echo -e "${YELLOW}Continuing with current version.${NC}"
            return
        fi
        perform_script_update
    fi
}

update_script() {
    echo -e "${YELLOW}Checking for updates...${NC}"
    local latest_version
    latest_version=$(fetch_latest_script_version)

    if [[ -z "$latest_version" ]]; then
        echo -e "${RED}Could not check for updates. Please check your internet connection or the repository URL.${NC}"
        return
    fi

    if [[ "$SCRIPT_VERSION" == "$latest_version" ]]; then
        echo -e "${GREEN}You are already using the latest version of the script.${NC}"
        return
    fi

    echo -e "${YELLOW}A new version of the script is available: $latest_version${NC}"
    read -p "Do you want to update? [Y/n]: " update_confirm
    if [[ "$update_confirm" == "n" || "$update_confirm" == "N" ]]; then
        echo -e "${RED}Update cancelled.${NC}"
        return
    fi

    perform_script_update
}

# --- Entrypoint ---

run_main_menu() {
    local choice ver_choice update_choice delete_choice
    while true; do
        echo -e "${YELLOW}--- Proxy Installer v${SCRIPT_VERSION} ---${NC}"
        echo "Please choose an option:"
        echo "0) Update this script"
        echo "1) Environment Check (Check distro and install Docker)"
        echo "2) Install Xray (VLESS-XHTTP-Reality)"
        echo "3) Install Shadowsocks (ssserver-rust)"
        echo "4) Update / Change version of existing container (Xray / Shadowsocks)"
        echo "5) Restore deployment from existing config"
        echo "6) Show VLESS links for current config"
        echo "7) Show SS links for current config"
        echo "8) Delete container and config (Xray / Shadowsocks)"
        echo "9) Manage Xray per-user data quotas"
        echo "10) Manage users (Add/Remove for Xray / Shadowsocks)"
        echo "11) Exit"
        read -p "Enter your choice [0-11]: " choice

        case $choice in
            0)
                update_script
                ;;
            1)
                check_environment
                ;;
            2)
                if ! ensure_docker_compose; then
                    continue
                fi
                install_xray
                ;;
            3)
                if ! ensure_docker_compose; then
                    continue
                fi
                install_shadowsocks
                ;;
            4)
                if ! ensure_docker_compose; then
                    continue
                fi
                echo ""
                echo "Version / Update Management:"
                echo "1) Update existing containers to latest"
                echo "2) Downgrade / Change container version"
                echo "0) Back"
                read -p "Enter your choice [0-2]: " ver_choice
                case $ver_choice in
                    1)
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
                                echo -e "${RED}Invalid choice.${NC}"
                                ;;
                        esac
                        ;;
                    2)
                        change_container_version
                        ;;
                    0)
                        ;;
                    *)
                        echo -e "${RED}Invalid choice.${NC}"
                        ;;
                esac
                ;;
            5)
                if ! ensure_docker_compose; then
                    continue
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
                if ! ensure_docker_compose; then
                    continue
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
                        echo -e "${RED}Invalid choice.${NC}"
                        ;;
                esac
                ;;
            9)
                if ! ensure_docker_compose; then
                    continue
                fi
                manage_xray_quotas
                ;;
            10)
                if ! ensure_docker_compose; then
                    continue
                fi
                manage_proxy_users
                ;;
            11)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice.${NC}"
                ;;
        esac

        echo ""
    done
}

main() {
    case "${1:-}" in
        --quota-check)
            if ! ensure_docker_compose; then
                return 1
            fi
            check_and_apply_xray_quotas
            return
            ;;
        --quota-check-status)
            show_xray_quota_auto_check_status
            return
            ;;
    esac

    check_dependencies
    auto_check_script_update
    run_main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
