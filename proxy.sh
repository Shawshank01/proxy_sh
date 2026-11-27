#!/bin/bash
set -euo pipefail
#
# proxy.sh: An automated script to install and manage a proxy server.
#
# Copyright (C) 2026 Michifumi
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, see <https://www.gnu.org/licenses/>.
#

# --- Configuration & Colors ---
SCRIPT_VERSION="7.3.3"
DEFAULT_UUIDS=1
DEFAULT_SHORTIDS=1
DEFAULT_SS_USERS=1
DEFAULT_SS_PORT=80
DEFAULT_QUOTA_TIMEZONE="UTC"
DEFAULT_USER_LIMIT_GB=300
MAX_USER_LIMIT_GB=8589934591
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

require_gnu_linux() {
	if [[ "$(uname -s 2>/dev/null || true)" != "Linux" ]]; then
		echo -e "${RED}This script supports GNU/Linux only.${NC}" >&2
		exit 1
	fi
	if ! date -d now +%s >/dev/null 2>&1 || ! stat -c %u / >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
		echo -e "${RED}GNU coreutils (date, stat, timeout) are required. Please use a GNU/Linux system.${NC}" >&2
		exit 1
	fi
}

require_valid_server_address() {
	local address=$1
	if [[ -z "$address" || ${#address} -gt 253 || "$address" =~ [[:space:]/?#@] ]]; then
		echo -e "${RED}Server address must be a non-empty hostname, IPv4 address, or IPv6 address without whitespace or URI delimiters.${NC}" >&2
		return 1
	fi
}

require_valid_label() {
	local label=$1
	if [[ -z "$label" || ${#label} -gt 128 || "$label" == *'|'* ]]; then
		echo -e "${RED}User label must be 1-128 characters and cannot contain '|'.${NC}" >&2
		return 1
	fi
}

# Normalise decimal input before using it in arithmetic or passing it to jq.
parse_decimal_range() {
	local number=$1 min=$2 max=$3
	[[ "$number" =~ ^[0-9]+$ ]] || return 1
	number=${number#"${number%%[!0]*}"}
	number=${number:-0}
	[[ ${#number} -le ${#max} ]] || return 1
	if [[ ${#number} -eq ${#max} && "$number" > "$max" ]]; then
		return 1
	fi
	((number >= min)) || return 1
	printf '%s\n' "$number"
}

require_gnu_linux

# Privilege check & sudo helper
SUDO=""
if [[ "$EUID" -ne 0 ]]; then
	if command -v sudo >/dev/null 2>&1; then
		SUDO="sudo"
	elif [[ "${1:-}" != --quota-scheduled-* && "${1:-}" != "--quota-scheduler-probe" &&
		"${1:-}" != "--quota-check-status" ]]; then
		echo -e "${RED}This script requires root privileges or sudo.${NC}" >&2
		exit 1
	fi
fi

# Global variable for Docker Compose command
DOCKER_COMPOSE_CMD=()
XRAY_DOCKER_IMAGE="ghcr.io/xtls/xray-core:latest"
SS_DOCKER_IMAGE="ghcr.io/shadowsocks/ssserver-rust:latest"
HYSTERIA_DOCKER_IMAGE="tobyxdd/hysteria:latest"
CERTBOT_DOCKER_IMAGE="certbot/certbot:v5.10.0"
HYSTERIA_STATS_PORT=10087
HYSTERIA_ECH_DEFAULT_PUBLIC_NAME="dns.quad9.net"
XRAY_REALITY_FALLBACK_PORT=10086
RELEASE_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAnawkCaPdD130GQ0E6AAr
87qtwOr7aGMWOCCmbhxAYMoWFlj3vU55uU53lbvyIp27gfItRthH7D5B1RvoB00M
qMGNAv1uoUs8dxC4zeREEbj/J/uOic4W9zl6/xhX/Rf+VKwkPonUYZfevYdOtjiX
ra6hzNX1Wr4VDfMlsEFNi+tYtNnPcGoYwWhRXw7RuZSX2DmWJvLSbk7VuvgJijmQ
oFl1v9dWS+OuT4kAadqLB5gzKcNl+973jTaLBz1bdGElrEYYXdJhfY/4L0s5zVhT
abLugfXBh59BGJbqtqc0mCnGGlnP0w0r6vJMwcQRfpGC2sZBo0/hH4DahFQZTdzG
OJHtGsPxR+oOXHcE00ZlpVZtCZlyK1CafQliep3J3sDuPHZWnAbhk2HyueD+vkJH
Sg0pJ4yyHYgDUWAIM/3mHbdmbbzK5MwLgKHHXDP3ZyKmput1NXmIjtWA5Y8jQzkb
kb2OM7eQy6wsROxRjEWezoii1xfkLvaGFjCQaQi8VLwrAgMBAAE=
-----END PUBLIC KEY-----'

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

release_xray_quota_directory_lock() {
	if [[ "${_XRAY_QUOTA_MKDIR_OWNER:-}" == "$BASHPID" ]]; then
		rmdir -- "$_XRAY_QUOTA_MKDIR_LOCK/held" "$_XRAY_QUOTA_MKDIR_LOCK" 2>/dev/null || true
		unset _XRAY_QUOTA_MKDIR_OWNER _XRAY_QUOTA_MKDIR_LOCK
	fi
}

cleanup_script_tmp_dir() {
	release_xray_quota_directory_lock
	if [[ -n "${SCRIPT_TMP_DIR:-}" && -d "$SCRIPT_TMP_DIR" ]]; then
		rm -rf "$SCRIPT_TMP_DIR" 2>/dev/null || true
	fi
}
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup_script_tmp_dir EXIT

# --- Generic utilities ---

INITIAL_SCRIPT_SRC="${BASH_SOURCE[0]:-$0}"
INITIAL_SCRIPT_DIR="$(cd -- "$(dirname -- "$INITIAL_SCRIPT_SRC")" 2>/dev/null && pwd -P)"
INITIAL_SCRIPT_PATH="${INITIAL_SCRIPT_DIR}/$(basename -- "$INITIAL_SCRIPT_SRC")"
if command -v realpath >/dev/null 2>&1; then
	INITIAL_SCRIPT_PATH="$(realpath "$INITIAL_SCRIPT_PATH" 2>/dev/null || echo "$INITIAL_SCRIPT_PATH")"
fi

generate_uuid() {
	if [[ -r /proc/sys/kernel/random/uuid ]]; then
		cat /proc/sys/kernel/random/uuid
	elif command -v uuidgen >/dev/null 2>&1; then
		uuidgen | tr '[:upper:]' '[:lower:]'
	else
		local hex
		hex=$(openssl rand -hex 16) || return 1
		printf '%s-%s-4%s-%s%s-%s\n' \
			"${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
			"$(printf '%x' $(((0x${hex:16:2} & 0x3f) | 0x80)))" "${hex:18:2}" "${hex:20:12}"
	fi
}

ensure_service_dir() {
	local dir=$1
	if [[ ! -d "$dir" ]]; then
		if [[ "$PWD" == "/opt/proxy-sh" ]]; then
			$SUDO mkdir -m 0700 -- "$dir" || return 1
		else
			mkdir -p "$dir" 2>/dev/null || $SUDO mkdir -p "$dir" || return 1
		fi
	fi
	if [[ "$EUID" -ne 0 ]] && [[ -n "$SUDO" ]] && [[ -d "$dir" ]]; then
		$SUDO chown -R "$(id -u):$(id -g)" "$dir" 2>/dev/null || return 1
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
	if [[ -n "${INITIAL_SCRIPT_PATH:-}" && -f "$INITIAL_SCRIPT_PATH" ]]; then
		echo "$INITIAL_SCRIPT_PATH"
		return 0
	fi
	local path="${BASH_SOURCE[0]:-$0}"
	if command -v realpath >/dev/null 2>&1; then
		local rpath
		rpath=$(realpath "$path" 2>/dev/null || true)
		if [[ -n "$rpath" && -f "$rpath" ]]; then
			echo "$rpath"
			return 0
		fi
	fi
	if [[ -f "$path" ]]; then
		echo "$path"
		return 0
	fi
	if [[ "$path" != /* ]]; then
		local script_dir
		script_dir=$(cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || true
		if [[ -n "$script_dir" && -f "${script_dir}/$(basename -- "$path")" ]]; then
			echo "${script_dir}/$(basename -- "$path")"
			return 0
		fi
		if [[ -f "../$(basename -- "$path")" ]]; then
			local parent_dir
			parent_dir=$(cd .. 2>/dev/null && pwd -P) || true
			if [[ -n "$parent_dir" && -f "${parent_dir}/$(basename -- "$path")" ]]; then
				echo "${parent_dir}/$(basename -- "$path")"
				return 0
			fi
		fi
	fi
	if [[ -f "$path" ]]; then
		echo "$path"
		return 0
	fi
	echo "$path"
	return 1
}

# --- System and dependency helpers ---

install_system_packages() {
	if command -v apt-get &>/dev/null; then
		$SUDO apt-get update && $SUDO apt-get install -y "$@"
	elif command -v dnf &>/dev/null; then
		$SUDO dnf install -y "$@"
	elif command -v yum &>/dev/null; then
		$SUDO yum install -y "$@"
	else
		return 1
	fi
}

check_dependencies() {
	local dependencies=("curl" "openssl" "jq")
	local missing_deps=()

	for cmd in "${dependencies[@]}"; do
		if ! command -v "$cmd" &>/dev/null; then
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
			if ! command -v "$cmd" &>/dev/null; then
				echo -e "${RED}Failed to install $cmd. Please install manually.${NC}"
				return 1
			fi
		done
		echo -e "${GREEN}Dependencies installed successfully!${NC}"
	fi
}

ensure_jq() {
	if command -v jq &>/dev/null; then
		return 0
	fi

	echo -e "${YELLOW}This feature requires 'jq' to read/edit JSON configs. Installing it now...${NC}"

	if ! install_system_packages jq; then
		echo -e "${RED}Could not detect package manager. Please install 'jq' manually.${NC}"
		return 1
	fi

	if ! command -v jq &>/dev/null; then
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

	$SUDO install -m 0755 -d /etc/apt/keyrings || return 1

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

	local docker_key architecture
	make_temp_file docker_key || return 1
	if ! curl -fsSL "${repo_url}/gpg" | gpg --batch --yes --dearmor -o "$docker_key"; then
		rm -f "$docker_key"
		return 1
	fi
	$SUDO install -m 0644 "$docker_key" /etc/apt/keyrings/docker.gpg || return 1
	rm -f "$docker_key"
	architecture=$(dpkg --print-architecture) || return 1

	echo "deb [arch=$architecture signed-by=/etc/apt/keyrings/docker.gpg] $repo_url $repo_codename stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
}

install_docker_packages() {
	if [[ -z "${DISTRO:-}" ]]; then
		check_distro || return 1
	fi

	echo "Installing Docker for ${DISTRO}..."
	case "$DISTRO" in
	ubuntu | debian | linuxmint)

		$SUDO apt-get update || return 1
		if ! $SUDO apt-get install -y ca-certificates curl gnupg; then
			echo -e "${RED}Failed to install prerequisites. Please install them manually.${NC}"
			return 1
		fi

		setup_docker_apt_repo || return 1

		# Update and install Docker
		$SUDO apt-get update || return 1
		if ! $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
			echo -e "${RED}Failed to install Docker. Please install it manually.${NC}"
			return 1
		fi
		;;
	centos | rhel | fedora)
		local repo_url="https://download.docker.com/linux/$DISTRO/docker-ce.repo"
		if dnf --version 2>/dev/null | awk '/^dnf5 version / { found=1 } END { exit !found }'; then
			$SUDO dnf config-manager addrepo --overwrite --from-repofile="$repo_url" || return 1
		else
			$SUDO dnf -y install dnf-plugins-core || return 1
			$SUDO dnf config-manager --add-repo "$repo_url" || return 1
		fi
		$SUDO dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
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
	if command -v docker &>/dev/null; then
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
	ubuntu | debian | linuxmint)
		# Try to install docker-compose-plugin
		if $SUDO apt-get install -y docker-compose-plugin 2>/dev/null; then
			echo -e "${GREEN}Docker Compose plugin installed successfully.${NC}"
		else
			echo -e "${YELLOW}Docker Compose plugin not available, trying alternative installation...${NC}"
			if ! $SUDO apt-get install -y ca-certificates curl gnupg; then
				echo -e "${RED}Failed to install prerequisites for Docker Compose.${NC}"
				return 1
			fi

			setup_docker_apt_repo || return 1

			# Remove conflicting packages that might be installed from distro repos
			echo -e "${YELLOW}Removing conflicting packages to avoid installation errors...${NC}"
			$SUDO apt-get remove -y docker-buildx docker-compose docker-doc podman-docker || true

			$SUDO apt-get update || return 1
			if $SUDO apt-get install -y docker-compose-plugin; then
				echo -e "${GREEN}Docker Compose plugin installed successfully from Docker repository.${NC}"
			else
				echo -e "${RED}Failed to install Docker Compose. Please install it manually.${NC}"
				return 1
			fi
		fi
		;;
	centos | rhel | fedora)
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
	if command -v docker &>/dev/null; then
		echo -e "${GREEN}Docker is already installed.${NC}"
	else
		echo -e "${YELLOW}Docker is not installed.${NC}"
		read -p "$(echo -e ${YELLOW}Would you like to install Docker? [y/N]: ${NC})" install_confirm || return 1
		if [[ "$install_confirm" != "y" && "$install_confirm" != "Y" ]]; then
			echo -e "${RED}Docker installation cancelled.${NC}"
			return 1
		fi
		install_docker_packages
		return
	fi

	# Check if Docker Compose is working
	if docker compose version &>/dev/null 2>&1; then
		echo -e "${GREEN}Docker Compose is working properly.${NC}"
		return
	elif command -v docker-compose &>/dev/null; then
		if docker-compose version &>/dev/null 2>&1; then
			echo -e "${GREEN}Docker Compose is working properly.${NC}"
			return
		else
			echo -e "${YELLOW}Docker Compose is installed but not working (broken on newer Python versions).${NC}"
			read -p "$(echo -e ${YELLOW}Would you like to upgrade to a working Docker Compose version? [y/N]: ${NC})" upgrade_confirm || return 1
			if [[ "$upgrade_confirm" == "y" || "$upgrade_confirm" == "Y" ]]; then
				echo -e "${YELLOW}Upgrading Docker Compose...${NC}"
				install_docker_compose
			else
				echo -e "${RED}Docker Compose upgrade cancelled. Some features may not work.${NC}"
				return 1
			fi
			return
		fi
	else
		echo -e "${YELLOW}Docker Compose is not installed.${NC}"
		read -p "$(echo -e ${YELLOW}Would you like to install Docker Compose? [y/N]: ${NC})" install_confirm || return 1
		if [[ "$install_confirm" == "y" || "$install_confirm" == "Y" ]]; then
			install_docker_compose
		else
			echo -e "${RED}Docker Compose installation cancelled. Some features may not work.${NC}"
			return 1
		fi
		return
	fi
}

ensure_docker_compose() {
	if [[ ${#DOCKER_COMPOSE_CMD[@]} -gt 0 ]]; then
		return 0
	fi

	if ! command -v docker &>/dev/null; then
		echo -e "${RED}Docker is not installed. Please run option 1 (Environment Check) first.${NC}"
		return 1
	fi
	echo -e "${YELLOW}Checking Docker Compose availability...${NC}"

	# Check for both docker-compose (hyphen) and docker compose (space) versions
	# Prioritise the newer 'docker compose' version (with space)
	if docker compose version &>/dev/null 2>&1; then
		DOCKER_COMPOSE_CMD=(docker compose)
		echo -e "${GREEN}Using Docker Compose: ${DOCKER_COMPOSE_CMD[*]}${NC}"
	elif command -v docker-compose &>/dev/null; then
		echo -e "${YELLOW}Found docker-compose (old version), testing if it works...${NC}"
		if docker-compose version &>/dev/null 2>&1; then
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
	check_distro || return 1
	install_docker || return 1
	echo -e "${GREEN}Environment check completed!${NC}"
}

# --- Shared container lifecycle ---

reload_xray_container() {
	if [[ "${XRAY_QUOTA_SCHEDULED:-0}" -eq 1 ]]; then
		local container_id
		container_id=$(scheduled_xray_container) || return 1
		docker restart "$container_id"
		return
	fi
	if [[ ! -d "xray" ]] || [[ ! -f "xray/docker-compose.yml" ]]; then
		echo -e "${RED}xray/docker-compose.yml not found.${NC}"
		return 1
	fi

	if ! ensure_docker_compose; then
		return 1
	fi

	if (cd xray && $SUDO "${DOCKER_COMPOSE_CMD[@]}" restart xray); then
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

	if (cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d); then
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
	local service=$4

	if [[ ! -f "$dir/docker-compose.yml" ]]; then
		return 0
	fi

	local current_image
	current_image=$(compose_service_image "$service" "$dir/docker-compose.yml") || return 1

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
		make_temp_file tmp_file || return 1
		make_temp_file backup_file || return 1
		cp -p "$dir/docker-compose.yml" "$backup_file" || return 1

		if ! compose_service_image "$service" "$dir/docker-compose.yml" "$expected_default" >"$tmp_file"; then
			rm -f "$tmp_file" "$backup_file"
			echo -e "${RED}Failed to update docker-compose.yml to release lock.${NC}"
			return 1
		fi
		apply_preserved_file_metadata "$dir/docker-compose.yml" "$tmp_file"
		mv "$tmp_file" "$dir/docker-compose.yml" || return 1

		echo "Recreating container with latest image..."
		if (cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" pull) &&
			{ [[ "$dir" != hysteria ]] || checkpoint_hysteria_traffic; } &&
			(cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d) &&
			{ [[ "$dir" != hysteria ]] || wait_for_hysteria; }; then
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
	release_version_lock_if_needed "$compose_dir" "$base_image" "$default_tag" "$container_name" || lock_status=$?
	if [[ "$lock_status" -eq 1 ]]; then
		return 1
	elif [[ "$lock_status" -eq 2 ]]; then
		return 0
	fi

	local old_img_id=""
	old_img_id=$($SUDO docker inspect -f '{{.Image}}' "$container_name" 2>/dev/null || true)

	echo "Updating ${container_name} to latest image..."

	if ! (cd "$compose_dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" pull); then
		echo -e "${RED}Failed to pull latest image for ${container_name}.${NC}"
		return 1
	fi

	if [[ "$compose_dir" == hysteria ]]; then
		checkpoint_hysteria_traffic
	fi
	if ! (cd "$compose_dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d) ||
		{ [[ "$compose_dir" == hysteria ]] && ! wait_for_hysteria; }; then
		echo -e "${RED}Failed to update ${container_name}.${NC}"
		return 1
	fi

	local new_img_id=""
	new_img_id=$($SUDO docker inspect -f '{{.Image}}' "$container_name" 2>/dev/null || true)

	if [[ -n "$old_img_id" && -n "$new_img_id" && "$old_img_id" == "$new_img_id" ]]; then
		echo -e "${GREEN}${container_name} is already up to date.${NC}"
	else
		echo -e "${GREEN}${container_name} updated successfully.${NC}"
	fi
	return 0
}

compose_service_image() {
	local service=$1 config=$2 image=${3:-}
	# Read or replace only the selected service's image key.
	awk -v service="$service" -v image="$image" '
        /^[^[:space:]#]/ { services = /^services:[[:space:]]*(#.*)?$/; selected = 0 }
        services && $0 ~ ("^[[:space:]]+" service ":[[:space:]]*(#.*)?$") {
            match($0, /^[[:space:]]*/); service_indent = RLENGTH
            property_indent = 0; selected = 1
            if (image != "") print
            next
        }
        selected && /^[[:space:]]*[^[:space:]#]/ {
            match($0, /^[[:space:]]*/)
            if (RLENGTH <= service_indent) selected = 0
            else {
                if (!property_indent || RLENGTH < property_indent) property_indent = RLENGTH
                if (RLENGTH == property_indent && $0 ~ /^[[:space:]]+image:[[:space:]]/) {
                    old_image = $2
                    gsub(/["\047]/, "", old_image)
                    # An implicit latest and an explicit latest are equivalent.
                    if (image == "") print old_image
                    else if (old_image != image && old_image ":latest" != image)
                        sub(/image:[[:space:]]*[^[:space:]]+/, "image: " image)
                    changed++
                }
            }
        }
        image != "" { print }
        END { if (changed != 1) exit 1 }
	' "$config"
}

start_xray_image() {
	local image_id=$1 mode=$2
	shift 2
	local -a pull_options=()
	if $SUDO "${DOCKER_COMPOSE_CMD[@]}" up --help | awk '/--pull / { supported = 1 } END { exit !supported }'; then
		pull_options=(--pull never)
	fi

	# A transient override pins this invocation without changing the saved tag.
	{
		# Compose v1 requires compatible version headers in merged files.
		awk '/^version:/ { print; exit }' docker-compose.yml
		printf 'services:\n  xray:\n    image: "%s"\n' "$image_id"
	} | $SUDO "${DOCKER_COMPOSE_CMD[@]}" "$@" -f - up "$mode" --no-deps --no-build --force-recreate "${pull_options[@]}" xray
}

wait_for_xray_image() {
	local expected_image=$1 config_file=$2
	local state image status restart_count previous_restart_count="" health
	local deadline=$((SECONDS + 30))
	local stats_api=0
	if jq -e '
        (.api.services // [] | index("StatsService") != null) and
        any(.inbounds[]?; .tag == "api" and .listen == "127.0.0.1" and .port == 10085)
	' "$config_file" >/dev/null 2>&1; then
		stats_api=1
	fi

	while ((SECONDS < deadline)); do
		if ! state=$(timeout 3s $SUDO docker inspect --type container -f \
			'{{.Image}} {{.State.Status}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
			xray_server 2>/dev/null); then
			# The daemon may still be replacing the named container.
			previous_restart_count=""
			sleep 1
			continue
		fi
		read -r image status restart_count health <<<"$state"
		if [[ "$image" == "$expected_image" && ("$status" == "exited" || "$status" == "dead") ]]; then
			return 1
		fi

		if [[ "$image" == "$expected_image" && "$status" == "running" && ("$health" == "healthy" || "$health" == "none") ]] &&
			{ [[ "$stats_api" -eq 0 ]] || timeout 3s $SUDO docker exec xray_server xray api statsquery \
				--server=127.0.0.1:10085 -pattern "user>>>" >/dev/null 2>&1; }; then
			if [[ "$restart_count" == "$previous_restart_count" ]]; then
				return 0
			fi
			previous_restart_count=$restart_count
		else
			previous_restart_count=""
		fi
		sleep 1
	done
	return 1
}

finish_xray_image_change() {
	# The EXIT trap runs inside apply_xray_image_change and holds its quota lock.
	local rc=$1 restored=1
	if [[ "$rollback_needed" -eq 1 ]]; then
		echo -e "${YELLOW}Restoring the previous Xray deployment...${NC}" >&2
		if [[ "$compose_changed" -eq 1 ]]; then
			cp -p "$work_dir/docker-compose.yml" "$work_dir/restore-compose.yml" &&
				mv -f "$work_dir/restore-compose.yml" docker-compose.yml || restored=0
		fi
		if [[ "$restored" -eq 1 && "$launch_attempted" -eq 1 ]]; then
			if [[ -z "$old_image" ]]; then
				$SUDO "${DOCKER_COMPOSE_CMD[@]}" "${compose_files[@]}" rm --stop --force xray || restored=0
			elif [[ "$old_running" == "true" ]]; then
				start_xray_image "$old_image" -d "${compose_files[@]}" &&
					wait_for_xray_image "$old_image" server.jsonc || restored=0
			else
				start_xray_image "$old_image" --no-start "${compose_files[@]}" &&
					[[ "$($SUDO docker inspect --type container -f '{{.Image}} {{.State.Running}}' xray_server)" == "$old_image false" ]] || restored=0
			fi
		fi

		if [[ "$restored" -ne 1 ]]; then
			echo -e "${RED}Xray rollback failed. Recovery details are in $work_dir.${NC}" >&2
			return 1
		fi
		echo -e "${YELLOW}Previous Xray configuration and container state restored.${NC}" >&2
	fi

	rm -rf -- "$work_dir"
	return "$rc"
}

apply_xray_image_change() (
	local target_image=$1 require_existing=$2
	local container_id old_state old_image="" old_running="" target_id work_dir
	local rollback_needed=0 launch_attempted=0 compose_changed=0 override
	local -a compose_files=(-f docker-compose.yml)
	cd xray || return 1
	if [[ ! -f docker-compose.yml || ! -f server.jsonc ]]; then
		echo -e "${RED}Xray requires both docker-compose.yml and server.jsonc.${NC}" >&2
		return 1
	fi

	container_id=$($SUDO docker ps -a -q -f 'name=^/xray_server$') || return 1
	if [[ -n "$container_id" ]]; then
		old_state=$($SUDO docker inspect --type container -f '{{.Image}} {{.State.Running}}' "$container_id") || return 1
		read -r old_image old_running <<<"$old_state"
	elif [[ "$require_existing" -eq 1 ]]; then
		echo -e "${RED}Container 'xray_server' not found. Cannot update.${NC}" >&2
		return 1
	fi

	for override in docker-compose.override.yml docker-compose.override.yaml compose.override.yml compose.override.yaml; do
		if [[ -f "$override" ]]; then
			compose_files+=(-f "$override")
			break
		fi
	done

	echo "Pulling $target_image..."
	$SUDO docker pull "$target_image" || return 1
	target_id=$($SUDO docker image inspect -f '{{.Id}}' "$target_image") || return 1

	# Same-filesystem staging keeps each replacement atomic and allows recovery
	# files to survive a failed rollback or loss of power.
	work_dir=$(mktemp -d "$PWD/.update.XXXXXX") || return 1
	trap 'finish_xray_image_change "$?"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	printf '%s\n' "${old_image:-none}" >"$work_dir/previous-image" || return 1
	cp -p docker-compose.yml "$work_dir/docker-compose.yml" || return 1
	cp -p server.jsonc "$work_dir/server.jsonc" || return 1
	if ! compose_service_image xray "$work_dir/docker-compose.yml" "$target_image" >"$work_dir/next-compose.yml"; then
		echo -e "${RED}Could not find exactly one image key for the xray service.${NC}" >&2
		return 1
	fi
	apply_preserved_file_metadata docker-compose.yml "$work_dir/next-compose.yml"

	# The managed Compose service reads the bind mount as root. Match it
	# here so validation also works with owner-only configuration files.
	if ! $SUDO docker run --rm --network none --user 0:0 --entrypoint xray \
		-v "$work_dir/server.jsonc:/etc/xray/config.json:ro" "$target_id" \
		run -test -c /etc/xray/config.json; then
		echo -e "${RED}The target Xray image rejected the configuration.${NC}" >&2
		return 1
	fi

	cmp -s docker-compose.yml "$work_dir/next-compose.yml" || compose_changed=1
	if [[ "$old_image" == "$target_id" && "$old_running" == "true" && "$compose_changed" -eq 0 ]] &&
		wait_for_xray_image "$target_id" server.jsonc; then
		echo -e "${GREEN}Xray is already running the requested image and configuration.${NC}"
		return 0
	fi

	(cd .. && checkpoint_xray_quota_usage)
	rollback_needed=1
	if [[ "$compose_changed" -eq 1 ]]; then
		mv -f "$work_dir/next-compose.yml" docker-compose.yml || return 1
	fi
	launch_attempted=1
	if ! start_xray_image "$target_id" -d "${compose_files[@]}" || ! wait_for_xray_image "$target_id" server.jsonc; then
		echo -e "${RED}The updated Xray container failed to start or become ready.${NC}" >&2
		return 1
	fi

	rollback_needed=0
	echo -e "${GREEN}Xray is ready on $target_image.${NC}"
)

change_xray_image() {
	ensure_docker_compose && ensure_jq || return 1
	with_xray_quota_lock apply_xray_image_change "$@"
}

update_xray() {
	change_xray_image "$XRAY_DOCKER_IMAGE" 1
}

update_shadowsocks() {
	update_container "ssserver" "shadowsocks" "${SS_DOCKER_IMAGE%%:*}" "latest"
}

update_hysteria() {
	update_container "hysteria" "hysteria" "${HYSTERIA_DOCKER_IMAGE%%:*}" "latest"
}

change_container_version() {
	local container_choice
	echo ""
	echo -e "${YELLOW}--- Change Container Version (Downgrade/Upgrade) ---${NC}"
	echo "1) Xray"
	echo "2) Hysteria 2"
	echo "3) Shadowsocks"
	echo "0) Back"
	read -r -p "Select the container [0-3]: " container_choice || return 1

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
		dir="hysteria"
		container_name="hysteria"
		base_image="${HYSTERIA_DOCKER_IMAGE%%:*}"
		;;
	3)
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
	local service=$container_name current_image
	[[ "$dir" != xray ]] || service=xray
	if ! current_image=$(compose_service_image "$service" "$dir/docker-compose.yml"); then
		echo -e "${RED}Could not find a single image for $service in $dir/docker-compose.yml.${NC}" >&2
		return 1
	fi
	echo -e "Current image in docker-compose.yml: ${GREEN}${current_image}${NC}"

	echo ""
	echo "Enter the specific version tag you want to downgrade/upgrade to:"
	read -p "Target version tag: " target_version || return 1

	target_version=$(echo "$target_version" | xargs)
	if [[ -z "$target_version" ]]; then
		echo -e "${RED}Version tag cannot be empty.${NC}"
		return 1
	fi
	if ! [[ "$target_version" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
		echo -e "${RED}Invalid container version tag.${NC}"
		return 1
	fi

	if [[ "$dir" == "xray" ]]; then
		change_xray_image "${base_image}:${target_version}" 0
		return
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
	make_temp_file tmp_file || return 1
	make_temp_file backup_file || return 1
	cp -p "$dir/docker-compose.yml" "$backup_file" || return 1

	if ! compose_service_image "$service" "$dir/docker-compose.yml" "$new_image" >"$tmp_file"; then
		rm -f "$tmp_file" "$backup_file"
		echo -e "${RED}Failed to update docker-compose.yml.${NC}"
		return 1
	fi
	apply_preserved_file_metadata "$dir/docker-compose.yml" "$tmp_file"
	mv "$tmp_file" "$dir/docker-compose.yml" || return 1

	echo "Pulling new image version..."
	if (cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" pull) &&
		{ [[ "$dir" != hysteria ]] || checkpoint_hysteria_traffic; } &&
		(cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d) &&
		{ [[ "$dir" != hysteria ]] || wait_for_hysteria; }; then
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
	local links_file=$4
	local link_type=$5

	echo -e "\n${YELLOW}Restoring ${service_name} deployment...${NC}"

	# Check if container already exists
	if $SUDO docker ps -a -q -f name="^/${container_name}$" | grep -q .; then
		echo -e "${YELLOW}${service_name} container already exists. Checking status...${NC}"
		if $SUDO docker ps -q -f name="^/${container_name}$" | grep -q .; then
			echo -e "${GREEN}${service_name} container is already running!${NC}"
			return 0
		else
			echo -e "${YELLOW}Container exists but is stopped. Starting...${NC}"
			(cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" start) || return 1
			echo -e "${GREEN}${service_name} container started successfully!${NC}"
			return 0
		fi
	fi

	(
		cd "$dir" || return 1
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
				done <"$links_file"
			fi
		else
			echo -e "${RED}Failed to start ${service_name} container.${NC}"
			return 1
		fi

	) || return 1
}

restore_xray() {
	restore_container "Xray" "xray_server" "xray" "vless_links.txt" "VLESS"
}

restore_shadowsocks() {
	restore_container "Shadowsocks" "ssserver" "shadowsocks" "ss_links.txt" "SS"
}

restore_hysteria() {
	checkpoint_hysteria_traffic
	(cd hysteria && $SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d) &&
		wait_for_hysteria && show_hysteria_links
}

restore_deployment() {
	echo -e "${YELLOW}Restore Deployment - Re-deploy containers from existing config files${NC}"
	echo -e "${YELLOW}Use this when Docker was reinstalled or containers were accidentally deleted.${NC}\n"

	local XRAY_CONFIG_EXISTS=0
	local SS_CONFIG_EXISTS=0
	local HYSTERIA_CONFIG_EXISTS=0
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

	if [[ -f "hysteria/docker-compose.yml" && -f "hysteria/config/hysteria.yaml" ]]; then
		HYSTERIA_CONFIG_EXISTS=1
		echo -e "${GREEN}✓ Hysteria 2 configuration found${NC}"
	fi

	echo ""

	if ((XRAY_CONFIG_EXISTS + SS_CONFIG_EXISTS + HYSTERIA_CONFIG_EXISTS == 0)); then
		echo -e "${RED}No existing configurations found. Choose Install Proxy Server first.${NC}"
		return 1
	fi

	echo "Which deployment do you want to restore?"
	if [[ "$XRAY_CONFIG_EXISTS" -eq 1 ]]; then
		echo "1) Xray (VLESS-XHTTP-Reality)"
	fi
	if [[ "$SS_CONFIG_EXISTS" -eq 1 ]]; then
		echo "2) Shadowsocks (ss-2022)"
	fi
	if [[ "$HYSTERIA_CONFIG_EXISTS" -eq 1 ]]; then
		echo "3) Hysteria 2"
	fi
	echo "0) Cancel"
	read -p "Enter your choice: " restore_choice || return 1

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
		if [[ "$HYSTERIA_CONFIG_EXISTS" -eq 1 ]]; then
			restore_hysteria
		else
			echo -e "${RED}Hysteria 2 configuration not available.${NC}"
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

	if ! (cd "$dir" && $SUDO "${DOCKER_COMPOSE_CMD[@]}" down); then
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

	if [[ "$dir" == hysteria && -d "$dir/acme-ip" ]]; then
		$SUDO rm -rf -- "$dir/acme-ip" || return 1
	fi

	if ! rm -rf -- "$dir"; then
		echo -e "${RED}Failed to remove ${dir}.${NC}"
		return 1
	fi
	echo -e "${GREEN}${service_name} container and config deleted successfully!${NC}"
}

delete_xray() {
	if [[ -d "xray" ]]; then
		with_xray_quota_lock delete_container "Xray" "xray" || return 1
	fi
	[[ -f hysteria/config/user_limits.db ]] || apply_quota_scheduler disabled
}

delete_hysteria() {
	delete_container "Hysteria 2" "hysteria" || return 1
	[[ -f xray/user_limits.db ]] || apply_quota_scheduler disabled
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

prompt_reality_target() {
	local REALITY_DOMAIN REALITY_DOMAIN_CLEAN PING_HOST probe_port probe_target DOMAIN_WARNING china_confirm PING_OUTPUT VALIDATION_ERRORS CURL_H2_HEADERS force_continue use_domain
	local ALLOWED_DOMAINS DROPPED_WILDCARDS SEEN_DOMAINS domain SERVER_NAMES_INPUT sni_input_arr sni_entry
	local ping_lower d wd inc_aux sni_choice i

	while true; do
		read -p "Enter a domain to probe with 'xray tls ping': " REALITY_DOMAIN || return 1
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
		probe_port=443
		if [[ -z "$PING_HOST" || "$PING_HOST" == -* || ! "$PING_HOST" =~ ^[[:alnum:]_.-]+$ ]]; then
			echo -e "${RED}Enter a domain name with an optional port.${NC}"
			continue
		fi
		if [[ "$REALITY_DOMAIN_CLEAN" == *":"* ]] &&
			! probe_port=$(parse_decimal_range "${REALITY_DOMAIN_CLEAN#*:}" 1 65535); then
			echo -e "${RED}Reality target port must be between 1 and 65535.${NC}"
			continue
		fi
		probe_target="${PING_HOST}:${probe_port}"
		if is_microsoft_domain "${PING_HOST%.}"; then
			echo -e "${RED}Error: Microsoft domains (e.g., microsoft.com, azure.com, office.com, bing.com, etc.) are not accepted for Reality SNI. Please enter a different domain.${NC}"
			continue
		fi

		DOMAIN_WARNING=""
		if is_chinese_domain "$PING_HOST"; then
			DOMAIN_WARNING="${RED}⚠ WARNING: '$PING_HOST' appears to be a Chinese website/domain. Reality target must be a foreign website outside China!${NC}"
		fi

		if [[ -n "$DOMAIN_WARNING" ]]; then
			echo -e "$DOMAIN_WARNING"
			read -p "Are you sure you want to continue with this domain? [y/N]: " china_confirm || return 1
			if [[ "$china_confirm" != "y" && "$china_confirm" != "Y" ]]; then
				continue
			fi
		fi

		echo "Running xray tls ping for $probe_target..."
		VALIDATION_ERRORS=0
		PING_OUTPUT=$($SUDO docker run --rm "$XRAY_DOCKER_IMAGE" tls ping "$probe_target" 2>&1) || VALIDATION_ERRORS=1
		echo "----- tls ping output -----"
		echo "$PING_OUTPUT"
		echo "---------------------------"

		if echo "$PING_OUTPUT" | grep -qi "TLS 1.3\|TLSv1.3\|Version:.*303"; then
			echo -e "${GREEN}✓ TLSv1.3 supported${NC}"
		else
			echo -e "${RED}✗ TLSv1.3 NOT detected - Reality requires TLS 1.3${NC}"
			VALIDATION_ERRORS=1
		fi

		CURL_H2_HEADERS=$(curl -I --http2 --max-time 10 -sS "https://${probe_target}" 2>&1 || true)
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

		if echo "$PING_OUTPUT" | grep -qi "error\|failed\|timeout\|refused"; then
			echo -e "${RED}✗ Connection error detected - domain may be unreachable${NC}"
			VALIDATION_ERRORS=1
		fi

		if [[ "$VALIDATION_ERRORS" -eq 1 ]]; then
			echo -e "${YELLOW}This domain may not be suitable as a Reality target.${NC}"
			read -p "Continue anyway? [y/N]: " force_continue || return 1
			if [[ "$force_continue" != "y" && "$force_continue" != "Y" ]]; then
				continue
			fi
		fi

		read -p "Use this domain and output? [Y/n]: " use_domain || return 1
		if [[ "$use_domain" == "n" || "$use_domain" == "N" ]]; then
			continue
		fi

		REALITY_TARGET="$probe_target"

		local extracted_domains=()
		ALLOWED_DOMAINS=$(echo "$PING_OUTPUT" | sed -nE "s/.*Cert's allowed domains: *\[([^]]*)\].*/\1/p")
		if [[ -n "$ALLOWED_DOMAINS" ]]; then
			DROPPED_WILDCARDS=0
			SEEN_DOMAINS=""
			for domain in $ALLOWED_DOMAINS; do
				if [[ "$domain" == *"*"* ]]; then
					DROPPED_WILDCARDS=1
					continue
				fi
				if is_microsoft_domain "$domain" || [[ " $SEEN_DOMAINS " == *" $domain "* ]]; then
					continue
				fi
				SEEN_DOMAINS+=" $domain"
				extracted_domains+=("$domain")
			done
			if [[ "$DROPPED_WILDCARDS" -eq 1 ]]; then
				echo -e "${YELLOW}Wildcard domains were omitted from serverNames (not supported).${NC}"
			fi
		fi

		REALITY_SERVER_NAMES=()

		# Check if PING_HOST is covered by the certificate
		local ping_host_in_cert=0
		local ping_lower
		ping_lower=$(echo "$PING_HOST" | tr '[:upper:]' '[:lower:]')

		for d in "${extracted_domains[@]}"; do
			local d_lower
			d_lower=$(echo "$d" | tr '[:upper:]' '[:lower:]')
			if [[ "$d_lower" == "$ping_lower" ]]; then
				ping_host_in_cert=1
				break
			fi
		done

		if [[ "$ping_host_in_cert" -eq 0 && -n "$ALLOWED_DOMAINS" ]]; then
			for wd in $ALLOWED_DOMAINS; do
				if [[ "$wd" == "*."* ]]; then
					local base_wd
					base_wd=$(echo "${wd#\*.}" | tr '[:upper:]' '[:lower:]')
					if [[ "$ping_lower" == *."$base_wd" && "$ping_lower" != *.*."$base_wd" ]]; then
						ping_host_in_cert=1
						break
					fi
				fi
			done
		fi

		if [[ "$ping_host_in_cert" -eq 1 ]]; then
			# PING_HOST is covered by the certificate: ALWAYS place it first as primary SNI
			local aux_domains=()
			for d in "${extracted_domains[@]}"; do
				local d_lower
				d_lower=$(echo "$d" | tr '[:upper:]' '[:lower:]')
				if [[ "$d_lower" != "$ping_lower" ]]; then
					aux_domains+=("$d")
				fi
			done

			if [[ ${#aux_domains[@]} -gt 0 ]]; then
				echo -e "\n${YELLOW}Notice: The certificate contains multiple domains:${NC}"
				echo -e "  Primary target: ${GREEN}$PING_HOST${NC}"
				echo -e "  Auxiliary:      ${aux_domains[*]}"
				read -p "Include auxiliary domains in serverNames? (Recommended 'N' to keep only $PING_HOST) [y/N]: " inc_aux || return 1
				if [[ "$inc_aux" == "y" || "$inc_aux" == "Y" ]]; then
					REALITY_SERVER_NAMES=("$PING_HOST" "${aux_domains[@]}")
				else
					REALITY_SERVER_NAMES=("$PING_HOST")
				fi
			else
				REALITY_SERVER_NAMES=("$PING_HOST")
			fi
		elif [[ ${#extracted_domains[@]} -gt 0 ]]; then
			echo -e "\n${YELLOW}Notice: '$PING_HOST' was not found in the certificate's domain list:${NC}"
			for i in "${!extracted_domains[@]}"; do
				echo "  $((i + 1))) ${extracted_domains[$i]}"
			done
			read -p "Select primary SNI [1-${#extracted_domains[@]}] (Default: 1): " sni_choice || return 1
			local chosen_primary=""
			if sni_choice=$(parse_decimal_range "$sni_choice" 1 "${#extracted_domains[@]}"); then
				chosen_primary="${extracted_domains[$((sni_choice - 1))]}"
			else
				chosen_primary="${extracted_domains[0]}"
			fi

			local remaining_aux=()
			for d in "${extracted_domains[@]}"; do
				[[ "$d" != "$chosen_primary" ]] && remaining_aux+=("$d")
			done

			if [[ ${#remaining_aux[@]} -gt 0 ]]; then
				read -p "Include other auxiliary domains in serverNames? [y/N]: " inc_aux || return 1
				if [[ "$inc_aux" == "y" || "$inc_aux" == "Y" ]]; then
					REALITY_SERVER_NAMES=("$chosen_primary" "${remaining_aux[@]}")
				else
					REALITY_SERVER_NAMES=("$chosen_primary")
				fi
			else
				REALITY_SERVER_NAMES=("$chosen_primary")
			fi
		else
			read -p "Enter serverNames (comma-separated, no * wildcards) [Default: $PING_HOST]: " SERVER_NAMES_INPUT || return 1
			if [[ -n "$SERVER_NAMES_INPUT" ]]; then
				IFS=',' read -r -a sni_input_arr <<<"$SERVER_NAMES_INPUT"
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
		return 0
	done
}

install_xray() (
	local num_uuids QUOTA_TIMEZONE KEYS PRIVATE_KEY PUBLIC_KEY DERIVED
	local SERVER_SHORTIDS USED_SHORTIDS sid_idx shortid
	local QUOTA_DB_LINES USED_EMAILS USER_UUIDS USER_EMAILS USER_LIMITS
	local i uuid user_email set_limit user_limit_gb user_anchor_now cycle_bounds user_cycle_start user_cycle_end
	local default_anchor_epoch has_quota_limits cycle_type_choice cycle_day clean_day now_epoch u_email u_uuid u_limit u_anchor
	local XHTTP_PATH REALITY_TARGET REALITY_SERVER_NAMES
	local REALITY_FALLBACK_ADDRESS REALITY_FALLBACK_PORT
	local enable_ipv6 LISTEN_ADDR client_pairs idx shortids_json server_names_json clients_json
	local SERVER_ADDR REMARKS SNI_DOMAIN TARGET_VALUE LINKS link server_uri_host sni_url public_key_url xhttp_path_url fragment_url start_confirm

	echo -e "${YELLOW}Starting Xray VLESS-XHTTP-Reality installation...${NC}"

	ensure_service_dir "xray" || return 1
	cd xray || return 1

	echo "Pulling $XRAY_DOCKER_IMAGE image..."
	$SUDO docker pull "$XRAY_DOCKER_IMAGE" || return 1

	read -p "How many users do you need? [Default: $DEFAULT_UUIDS]: " num_uuids || return 1
	num_uuids=${num_uuids:-$DEFAULT_UUIDS}

	if ! num_uuids=$(parse_decimal_range "$num_uuids" 1 9223372036854775806); then
		echo -e "${RED}User count must be a positive integer.${NC}"
		return 1
	fi

	QUOTA_TIMEZONE="$DEFAULT_QUOTA_TIMEZONE"

	# Generate keys and IDs
	echo "Generating keys and IDs..."
	KEYS=$($SUDO docker run --rm "$XRAY_DOCKER_IMAGE" x25519) || return 1
	PRIVATE_KEY=$(echo "$KEYS" | awk -F': *' 'tolower($0) ~ /private[[:space:]]*key/ {gsub(/\r/, "", $2); print $2; exit}')
	PUBLIC_KEY=$(echo "$KEYS" | awk -F': *' 'tolower($0) ~ /(public[[:space:]]*key|password)/ {gsub(/\r/, "", $2); print $2; exit}')

	if [[ -z "$PRIVATE_KEY" ]]; then
		echo -e "${RED}Failed to parse x25519 private key. Command output:${NC}"
		echo "$KEYS"
		return 1
	fi

	if [[ -z "$PUBLIC_KEY" ]]; then
		DERIVED=$($SUDO docker run --rm "$XRAY_DOCKER_IMAGE" x25519 -i "$PRIVATE_KEY") || return 1
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
	USER_LIMITS=()

	for ((i = 1; i <= num_uuids; i++)); do
		uuid=$(generate_uuid) || return 1

		while true; do
			user_email="u$(openssl rand -hex 8)"
			if [[ -z "${USED_EMAILS[$user_email]:-}" ]]; then
				USED_EMAILS[$user_email]=1
				break
			fi
		done
		echo "Generated user ID for user ${i}: ${user_email}"

		read -p "Set monthly data limit for ${user_email}? [Y/n]: " set_limit || return 1
		user_limit_gb=0
		if [[ -z "$set_limit" || "$set_limit" == "y" || "$set_limit" == "Y" ]]; then
			while true; do
				read -p "Enter monthly limit for ${user_email} in GB [Default: ${DEFAULT_USER_LIMIT_GB}]: " user_limit_gb || return 1
				user_limit_gb=${user_limit_gb:-$DEFAULT_USER_LIMIT_GB}
				if user_limit_gb=$(parse_decimal_range "$user_limit_gb" 1 "$MAX_USER_LIMIT_GB"); then
					break
				fi
				echo -e "${RED}Please enter an integer between 1 and ${MAX_USER_LIMIT_GB} GB.${NC}"
			done
		fi

		USER_LIMITS+=("$user_limit_gb")
		USER_UUIDS+=("$uuid")
		USER_EMAILS+=("$user_email")
	done

	default_anchor_epoch=$(date +%s)
	has_quota_limits=0

	for lim in "${USER_LIMITS[@]}"; do
		if [[ "$lim" -gt 0 ]]; then
			has_quota_limits=1
			break
		fi
	done

	if [[ "$has_quota_limits" -eq 1 ]]; then
		prompt_select_timezone QUOTA_TIMEZONE "$DEFAULT_QUOTA_TIMEZONE" || return 1

		echo ""
		echo "Choose billing cycle reset schedule for users with data limits:"
		echo "1) Start today (resets 1 month from right now) [Default]"
		echo "2) Reset on a specific day of every month (e.g. 1st of the month)"
		read -p "Enter choice [1-2, Default: 1]: " cycle_type_choice || return 1
		cycle_type_choice=${cycle_type_choice:-1}

		if [[ "$cycle_type_choice" == "2" ]]; then
			read -p "Enter the day of the month [1-31, Default: 1]: " cycle_day || return 1
			cycle_day=${cycle_day:-1}
			if ! clean_day=$(parse_decimal_range "$cycle_day" 1 31); then
				echo -e "${YELLOW}Invalid day. Using day 1.${NC}"
				clean_day=1
			fi
			default_anchor_epoch=$(quota_wall_time_epoch "2000-01-$(printf "%02d" "$clean_day") 00:00:00" "$QUOTA_TIMEZONE") || return 1
		fi
	fi

	now_epoch=$(date +%s)
	for idx in "${!USER_UUIDS[@]}"; do
		u_email="${USER_EMAILS[$idx]}"
		u_uuid="${USER_UUIDS[$idx]}"
		u_limit="${USER_LIMITS[$idx]}"
		u_anchor="$default_anchor_epoch"

		cycle_bounds=$(calculate_cycle_bounds "$u_anchor" "$now_epoch" "$QUOTA_TIMEZONE") || return 1
		user_cycle_start="${cycle_bounds%%|*}"
		user_cycle_end="${cycle_bounds##*|}"

		QUOTA_DB_LINES+="${u_email}|${u_uuid}|${u_limit}|${u_anchor}|${user_cycle_start}|${user_cycle_end}|0|0|active"
		if [[ "$idx" -lt $((${#USER_UUIDS[@]} - 1)) ]]; then
			QUOTA_DB_LINES+=$'\n'
		fi
	done

	# Generate random XHTTP path for security
	XHTTP_PATH=$(openssl rand -hex 4) || return 1

	REALITY_TARGET=""
	REALITY_SERVER_NAMES=()
	prompt_reality_target || return 1

	# Keep the REALITY fallback target behind a loopback-only Tunnel. This prevents
	# failed REALITY handshakes from directly exposing a configurable egress target.
	REALITY_FALLBACK_ADDRESS="${REALITY_TARGET%:*}"
	REALITY_FALLBACK_PORT="${REALITY_TARGET##*:}"
	REALITY_TARGET="127.0.0.1:${XRAY_REALITY_FALLBACK_PORT}"

	local enable_ipv6
	while true; do
		read -p "Enable IPv6 listening (dual-stack)? [y/N]: " enable_ipv6 || return 1
		case "$enable_ipv6" in
		[yY])
			LISTEN_ADDR="::"
			break
			;;
		[nN] | "")
			LISTEN_ADDR="0.0.0.0"
			break
			;;
		*)
			echo -e "${RED}Invalid choice. Please enter 'y' or 'n' (or press Enter for default 'n').${NC}"
			;;
		esac
	done

	local enable_china_rules=true
	local china_rules_choice
	while true; do
		read -p "Enable routing rules to block mainland China domains and IPs (geosite:cn, geoip:cn)? [Y/n]: " china_rules_choice || return 1
		case "$china_rules_choice" in
		[yY] | "")
			enable_china_rules=true
			break
			;;
		[nN])
			enable_china_rules=false
			break
			;;
		*)
			echo -e "${RED}Invalid choice. Please enter 'y' or 'n' (or press Enter for default 'y').${NC}"
			;;
		esac
	done

	cat >docker-compose.yml <<EOL || return 1
services:
  xray:
    image: $XRAY_DOCKER_IMAGE
    container_name: xray_server
    restart: unless-stopped
    network_mode: host
    user: "0:0"
    command: ["run", "-c", "/etc/xray/config.json"]
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
	clients_json=$(jq -nc '$ARGS.positional | [range(0; length; 2) as $i | {id: .[$i], flow: "", email: .[$i+1]}]' --args "${client_pairs[@]}") || return 1
	shortids_json=$(jq -nc '$ARGS.positional' --args "${SERVER_SHORTIDS[@]}") || return 1
	server_names_json=$(jq -nc '$ARGS.positional' --args "${REALITY_SERVER_NAMES[@]}") || return 1

	jq -n \
		--arg listen "$LISTEN_ADDR" \
		--arg xhttp_path "/$XHTTP_PATH" \
		--arg target "$REALITY_TARGET" \
		--arg fallback_address "$REALITY_FALLBACK_ADDRESS" \
		--argjson fallback_port "$REALITY_FALLBACK_PORT" \
		--argjson tunnel_port "$XRAY_REALITY_FALLBACK_PORT" \
		--arg private_key "$PRIVATE_KEY" \
		--argjson clients "$clients_json" \
		--argjson server_names "$server_names_json" \
		--argjson shortids "$shortids_json" \
		--argjson enable_china_rules "$enable_china_rules" \
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
            "rules": (
                [
                    {
                        "type": "field",
                        "inboundTag": ["api"],
                        "outboundTag": "api"
                    },
                    {
                        "type": "field",
                        "inboundTag": ["reality-fallback"],
                        "domain": $server_names,
                        "outboundTag": "direct"
                    },
                    {
                        "type": "field",
                        "inboundTag": ["reality-fallback"],
                        "outboundTag": "block"
                    }
                ]
                + (if $enable_china_rules then [
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
                ] else [] end)
            )
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
                        "minClientVer": "",
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
            },
            {
                "listen": "127.0.0.1",
                "port": $tunnel_port,
                "protocol": "dokodemo-door",
                "settings": {
                    "network": "tcp",
                    "address": $fallback_address,
                    "port": $fallback_port,
                    "followRedirect": false,
                    "userLevel": 0
                },
                "sniffing": {
                    "enabled": true,
                    "destOverride": ["tls"],
                    "routeOnly": true
                },
                "tag": "reality-fallback"
            }
        ],
        "outbounds": [
            {
                "protocol": "freedom",
                "tag": "direct",
                "settings": {
                    "domainStrategy": "AsIs",
                    "finalRules": (
                        (if $enable_china_rules then [
                            {
                                "action": "block",
                                "ip": [
                                    "geoip:cn"
                                ]
                            }
                        ] else [] end)
                        + [
                            {
                                "action": "block",
                                "network": "tcp",
                                "port": "25"
                            },
                            {
                                "action": "allow"
                            }
                        ]
                    )
                }
            },
            {
                "protocol": "freedom",
                "tag": "api",
                "settings": {
                    "finalRules": [
                        {
                            "action": "allow"
                        }
                    ]
                }
            },
            {
                "protocol": "blackhole",
                "tag": "block"
            }
        ]
      }' >server.jsonc || return 1

	echo -e "${GREEN}Configuration files created successfully!${NC}"
	echo "--- docker-compose.yml ---"
	cat docker-compose.yml
	echo "--------------------------"
	echo "--- server.jsonc ---"
	cat server.jsonc
	echo "--------------------"
	echo -e "${YELLOW}Public Key: $PUBLIC_KEY${NC}"

	# Prompt for server IP/domain and remarks
	while true; do
		read -p "Enter your server IP address or domain: " SERVER_ADDR || return 1
		require_valid_server_address "$SERVER_ADDR" && break
	done
	read -p "Enter a remarks name for this server: " REMARKS || return 1

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
			link="vless://$uuid@$server_uri_host:443?security=reality&sni=$sni_url&fp=chrome&pbk=$public_key_url&sid=$shortid&type=xhttp&path=$xhttp_path_url#${fragment_url}"
			echo "$link"
			echo
			if [[ -n "$LINKS" ]]; then
				LINKS+="\n"
			fi
			LINKS+="$link\n"
		done
	done

	umask 077
	echo -e "\nSaving links to vless_links.txt..."
	printf "%b" "$LINKS" >vless_links.txt || return 1
	echo "Links saved successfully!"

	cat >user_limits.conf <<EOL || return 1
TIMEZONE=$QUOTA_TIMEZONE
EOL

	write_quota_db_file user_limits.db "$QUOTA_DB_LINES" "# quota-sample||$now_epoch" "" || return 1

	echo -e "${GREEN}Saved quota metadata:${NC} xray/user_limits.conf, xray/user_limits.db"

	read -p "Is the configuration correct? Do you want to start the container? [Y/n]: " start_confirm || return 1
	if [[ -z "$start_confirm" || "$start_confirm" == "y" || "$start_confirm" == "Y" ]]; then
		$SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d || return 1
		echo -e "${GREEN}Xray container has been started!${NC}"
		echo "Remember to open port 443 (TCP & UDP) in your server's firewall."

		prompt_install_quota_scheduler "$has_quota_limits"
	else
		echo -e "${RED}Container start cancelled.${NC}"
	fi

)

change_xray_reality_target() {
	local config_file="xray/server.jsonc"

	if [[ ! -f "$config_file" ]]; then
		echo -e "${RED}Xray configuration not found. Install Xray first.${NC}"
		return 1
	fi
	if ! ensure_jq || ! ensure_docker_compose; then
		return 1
	fi

	local inbound_count tunnel_count tunnel_port
	tunnel_count=$(jq -er '[.inbounds[]? | select(.tag == "reality-fallback" and .protocol == "dokodemo-door")] | length' "$config_file" 2>/dev/null) || {
		echo -e "${RED}Xray config must be valid JSON before changing the Reality target.${NC}"
		return 1
	}
	if [[ "$tunnel_count" -ne 1 ]]; then
		echo -e "${RED}Expected one reality-fallback Tunnel inbound; found ${tunnel_count}.${NC}"
		return 1
	fi
	tunnel_port=$(jq -r '.inbounds[] | select(.tag == "reality-fallback" and .protocol == "dokodemo-door") | .port // empty' "$config_file") || return 1
	if ! tunnel_port=$(parse_decimal_range "$tunnel_port" 1 65535); then
		echo -e "${RED}The reality-fallback Tunnel has an invalid listening port.${NC}"
		return 1
	fi

	inbound_count=$(jq -er '[.inbounds[]? | select(.protocol == "vless" and (.streamSettings.realitySettings? != null))] | length' "$config_file" 2>/dev/null) || {
		echo -e "${RED}Xray config must be valid JSON before changing the Reality target.${NC}"
		return 1
	}
	if [[ "$inbound_count" -ne 1 ]]; then
		echo -e "${RED}Expected exactly one VLESS Reality inbound; found ${inbound_count}. No changes were made.${NC}"
		return 1
	fi

	local old_target old_sni old_fallback_address old_fallback_port
	old_target=$(jq -r '[.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.target][0] // empty' "$config_file")
	old_sni=$(jq -r '[.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.serverNames[0]][0] // empty' "$config_file")
	echo -e "Current Reality target: ${GREEN}${old_target:-unknown}${NC}"
	echo -e "Current Reality SNI: ${GREEN}${old_sni:-unknown}${NC}"
	old_fallback_address=$(jq -r '.inbounds[] | select(.tag == "reality-fallback" and .protocol == "dokodemo-door") | .settings.address // empty' "$config_file") || return 1
	old_fallback_port=$(jq -r '.inbounds[] | select(.tag == "reality-fallback" and .protocol == "dokodemo-door") | .settings.port // empty' "$config_file") || return 1
	if [[ -n "$old_fallback_address" ]]; then
		echo -e "Current Tunnel fallback destination: ${GREEN}${old_fallback_address}${old_fallback_port:+:${old_fallback_port}}${NC}"
	fi

	local REALITY_TARGET REALITY_SERVER_NAMES=()
	prompt_reality_target || return 1
	with_xray_quota_lock apply_xray_reality_target "$tunnel_port" "$REALITY_TARGET" "${REALITY_SERVER_NAMES[@]}"
}

apply_xray_reality_target() {
	local tunnel_port=$1 reality_target=$2
	shift 2
	local server_names=("$@")
	local config_file="xray/server.jsonc" links_file="xray/vless_links.txt"
	local fallback_address="${reality_target%:*}" fallback_port="${reality_target##*:}"
	local tunnel_target="127.0.0.1:${tunnel_port}"

	local server_names_json
	server_names_json=$(jq -nc '$ARGS.positional' --args "${server_names[@]}") || return 1

	local tmp_config config_backup
	make_temp_file tmp_config || return 1
	make_temp_file config_backup || return 1
	if ! cp -p "$config_file" "$config_backup"; then
		rm -f "$tmp_config"
		echo -e "${RED}Failed to back up Xray configuration. No changes were made.${NC}"
		return 1
	fi

	if ! jq \
		--arg target "$tunnel_target" \
		--arg fallback_address "$fallback_address" \
		--argjson fallback_port "$fallback_port" \
		--argjson server_names "$server_names_json" '
        def fallback_rule: (.inboundTag // []) == ["reality-fallback"] and .outboundTag == "direct";
        if ([.routing.rules[] | select(fallback_rule)] | length) != 1
        then error("expected one direct route for the Reality fallback") else . end
        | (.inbounds[] | select(.protocol == "vless" and .streamSettings.realitySettings? != null) | .streamSettings.realitySettings)
        |= (.target = $target | .serverNames = $server_names)
        | (.inbounds[] | select(.tag == "reality-fallback" and .protocol == "dokodemo-door") | .settings)
        |= (.address = $fallback_address | .port = $fallback_port)
        | (.routing.rules[] | select(fallback_rule) | .domain)
        = $server_names
    ' "$config_file" >"$tmp_config"; then
		rm -f "$tmp_config" "$config_backup"
		echo -e "${RED}Failed to prepare the new Xray Reality configuration. No changes were made.${NC}"
		return 1
	fi

	local tmp_links="" sni_url
	if [[ -f "$links_file" ]]; then
		sni_url=$(url_encode_component "${server_names[0]}") || return 1
		make_temp_file tmp_links "$PWD/xray/.vless_links.XXXXXX" || return 1
		if ! sed -E "s|([?&]sni=)[^&#]*|\1${sni_url}|" "$links_file" >"$tmp_links"; then
			rm -f "$tmp_links"
			return 1
		fi
		apply_preserved_file_metadata "$links_file" "$tmp_links"
	fi

	apply_preserved_file_metadata "$config_file" "$tmp_config"
	if ! mv "$tmp_config" "$config_file"; then
		rm -f "$tmp_links" "$tmp_config"
		return 1
	fi

	checkpoint_xray_quota_usage
	echo "Restarting Xray with the new Reality target..."
	if ! reload_xray_container || { [[ -n "$tmp_links" ]] && ! mv "$tmp_links" "$links_file"; }; then
		rm -f "$tmp_links"
		if cp -p "$config_backup" "$config_file" && reload_xray_container; then
			echo -e "${RED}Reality target change failed. The previous configuration was restored.${NC}"
		else
			echo -e "${RED}Could not restore the previous running Xray configuration.${NC}" >&2
		fi
		return 1
	fi

	rm -f "$config_backup"
	echo -e "${GREEN}Xray Reality target changed successfully to ${reality_target}.${NC}"
	if [[ -n "$tmp_links" ]]; then
		echo -e "${YELLOW}Saved VLESS links were updated with SNI ${server_names[0]}.${NC}"
	fi
}

# --- Shadowsocks installation ---

install_shadowsocks() (
	local num_users ss_port enable_ss_ipv6 SS_LISTEN_ADDR SS_METHOD SERVER_PSK
	local ss_users_args USER_PSKS USER_LABELS i user_psk default_label user_label ss_users_json
	local SERVER_ADDR REMARKS start_confirm LINKS server_uri_host fragment_url PASSWORD BASE64 link

	echo -e "${YELLOW}Starting Shadowsocks (ss-2022) installation...${NC}"

	ensure_service_dir "shadowsocks" || return 1
	cd shadowsocks || return 1

	echo "Pulling $SS_DOCKER_IMAGE image..."
	$SUDO docker pull "$SS_DOCKER_IMAGE" || return 1

	while true; do
		read -p "How many users do you need? [Default: $DEFAULT_SS_USERS]: " num_users || return 1
		num_users=${num_users:-$DEFAULT_SS_USERS}
		if num_users=$(parse_decimal_range "$num_users" 1 1000); then
			break
		fi
		echo -e "${RED}User count must be an integer between 1 and 1000.${NC}"
	done

	while true; do
		read -p "Which port should Shadowsocks listen on? [Default: $DEFAULT_SS_PORT]: " ss_port || return 1
		ss_port=${ss_port:-$DEFAULT_SS_PORT}
		if ss_port=$(parse_decimal_range "$ss_port" 1 65535); then
			break
		fi
		echo -e "${RED}Port must be an integer between 1 and 65535.${NC}"
	done

	read -p "Enable IPv6 listening (dual-stack)? [y/N]: " enable_ss_ipv6 || return 1
	if [[ "$enable_ss_ipv6" == "y" || "$enable_ss_ipv6" == "Y" ]]; then
		SS_LISTEN_ADDR="::"
	else
		SS_LISTEN_ADDR="0.0.0.0"
	fi

	SS_METHOD="2022-blake3-chacha20-poly1305"
	SERVER_PSK=$(openssl rand -base64 32) || return 1

	local ss_users_args=()
	USER_PSKS=()
	USER_LABELS=()
	for ((i = 1; i <= num_users; i++)); do
		local user_psk default_label user_label
		user_psk=$(openssl rand -base64 32) || return 1
		default_label="user${i}"
		while true; do
			read -p "Enter a label for user ${i} [${default_label}]: " user_label || return 1
			user_label=${user_label:-$default_label}
			require_valid_label "$user_label" && break
		done

		USER_PSKS+=("$user_psk")
		USER_LABELS+=("$user_label")
		ss_users_args+=("$user_label" "$user_psk")
	done

	cat >docker-compose.yml <<EOL || return 1
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
	ss_users_json=$(jq -nc '$ARGS.positional | [range(0; length; 2) as $i | {name: .[$i], password: .[$i+1]}]' --args "${ss_users_args[@]}") || return 1

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
      }' >server.json || return 1

	echo -e "${GREEN}Configuration files created successfully!${NC}"
	echo "--- docker-compose.yml ---"
	cat docker-compose.yml
	echo "--------------------------"
	echo "--- server.json ---"
	cat server.json
	echo "-------------------"

	# Prompt for server IP/domain and remarks
	while true; do
		read -p "Enter your server IP address or domain: " SERVER_ADDR || return 1
		require_valid_server_address "$SERVER_ADDR" && break
	done
	read -p "Enter a remarks name for this server: " REMARKS || return 1
	REMARKS=${REMARKS:-shadowsocks_rust}

	read -p "Is the configuration correct? Do you want to start the container? [Y/n]: " start_confirm || return 1
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

			umask 077
			echo -e "\nSaving links to ss_links.txt..."
			printf "%b" "$LINKS" >ss_links.txt || return 1
			echo "Links saved successfully!"
		else
			echo -e "${RED}Failed to start Shadowsocks container.${NC}"
			return 1
		fi
	else
		echo -e "${RED}Container start cancelled.${NC}"
	fi
)

# --- Hysteria 2 installation ---

is_hysteria_ip_address() {
	local address=$1 octet='([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])'
	local group='[[:xdigit:]]{1,4}' left right
	local -a left_groups=() right_groups=()

	if [[ "$address" != *:* ]]; then
		[[ "$address" =~ ^$octet(\.$octet){3}$ ]]
		return
	fi
	if [[ "$address" == *.* ]]; then
		[[ "${address##*:}" =~ ^$octet(\.$octet){3}$ ]] || return 1
		address="${address%:*}:0:0"
	fi
	if [[ "$address" != *::* ]]; then
		[[ "$address" =~ ^$group(:$group){7}$ ]]
		return
	fi
	left=${address%%::*}
	right=${address#*::}
	[[ "$left" =~ ^($group(:$group){0,6})?$ && "$right" =~ ^($group(:$group){0,6})?$ ]] || return 1
	IFS=: read -r -a left_groups <<<"$left"
	IFS=: read -r -a right_groups <<<"$right"
	((${#left_groups[@]} + ${#right_groups[@]} < 8))
}

is_hysteria_dns_name() {
	local name=$1 label
	local dns_label='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
	local -a labels

	[[ ${#name} -le 253 && "$name" =~ ^[a-zA-Z0-9.-]+$ && "$name" != *. && ! "$name" =~ ^[0-9.]+$ ]] || return 1
	IFS=. read -r -a labels <<<"$name"
	for label in "${labels[@]}"; do
		[[ "$label" =~ $dns_label ]] || return 1
	done
}

generate_hysteria_ech() {
	local config_dir=$1 public_name=$2 config_list
	if ! $SUDO docker run --rm --pull=always --network none --user "$(id -u):$(id -g)" \
		-v "$config_dir:/etc/proxy-hysteria" "$HYSTERIA_DOCKER_IMAGE" \
		ech --public-name "$public_name" --output /etc/proxy-hysteria/ech.pem >/dev/null; then
		echo "Could not generate ECH keys with the Hysteria Docker image." >&2
		return 1
	fi

	chmod 600 "$config_dir/ech.pem" || return 1
	config_list=$(awk '
		/^-----BEGIN ECH CONFIGS-----$/ { configs = 1; next }
		/^-----END ECH CONFIGS-----$/ { exit }
		configs { printf "%s", $0 }
	' "$config_dir/ech.pem") || return 1
	if [[ ! "$config_list" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
		echo "The Hysteria Docker image did not produce a valid public ECH config." >&2
		return 1
	fi
	url_encode_component "$config_list"
}

prompt_hysteria_bandwidth_mbps() {
	local direction=$1 current=${2:-} client_direction=${3:-} rate
	local prompt="Server $direction bandwidth in Mbps: "
	if [[ -n "$current" ]]; then
		prompt="Server $direction limit in Mbps (caps client $client_direction) [Enter to keep $current]: "
	fi
	while true; do
		read -r -p "$prompt" rate || return 1
		if [[ -n "$current" && -z "$rate" ]]; then return 0; fi
		# Whole Mbps must fit in an unsigned 64-bit bits-per-second value.
		if parse_decimal_range "$rate" 1 18446744073709; then
			return 0
		fi
		echo "Enter a positive whole number in Mbps." >&2
	done
}

hysteria_bandwidth_config() {
	local config=$1 action=$2 upload=${3:-} download=${4:-}
	awk -v action="$action" -v upload="$upload" -v download="$download" '
		/^bandwidth:[[:blank:]]*(#.*)?$/ { in_bandwidth = 1; sections++ }
		/^[^[:space:]#]/ && $0 !~ /^bandwidth:/ { in_bandwidth = 0 }
		in_bandwidth && /^  (up|down):[[:blank:]]+/ {
			key = ($0 ~ /^  up:/ ? "up" : "down")
			value = $0
			sub(/^  (up|down):[[:blank:]]*/, "", value)
			comment = ""
			if (match(value, /[[:blank:]]+#.*/)) {
				comment = substr(value, RSTART)
				value = substr(value, 1, RSTART - 1)
			}
			sub(/[[:blank:]]+$/, "", value)
			gsub(/^["\047]|["\047]$/, "", value)
			count[key]++
			current[key] = value
			rate = (key == "up" ? upload : download)
			if (action == "write" && rate != "" && value != rate " mbps")
				$0 = "  " key ": \"" rate " mbps\"" comment
		}
		action == "write" { print }
		END {
			if (sections != 1 || count["up"] != 1 || count["down"] != 1 ||
				current["up"] !~ /^[0-9]+([[:blank:]]+[a-zA-Z]+)?$/ ||
				current["down"] !~ /^[0-9]+([[:blank:]]+[a-zA-Z]+)?$/) exit 1
			if (action == "read") printf "%s|%s\n", current["up"], current["down"]
		}
	' "$config"
}

change_hysteria_bandwidth() (
	local directory=hysteria/config
	local config="$directory/hysteria.yaml"
	local current current_upload current_download upload download work
	if [[ ! -f "$config" ]] || ! current=$(hysteria_bandwidth_config "$config" read); then
		echo "Could not read the Hysteria 2 server upload and download limits." >&2
		return 1
	fi
	IFS='|' read -r current_upload current_download <<<"$current"
	echo "Current Hysteria 2 server limits: upload $current_upload, download $current_download."
	upload=$(prompt_hysteria_bandwidth_mbps upload "$current_upload" download) || return 1
	download=$(prompt_hysteria_bandwidth_mbps download "$current_download" upload) || return 1
	[[ -n "$upload" || -n "$download" ]] || return 0

	umask 077
	work=$(mktemp -d "$directory/.bandwidth.XXXXXX") || return 1
	trap 'if [[ ! -d "$work/previous" ]]; then rm -rf -- "$work"; fi' EXIT
	mkdir -- "$work/next" || return 1
	with_hysteria_quota_lock apply_hysteria_bandwidth "$directory" "$work" "$current" "$upload" "$download"
)

apply_hysteria_bandwidth() {
	local directory=$1 work=$2 expected=$3 upload=$4 download=$5 current
	if ! current=$(hysteria_bandwidth_config "$directory/hysteria.yaml" read) || [[ "$current" != "$expected" ]]; then
		echo "The Hysteria 2 bandwidth settings changed while the prompt was open. Run the action again." >&2
		return 1
	fi
	hysteria_bandwidth_config "$directory/hysteria.yaml" write "$upload" "$download" >"$work/next/hysteria.yaml" || return 1
	apply_hysteria_file_update "$directory" "$work" bandwidth hysteria.yaml
}

download_hysteria_geodata() (
	local directory=$1 url asset checksum expected
	local -a fetch=(curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 --retry 2)
	mkdir -- "$directory" && cd -- "$directory" || return 1
	for url in \
		https://github.com/XTLS/Xray-rules-dat/releases/latest/download/geosite.dat \
		https://raw.githubusercontent.com/XTLS/Xray-rules-dat/release/geoip/dat/cn.dat; do
		asset=${url##*/}
		if ! "${fetch[@]}" -o "$asset" "$url" ||
			! checksum=$("${fetch[@]}" "$url.sha256sum"); then
			echo "Could not download XTLS geodata or its checksum for $asset." >&2
			return 1
		fi
		read -r expected _ <<<"$checksum"
		if ! [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] ||
			! printf '%s  %s\n' "$expected" "$asset" | sha256sum --check --status; then
			echo "XTLS geodata checksum verification failed for $asset." >&2
			return 1
		fi
	done
)

update_hysteria_geodata() (
	local config=hysteria/config/hysteria.yaml directory=hysteria/config/geo work
	if ! [[ -f "$config" && -f "$directory/geosite.dat" && -f "$directory/cn.dat" ]] ||
		! grep -Fxq '  geosite: /etc/proxy-hysteria/geo/geosite.dat' "$config" ||
		! grep -Fxq '  geoip: /etc/proxy-hysteria/geo/cn.dat' "$config"; then
		echo "This deployment does not use the managed Hysteria 2 XTLS geodata files." >&2
		return 1
	fi

	umask 077
	work=$(mktemp -d "$directory/.update.XXXXXX") || return 1
	trap 'if [[ ! -d "$work/previous" ]]; then rm -rf -- "$work"; fi' EXIT
	echo "Downloading XTLS GeoSite and China GeoIP databases..."
	download_hysteria_geodata "$work/next" || return 1
	with_hysteria_quota_lock apply_hysteria_file_update "$directory" "$work" geodata geosite.dat cn.dat
)

apply_hysteria_file_update() (
	local directory=$1 work=$2 subject=$3 file container running quota_data_dir=hysteria/config
	shift 3
	local -a files=("$@")
	local changed=0 replacing=0 restart_attempted=0 committed=0
	for file in "${files[@]}"; do
		[[ -f "$directory/$file" && -f "$work/next/$file" ]] || return 1
		cmp -s "$directory/$file" "$work/next/$file" || changed=1
	done
	if [[ "$changed" -eq 0 ]]; then
		echo "Hysteria 2 $subject is already up to date."
		return 0
	fi

	container=$(scheduled_hysteria_container) || return 1
	running=$($SUDO docker inspect --type container -f '{{.State.Running}}' "$container") || return 1
	if [[ "$running" == true ]] && ! refresh_xray_quota_accounting status; then
		echo "Could not save Hysteria 2 quota usage before restarting. Hysteria 2 $subject update cancelled." >&2
		return 1
	fi

	mkdir -- "$work/previous" || return 1
	trap 'finish_hysteria_file_update "$?"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	for file in "${files[@]}"; do
		cp -p -- "$directory/$file" "$work/previous/$file" || return 1
		apply_preserved_file_metadata "$directory/$file" "$work/next/$file"
	done

	replacing=1
	for file in "${files[@]}"; do
		mv -f -- "$work/next/$file" "$directory/$file" || return 1
	done
	if [[ "$running" == true ]]; then
		restart_attempted=1
		if ! { $SUDO docker restart "$container" >/dev/null && wait_for_hysteria; }; then
			echo "Hysteria 2 failed to start with the new $subject." >&2
			return 1
		fi
	fi
	committed=1
	echo "Updated Hysteria 2 $subject."
)

finish_hysteria_file_update() {
	local rc=$1 file restored=1
	if [[ "$committed" -eq 0 && "$replacing" -eq 1 ]]; then
		for file in "${files[@]}"; do
			mv -f -- "$work/previous/$file" "$directory/$file" || restored=0
		done
		if [[ "$restored" -eq 0 ]]; then
			echo "Could not restore Hysteria 2 $subject. Remaining backups are in $work/previous." >&2
			return 1
		fi
		echo "Previous Hysteria 2 $subject restored." >&2
		if [[ "$restart_attempted" -eq 1 ]] &&
			! { $SUDO docker restart "$container" >/dev/null && wait_for_hysteria; }; then
			echo "Hysteria 2 did not start after restoring the previous $subject." >&2
		fi
	fi
	rm -rf -- "$work/previous"
	return "$rc"
}

write_hysteria_quota_auth() {
	local directory=$1
	cat >"$directory/quota-auth.sh" <<'AUTH' || return 1
#!/bin/sh
set -eu
auth=$2
case "$auth" in
	*:*) username=${auth%%:*}; password=${auth#*:} ;;
	*) username=user; password=$auth ;;
esac
username=$(printf '%s' "$username" | tr '[:upper:]' '[:lower:]')
case "$username" in
	''|*[!a-z0-9_-]*) exit 1 ;;
esac
case "$password" in
	''|*[!a-f0-9]*) exit 1 ;;
esac
[ "${#password}" -eq 64 ] || exit 1
directory=/etc/proxy-hysteria
awk -F '|' -v user="$username" -v pass="$password" '
	$1 == user && "x" $2 == "x" pass { found = 1 }
	END { exit !found }
' "$directory/auth-users" || exit 1
awk -F '|' -v user="$username" '
	$1 == user && $9 == "active" { found = 1 }
	END { exit !found }
' "$directory/user_limits.db" || exit 1
printf '%s\n' "$username"
AUTH
	chmod 0700 "$directory/quota-auth.sh"
}

initialize_hysteria_quota_files() {
	local directory=$1 timezone=$2 anchor=$3
	local now bounds username password limit rows=""
	now=$(date +%s) || return 1
	anchor=${anchor:-$now}
	bounds=$(calculate_cycle_bounds "$anchor" "$now" "$timezone") || return 1
	while IFS='|' read -r username password limit; do
		rows+="${rows:+$'\n'}$username|$username|${limit:-0}|$anchor|${bounds%%|*}|${bounds##*|}|0|0|active"
	done <"$directory/auth-users"
	[[ -n "$rows" ]] || return 1
	printf 'TIMEZONE=%s\n' "$timezone" >"$directory/user_limits.conf" &&
		write_quota_db_file "$directory/user_limits.db" "$rows" "# quota-sample|hysteria-total|$now" "" &&
		write_hysteria_quota_auth "$directory"
}

prompt_hysteria_billing_anchor() {
	local timezone=$1 choice day reset_time
	echo "1) Start the monthly cycle at installation time [default]" >&2
	echo "2) Set a monthly reset day and local time" >&2
	while true; do
		read -r -p "Choose a billing cycle [1]: " choice || return 1
		case ${choice:-1} in
		1) return 0 ;;
		2) break ;;
		*) echo "Choose 1 or 2." >&2 ;;
		esac
	done
	while true; do
		read -r -p "Monthly reset day [1-31, default 1]: " day || return 1
		if day=$(parse_decimal_range "${day:-1}" 1 31); then break; fi
		echo "Enter a day between 1 and 31." >&2
	done
	while true; do
		read -r -p "Reset time in $timezone [HH:MM, default 00:00]: " reset_time || return 1
		reset_time=${reset_time:-00:00}
		if [[ "$reset_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then break; fi
		echo "Enter a 24-hour time such as 09:30." >&2
	done
	quota_wall_time_epoch "2000-01-$(printf '%02d' "$day") $reset_time:00" "$timezone"
}

wait_for_hysteria() {
	local attempt attempts=15 status started logs
	# A deployment with geo rules can download both databases at startup.
	[[ ! -d hysteria/geo ]] || attempts=60
	for ((attempt = 0; attempt < attempts; attempt++)); do
		read -r status started < <($SUDO docker inspect --type container \
			-f '{{.State.Status}} {{.State.StartedAt}}' hysteria) || break
		if [[ "$status" == running ]]; then
			logs=$($SUDO docker logs --since "$started" hysteria 2>&1) || break
			if [[ "$logs" == *'server up and running'* ]]; then
				return 0
			fi
		fi
		sleep 1
	done
	$SUDO docker logs --tail 15 hysteria >&2
	echo -e "${RED}Hysteria 2 did not report startup. Check the container logs above.${NC}" >&2
	return 1
}

issue_hysteria_ip_certificate() {
	local directory=$1 address=$2 email=$3
	local lineage="$directory/live/hysteria-ip"
	local -a contact=()
	if [[ -n "$email" ]]; then
		contact=(--email "$email")
	fi
	mkdir -- "$directory" || return 1
	echo "Requesting a new Let's Encrypt certificate for $address..."
	$SUDO docker run --rm --network host \
		-v "$directory:/etc/letsencrypt" "$CERTBOT_DOCKER_IMAGE" \
		certonly --non-interactive --agree-tos "${contact[@]}" --standalone \
		--required-profile shortlived --cert-name hysteria-ip --ip-address "$address" || return 1
	$SUDO test -s "$lineage/privkey.pem" &&
		$SUDO openssl verify -purpose sslserver -verify_ip "$address" \
			-untrusted "$lineage/fullchain.pem" "$lineage/cert.pem" >/dev/null
}

install_hysteria() (
	local address host port mode cert_path key_path san
	local challenge_port fingerprint staging start_confirm acme_mount="" acme_email
	local enable_ech ech_public_name="" ech_config link_query="" link_endpoint
	local obfs_choice obfs_type="" obfs_password
	local bandwidth_up bandwidth_down
	local user_count user_number
	local set_limits limit has_quota_limits=0 quota_timezone=$DEFAULT_QUOTA_TIMEZONE billing_anchor=""
	local china_rules_choice block_china=0
	local stats_port=$HYSTERIA_STATS_PORT stats_secret
	local -a identity_check user_passwords=()

	if [[ -e hysteria || -L hysteria ]]; then
		echo "A Hysteria 2 deployment already exists. Choose Restore deployment from existing config."
		return 1
	fi
	if command -v ss >/dev/null; then
		while [[ -n "$(ss -H -ltn "sport = :$stats_port")" ]]; do
			if ((stats_port == 65535)); then
				echo "No available TCP port for the Hysteria traffic API." >&2
				return 1
			fi
			stats_port=$((stats_port + 1))
		done
	fi

	while true; do
		acme_mount=""
		echo "How should Hysteria 2 get its certificate?"
		echo "1) Generate a pinned self-signed certificate (TLS)"
		echo "2) Obtain a Let's Encrypt certificate (ACME)"
		echo "0) Back"
		read -r -p "Certificate option [1]: " mode || return 1
		mode=${mode:-1}
		case $mode in
		1|2) ;;
		0) return 0 ;;
		*) echo "Choose 1, 2 or 0."; continue ;;
		esac

		while true; do
			read -r -p "Enter your VPS's public IPv4, IPv6, or domain [0 to go back]: " address || return 1
			[[ "$address" != 0 ]] || break
			local ip_address=$address
			[[ "$ip_address" != \[*\] ]] || ip_address=${ip_address:1:-1}
			if is_hysteria_ip_address "$ip_address"; then
				address=$ip_address
				san="IP:$address"
				identity_check=(-verify_ip "$address")
				break
			fi
			address=${address%.}
			if is_hysteria_dns_name "$address" && [[ "$address" == *.* ]]; then
				san="DNS:$address"
				identity_check=(-verify_hostname "$address")
				break
			fi
			echo "Enter a public IPv4 or IPv6 address or a hostname such as proxy.example.com."
		done
		[[ "$address" != 0 ]] || continue

		if [[ "$mode" == 2 && "$san" == DNS:* ]]; then
			echo "Point DNS to this server and allow inbound TCP on the challenge port."
			while true; do
				read -r -p "ACME challenge [1 = HTTP on TCP 80, 2 = TLS-ALPN on TCP 443, 0 = Back, default 1]: " challenge_port || return 1
				case ${challenge_port:-1} in
				1) challenge_port=80 ;;
				2) challenge_port=443 ;;
				0) continue 2 ;;
				*) echo "Choose 1, 2 or 0."; continue ;;
				esac
				if command -v ss >/dev/null && [[ -n "$(ss -H -ltn "sport = :$challenge_port")" ]]; then
					echo "TCP port $challenge_port is already in use. Choose another challenge."
					continue
				fi
				break
			done
			acme_mount='      - ./acme:/acme'
		elif [[ "$mode" == 2 ]]; then
			echo "Let's Encrypt verifies your public IP over TCP 80. Keep this port reachable for automatic renewal."
			if command -v ss >/dev/null && [[ -n "$(ss -H -ltn 'sport = :80')" ]]; then
				echo "TCP port 80 is already in use. Free it before requesting an IP certificate."
				continue
			fi
			acme_mount='      - ./acme-ip/live:/etc/letsencrypt/live:ro
      - ./acme-ip/archive:/etc/letsencrypt/archive:ro'
		fi
		if [[ "$mode" == 2 ]]; then
			while true; do
				read -r -p "ACME email [Enter to skip, 0 to go back]: " acme_email || return 1
				[[ "$acme_email" != 0 ]] || continue 2
				if [[ -z "$acme_email" || "$acme_email" =~ ^[^[:space:]@]+@[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$ ]]; then break; fi
				echo "Enter a valid email address."
			done
		fi
		break
	done
	host=$(format_uri_host "$address")

	while true; do
		read -r -p "UDP port for Hysteria 2 [443]: " port || return 1
		if ! port=$(parse_decimal_range "${port:-443}" 1 65535); then
			echo "Enter a port between 1 and 65535."
		elif command -v ss >/dev/null && [[ -n "$(ss -H -lun "sport = :$port")" ]]; then
			echo "UDP port $port is already in use. Choose a different UDP port."
		else
			break
		fi
	done

	umask 077
	staging=$(mktemp -d ./.hysteria.XXXXXX) || return 1
	trap 'if [[ -n "$staging" ]]; then
		if [[ -d "$staging/acme-ip" ]]; then $SUDO rm -rf -- "$staging/acme-ip"; fi
		rm -rf -- "$staging"
	fi' EXIT
	mkdir -- "$staging/config" || return 1
	cert_path="$staging/config/server.crt"
	key_path="$staging/config/server.key"

	if [[ "$mode" == 1 ]]; then
		openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 -days 365 \
			-subj "/CN=Hysteria 2" -addext "subjectAltName=$san" \
			-addext 'basicConstraints=critical,CA:FALSE' -addext extendedKeyUsage=serverAuth \
			-keyout "$key_path" -out "$cert_path" || return 1
		openssl verify -partial_chain -trusted "$cert_path" -purpose sslserver \
			"${identity_check[@]}" "$cert_path" >/dev/null || return 1
		fingerprint=$(openssl x509 -in "$cert_path" -noout -fingerprint -sha256) || return 1
		fingerprint=${fingerprint#*=}
		link_query="insecure=1&pinSHA256=${fingerprint//:/}"
	fi

	while true; do
		read -r -p "Enable Encrypted Client Hello (ECH)? [y/N]: " enable_ech || return 1
		case ${enable_ech:-n} in
		y|Y)
			local ech_default=$HYSTERIA_ECH_DEFAULT_PUBLIC_NAME
			if [[ "${address,,}" == "$ech_default" ]]; then ech_default=""; fi
			while true; do
				read -r -p "ECH public DNS name (visible to the network)${ech_default:+ [$ech_default]}: " ech_public_name || return 1
				ech_public_name=${ech_public_name:-$ech_default}
				if is_hysteria_dns_name "$ech_public_name" && [[ "$ech_public_name" == *.* &&
					"${ech_public_name,,}" != "${address,,}" ]]; then
					break
				fi
				echo "Enter a DNS name different from the server address."
			done
			break
			;;
		n|N) break ;;
		*) echo "Choose y or n." ;;
		esac
	done

	echo "0) No obfuscation (default HTTP/3 behavior)"
	echo "1) Salamander"
	echo "2) Gecko (experimental)"
	while true; do
		read -r -p "Hysteria 2 obfuscation [0]: " obfs_choice || return 1
		case ${obfs_choice:-0} in
		0) break ;;
		1) obfs_type=salamander; break ;;
		2) obfs_type=gecko; break ;;
		*) echo "Choose 0, 1 or 2." ;;
		esac
	done

	echo "Set the server bandwidth limits for Brutal."
	bandwidth_up=$(prompt_hysteria_bandwidth_mbps upload) || return 1
	bandwidth_down=$(prompt_hysteria_bandwidth_mbps download) || return 1

	while true; do
		read -r -p "Block outbound connections to mainland China domains and IPs? [Y/n]: " china_rules_choice || return 1
		case ${china_rules_choice:-y} in
		y|Y)
			block_china=1
			break
			;;
		n|N) break ;;
		*) echo "Choose y or n." ;;
		esac
	done

	while true; do
		read -r -p "How many Hysteria 2 users? [1]: " user_count || return 1
		if user_count=$(parse_decimal_range "${user_count:-1}" 1 9223372036854775806); then
			break
		fi
		echo "Enter a positive whole number of users."
	done

	read -r -p "Set monthly limits for Hysteria 2 users now? [y/N]: " set_limits || return 1

	cat >"$staging/config/hysteria.yaml" <<EOF || return 1
listen: ":$port"
auth:
  type: command
  command: /etc/proxy-hysteria/quota-auth.sh
EOF
	for ((user_number = 1; user_number <= user_count; user_number++)); do
		user_passwords[user_number]=$(openssl rand -hex 32) || return 1
		limit=0
		if [[ "$set_limits" == [yY] ]]; then
			while true; do
				read -r -p "Monthly limit for user$user_number in GB [0 = unlimited]: " limit || return 1
				if limit=$(parse_decimal_range "${limit:-0}" 0 "$MAX_USER_LIMIT_GB"); then break; fi
				echo "Enter a whole number from 0 to $MAX_USER_LIMIT_GB."
			done
		fi
		if ((limit > 0)); then has_quota_limits=1; fi
		printf 'user%s|%s|%s\n' "$user_number" "${user_passwords[user_number]}" "$limit" || return 1
	done >"$staging/config/auth-users" || return 1
	if [[ "$has_quota_limits" -eq 1 ]]; then
		prompt_select_timezone quota_timezone "$DEFAULT_QUOTA_TIMEZONE" || return 1
		billing_anchor=$(prompt_hysteria_billing_anchor "$quota_timezone") || return 1
	fi
	initialize_hysteria_quota_files "$staging/config" "$quota_timezone" "$billing_anchor" || return 1
	stats_secret=$(openssl rand -hex 32) || return 1
	cat >>"$staging/config/hysteria.yaml" <<EOF || return 1
bandwidth:
  up: "$bandwidth_up mbps"
  down: "$bandwidth_down mbps"
trafficStats:
  listen: "127.0.0.1:$stats_port"
  secret: "$stats_secret"
EOF
	if [[ "$block_china" -eq 1 ]]; then
		cat >>"$staging/config/hysteria.yaml" <<'EOF' || return 1
sniff:
  enable: true
  rewriteDomain: false
  tcpPorts: "80,443"
  udpPorts: "443"
acl:
  geosite: /etc/proxy-hysteria/geo/geosite.dat
  geoip: /etc/proxy-hysteria/geo/cn.dat
  inline:
    - reject(geosite:cn)
    - reject(geoip:cn)
EOF
	fi
	if [[ -n "$obfs_type" ]]; then
		obfs_password=$(openssl rand -hex 32) || return 1
		cat >>"$staging/config/hysteria.yaml" <<EOF || return 1
obfs:
  type: $obfs_type
  $obfs_type:
    password: "$obfs_password"
EOF
		link_query="${link_query:+$link_query&}obfs=$obfs_type&obfs-password=$obfs_password"
	fi
	if [[ "$mode" == 2 && "$san" == DNS:* ]]; then
		local challenge=http email_yaml email_line=""
		[[ "$challenge_port" == 443 ]] && challenge=tls
		mkdir -- "$staging/acme" || return 1
		if [[ -n "$acme_email" ]]; then
			email_yaml=$(jq -cn --arg email "$acme_email" '$email') || return 1
			email_line=$'\n'"  email: $email_yaml"
		fi
		cat >>"$staging/config/hysteria.yaml" <<EOF || return 1
acme:
  domains:
    - "$address"
  ca: letsencrypt$email_line
  dir: /acme
  type: $challenge
EOF
	elif [[ "$mode" == 2 ]]; then
		cat >>"$staging/config/hysteria.yaml" <<'EOF' || return 1
tls:
  cert: /etc/letsencrypt/live/hysteria-ip/fullchain.pem
  key: /etc/letsencrypt/live/hysteria-ip/privkey.pem
EOF
	else
		cat >>"$staging/config/hysteria.yaml" <<'EOF' || return 1
tls:
  cert: /etc/proxy-hysteria/server.crt
  key: /etc/proxy-hysteria/server.key
EOF
	fi

	cat >"$staging/docker-compose.yml" <<EOF || return 1
services:
  hysteria:
    image: $HYSTERIA_DOCKER_IMAGE
    container_name: hysteria
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config:/etc/proxy-hysteria:ro
$acme_mount
    command: ["server", "-c", "/etc/proxy-hysteria/hysteria.yaml"]
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
	if [[ "$mode" == 2 && "$san" == IP:* ]]; then
		printf '  certbot:\n    image: %s\n' "$CERTBOT_DOCKER_IMAGE" >>"$staging/docker-compose.yml" || return 1
		cat >>"$staging/docker-compose.yml" <<'EOF' || return 1
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./acme-ip:/etc/letsencrypt
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        trap 'exit 0' TERM INT
        while :; do
          certbot renew --non-interactive --quiet --required-profile shortlived
          sleep 43200 & wait $$!
        done
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
	fi
	read -r -p "Save the deployment and start Hysteria 2 on UDP $port? [Y/n]: " start_confirm || return 1
	case ${start_confirm:-y} in
	y|Y) ;;
	*) return 0 ;;
	esac

	if [[ "$block_china" -eq 1 ]]; then
		echo "Downloading XTLS GeoSite and GeoIP databases..."
		download_hysteria_geodata "$staging/config/geo" || return 1
	fi
	if [[ -n "$ech_public_name" ]]; then
		ech_config=$(generate_hysteria_ech "$PWD/${staging#./}/config" "$ech_public_name") || return 1
		cat >>"$staging/config/hysteria.yaml" <<'EOF' || return 1
ech:
  keyPath: /etc/proxy-hysteria/ech.pem
EOF
		link_query="${link_query:+$link_query&}ech=$ech_config"
	fi
	if [[ "$mode" == 2 && "$san" == IP:* ]]; then
		if ! issue_hysteria_ip_certificate "$PWD/${staging#./}/acme-ip" "$address" "$acme_email"; then
			echo "Could not obtain a trusted Let's Encrypt IP certificate. Check that TCP 80 is reachable." >&2
			return 1
		fi
	fi
	link_endpoint="$host:$port/${link_query:+?$link_query}"
	printf '%s\n' "$link_endpoint" >"$staging/link-endpoint" || return 1
	for ((user_number = 1; user_number <= user_count; user_number++)); do
		printf 'hysteria2://user%s:%s@%s#Hysteria%%202-user%s\n' \
			"$user_number" "${user_passwords[user_number]}" "$link_endpoint" "$user_number" ||
			return 1
	done >"$staging/hysteria_links.txt" || return 1

	mv -nT -- "$staging" hysteria || return 1
	if [[ -d "$staging" ]]; then
		echo "A Hysteria 2 deployment was created in another session." >&2
		return 1
	fi
	staging=""
	if ! (cd hysteria && { [[ -n "$ech_public_name" ]] || $SUDO "${DOCKER_COMPOSE_CMD[@]}" pull; } &&
		$SUDO "${DOCKER_COMPOSE_CMD[@]}" up -d) || ! wait_for_hysteria; then
		echo "Hysteria 2 settings were saved. After fixing startup, choose Restore deployment from existing config." >&2
		return 1
	fi
	echo "Hysteria 2 is running. Allow inbound UDP $port in your firewall."
	show_hysteria_links
	printf '\nThe link carries connection settings. Set bandwidth in your client to use Brutal.\n'
	printf 'Use these client values if your connection can sustain them:\n'
	printf 'bandwidth:\n  up: "%s mbps"\n  down: "%s mbps"\n' "$bandwidth_down" "$bandwidth_up"
	prompt_install_quota_scheduler "$has_quota_limits"
)

# --- Quota subsystem ---

days_in_month() {
	local year=$((10#$1))
	local month=$((10#$2))
	case $month in
	1 | 3 | 5 | 7 | 8 | 10 | 12) echo 31 ;;
	4 | 6 | 9 | 11) echo 30 ;;
	2)
		if (((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0))); then
			echo 29
		else
			echo 28
		fi
		;;
	*) echo 30 ;;
	esac
}

quota_wall_time_epoch() {
	local wall_time=$1 timezone=$2 wall_epoch probe offset seconds candidate actual
	local first_match="" shifted_epoch="" shifted_time=""
	local -A offsets_seen=()
	wall_epoch=$(TZ=UTC0 date -d "$wall_time" +%s) || return 1

	# Try the offsets on either side of a possible transition. Two matches
	# indicate a repeated time. A gap has no match, so use the forward shift.
	for probe in "$((wall_epoch - 86400))" "$wall_epoch" "$((wall_epoch + 86400))"; do
		offset=$(TZ="$timezone" date -d "@$probe" +%::z) || return 1
		[[ -n "$offset" ]] || return 1
		if [[ -n "${offsets_seen[$offset]+set}" ]]; then
			continue
		fi
		offsets_seen["$offset"]=1
		seconds=$((10#${offset:1:2} * 3600 + 10#${offset:4:2} * 60 + 10#${offset:7:2}))
		if [[ "$offset" == -* ]]; then
			seconds=$((-seconds))
		fi
		candidate=$((wall_epoch - seconds))
		actual=$(TZ="$timezone" date -d "@$candidate" +'%F %T') || return 1
		if [[ "$actual" == "$wall_time" ]]; then
			if [[ -z "$first_match" || "$candidate" -lt "$first_match" ]]; then
				first_match=$candidate
			fi
		elif [[ "$actual" > "$wall_time" && (-z "$shifted_time" || "$actual" < "$shifted_time") ]]; then
			shifted_time=$actual
			shifted_epoch=$candidate
		fi
	done

	local result=${first_match:-$shifted_epoch}
	[[ -n "$result" ]] || return 1
	printf '%s\n' "$result"
}

add_months_clamped_epoch() {
	local anchor_epoch=$1
	local add_months=$2
	local timezone=$3
	if [[ "$add_months" -eq 0 ]]; then
		printf '%s\n' "$anchor_epoch"
		return
	fi

	local ay am ad ah amin asec
	read -r ay am ad ah amin asec < <(TZ="$timezone" date -d "@$anchor_epoch" +'%Y %m %d %H %M %S') || return 1

	local total_months=$((10#$ay * 12 + 10#$am - 1 + add_months))
	local ny=$((total_months / 12))
	local nm=$((total_months % 12 + 1))

	local dim
	dim=$(days_in_month "$ny" "$nm")

	local nd=$((10#$ad))
	if [[ "$nd" -gt "$dim" ]]; then
		nd=$dim
	fi

	quota_wall_time_epoch "$(printf "%04d-%02d-%02d %s:%s:%s" "$ny" "$nm" "$nd" "$ah" "$amin" "$asec")" "$timezone"
}

calculate_cycle_bounds() {
	local anchor_epoch=$1
	local now_epoch=$2
	local timezone=$3

	local ay am ny nm
	read -r ay am < <(TZ="$timezone" date -d "@$anchor_epoch" +'%Y %m') || return 1
	read -r ny nm < <(TZ="$timezone" date -d "@$now_epoch" +'%Y %m') || return 1

	local elapsed_months=$(((10#$ny * 12 + 10#$nm) - (10#$ay * 12 + 10#$am)))
	if [[ "$elapsed_months" -lt 0 ]]; then
		elapsed_months=0
	fi

	local start_epoch
	start_epoch=$(add_months_clamped_epoch "$anchor_epoch" "$elapsed_months" "$timezone") || return 1

	if [[ "$start_epoch" -gt "$now_epoch" ]]; then
		elapsed_months=$((elapsed_months - 1))
		if [[ "$elapsed_months" -lt 0 ]]; then
			elapsed_months=0
		fi
		start_epoch=$(add_months_clamped_epoch "$anchor_epoch" "$elapsed_months" "$timezone") || return 1
	fi

	local end_epoch
	end_epoch=$(add_months_clamped_epoch "$anchor_epoch" $((elapsed_months + 1)) "$timezone") || return 1
	echo "${start_epoch}|${end_epoch}"
}

is_quota_timezone() {
	local zone=$1
	[[ "$zone" == "UTC" ]] && return 0
	[[ "$zone" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] &&
		[[ "$(head -c 4 -- "${TZDIR:-/usr/share/zoneinfo}/$zone" 2>/dev/null)" == "TZif" ]]
}

normalize_timezone_input() {
	local input=$1 default_tz=${2:-UTC}
	if [[ -z "$input" ]]; then
		echo "$default_tz"
		return
	fi

	local sign hours max=14 normalized
	if [[ "$input" =~ ^([Uu][Tt][Cc]|[Gg][Mm][Tt])([+-][0-9]+)$ ]]; then
		input=${BASH_REMATCH[2]}
	fi
	if [[ "$input" =~ ^([+-]?)([0-9]+)$ ]]; then
		sign=${BASH_REMATCH[1]}
		hours=${BASH_REMATCH[2]}
		[[ "$sign" != "-" ]] || max=12
		if hours=$(parse_decimal_range "$hours" 0 "$max"); then
			if [[ "$hours" -eq 0 ]]; then
				echo UTC
				return
			fi
			normalized="Etc/GMT-$hours"
			[[ "$sign" != "-" ]] || normalized="Etc/GMT+$hours"
			input=$normalized
		fi
	fi

	if is_quota_timezone "$input"; then
		echo "$input"
	else
		echo -e "${YELLOW}Invalid timezone '$input', falling back to ${default_tz}.${NC}" >&2
		echo "$default_tz"
	fi
}

prompt_select_timezone() {
	local tz_result_var=$1
	local default_tz=${2:-"UTC"}

	echo ""
	echo -e "${YELLOW}Select timezone for quota billing cycles:${NC}"
	echo " 1) UTC (Coordinated Universal Time) [Default]"
	echo " 2) UTC-8  US Pacific (Los Angeles, San Francisco, Vancouver)"
	echo " 3) UTC-7  US Mountain / Arizona (Denver, Phoenix, Salt Lake City)"
	echo " 4) UTC-6  US Central (Chicago, Dallas, Houston, Mexico City)"
	echo " 5) UTC-5  US Eastern (New York, Miami, Toronto, Montreal)"
	echo " 6) UTC+0  Western Europe (London, Dublin, Lisbon)"
	echo " 7) UTC+1  Central Europe (Paris, Berlin, Rome, Madrid, Amsterdam)"
	echo " 8) UTC+2  Eastern Europe / Egypt (Athens, Cairo, Helsinki, Kyiv)"
	echo " 9) UTC+3  Middle East / Moscow (Moscow, Istanbul, Riyadh, Doha)"
	echo "10) UTC+4  Gulf / UAE (Dubai, Abu Dhabi, Muscat, Baku)"
	echo "11) UTC+7  Southeast Asia (Bangkok, Jakarta, Hanoi)"
	echo "12) UTC+8  East Asia (Beijing, Shanghai, Hong Kong, Singapore, Taipei)"
	echo "13) UTC+9  Japan, Korea (Tokyo, Seoul)"
	echo "14) UTC+10 Eastern Australia (Sydney, Melbourne, Brisbane)"
	echo "15) Custom / Other timezone"

	local choice
	read -p "Enter choice [1-15, Default: 1]: " choice || return 1
	choice=${choice:-1}

	local selected_tz="UTC"
	case "$choice" in
	1) selected_tz="UTC" ;;
	2) selected_tz="America/Los_Angeles" ;;
	3) selected_tz="America/Denver" ;;
	4) selected_tz="America/Chicago" ;;
	5) selected_tz="America/New_York" ;;
	6) selected_tz="Europe/London" ;;
	7) selected_tz="Europe/Paris" ;;
	8) selected_tz="Europe/Athens" ;;
	9) selected_tz="Europe/Moscow" ;;
	10) selected_tz="Asia/Dubai" ;;
	11) selected_tz="Asia/Bangkok" ;;
	12) selected_tz="Asia/Shanghai" ;;
	13) selected_tz="Asia/Tokyo" ;;
	14) selected_tz="Australia/Sydney" ;;
	15)
		local custom_tz
		read -p "Enter timezone name or offset (e.g. America/Phoenix, UTC-7, +8): " custom_tz || return 1
		selected_tz=$(normalize_timezone_input "$custom_tz" "$default_tz") || return 1
		;;
	*)
		echo -e "${YELLOW}Invalid choice, defaulting to ${default_tz}.${NC}"
		selected_tz="$default_tz"
		;;
	esac

	if ! is_quota_timezone "$selected_tz"; then
		echo -e "${YELLOW}Timezone '$selected_tz' is unavailable on this host. Using $default_tz.${NC}" >&2
		selected_tz=$default_tz
	fi
	echo -e "Configured timezone: ${GREEN}${selected_tz}${NC}"
	printf -v "$tz_result_var" '%s' "$selected_tz"
}

read_xray_quota_timezone() {
	local conf_file="${quota_data_dir:-xray}/user_limits.conf"
	local tz="$DEFAULT_QUOTA_TIMEZONE"

	if [[ -f "$conf_file" ]]; then
		local parsed_tz
		parsed_tz=$(awk '/^TIMEZONE=/ { tz = substr($0, 10) } END { print tz }' "$conf_file") || return 1
		if [[ -n "$parsed_tz" ]]; then
			tz="$parsed_tz"
		fi
	fi

	normalize_timezone_input "$tz" "$DEFAULT_QUOTA_TIMEZONE"
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

	if [[ ! -d "xray" ]]; then
		echo -e "${RED}Xray configuration directory not found.${NC}" >&2
		return 1
	fi

	if command -v flock >/dev/null 2>&1; then
		local lock_fd
		if [[ ! -e "$lock_file" ]]; then
			(
				umask 022
				touch -- "$lock_file"
			) || return 1
		fi
		exec {lock_fd}<"$lock_file" || return 1
		if flock -x -w "$max_wait" "$lock_fd"; then
			local ret=0
			_XRAY_QUOTA_LOCK_HELD=1
			"$@" || ret=$?
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
				local lock_age=$(($(date +%s) - $(date -r "$lock_dir" +%s 2>/dev/null || date +%s)))
				if [[ "$lock_age" -gt 60 ]]; then
					rmdir "$lock_dir" 2>/dev/null || true
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
		# A live holder may spend longer than the legacy stale-lock threshold
		# pulling an image. An occupied directory cannot be reclaimed by rmdir.
		if ! mkdir "$lock_dir/held"; then
			rmdir "$lock_dir" 2>/dev/null || true
			return 1
		fi
		_XRAY_QUOTA_MKDIR_LOCK="$PWD/$lock_dir"
		_XRAY_QUOTA_MKDIR_OWNER=$BASHPID
		local ret=0
		_XRAY_QUOTA_LOCK_HELD=1
		"$@" || ret=$?
		release_xray_quota_directory_lock
		_XRAY_QUOTA_LOCK_HELD=0
		return $ret
	fi
}

get_quota_db_records() {
	local db_file="${quota_data_dir:-xray}/user_limits.db"
	if [[ -f "$db_file" ]]; then
		awk 'NF && $0 !~ /^[[:space:]]*#/' "$db_file"
	fi
}

with_proxy_quota_lock() {
	if [[ "${quota_data_dir:-xray}" == xray ]]; then
		with_xray_quota_lock "$@"
	else
		with_hysteria_quota_lock "$@"
	fi
}

with_hysteria_quota_lock() (
	if [[ ${hysteria_quota_locked:-0} != 1 ]]; then
		local lock_fd
		exec {lock_fd}<hysteria || return 1
		flock -x -w 10 "$lock_fd" || {
			echo "Could not lock Hysteria 2 quota accounting." >&2
			return 1
		}
	fi
	local hysteria_quota_locked=1
	"$@"
)

parse_quota_db_line() {
	local line=$1
	IFS='|' read -r email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status <<<"$line"

	if [[ -z "$email" || -z "$uuid" || -z "$status" ]]; then
		return 1
	fi
	if ! [[ "$limit_gb" =~ ^[0-9]+$ && "$anchor_epoch" =~ ^[0-9]+$ && "$cycle_start" =~ ^[0-9]+$ && "$cycle_end" =~ ^[0-9]+$ && "$cycle_usage" =~ ^[0-9]+$ && "$last_total" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	if [[ "$status" != "active" && "$status" != "suspended" ]]; then
		return 1
	fi

	[[ "$limit_gb" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
	[[ ${#limit_gb} -lt ${#MAX_USER_LIMIT_GB} ||
		(${#limit_gb} -eq ${#MAX_USER_LIMIT_GB} && ! "$limit_gb" > "$MAX_USER_LIMIT_GB") ]]
}

get_quota_accounting_metadata() {
	local db_file=${1:-${quota_data_dir:-xray}/user_limits.db}
	if [[ -f "$db_file" ]]; then
		awk '/^# quota-(sample|closed)\|/' "$db_file"
	fi
}

write_quota_db_file() {
	local destination=$1 content=$2 metadata=$3 profiles=$4
	{
		printf '%s\n' '# email|uuid|limit_gb|anchor_epoch|cycle_start_epoch|cycle_end_epoch|cycle_usage_bytes|last_total_bytes|status' &&
			{ [[ -z "$metadata" ]] || printf '%s\n' "$metadata"; } &&
			{ [[ -z "$profiles" ]] || printf '%s\n' "$profiles"; } &&
			{ [[ -z "$content" ]] || printf '%s\n' "$content"; }
	} >"$destination"
}

save_quota_db_content() {
	local content=$1 db_file="${quota_data_dir:-xray}/user_limits.db"
	local tmp_db metadata profiles=""
	if [[ $# -ge 2 ]]; then
		metadata=$2
	else
		metadata=$(get_quota_accounting_metadata) || return 1
	fi
	if [[ -f "$db_file" ]]; then
		profiles=$(awk '/^# vless-client /' "$db_file") || return 1
	fi
	make_temp_file tmp_db "$PWD/${quota_data_dir:-xray}/.user_limits.db.XXXXXX" || return 1
	if ! write_quota_db_file "$tmp_db" "$content" "$metadata" "$profiles"; then
		rm -f "$tmp_db"
		return 1
	fi
	apply_preserved_file_metadata "$db_file" "$tmp_db"
	if ! mv "$tmp_db" "$db_file"; then
		rm -f "$tmp_db"
		return 1
	fi
}

stage_xray_client_sync() {
	local current_db=$1 next_db=$2 current_config=$3
	# Match UUIDs without changing the spelling in the original entries.
	# Custom client IDs use exact-string matching.
	jq -es --rawfile current_db "$current_db" --rawfile next_db "$next_db" '
        def client_key:
            if type == "string" and test("^[0-9a-fA-F]{8}(-?[0-9a-fA-F]{4}){3}-?[0-9a-fA-F]{12}$")
            then ascii_downcase | gsub("-"; "") else . end;

        def quota_rows($db):
            [$db | split("\n")[] | select(test("^[[:space:]]*(#|$)") | not) | split("|") |
             if length == 9 and .[0] != "" and .[1] != "" and (.[8] == "active" or .[8] == "suspended")
             then {email: .[0], id: .[1], status: .[8]}
             else error("invalid Xray quota user record") end];

        def keyed($entries; $label):
            reduce $entries[] as $entry ({};
                ($entry.id | client_key) as $id |
                if ($id | type) != "string" or $id == "" then error("invalid ID in " + $label)
                elif has($id) then error("duplicate client ID in " + $label)
                else .[$id] = $entry end);

        if length != 1 or (.[0] | type) != "object" then error("expected one Xray configuration object") else .[0] end |
        . as $config |
        [(.inbounds // []) | to_entries[] |
         select(.value.protocol == "vless" and ((.value.settings.clients? | type) == "array")) | .key] as $targets |
        if ($targets | length) != 1 then error("expected exactly one VLESS inbound with a clients array") else . end |
        $targets[0] as $target |
        $config.inbounds[$target].settings.clients as $live |
        quota_rows($current_db) as $previous_rows |
        quota_rows($next_db) as $next_rows |
        keyed($previous_rows; "the previous quota database") as $previous |
        keyed($next_rows; "the updated quota database") as $next |
        ($previous + $next) as $managed |
        keyed(
            [$current_db | split("\n")[] | select(startswith("# vless-client ")) |
             ltrimstr("# vless-client ") | fromjson];
            "saved VLESS client profiles"
        ) as $saved |
        keyed(
            [$live[] | select(type == "object") |
             select((.id | client_key) as $id | ($id | type) == "string" and ($managed | has($id)))];
            "the managed VLESS clients"
        ) as $live_managed |
        if any($next_rows[]; (.id | client_key) as $id | ($previous | has($id) | not) and ($live_managed | has($id)))
        then error("a new quota UUID already belongs to an existing VLESS client")
        else . end |
        (
            [$live[] | select(
                if type != "object" or (.id | type) != "string" then true
                else (.id | client_key) as $id |
                     ($managed | has($id) | not) or ($next[$id].status == "active")
                end
            )]
            + [$next_rows[] | select(.status == "active") |
               (.id | client_key) as $id |
               select($live_managed | has($id) | not) |
               $saved[$id] //
               (if $previous[$id].status == "suspended"
                then error("missing VLESS client profile for suspended user " + .email)
                else {id, email, flow: ""} end)]
        ) as $clients |
        {
            changed: ($clients != $live),
            config: ($config | .inbounds[$target].settings.clients = $clients),
            profiles: [
                $next_rows[] | select(.status == "suspended") |
                (.id | client_key) as $id |
                ($live_managed[$id] // $saved[$id] // empty)
            ]
        }
    ' "$current_config"
}

finish_xray_quota_client_update() {
	# The EXIT trap runs inside apply_xray_quota_client_update under the quota lock.
	local rc=$1 restored=1
	if [[ "$rollback_needed" -eq 1 ]]; then
		cp -p "$work_dir/previous.db" "$work_dir/restore.db" &&
			mv -f "$work_dir/restore.db" "$db_file" || restored=0
		if [[ "$config_replaced" -eq 1 ]]; then
			cp -p "$work_dir/previous.jsonc" "$work_dir/restore.jsonc" &&
				mv -f "$work_dir/restore.jsonc" "$config_file" || restored=0
			if [[ "$restored" -eq 1 && "$reload_attempted" -eq 1 ]]; then
				reload_xray_container || restored=0
			fi
		fi
		if [[ "$restored" -ne 1 ]]; then
			echo -e "${RED}Xray quota rollback failed. Recovery files are in $work_dir.${NC}" >&2
			return 1
		fi
		echo -e "${YELLOW}Previous Xray quota database and configuration restored.${NC}" >&2
	fi
	rm -rf -- "$work_dir"
	return "$rc"
}

apply_xray_quota_client_update() (
	local db_lines=$1
	local db_file="xray/user_limits.db" config_file="xray/server.jsonc"
	if [[ ! -f "$db_file" || ! -f "$config_file" ]]; then
		echo -e "${RED}Cannot update Xray clients: database or configuration file missing.${NC}" >&2
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		echo -e "${RED}Cannot safely update Xray clients because jq is unavailable.${NC}" >&2
		return 1
	fi

	local work_dir metadata changed rollback_needed=0 config_replaced=0 reload_attempted=0
	work_dir=$(mktemp -d "$PWD/xray/.quota-update.XXXXXX") || return 1
	trap 'finish_xray_quota_client_update "$?"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	cp -p "$db_file" "$work_dir/previous.db" || return 1
	cp -p "$config_file" "$work_dir/previous.jsonc" || return 1
	if [[ $# -ge 2 ]]; then
		metadata=$2
	else
		metadata=$(get_quota_accounting_metadata "$work_dir/previous.db") || return 1
	fi

	write_quota_db_file "$work_dir/next.db" "$db_lines" "$metadata" "" || return 1
	if ! stage_xray_client_sync "$work_dir/previous.db" "$work_dir/next.db" "$work_dir/previous.jsonc" >"$work_dir/sync.json"; then
		echo -e "${RED}Could not prepare the VLESS client update.${NC}" >&2
		return 1
	fi
	jq -r '.profiles[] | "# vless-client " + tojson' "$work_dir/sync.json" >>"$work_dir/next.db" || return 1
	changed=$(jq -r '.changed' "$work_dir/sync.json") || return 1
	if [[ "$changed" == "true" ]]; then
		jq '.config' "$work_dir/sync.json" >"$work_dir/next.jsonc" || return 1
		apply_preserved_file_metadata "$config_file" "$work_dir/next.jsonc"
	fi
	apply_preserved_file_metadata "$db_file" "$work_dir/next.db"

	if ! cmp -s "$db_file" "$work_dir/previous.db" || ! cmp -s "$config_file" "$work_dir/previous.jsonc"; then
		echo -e "${RED}The Xray database or configuration changed during staging. Retry the update.${NC}" >&2
		return 1
	fi
	rollback_needed=1
	mv -f "$work_dir/next.db" "$db_file" || return 1
	if [[ "$changed" == "true" ]]; then
		# Restore both files if this replacement or the subsequent reload fails.
		config_replaced=1
		mv -f "$work_dir/next.jsonc" "$config_file" || return 1
		reload_attempted=1
		if ! reload_xray_container; then
			echo -e "${RED}Xray reload failed after updating clients.${NC}" >&2
			return 1
		fi
	fi
	rollback_needed=0
)

finalize_quota_db_update() {
	with_proxy_quota_lock _finalize_quota_db_update_internal "$@"
}

_finalize_quota_db_update_internal() {
	local db_lines=$1 config_changed=$2

	# Only the explicit remove-user operation can empty a populated database.
	local existing_records
	existing_records=$(get_quota_db_records) || return 1
	if [[ -z "$db_lines" && -n "$existing_records" ]]; then
		echo -e "${RED}Quota update produced an empty database. Changes were cancelled.${NC}" >&2
		return 1
	fi

	if [[ "${quota_data_dir:-xray}" == hysteria/config ]]; then
		save_quota_db_content "$db_lines" "${@:3}" || return 1
		if [[ "$config_changed" -eq 1 ]]; then
			disconnect_suspended_hysteria_users
		fi
	elif [[ "$config_changed" -eq 1 ]]; then
		apply_xray_quota_client_update "$db_lines" "${@:3}"
	else
		save_quota_db_content "$db_lines" "${@:3}"
	fi
}

collect_xray_user_stats() {
	local map_file=$1
	: >"$map_file" || return 1

	local container_id
	if ! container_id=$($SUDO docker ps -q -f name="^/xray_server$" 2>&1); then
		echo '|||Could not query Docker for the Xray container.'
		return 0
	fi
	if [[ -z "$container_id" ]]; then
		echo '|||'
		return 0
	fi

	local inspect_format='{{.Id}}|{{.State.StartedAt}}|{{.State.Running}}'
	local before after full_id started_at running raw_stats sample_epoch started_epoch
	if ! before=$(timeout 5s $SUDO docker inspect --type container -f "$inspect_format" "$container_id" 2>/dev/null); then
		echo '|||Could not inspect the running Xray container.'
		return 0
	fi
	IFS='|' read -r full_id started_at running <<<"$before"
	if [[ -z "$full_id" || "$running" != "true" ]]; then
		echo '|||Xray stopped before its counters could be read.'
		return 0
	fi

	if ! raw_stats=$(timeout 15s $SUDO docker exec "$full_id" xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>" 2>&1); then
		printf '|||%s\n' "$(printf '%s' "${raw_stats:-statsquery failed or timed out}" | tr '\n' ' ')"
		return 0
	fi
	sample_epoch=$(date +%s) || return 1
	if ! after=$(timeout 5s $SUDO docker inspect --type container -f "$inspect_format" xray_server 2>/dev/null) ||
		[[ "$before" != "$after" ]]; then
		echo '|||Xray changed during the counter query. Discarded the sample.'
		return 0
	fi
	started_epoch=$(date -d "$started_at" +%s) || return 1

	# Xray omits zero-valued fields and may return an empty object before
	# any user has connected. Reject invalid responses before using totals.
	if [[ -z "$raw_stats" ]] || ! jq -r '
        if type != "object" or (length != 0 and (has("stat") | not)) or ((.stat // []) | type) != "array" then
            error("invalid StatsService response")
        else
            (.stat // [])[] |
            (.name | capture("^user>>>(?<user>[^>|\r\n]+)>>>traffic>>>(?<direction>uplink|downlink)$")) as $counter |
            ((.value // 0) | tostring) as $value |
            if $value | test("^[0-9]+$") then
                [$counter.user, $counter.direction, $value] | join("|")
            else
                error("invalid traffic counter")
            end
        end
    ' <<<"$raw_stats" >"$map_file"; then
		: >"$map_file" || return 1
		echo '|||Could not parse the Xray traffic counters.'
		return 0
	fi

	printf '%s@%s|%s|%s|\n' "$full_id" "$started_at" "$sample_epoch" "$started_epoch"
}

# Store accounting metadata in comment lines alongside user records.
# The collector and all quota writes hold the same lock.
refresh_xray_quota_accounting() {
	local mode=${1:-quiet}
	local stats_map_file result generation sample_epoch started_epoch stats_error
	local db_records metadata previous_generation="" previous_sample=""
	local kind first second closed_start closed_end closed_usage pending_resume
	local -A closed_cycles=() totals=()
	db_records=$(get_quota_db_records) || return 1
	[[ -n "$db_records" ]] || return 0
	metadata=$(get_quota_accounting_metadata) || return 1
	while IFS='|' read -r kind first second closed_start closed_end closed_usage pending_resume; do
		case "$kind" in
		'# quota-sample')
			if ! [[ "$second" =~ ^[0-9]+$ ]]; then
				echo -e "${RED}Invalid quota sample metadata.${NC}" >&2
				return 1
			fi
			previous_generation=$first
			previous_sample=$second
			;;
		'# quota-closed')
			if ! [[ -n "$second" && "$closed_start" =~ ^[0-9]+$ && "$closed_end" =~ ^[0-9]+$ &&
				"$closed_usage" =~ ^[0-9]+$ && "$pending_resume" =~ ^[01]$ ]]; then
				echo -e "${RED}Invalid quota cycle metadata.${NC}" >&2
				return 1
			fi
			closed_cycles["$second"]="$closed_start|$closed_end|$closed_usage|$pending_resume"
			;;
		esac
	done <<<"$metadata"

	if [[ -z "$previous_sample" ]]; then
		echo -e "${RED}Quota database is missing its accounting metadata.${NC}" >&2
		return 1
	fi

	make_temp_file stats_map_file || return 1
	local collector=collect_xray_user_stats
	[[ "${quota_data_dir:-xray}" != hysteria/config ]] || collector=collect_hysteria_quota_stats
	if ! result=$("$collector" "$stats_map_file"); then
		rm -f "$stats_map_file"
		return 1
	fi
	IFS='|' read -r generation sample_epoch started_epoch stats_error <<<"$result"
	if [[ "$mode" == status && ( -z "$generation" || -n "$stats_error" ) ]]; then
		rm -f "$stats_map_file"
		return 1
	fi
	if [[ -n "$stats_error" ]]; then
		echo -e "${YELLOW}Could not sample traffic: ${stats_error}${NC}" >&2
		if [[ "$mode" == "strict" ]]; then
			rm -f "$stats_map_file"
			return 1
		fi
	fi
	local counter_email direction value
	while IFS='|' read -r counter_email direction value; do
		[[ -n "$counter_email" ]] || continue
		totals["$counter_email"]=$((${totals[$counter_email]:-0} + 10#$value))
	done <"$stats_map_file"
	rm -f "$stats_map_file"

	local now_epoch timezone new_run=0
	now_epoch=${sample_epoch:-$(date +%s)}
	timezone=$(read_xray_quota_timezone) || return 1
	if [[ -n "$generation" && -n "$previous_generation" && "$generation" != "$previous_generation" ]]; then
		new_run=1
	fi

	local db_lines="" closed_lines="" raw_line
	local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status
	local cycle_bounds new_start new_end old_month new_month delta interval_start current_total
	while IFS= read -r raw_line; do
		if ! parse_quota_db_line "$raw_line"; then
			echo -e "${RED}Quota database contains an invalid record. Changes were cancelled.${NC}" >&2
			return 1
		fi
		IFS='|' read -r closed_start closed_end closed_usage pending_resume <<<"${closed_cycles[$uuid]:-}"
		delta=0
		interval_start=$previous_sample
		if [[ -n "$generation" ]]; then
			if [[ "$new_run" -eq 1 || (-z "$previous_generation" && "$started_epoch" -gt "$previous_sample") ]]; then
				interval_start=$started_epoch
				last_total=0
			fi
			current_total=${totals[$email]:-$last_total}
			delta=$((current_total - last_total))
			if [[ "$delta" -lt 0 ]]; then
				# Adopt a reset counter even within the same running container.
				delta=$current_total
			fi
			last_total=$current_total
		fi

		if [[ "$now_epoch" -ge "$cycle_end" ]]; then
			cycle_bounds=$(calculate_cycle_bounds "$anchor_epoch" "$now_epoch" "$timezone") || return 1
			new_start=${cycle_bounds%%|*}
			new_end=${cycle_bounds##*|}
			if [[ "$new_start" != "$cycle_start" ]]; then
				# Compare calendar months so a corrected DST occurrence
				# in the same monthly cycle preserves accumulated usage.
				old_month=$(TZ="$timezone" date -d "@$cycle_start" +%Y-%m) || return 1
				new_month=$(TZ="$timezone" date -d "@$new_start" +%Y-%m) || return 1
				if [[ "$cycle_start" -gt 0 && "$cycle_end" -gt "$cycle_start" && "$new_month" > "$old_month" ]]; then
					closed_start=$cycle_start
					closed_end=$new_start
					# When several cutoffs passed, retain the actual end
					# of the cycle being closed.
					if [[ "$cycle_end" -lt "$closed_end" ]]; then
						closed_end=$cycle_end
					fi
					closed_usage=$cycle_usage
					pending_resume=0
					[[ "$status" != "suspended" ]] || pending_resume=1
					cycle_usage=0
				fi
			fi
			cycle_start=$new_start
			cycle_end=$new_end
		fi

		if [[ -n "$closed_start" && "$interval_start" -lt "$cycle_start" ]]; then
			closed_usage=$((closed_usage + delta))
		else
			cycle_usage=$((cycle_usage + delta))
		fi

		if [[ -n "$closed_start" ]]; then
			closed_lines+="${closed_lines:+$'\n'}# quota-closed|${email}|${uuid}|${closed_start}|${closed_end}|${closed_usage}|${pending_resume}"
		fi
		db_lines+="${db_lines:+$'\n'}${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
	done <<<"$db_records"

	local new_metadata="# quota-sample|${generation:-$previous_generation}|${sample_epoch:-$previous_sample}"
	new_metadata+="${closed_lines:+$'\n'$closed_lines}"
	if [[ "$db_lines" != "$db_records" || "$new_metadata" != "$metadata" ]]; then
		save_quota_db_content "$db_lines" "$new_metadata"
	fi
}

# --- Hysteria traffic accounting ---

hysteria_traffic_api_settings() {
	awk '
		/^trafficStats:[[:space:]]*$/ { in_stats = 1; next }
		in_stats && /^[^[:space:]#]/ { exit }
		in_stats && /^[[:space:]]+listen:/ { address = $2 }
		in_stats && /^[[:space:]]+secret:/ { secret = $2 }
		END {
			gsub(/"/, "", address)
			gsub(/"/, "", secret)
			if (address != "" && secret != "") print address, secret
		}
	' hysteria/config/hysteria.yaml
}

read_hysteria_traffic_endpoint() {
	local endpoint token
	read -r endpoint token < <(hysteria_traffic_api_settings) || return 1
	[[ "$endpoint" =~ ^127\.0\.0\.1:[0-9]+$ && "$token" =~ ^[a-fA-F0-9]{64}$ ]] &&
		parse_decimal_range "${endpoint##*:}" 1 65535 >/dev/null || return 1
	printf '%s %s\n' "$endpoint" "$token"
}

hysteria_traffic_request() {
	local address=$1 secret=$2 path=$3
	shift 3
	printf 'Authorization: %s\n' "$secret" |
		curl -q -fsS --noproxy '*' --connect-timeout 2 --max-time 5 --header @- \
			"$@" "http://$address/$path"
}

sample_hysteria_traffic() (
	local address=$1 secret=$2
	local database=hysteria/traffic-usage.json previous=/dev/null staged="" lock_fd
	local config_dir identity before after generation stats usernames
	identity='{{.Id}}|{{.State.StartedAt}}|{{.State.Running}}|{{json .Mounts}}'

	if ! command -v flock >/dev/null; then
		echo "Hysteria 2 traffic snapshots require flock from util-linux." >&2
		return 1
	fi
	if [[ ${hysteria_quota_locked:-0} != 1 ]]; then
		exec {lock_fd}<hysteria || return 1
		flock -x -w 10 "$lock_fd" || return 1
	fi
	config_dir=$(cd -P hysteria/config && pwd) || return 1
	before=$(timeout 5s $SUDO docker inspect --type container -f "$identity" hysteria 2>/dev/null) || return 1
	generation=${before%%|true|*}
	[[ "$before" != "$generation" ]] || return 1
	jq -e --arg source "$config_dir" 'any(.[]; .Source == $source and .Destination == "/etc/proxy-hysteria")' \
		<<<"${before#*|true|}" >/dev/null || return 1

	# Read cumulative counters. Clearing them before the snapshot is committed can lose traffic.
	stats=$(hysteria_traffic_request "$address" "$secret" traffic) || return 1
	after=$(timeout 5s $SUDO docker inspect --type container -f "$identity" hysteria 2>/dev/null) || return 1
	[[ "$after" == "$before" ]] || return 1

	usernames=$(sed -nE '
		s#^hysteria2://([a-z0-9_-]+):[[:xdigit:]]+@.*#\1#p
		s#^hysteria2://[[:xdigit:]]+@.*#user#p
	' hysteria/hysteria_links.txt 2>/dev/null) || usernames=""
	[[ ! -e "$database" ]] || previous=$database
	staged=$(mktemp hysteria/.traffic.XXXXXX) || return 1
	trap 'rm -f -- "$staged"' EXIT
	jq -es --arg generation "$generation" --arg usernames "$usernames" --slurpfile stored "$previous" '
		def zero: {tx: 0, rx: 0, upload: 0, download: 0};
		def counter: type == "number" and . >= 0 and . <= 9007199254740991 and . == floor;
		def delta($last): if . >= $last then . - $last else . end;
		if length != 1 then error("expected one traffic snapshot") else .[0] end |
		if type != "object" or any(.[]; (.tx | counter | not) or (.rx | counter | not))
		then error("invalid Hysteria Traffic Stats API response") else . end |
		. as $sample |
		($stored[0] // {generation: "", users: {}}) |
		if .generation != $generation then
			.generation = $generation | .users[] |= (.tx = 0 | .rx = 0)
		else . end |
		reduce ($usernames | split("\n")[] | select(length > 0)) as $user
			(. ; .users[$user] //= zero) |
		reduce ($sample | to_entries[]) as $entry
			(. ; .users[$entry.key] |= ((. // zero) | . as $prior |
				.upload += ($entry.value.tx | delta($prior.tx)) |
				.download += ($entry.value.rx | delta($prior.rx)) |
				.tx = $entry.value.tx | .rx = $entry.value.rx))
	' <<<"$stats" >"$staged" || return 1
	mv -f -- "$staged" "$database"
)

checkpoint_hysteria_traffic() {
	[[ -f hysteria/config/hysteria.yaml ]] || return 0
	if [[ -f hysteria/config/user_limits.db ]]; then
		local quota_data_dir=hysteria/config
		with_proxy_quota_lock checkpoint_xray_quota_usage
		return
	fi
	local address secret
	read -r address secret < <(read_hysteria_traffic_endpoint) || return 0
	if ! sample_hysteria_traffic "$address" "$secret"; then
		echo "Could not refresh Hysteria 2 traffic. Showing the last saved sample if available." >&2
	fi
}

collect_hysteria_quota_stats() {
	local map_file=$1 address secret now
	: >"$map_file" || return 1
	if ! read -r address secret < <(read_hysteria_traffic_endpoint) ||
		! sample_hysteria_traffic "$address" "$secret"; then
		echo '|||Could not read the Hysteria 2 Traffic Stats API.'
		return 0
	fi
	jq -er '
		.users | to_entries | map(select(.key | test("^[a-z0-9_-]+$")) |
			[.key, "total", ((.value.upload + .value.download) | tostring)] | join("|")) | join("\n")
	' hysteria/traffic-usage.json >"$map_file" || return 1
	now=$(date +%s) || return 1
	printf 'hysteria-total|%s|%s|\n' "$now" "$now"
}

disconnect_suspended_hysteria_users() {
	local suspended
	suspended=$(get_quota_db_records | awk -F'|' '$9 == "suspended" { print $1 }' | jq -Rn '[inputs]') || return 1
	[[ "$suspended" != '[]' ]] || return 0
	if ! disconnect_hysteria_users "$suspended"; then
		echo "Could not disconnect suspended Hysteria 2 sessions. The next quota check will retry." >&2
		return 1
	fi
}

disconnect_hysteria_users() {
	local users=$1 address secret online container_id
	read -r address secret < <(read_hysteria_traffic_endpoint) || return 1
	online=$(hysteria_traffic_request "$address" "$secret" online) || return 1
	jq -e 'type == "object"' <<<"$online" >/dev/null || return 1
	if ! jq -e --argjson users "$users" '. as $online | any($users[]; ($online[.] // 0) > 0)' \
		<<<"$online" >/dev/null; then
		return 0
	fi

	# Hysteria's /kick marks only the next session that logs traffic. Restart
	# once to retire every existing session after saving the denied accounts.
	container_id=$(scheduled_hysteria_container) || return 1
	$SUDO docker restart "$container_id" >/dev/null && wait_for_hysteria
}

hysteria_lifetime_traffic_rows() {
	local rows
	rows=$(jq -r '.users | to_entries | sort_by(.key)[] | [.key, .value.upload, .value.download] | @tsv' "$1") || return 1
	LC_ALL=C awk -F '\t' '
		NF == 3 { printf "%s\tup=%.2f GB | down=%.2f GB | total=%.2f GB\n",
			$1, $2 / 1073741824, $3 / 1073741824, ($2 + $3) / 1073741824 }
	' <<<"$rows"
}

show_refreshed_quota_status() {
	if ! with_proxy_quota_lock refresh_xray_quota_accounting status; then
		echo "Live usage unavailable. Showing the last saved snapshot."
	fi
	show_xray_quota_status "$@"
}

show_proxy_quota_status() {
	local quota_data_dir=xray
	if [[ -f xray/user_limits.db ]]; then
		echo "Xray quotas"
		show_refreshed_quota_status || true
	fi
	if [[ -f hysteria/config/hysteria.yaml ]]; then
		if [[ -z "$(hysteria_traffic_api_settings)" ]]; then
			echo "Traffic Stats API is not configured for this deployment."
			return 0
		fi
		if [[ -f hysteria/config/user_limits.db ]]; then
			echo "Hysteria 2 quota status and lifetime traffic"
			quota_data_dir=hysteria/config
			show_refreshed_quota_status hysteria/traffic-usage.json
			return
		fi
		echo "Hysteria 2 lifetime traffic by username"
		checkpoint_hysteria_traffic
		if [[ -f hysteria/traffic-usage.json ]]; then
			local traffic_user traffic_summary traffic_totals
			traffic_totals=$(hysteria_lifetime_traffic_rows hysteria/traffic-usage.json) || return 1
			while IFS=$'\t' read -r traffic_user traffic_summary; do
				[[ -n "$traffic_user" ]] || continue
				printf '%s\n  Lifetime traffic | %s\n' "- $traffic_user" "$traffic_summary"
			done <<<"$traffic_totals"
		else
			echo "No Hysteria 2 traffic sample has been saved."
		fi
	elif [[ ! -f xray/user_limits.db ]]; then
		echo "No proxy usage or quota data found."
	fi
}

checkpoint_xray_quota_usage() {
	[[ -f "${quota_data_dir:-xray}/user_limits.db" && -f "${quota_data_dir:-xray}/user_limits.conf" ]] || return 0
	if ! refresh_xray_quota_accounting strict; then
		echo -e "${YELLOW}Continuing without a fresh quota checkpoint.${NC}" >&2
	fi
}

check_and_apply_xray_quotas() {
	if [[ "${XRAY_QUOTA_SCHEDULED:-0}" -eq 1 ]]; then
		if [[ "${quota_data_dir:-xray}" == hysteria/config ]]; then
			if [[ "$EUID" -eq 0 ]]; then trusted_root_hysteria_quota_deployment "$PWD" || return 1; fi
			scheduled_hysteria_container >/dev/null || return 1
		elif [[ "$EUID" -eq 0 ]] && ! trusted_root_quota_deployment "$PWD"; then
			echo 'Root quota checks stopped because deployment ownership or permissions changed.' >&2
			return 1
		fi
		[[ "${quota_data_dir:-xray}" == hysteria/config ]] || scheduled_xray_container >/dev/null || return 1
	fi
	with_proxy_quota_lock _check_and_apply_xray_quotas_internal "$@"
}

_check_and_apply_xray_quotas_internal() {
	if [[ ! -f "${quota_data_dir:-xray}/user_limits.db" || ! -f "${quota_data_dir:-xray}/user_limits.conf" ]]; then
		echo -e "${RED}Quota files not found for the selected proxy.${NC}"
		return 1
	fi

	# Commit accounting before changing access. If the enforcement restart
	# fails, its rollback keeps the bytes measured by the outgoing process.
	refresh_xray_quota_accounting || return 1
	local db_records metadata
	db_records=$(get_quota_db_records) || return 1
	metadata=$(get_quota_accounting_metadata) || return 1
	local -A resume_users=()
	local kind close_email close_uuid close_start close_end close_usage resume_flag new_metadata=""
	local metadata_line
	while IFS= read -r metadata_line; do
		[[ -n "$metadata_line" ]] || continue
		IFS='|' read -r kind close_email close_uuid close_start close_end close_usage resume_flag <<<"$metadata_line"
		if [[ "$kind" == '# quota-closed' && -n "$close_uuid" && "$resume_flag" == 1 ]]; then
			resume_users["$close_uuid"]=1
			metadata_line="${metadata_line%|*}|0"
		fi
		new_metadata+="${new_metadata:+$'\n'}$metadata_line"
	done <<<"$metadata"

	local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status
	local db_lines="" config_changed=0 raw_line old_status
	local -a notices=()
	while IFS= read -r raw_line; do
		[[ -n "$raw_line" ]] || continue
		parse_quota_db_line "$raw_line" || return 1
		old_status=$status
		if ((limit_gb > 0 && cycle_usage >= limit_gb * 1073741824)); then
			status=suspended
		elif [[ -n "${resume_users[$uuid]+set}" ]]; then
			status=active
		fi
		if [[ "$status" != "$old_status" ]]; then
			config_changed=1
			if [[ "$status" == "suspended" ]]; then
				notices+=("User $email reached quota ($limit_gb GB). Suspended.")
			else
				notices+=("Re-enabled user $email for the new cycle.")
			fi
		fi
		db_lines+="${db_lines:+$'\n'}${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
	done <<<"$db_records"

	if [[ "$config_changed" -eq 1 || "$new_metadata" != "$metadata" ]]; then
		finalize_quota_db_update "$db_lines" "$config_changed" "$new_metadata" || return 1
	fi
	if [[ "${quota_data_dir:-xray}" == hysteria/config && "$config_changed" -eq 0 ]]; then
		disconnect_suspended_hysteria_users || return 1
	fi
	if [[ ${#notices[@]} -gt 0 ]]; then
		printf '%s\n' "${notices[@]}"
	fi
	if [[ "${1:-}" != "quiet" && "${1:-}" != "1" ]]; then
		echo -e "${GREEN}Quota check complete.${NC}"
	fi
}

check_and_apply_proxy_quotas() {
	local quota_data_dir=xray status=0 found=0
	if [[ -f xray/user_limits.db ]]; then
		found=1
		check_and_apply_xray_quotas "$@" || status=1
	fi
	if [[ -f hysteria/config/user_limits.db ]]; then
		found=1
		quota_data_dir=hysteria/config
		check_and_apply_xray_quotas "$@" || status=1
	fi
	if [[ "$found" -eq 0 ]]; then
		echo "No Xray or Hysteria 2 quotas are configured." >&2
		return 1
	fi
	return "$status"
}

show_xray_quota_status() {
	local db_file="${quota_data_dir:-xray}/user_limits.db"
	local traffic_file=${1:-} traffic_summary traffic_user traffic_totals=""
	local -A traffic_by_user=() shown_users=()

	if [[ ! -f "$db_file" ]]; then
		echo -e "${RED}Quota database not found.${NC}"
		return 1
	fi

	local timezone
	timezone=$(read_xray_quota_timezone) || return 1

	echo -e "${YELLOW}Timezone:${NC} ${timezone}"
	if [[ -n "$traffic_file" && -f "$traffic_file" ]]; then
		traffic_totals=$(hysteria_lifetime_traffic_rows "$traffic_file") || traffic_totals=""
		while IFS=$'\t' read -r traffic_user traffic_summary; do
			[[ "$traffic_user" =~ ^[a-z0-9_-]+$ ]] || continue
			traffic_by_user["$traffic_user"]=$traffic_summary
		done <<<"$traffic_totals"
	fi

	local -A closed_cycles=()
	local metadata kind closed_email closed_uuid closed_start closed_end closed_usage resume_flag
	metadata=$(get_quota_accounting_metadata) || return 1
	while IFS='|' read -r kind closed_email closed_uuid closed_start closed_end closed_usage resume_flag; do
		if [[ "$kind" == '# quota-closed' && -n "$closed_uuid" ]]; then
			closed_cycles["$closed_uuid"]="$closed_start|$closed_end|$closed_usage"
		fi
	done <<<"$metadata"

	local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status row previous_row
	while IFS= read -r raw_line; do
		[ -z "$raw_line" ] && continue
		parse_quota_db_line "$raw_line" || continue

		local usage_display
		if [[ -n "$traffic_file" ]] && ((cycle_usage > 0 && cycle_usage < 1073741824)); then
			usage_display=$(awk -v b="$cycle_usage" 'BEGIN {
				if (b < 1048576) printf "%d bytes", b
				else printf "%.2f MiB", b / 1048576
			}')
		else
			usage_display=$(awk -v b="$cycle_usage" 'BEGIN { printf "%.2fGB", b/1073741824 }')
		fi
		local cycle_start_h cycle_end_h
		cycle_start_h=$(TZ="$timezone" date -d "@${cycle_start}" "+%Y-%m-%d %H:%M:%S")
		cycle_end_h=$(TZ="$timezone" date -d "@${cycle_end}" "+%Y-%m-%d %H:%M:%S")

		row="- ${email} | status=${status} | usage=${usage_display}"
		if [[ "$limit_gb" -gt 0 ]]; then
			local percent
			percent=$(awk -v b="$cycle_usage" -v limit="$limit_gb" 'BEGIN { printf "%.0f", int(b / 1073741824 / limit * 100) }')
			row+=" / ${limit_gb}GB (${percent}%)"
		else
			row+=" / unlimited"
		fi
		row+=" | cycle=${cycle_start_h} -> ${cycle_end_h}"
		previous_row=""
		if [[ -n "${closed_cycles[$uuid]+set}" ]]; then
			IFS='|' read -r closed_start closed_end closed_usage <<<"${closed_cycles[$uuid]}"
			local closing_gb closing_start_display closing_end_display
			closing_gb=$(awk -v b="$closed_usage" 'BEGIN { printf "%.2f", b/1073741824 }')
			closing_start_display=$(TZ="$timezone" date -d "@$closed_start" '+%Y-%m-%d %H:%M:%S')
			closing_end_display=$(TZ="$timezone" date -d "@$closed_end" '+%Y-%m-%d %H:%M:%S')
			if [[ -n "$traffic_file" ]]; then
				row+=" | previous cycle=${closing_start_display} -> ${closing_end_display} (${closing_gb}GB)"
			else
				printf -v previous_row '  Previous cycle %s -> %s | usage=%sGB' "$closing_start_display" "$closing_end_display" "$closing_gb"
			fi
		fi
		printf '%s\n' "$row"
		if [[ -n "$traffic_file" ]]; then
			shown_users["$email"]=1
			printf '  Lifetime traffic | %s\n' "${traffic_by_user[$email]:-unavailable}"
		fi
		[[ -z "$previous_row" ]] || printf '%s\n' "$previous_row"
	done < <(get_quota_db_records)
	while IFS=$'\t' read -r traffic_user traffic_summary; do
		[[ "$traffic_user" =~ ^[a-z0-9_-]+$ && -z "${shown_users[$traffic_user]:-}" ]] || continue
		printf '%s\n  Lifetime traffic | %s\n' "- $traffic_user | no quota record" "$traffic_summary"
	done <<<"$traffic_totals"
}

select_quota_user() {
	local db_file="${quota_data_dir:-xray}/user_limits.db"
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
	read -p "Select user [0-${#lines[@]}]: " select_idx </dev/tty || return 1
	if [[ "$select_idx" = "0" ]]; then
		return 1
	fi
	local sel_val
	if ! sel_val=$(parse_decimal_range "$select_idx" 1 "${#lines[@]}"); then
		echo -e "${RED}Invalid selection.${NC}" >&2
		return 1
	fi

	local selected="${lines[$((sel_val - 1))]}"
	echo "$selected" | cut -d'|' -f1
}

reset_xray_user_usage() {
	read -p "Do you want to reset usage for ALL users? [y/N]: " reset_all || return 1
	local target_email=""

	if [[ "$reset_all" == "y" || "$reset_all" == "Y" ]]; then
		target_email="ALL"
	else
		target_email=$(select_quota_user) || return 0
	fi

	with_proxy_quota_lock _reset_xray_user_usage "$target_email"
}

prompt_xray_quota_resume() {
	local selected_email=$1 result_var=$2 allowed_limit=$3 prompt=$4
	local record reply decision=0
	if [[ "$selected_email" == "ALL" ]]; then
		decision=1
	else
		record=$(get_quota_db_records | awk -F'|' -v selected="$selected_email" '$1 == selected && !found {print; found=1}') || return 1
		if [[ -n "$record" ]]; then
			local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status
			parse_quota_db_line "$record" || return 1
			if [[ "$status" == "suspended" ]] && ((allowed_limit == 0 || cycle_usage < allowed_limit * 1073741824)); then
				read -p "$prompt" reply || return 1
				[[ "$reply" == [nN] ]] || decision=1
			fi
		fi
	fi
	printf -v "$result_var" '%s' "$decision"
}

_reset_xray_user_usage() {
	local target_email=$1
	[[ -f "${quota_data_dir:-xray}/user_limits.db" ]] || return 1

	local resume_requested
	prompt_xray_quota_resume "$target_email" resume_requested 0 "User is suspended. Re-enable now? [Y/n]: " || return 1
	refresh_xray_quota_accounting strict || return 1

	local db_records
	db_records=$(get_quota_db_records) || return 1

	local db_lines=""
	local config_changed=0
	local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status

	while IFS= read -r raw_line; do
		[ -z "$raw_line" ] && continue
		if ! parse_quota_db_line "$raw_line"; then
			echo -e "${RED}Quota database contains an invalid record. Changes were cancelled.${NC}" >&2
			return 1
		fi

		if [[ "$target_email" = "ALL" ]] || [[ "$email" = "$target_email" ]]; then
			cycle_usage=0
			if [[ "$status" == "suspended" && "$resume_requested" -eq 1 ]]; then
				status=active
				config_changed=1
			fi
		fi

		if [[ -n "$db_lines" ]]; then
			db_lines+=$'\n'
		fi
		db_lines+="${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
	done <<<"$db_records"

	finalize_quota_db_update "$db_lines" "$config_changed" || return 1
	echo -e "${GREEN}Usage reset.${NC}"
}

change_xray_user_limit() {
	local target_email
	target_email=$(select_quota_user) || return 0

	local new_limit_gb
	read -p "Enter new monthly limit in GB (0 = unlimited): " new_limit_gb || return 1
	if ! new_limit_gb=$(parse_decimal_range "$new_limit_gb" 0 "$MAX_USER_LIMIT_GB"); then
		echo -e "${RED}Limit must be an integer between 0 and ${MAX_USER_LIMIT_GB} GB.${NC}"
		return 1
	fi

	with_proxy_quota_lock _change_xray_user_limit "$target_email" "$new_limit_gb"
}

_change_xray_user_limit() {
	local target_email=$1 new_limit_gb=$2
	[[ -f "${quota_data_dir:-xray}/user_limits.db" ]] || return 1
	local resume_requested
	prompt_xray_quota_resume "$target_email" resume_requested "$new_limit_gb" "New limit allows usage. Re-enable now? [Y/n]: " || return 1
	checkpoint_xray_quota_usage

	local db_records
	db_records=$(get_quota_db_records) || return 1

	local db_lines=""
	local config_changed=0
	local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status

	while IFS= read -r raw_line; do
		[ -z "$raw_line" ] && continue
		if ! parse_quota_db_line "$raw_line"; then
			echo -e "${RED}Quota database contains an invalid record. Changes were cancelled.${NC}" >&2
			return 1
		fi

		if [[ "$email" = "$target_email" ]]; then
			limit_gb=$new_limit_gb
			if [[ "$status" == "suspended" && "$resume_requested" -eq 1 ]] &&
				((limit_gb == 0 || cycle_usage < limit_gb * 1073741824)); then
				status=active
				config_changed=1
			fi
		fi

		if [[ -n "$db_lines" ]]; then
			db_lines+=$'\n'
		fi
		db_lines+="${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
	done <<<"$db_records"

	finalize_quota_db_update "$db_lines" "$config_changed" || return 1
	echo -e "${GREEN}Updated monthly limit to ${new_limit_gb} GB.${NC}"
}

change_xray_user_billing_cycle() {
	read -p "Do you want to change the billing cycle for ALL users? [y/N]: " change_all || return 1
	local target_email=""

	if [[ "$change_all" == "y" || "$change_all" == "Y" ]]; then
		target_email="ALL"
	else
		target_email=$(select_quota_user) || return 0
	fi

	echo ""
	if [[ "$target_email" = "ALL" ]]; then
		echo "How would you like to change the billing cycle for ALL users?"
	else
		echo "How would you like to change the billing cycle for ${target_email}?"
	fi
	echo "1) Restart cycle today (resets exactly 1 month from right now)"
	echo "2) Set a specific day of the month (e.g., the 1st or 15th)"
	echo "0) Cancel"
	read -p "Enter choice [0-2]: " cycle_choice || return 1

	local clean_day="" cycle_day reset_usage
	if [[ "$cycle_choice" = "2" ]]; then
		read -p "Enter the day of the month [1-31]: " cycle_day || return 1
		if ! clean_day=$(parse_decimal_range "$cycle_day" 1 31); then
			echo -e "${RED}Invalid day. Must be between 1 and 31.${NC}"
			return 1
		fi
	elif [[ "$cycle_choice" != "1" ]]; then
		return 0
	fi

	read -p "Do you also want to wipe their current traffic usage back to 0 GB? [y/N]: " reset_usage || return 1
	with_proxy_quota_lock _change_xray_user_billing_cycle "$target_email" "$clean_day" "$reset_usage"
}

_change_xray_user_billing_cycle() {
	local target_email=$1 clean_day=$2 reset_usage=$3
	[[ -f "${quota_data_dir:-xray}/user_limits.db" ]] || return 1

	local resume_requested=0
	if [[ "$reset_usage" == [yY] ]]; then
		prompt_xray_quota_resume "$target_email" resume_requested 0 "User is suspended. Re-enable now? [Y/n]: " || return 1
		refresh_xray_quota_accounting strict || return 1
	else
		checkpoint_xray_quota_usage
	fi

	local now_epoch timezone new_anchor_epoch
	now_epoch=$(date +%s) || return 1
	timezone=$(read_xray_quota_timezone) || return 1
	new_anchor_epoch=$now_epoch
	if [[ -n "$clean_day" ]]; then
		new_anchor_epoch=$(quota_wall_time_epoch "2000-01-$(printf "%02d" "$clean_day") 00:00:00" "$timezone") || return 1
	fi

	local db_records
	db_records=$(get_quota_db_records) || return 1

	local db_lines=""
	local config_changed=0

	local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status
	while IFS= read -r raw_line; do
		[ -z "$raw_line" ] && continue
		if ! parse_quota_db_line "$raw_line"; then
			echo -e "${RED}Quota database contains an invalid record. Changes were cancelled.${NC}" >&2
			return 1
		fi

		if [[ "$target_email" = "ALL" ]] || [[ "$email" = "$target_email" ]]; then
			anchor_epoch="$new_anchor_epoch"
			local cycle_bounds
			cycle_bounds=$(calculate_cycle_bounds "$anchor_epoch" "$now_epoch" "$timezone") || return 1
			cycle_start="${cycle_bounds%%|*}"
			cycle_end="${cycle_bounds##*|}"

			if [[ "$reset_usage" == [yY] ]]; then
				cycle_usage=0
				if [[ "$status" == "suspended" && "$resume_requested" -eq 1 ]]; then
					status=active
					config_changed=1
				fi
			fi
		fi

		if [[ -n "$db_lines" ]]; then
			db_lines+=$'\n'
		fi
		db_lines+="${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
	done <<<"$db_records"

	finalize_quota_db_update "$db_lines" "$config_changed" || return 1
	echo -e "${GREEN}Billing cycle updated.${NC}"
}

run_proxy_quota_action() {
	local quota_data_dir action=$1 choice
	if [[ -f xray/user_limits.db && -f hysteria/config/user_limits.db ]]; then
		echo "1) Xray"
		echo "2) Hysteria 2"
		echo "0) Back"
		read -r -p "Choose a proxy [0-2]: " choice || return 1
		case "$choice" in
		1) quota_data_dir=xray ;;
		2) quota_data_dir=hysteria/config ;;
		0) return 0 ;;
		*) echo "Invalid choice." >&2; return 1 ;;
		esac
	elif [[ -f hysteria/config/user_limits.db ]]; then
		quota_data_dir=hysteria/config
	elif [[ -f xray/user_limits.db ]]; then
		quota_data_dir=xray
	else
		echo "No Xray or Hysteria 2 quotas are configured." >&2
		return 1
	fi
	"$action"
}

manage_xray_quotas() {
	local quota_choice
	while true; do
		echo ""
		echo -e "${YELLOW}--- Proxy Usage and Quotas ---${NC}"
		echo "1) Show quota status"
		echo "2) Check/apply quotas now"
		echo "3) Reset one user's current cycle usage"
		echo "4) Change one user's monthly limit"
		echo "5) Change one user's billing cycle dates"
		echo "6) Configure automatic quota checks (systemd daemon / cron)"
		echo "7) Show automatic quota check configuration status"
		echo "8) Change quota billing timezone"
		echo "0) Back"
		read -r -p "Enter your choice [0-8]: " quota_choice || return 0

		case $quota_choice in
		1)
			show_proxy_quota_status || true
			;;
		2)
			check_and_apply_proxy_quotas || true
			;;
		3)
			run_proxy_quota_action reset_xray_user_usage || true
			;;
		4)
			run_proxy_quota_action change_xray_user_limit || true
			;;
		5)
			run_proxy_quota_action change_xray_user_billing_cycle || true
			;;
		6)
			configure_xray_quota_auto_check || true
			;;
		7)
			show_xray_quota_auto_check_status || true
			;;
		8)
			run_proxy_quota_action change_xray_quota_timezone || true
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

XRAY_QUOTA_CRON_MARKER="# proxy-sh:xray-quota-check"
XRAY_QUOTA_RUNNER="/usr/local/lib/proxy-sh/quota-check.sh"
XRAY_QUOTA_CRON_STATE="/etc/proxy-sh/quota-cron.conf"
XRAY_QUOTA_CRON_FILE="/etc/cron.d/xray-quota-check"
PROXY_QUOTA_SERVICE_FILE="/etc/systemd/system/proxy-quota-check.service"
XRAY_QUOTA_SCHEDULER_MARKER="# proxy-sh:managed-quota-scheduler"
XRAY_QUOTA_SCHEDULER_LOCK="/run/proxy-sh-quota-scheduler.lock"
XRAY_QUOTA_JOB_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

systemd_available() {
	command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

root_owned_quota_path() {
	local path=$1 owner mode
	[[ ! -L "$path" ]] || return 1
	read -r owner mode < <(stat -c '%u %a' -- "$path") || return 1
	[[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] && (((8#$mode & 022) == 0))
}

trusted_root_quota_directory() {
	local directory=$1
	[[ "$directory" == /* && "$(realpath -e -- "$directory")" == "$directory" ]] || return 1
	while [[ "$directory" != / ]]; do
		[[ -d "$directory" ]] && root_owned_quota_path "$directory" || return 1
		directory=$(dirname -- "$directory")
	done
	root_owned_quota_path /
}

trusted_root_quota_deployment() {
	local deployment=$1 item
	trusted_root_quota_directory "$deployment" || return 1
	[[ -d "$deployment/xray" ]] && root_owned_quota_path "$deployment/xray" || return 1
	for item in server.jsonc user_limits.db user_limits.conf; do
		[[ -f "$deployment/xray/$item" ]] && root_owned_quota_path "$deployment/xray/$item" || return 1
	done
	for item in .user_limits.lock .user_limits.lock.d; do
		if [[ -e "$deployment/xray/$item" || -L "$deployment/xray/$item" ]]; then
			root_owned_quota_path "$deployment/xray/$item" || return 1
		fi
	done
}

scheduled_xray_container() {
	# Restart only the existing container bound to this deployment's config.
	# This avoids loading a Compose file in an unattended privileged job.
	local inspected container_id source
	inspected=$(timeout 10s docker inspect --type container -f \
		'{{.Id}}{{printf "\n"}}{{range .Mounts}}{{if and (eq .Type "bind") (eq .Destination "/etc/xray/config.json")}}{{println .Source}}{{end}}{{end}}' \
		xray_server) || return 1
	container_id=${inspected%%$'\n'*}
	source=${inspected#*$'\n'}
	if ! [[ "$container_id" =~ ^[0-9a-f]{64}$ && "$source" == "$PWD/xray/server.jsonc" ]]; then
		echo "The Docker container xray_server is not bound to the configuration in $PWD/xray." >&2
		return 1
	fi
	printf '%s\n' "$container_id"
}

trusted_root_hysteria_quota_deployment() {
	local deployment=$1 item directory="$1/hysteria"
	trusted_root_quota_directory "$directory/config" || return 1
	for item in hysteria.yaml quota-auth.sh auth-users user_limits.db user_limits.conf; do
		[[ -f "$directory/config/$item" ]] && root_owned_quota_path "$directory/config/$item" || return 1
	done
	for item in hysteria_links.txt traffic-usage.json; do
		if [[ -e "$directory/$item" || -L "$directory/$item" ]]; then
			[[ -f "$directory/$item" ]] && root_owned_quota_path "$directory/$item" || return 1
		fi
	done
}

scheduled_hysteria_container() {
	local inspected container_id source
	inspected=$(timeout 10s $SUDO docker inspect --type container -f \
		'{{.Id}}{{printf "\n"}}{{range .Mounts}}{{if and (eq .Type "bind") (eq .Destination "/etc/proxy-hysteria")}}{{println .Source}}{{end}}{{end}}' \
		hysteria) || return 1
	container_id=${inspected%%$'\n'*}
	source=${inspected#*$'\n'}
	if ! [[ "$container_id" =~ ^[0-9a-f]{64}$ && "$source" == "$PWD/hysteria/config" ]]; then
		echo "The Hysteria 2 container is not bound to this deployment." >&2
		return 1
	fi
	printf '%s\n' "$container_id"
}

prepare_scheduled_quota_check() {
	SUDO=""
	XRAY_QUOTA_SCHEDULED=1
	cd -P -- "$1" || return 1
	if ! command -v docker >/dev/null || ! command -v jq >/dev/null; then
		echo 'Scheduled quota checks require Docker and jq.' >&2
		return 1
	fi

	# Use the same Docker endpoint for setup verification and unattended runs.
	unset DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG
	if [[ "$EUID" -ne 0 && -S "/run/user/$EUID/docker.sock" ]]; then
		export XDG_RUNTIME_DIR="/run/user/$EUID"
		export DOCKER_HOST="unix:///run/user/$EUID/docker.sock"
	fi
	if [[ -w xray && -r xray/server.jsonc && -r xray/user_limits.db && -r xray/user_limits.conf ]] &&
		{ [[ "$EUID" -ne 0 ]] || trusted_root_quota_deployment "$PWD"; } &&
		scheduled_xray_container >/dev/null 2>&1; then
		return 0
	fi
	if [[ -w hysteria && -w hysteria/config && -r hysteria/config/hysteria.yaml &&
		-r hysteria/config/user_limits.db && -r hysteria/config/user_limits.conf ]] &&
		{ [[ "$EUID" -ne 0 ]] || trusted_root_hysteria_quota_deployment "$PWD"; } &&
		scheduled_hysteria_container >/dev/null 2>&1; then
		return 0
	fi
	echo "The scheduler needs access to a managed Xray or Hysteria 2 deployment and its Docker container." >&2
	return 1
}

read_quota_cron_state() {
	local -a lines=()
	[[ -f "$XRAY_QUOTA_CRON_STATE" ]] &&
		trusted_root_quota_directory "${XRAY_QUOTA_CRON_STATE%/*}" &&
		root_owned_quota_path "$XRAY_QUOTA_CRON_STATE" || return 1
	mapfile -t lines <"$XRAY_QUOTA_CRON_STATE" || return 1
	[[ ${#lines[@]} -eq 3 ]] || return 1
	[[ "${lines[0]}" == system || "${lines[0]}" == personal ]] || return 1
	[[ "${lines[1]}" =~ ^[A-Za-z0-9_.-]+[$]?$ && "${lines[2]}" == /* ]] || return 1
	cron_scope=${lines[0]} cron_account=${lines[1]} cron_deployment=${lines[2]}
}

quota_scheduler_account() {
	local deployment=$1 uid
	if trusted_root_quota_deployment "$deployment" || trusted_root_hysteria_quota_deployment "$deployment"; then
		echo root
		return
	fi
	uid=$(stat -c %u -- "$deployment") || return 1
	if [[ "$uid" == 0 ]]; then
		if [[ -f "$deployment/xray/user_limits.db" ]]; then
			uid=$(stat -c %u -- "$deployment/xray") || return 1
		else
			uid=$(stat -c %u -- "$deployment/hysteria") || return 1
		fi
	fi
	if [[ "$uid" == 0 ]]; then
		echo 'This deployment needs an admin-controlled path for a root job, or a non-root deployment owner with Docker access.' >&2
		return 1
	fi
	id -nu "$uid"
}

render_quota_service() {
	local deployment=$1 account=$2 interval=$3
	# WorkingDirectory expands systemd specifiers. A final /. also preserves
	# literal trailing spaces or backslashes before systemd simplifies the path.
	local directory="${deployment//%/%%}/."
	cat <<EOL
$XRAY_QUOTA_SCHEDULER_MARKER
[Unit]
Description=Proxy per-user quota check daemon
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=$account
Environment=PATH=$XRAY_QUOTA_JOB_PATH
WorkingDirectory=$directory
ExecStartPre=/bin/bash $XRAY_QUOTA_RUNNER --quota-scheduler-probe
ExecStart=/bin/bash $XRAY_QUOTA_RUNNER --quota-scheduled-daemon $interval
Restart=always
RestartSec=5s
TimeoutStopSec=10s

[Install]
WantedBy=multi-user.target
EOL
}

render_quota_cron_job() {
	local schedule=$1 account=${2:-}
	printf '%s %sPATH=%s /bin/bash %s --quota-scheduled-cron >> /dev/null 2>&1 %s\n' \
		"$schedule" "${account:+$account }" "$XRAY_QUOTA_JOB_PATH" "$XRAY_QUOTA_RUNNER" "$XRAY_QUOTA_CRON_MARKER"
}

ensure_quota_scheduler_directory() {
	local directory=$1
	if [[ ! -e "$directory" && ! -L "$directory" ]]; then
		trusted_root_quota_directory "${directory%/*}" || return 1
		$SUDO install -d -o root -g root -m 0755 "$directory" || return 1
	fi
	trusted_root_quota_directory "$directory"
}

install_quota_scheduler_file() {
	local source=$1 destination=$2 mode=$3 temporary
	temporary=$($SUDO mktemp "${destination%/*}/.proxy-sh.XXXXXX") || return 1
	if ! $SUDO install -o root -g root -m "$mode" -- "$source" "$temporary" ||
		! $SUDO mv -fT -- "$temporary" "$destination"; then
		$SUDO rm -f -- "$temporary"
		return 1
	fi
}

snapshot_quota_scheduler_file() {
	local source=$1 backup=$2
	[[ ! -e "$source" && ! -L "$source" ]] || cp -- "$source" "$backup"
}

restore_quota_scheduler_file() {
	local backup=$1 target=$2 mode=$3
	if [[ -f "$backup" ]]; then
		install_quota_scheduler_file "$backup" "$target" "$mode"
	else
		$SUDO rm -f -- "$target"
	fi
}

quota_scheduler_probe_as() {
	local account=$1 deployment=$2
	if [[ "$account" == "$(id -un)" ]]; then
		(cd -- "$deployment" && env PATH="$XRAY_QUOTA_JOB_PATH" /bin/bash "$XRAY_QUOTA_RUNNER" --quota-scheduler-probe)
	else
		$SUDO runuser -u "$account" -- env PATH="$XRAY_QUOTA_JOB_PATH" /bin/bash -c \
			'cd -- "$1" && exec /bin/bash "$2" --quota-scheduler-probe' \
			proxy-sh "$deployment" "$XRAY_QUOTA_RUNNER"
	fi
}

refresh_verified_quota_runner() (
	local verified_script=$1
	if ! grep -Fxq "$XRAY_QUOTA_SCHEDULER_MARKER" "$PROXY_QUOTA_SERVICE_FILE" 2>/dev/null &&
		[[ ! -f "$XRAY_QUOTA_CRON_STATE" ]]; then
		return 0
	fi
	$SUDO mkdir -- "$XRAY_QUOTA_SCHEDULER_LOCK" || return 1
	trap '$SUDO rmdir -- "$XRAY_QUOTA_SCHEDULER_LOCK"' EXIT
	if cmp -s "$verified_script" "$XRAY_QUOTA_RUNNER"; then
		return 0
	fi
	trusted_root_quota_directory "${XRAY_QUOTA_RUNNER%/*}" &&
		install_quota_scheduler_file "$verified_script" "$XRAY_QUOTA_RUNNER" 0755
)

systemd_quota_interval() {
	local unit
	unit=$(cat "$PROXY_QUOTA_SERVICE_FILE" 2>/dev/null) || return 1
	[[ "$unit" =~ --quota-scheduled-daemon[[:space:]]+([0-9]+) ]] || return 1
	parse_decimal_range "${BASH_REMATCH[1]}" 1 9223372036854775807
}

cron_quota_running() {
	if systemd_available && { systemctl is-active --quiet cron.service || systemctl is-active --quiet crond.service; }; then
		return 0
	fi
	pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1
}

ensure_quota_cron_running() {
	cron_quota_running && return 0
	ensure_crontab_available || return 1
	if systemd_available; then
		$SUDO systemctl enable --now cron.service 2>/dev/null ||
			$SUDO systemctl enable --now crond.service 2>/dev/null || return 1
	else
		$SUDO service cron start 2>/dev/null || $SUDO service crond start 2>/dev/null || return 1
	fi
	cron_quota_running
}

read_quota_personal_crontab() {
	local account=$1 output
	shift
	local -a options=(-u "$account")
	if [[ $# -eq 0 && "$account" == "$(id -un)" ]]; then options=(); fi
	if output=$("$@" env LC_ALL=C crontab "${options[@]}" -l 2>&1); then
		printf '%s\n' "$output"
	elif [[ "$output" != *"no crontab for "* ]]; then
		printf '%s\n' "$output" >&2
		return 1
	fi
}

read_visible_quota_crontab() {
	local user=$1
	if [[ "$EUID" -eq 0 || "$user" == "$(id -un)" ]]; then
		read_quota_personal_crontab "$user"
	elif [[ -n "$SUDO" ]]; then
		read_quota_personal_crontab "$user" $SUDO -n
	else
		return 1
	fi
}

write_quota_personal_crontab() {
	$SUDO crontab -u "$1" "$2"
}

strip_quota_cron_jobs() {
	awk -v marker="$XRAY_QUOTA_CRON_MARKER" '
        { line = $0; sub(/[[:space:]]+$/, "", line) }
        substr(line, length(line) - length(marker) + 1) != marker || line !~ /[[:space:]]--quota-scheduled-cron[[:space:]]/
    '
}

valid_quota_cron_schedule() {
	[[ "$1" =~ ^[0-9*/,-]+(\ [0-9*/,-]+){4}$ ]]
}

cron_quota_schedules() {
	awk -v marker="$XRAY_QUOTA_CRON_MARKER" '
        { line = $0; sub(/[[:space:]]+$/, "", line) }
        NF >= 6 && $1 !~ /^#/ && line ~ /[[:space:]]--quota-scheduled-cron[[:space:]]/ &&
            substr(line, length(line) - length(marker) + 1) == marker {
            print $1 " " $2 " " $3 " " $4 " " $5
        }
    '
}

quota_cron_interval() {
	local schedule=$1 minutes
	case "$schedule" in
	"* * * * *") echo 60 ;;
	"0 * * * *") echo 3600 ;;
	*)
		[[ "$schedule" =~ ^\*/([0-9]+)\ \*\ \*\ \*\ \*$ ]] || return 1
		minutes=$(parse_decimal_range "${BASH_REMATCH[1]}" 1 59) || return 1
		((60 % minutes == 0)) || return 1
		echo "$((minutes * 60))"
		;;
	esac
}

quota_interval_cron() {
	local interval=$1
	((interval >= 60 && interval <= 3600 && interval % 60 == 0 && 3600 % interval == 0)) || return 1
	case "$interval" in
	60) echo '* * * * *' ;;
	3600) echo '0 * * * *' ;;
	*) printf '*/%s * * * *\n' "$((interval / 60))" ;;
	esac
}

format_seconds_label() {
	local sec=${1:-60}
	if [[ "$sec" -ge 86400 ]] && [[ $((sec % 86400)) -eq 0 ]]; then
		local days=$((sec / 86400))
		if [[ "$days" -eq 1 ]]; then echo "1 day"; else echo "$days days"; fi
	elif [[ "$sec" -ge 3600 ]] && [[ $((sec % 3600)) -eq 0 ]]; then
		local hrs=$((sec / 3600))
		if [[ "$hrs" -eq 1 ]]; then echo "1 hour"; else echo "$hrs hours"; fi
	elif [[ "$sec" -ge 60 ]] && [[ $((sec % 60)) -eq 0 ]]; then
		local mins=$((sec / 60))
		if [[ "$mins" -eq 1 ]]; then echo "1 minute"; else echo "$mins minutes"; fi
	else
		echo "${sec} seconds"
	fi
}

format_quota_cron_interval() {
	local seconds
	seconds=$(quota_cron_interval "$1") || return 1
	format_seconds_label "$seconds"
}

ensure_crontab_available() {
	if command -v crontab >/dev/null 2>&1; then
		return 0
	fi

	echo -e "${YELLOW}crontab command not found. Automatic quota checks require cron.${NC}"
	read -p "Install cron automatically now? [Y/n]: " install_cron_confirm || return 1
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

quota_daemon_sleep_seconds() {
	local interval=$1 now_epoch=$2
	local -a databases=()
	[[ ! -f xray/user_limits.db ]] || databases+=(xray/user_limits.db)
	[[ ! -f hysteria/config/user_limits.db ]] || databases+=(hysteria/config/user_limits.db)
	if [[ ${#databases[@]} -eq 0 ]]; then
		printf '%s\n' "$interval"
		return
	fi
	awk -F'|' -v now="$now_epoch" -v interval="$interval" '
        !/^[[:space:]]*#/ && NF == 9 && $6 ~ /^[0-9]+$/ && $6 > now {
            if (!next_cutoff || $6 < next_cutoff) next_cutoff = $6
        }
        END {
            if (next_cutoff && next_cutoff - now < interval) printf "%.0f\n", next_cutoff - now
            else print interval
        }
	' "${databases[@]}"
}

run_xray_quota_daemon() {
	local interval="${1:-60}"
	if ! interval=$(parse_decimal_range "$interval" 1 9223372036854775807); then
		interval=60
	fi

	local script_path
	script_path=$(resolve_script_path) || script_path="${BASH_SOURCE[0]:-$0}"
	local initial_script_stamp
	initial_script_stamp=$(stat -c '%d:%i:%y' "$script_path" 2>/dev/null || true)

	local running=1
	trap 'running=0; exit 0' SIGTERM SIGINT

	echo "Proxy quota daemon started (check interval: ${interval}s)."

	while [[ "$running" -eq 1 ]]; do
		# Self-detection: reload if the script file on disk has been updated
		local current_script_stamp
		current_script_stamp=$(stat -c '%d:%i:%y' "$script_path" 2>/dev/null || true)
		if [[ -n "$initial_script_stamp" && -n "$current_script_stamp" && "$current_script_stamp" != "$initial_script_stamp" ]]; then
			echo "Script update detected on disk (${script_path}). Reloading quota daemon..."
			cleanup_script_tmp_dir
			if [[ "${XRAY_QUOTA_SCHEDULED:-0}" -eq 1 ]]; then
				exec /bin/bash "$script_path" --quota-scheduled-daemon "$interval"
			fi
			exec /bin/bash "$script_path" --quota-daemon "$interval" "$PWD"
		fi

		check_and_apply_proxy_quotas quiet || true

		local sleep_seconds=$interval
		sleep_seconds=$(quota_daemon_sleep_seconds "$interval" "$(date +%s)") || sleep_seconds=$interval
		sleep "$sleep_seconds" &
		wait $! 2>/dev/null || true
	done
}

change_xray_quota_timezone() {
	local current_tz
	current_tz=$(read_xray_quota_timezone) || return 1
	echo ""
	echo -e "Current quota billing timezone: ${GREEN}${current_tz}${NC}"

	local new_tz
	prompt_select_timezone new_tz "$current_tz" || return 1

	if [[ -z "$new_tz" || "$new_tz" == "$current_tz" ]]; then
		echo "Timezone unchanged."
		return 0
	fi

	with_proxy_quota_lock _change_xray_quota_timezone "$new_tz"
}

_change_xray_quota_timezone() {
	local new_tz=$1
	local conf_file="${quota_data_dir:-xray}/user_limits.conf"
	checkpoint_xray_quota_usage
	local db_records db_lines="" now_epoch cycle_bounds
	local email uuid limit_gb anchor_epoch cycle_start cycle_end cycle_usage last_total status
	db_records=$(get_quota_db_records) || return 1
	now_epoch=$(date +%s) || return 1
	while IFS= read -r raw_line; do
		[[ -z "$raw_line" ]] && continue
		if ! parse_quota_db_line "$raw_line"; then
			echo -e "${RED}Quota database contains an invalid record. Changes were cancelled.${NC}" >&2
			return 1
		fi
		cycle_bounds=$(calculate_cycle_bounds "$anchor_epoch" "$now_epoch" "$new_tz") || return 1
		cycle_start="${cycle_bounds%%|*}"
		cycle_end="${cycle_bounds##*|}"
		db_lines+="${db_lines:+$'\n'}${email}|${uuid}|${limit_gb}|${anchor_epoch}|${cycle_start}|${cycle_end}|${cycle_usage}|${last_total}|${status}"
	done <<<"$db_records"

	local tmp_conf conf_backup=""
	make_temp_file tmp_conf "$PWD/${quota_data_dir:-xray}/.user_limits.conf.XXXXXX" || return 1
	if [[ -f "$conf_file" ]]; then
		make_temp_file conf_backup || return 1
		cp -p "$conf_file" "$conf_backup" || return 1
	fi
	if ! {
		if [[ -n "$conf_backup" ]]; then
			awk '!/^TIMEZONE=/' "$conf_backup"
		fi && printf 'TIMEZONE=%s\n' "$new_tz"
	} >"$tmp_conf"; then
		rm -f "$tmp_conf"
		return 1
	fi
	apply_preserved_file_metadata "$conf_file" "$tmp_conf"
	if ! mv "$tmp_conf" "$conf_file"; then
		rm -f "$tmp_conf"
		return 1
	fi

	if [[ "$db_lines" != "$db_records" ]] && ! finalize_quota_db_update "$db_lines" 0; then
		if [[ -n "$conf_backup" ]]; then
			cp -p "$conf_backup" "$conf_file" || echo -e "${RED}Failed to restore the previous quota timezone.${NC}" >&2
		else
			rm -f "$conf_file"
		fi
		return 1
	fi

	rm -f "${conf_backup:-}"
	echo -e "${GREEN}Updated quota billing timezone to: ${new_tz}${NC}"
}

quota_systemd_unit_state() {
	local unit=$1 enabled active=0
	enabled=$(systemctl is-enabled "$unit" 2>/dev/null) || true
	if systemctl is-active --quiet "$unit"; then active=1; fi
	printf '%s|%s\n' "${enabled:-unknown}" "$active"
}

remove_quota_systemd_unit() {
	local path=$1 old_state=$2 unit=${1##*/}
	if [[ -f "$path" || "${old_state#*|}" == 1 || "${old_state%%|*}" == enabled* ]]; then
		if systemd_available; then
			$SUDO systemctl disable --now "$unit" || return 1
		fi
		$SUDO rm -f -- "$path" || return 1
	fi
}

restore_quota_systemd_state() {
	local unit=$1 old_state=$2
	case "${old_state%%|*}" in
	enabled) $SUDO systemctl enable "$unit" || return 1 ;;
	enabled-runtime) $SUDO systemctl enable --runtime "$unit" || return 1 ;;
	esac
	if [[ "${old_state#*|}" == 1 ]]; then
		$SUDO systemctl start "$unit"
	fi
}

finish_quota_scheduler_change() {
	# The transaction's EXIT trap shares these local variables.
	local rc=$1 restored=1 user
	if [[ "$committed" -eq 0 && "$backup_ready" -eq 1 ]]; then
		if systemd_available; then
			if [[ "$service_touched" -eq 1 ]]; then
				$SUDO systemctl disable --now proxy-quota-check.service >/dev/null 2>&1 || true
				$SUDO systemctl stop proxy-quota-check.service >/dev/null 2>&1 || true
			fi
		fi
		if [[ "$runner_touched" -eq 1 ]]; then
			restore_quota_scheduler_file "$backup_dir/runner" "$XRAY_QUOTA_RUNNER" 0755 || restored=0
		fi
		if [[ "$cron_state_touched" -eq 1 ]]; then
			restore_quota_scheduler_file "$backup_dir/cron-state" "$XRAY_QUOTA_CRON_STATE" 0644 || restored=0
		fi
		if [[ "$cron_file_touched" -eq 1 ]]; then
			restore_quota_scheduler_file "$backup_dir/cron" "$XRAY_QUOTA_CRON_FILE" 0644 || restored=0
		fi
		for user in "${!personal_touched[@]}"; do
			write_quota_personal_crontab "$user" "$backup_dir/crontab.$user" || restored=0
		done
		if [[ "$service_touched" -eq 1 ]]; then
			restore_quota_scheduler_file "$backup_dir/service" "$PROXY_QUOTA_SERVICE_FILE" 0644 || restored=0
		fi
		if systemd_available && [[ "$service_touched" -eq 1 ]]; then
			$SUDO systemctl daemon-reload || restored=0
			restore_quota_systemd_state proxy-quota-check.service "$old_service" || restored=0
		fi
	fi
	$SUDO rmdir -- "$XRAY_QUOTA_SCHEDULER_LOCK" || restored=0
	if [[ "$restored" -eq 0 ]]; then
		echo -e "${RED}Scheduler rollback was incomplete. Backups are in $backup_dir.${NC}" >&2
		return 1
	fi
	rm -rf -- "$backup_dir"
	return "$rc"
}

apply_quota_scheduler() (
	local method=$1 timing=${2:-} deployment=${3:-}
	local source_script="" account="" new_scope="" user
	case "$method" in
	systemd) timing=$(parse_decimal_range "$timing" 1 9223372036854775807) || return 1 ;;
	cron)
		if ! valid_quota_cron_schedule "$timing"; then
			echo 'This cron interval needs five standard numeric time fields.' >&2
			return 1
		fi
		;;
	disabled) ;;
	*) return 1 ;;
	esac
	if [[ "$method" != disabled ]]; then
		if [[ "$deployment" != /* || "$deployment" == *[$'\r\n']* ]]; then
			echo 'Choose an absolute deployment path on a single line for the scheduler.' >&2
			return 1
		fi
		account=$(quota_scheduler_account "$deployment") || return 1
		[[ "$account" =~ ^[A-Za-z0-9_.-]+[$]?$ ]] || return 1
		source_script=$(resolve_script_path) && bash -n "$source_script" || return 1
		if [[ "$method" == cron ]]; then
			ensure_quota_cron_running || return 1
			if [[ -d "${XRAY_QUOTA_CRON_FILE%/*}" ]]; then
				new_scope=system
			else
				ensure_crontab_available || return 1
				new_scope=personal
			fi
		fi
	fi

	if ! $SUDO mkdir -- "$XRAY_QUOTA_SCHEDULER_LOCK"; then
		echo -e "${RED}Could not lock quota scheduler configuration.${NC}" >&2
		return 1
	fi
	local backup_dir
	backup_dir=$(mktemp -d "${TMPDIR:-/tmp}/proxy-sh-scheduler.XXXXXX") || {
		$SUDO rmdir -- "$XRAY_QUOTA_SCHEDULER_LOCK"
		return 1
	}
	local committed=0 backup_ready=0 runner_touched=0 service_touched=0
	local cron_state_touched=0 cron_file_touched=0
	local old_service='unknown|0'
	local cron_scope="" cron_account="" cron_deployment=""
	local -A personal_backed_up=() personal_touched=()
	trap 'finish_quota_scheduler_change "$?"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	if systemd_available; then
		old_service=$(quota_systemd_unit_state proxy-quota-check.service) || return 1
	fi
	snapshot_quota_scheduler_file "$XRAY_QUOTA_RUNNER" "$backup_dir/runner" &&
		snapshot_quota_scheduler_file "$PROXY_QUOTA_SERVICE_FILE" "$backup_dir/service" &&
		snapshot_quota_scheduler_file "$XRAY_QUOTA_CRON_FILE" "$backup_dir/cron" &&
		snapshot_quota_scheduler_file "$XRAY_QUOTA_CRON_STATE" "$backup_dir/cron-state" || return 1

	if [[ -f "$XRAY_QUOTA_CRON_STATE" ]]; then
		read_quota_cron_state || {
			echo 'Could not read the existing cron quota registration.' >&2
			return 1
		}
	fi
	if [[ "$new_scope" == system && "$cron_scope" != system && -e "$XRAY_QUOTA_CRON_FILE" ]]; then
		echo "The cron file $XRAY_QUOTA_CRON_FILE already exists without a system cron registration." >&2
		return 1
	fi
	local old_cron_scope=$cron_scope
	if command -v crontab >/dev/null; then
		for user in "$(id -un)" "${SUDO_USER:-}" root "$cron_account" "$account"; do
			[[ "$user" =~ ^[A-Za-z0-9_.-]+[$]?$ ]] || continue
			[[ -z "${personal_backed_up[$user]+set}" ]] || continue
			id -u "$user" >/dev/null 2>&1 || continue
			read_quota_personal_crontab "$user" $SUDO >"$backup_dir/crontab.$user" || return 1
			personal_backed_up["$user"]=1
		done
	fi
	backup_ready=1

	if [[ "$method" != disabled ]]; then
		ensure_quota_scheduler_directory "${XRAY_QUOTA_RUNNER%/*}" || return 1
		runner_touched=1
		install_quota_scheduler_file "$source_script" "$XRAY_QUOTA_RUNNER" 0755 || return 1
		if ! quota_scheduler_probe_as "$account" "$deployment"; then
			echo "The scheduler account '$account' could not access this deployment and Docker without sudo." >&2
			return 1
		fi
	fi

	case "$method" in
	systemd)
		render_quota_service "$deployment" "$account" "$timing" >"$backup_dir/new-service" || return 1
		service_touched=1
		install_quota_scheduler_file "$backup_dir/new-service" "$PROXY_QUOTA_SERVICE_FILE" 0644 &&
			$SUDO systemctl daemon-reload &&
			$SUDO systemctl enable proxy-quota-check.service &&
			$SUDO systemctl restart proxy-quota-check.service &&
			systemctl is-enabled --quiet proxy-quota-check.service &&
			systemctl is-active --quiet proxy-quota-check.service || return 1
		;;
	cron)
		ensure_quota_scheduler_directory "${XRAY_QUOTA_CRON_STATE%/*}" || return 1
		printf '%s\n' "$new_scope" "$account" "$deployment" >"$backup_dir/new-cron-state" || return 1
		cron_state_touched=1
		install_quota_scheduler_file "$backup_dir/new-cron-state" "$XRAY_QUOTA_CRON_STATE" 0644 || return 1
		if [[ "$new_scope" == system ]]; then
			render_quota_cron_job "$timing" "$account" >"$backup_dir/new-cron" || return 1
			cron_file_touched=1
			install_quota_scheduler_file "$backup_dir/new-cron" "$XRAY_QUOTA_CRON_FILE" 0644 &&
				cmp -s "$backup_dir/new-cron" "$XRAY_QUOTA_CRON_FILE" || return 1
		else
			[[ -n "${personal_backed_up[$account]+set}" ]] || return 1
			strip_quota_cron_jobs <"$backup_dir/crontab.$account" >"$backup_dir/new-cron" &&
				render_quota_cron_job "$timing" >>"$backup_dir/new-cron" || return 1
			personal_touched["$account"]=1
			write_quota_personal_crontab "$account" "$backup_dir/new-cron" &&
				read_quota_personal_crontab "$account" $SUDO >"$backup_dir/installed-cron" &&
				cmp -s "$backup_dir/new-cron" "$backup_dir/installed-cron" || return 1
		fi
		read_quota_cron_state &&
			[[ "$cron_scope" == "$new_scope" && "$cron_account" == "$account" && "$cron_deployment" == "$deployment" ]] &&
			cron_quota_running || return 1
		;;
	esac

	# Keep previous jobs in place until the replacement passes its checks.
	for user in "${!personal_backed_up[@]}"; do
		if [[ "$new_scope" == personal && "$user" == "$account" ]]; then
			continue
		fi
		strip_quota_cron_jobs <"$backup_dir/crontab.$user" >"$backup_dir/filtered-cron" || return 1
		if ! cmp -s "$backup_dir/crontab.$user" "$backup_dir/filtered-cron"; then
			personal_touched["$user"]=1
			write_quota_personal_crontab "$user" "$backup_dir/filtered-cron" || return 1
		fi
	done
	if [[ "$old_cron_scope" == system && "$new_scope" != system && -f "$XRAY_QUOTA_CRON_FILE" ]]; then
		cron_file_touched=1
		$SUDO rm -f -- "$XRAY_QUOTA_CRON_FILE" || return 1
	fi
	if [[ "$method" != cron && -f "$XRAY_QUOTA_CRON_STATE" ]]; then
		cron_state_touched=1
		$SUDO rm -f -- "$XRAY_QUOTA_CRON_STATE" || return 1
	fi
	if [[ "$method" != systemd && (-f "$PROXY_QUOTA_SERVICE_FILE" || "$old_service" == enabled* || "$old_service" == *'|1') ]]; then
		service_touched=1
		remove_quota_systemd_unit "$PROXY_QUOTA_SERVICE_FILE" "$old_service" || return 1
	fi
	if systemd_available && [[ "$service_touched" -eq 1 ]]; then
		$SUDO systemctl daemon-reload || return 1
	fi
	committed=1
	if [[ "$method" == disabled ]]; then
		echo 'Automatic quota checks disabled.'
	else
		echo "Verified $method quota scheduler for $account in $deployment."
	fi
)

first_quota_cron_schedule() {
	local cron_scope="" cron_account="" cron_deployment="" schedules="" personal
	read_quota_cron_state || return 1
	if [[ "$cron_scope" == system && -f "$XRAY_QUOTA_CRON_FILE" ]]; then
		schedules=$(cron_quota_schedules <"$XRAY_QUOTA_CRON_FILE") || return 1
	elif [[ "$cron_scope" == personal ]] && command -v crontab >/dev/null; then
		personal=$(read_visible_quota_crontab "$cron_account" 2>/dev/null) || return 1
		schedules=$(cron_quota_schedules <<<"$personal") || return 1
	fi
	local schedule="${schedules%%$'\n'*}"
	valid_quota_cron_schedule "$schedule" || return 1
	printf '%s\n' "$schedule"
}

prompt_install_quota_scheduler() {
	[[ "$1" -eq 1 ]] || return 0
	local answer
	while true; do
		read -r -p "Configure automatic quota checks now? [Y/n]: " answer || return 0
		case ${answer:-y} in
		y|Y) configure_xray_quota_auto_check; return ;;
		n|N) return 0 ;;
		*) echo "Choose y or n." ;;
		esac
	done
}

configure_xray_quota_auto_check() {
	local choice method=cron existing="" schedule="" interval deployment
	if systemd_available; then
		echo "1) Systemd daemon"
		echo "2) Cron"
		echo "3) Disable automatic quota checks"
		echo "0) Cancel"
		read -r -p "Choose a quota scheduler [0-3]: " choice || return 1
		case "$choice" in
		1) method=systemd ;;
		2) method=cron ;;
		3)
			apply_quota_scheduler disabled
			return
			;;
		0) return 0 ;;
		*)
			echo 'Invalid scheduler choice.' >&2
			return 1
			;;
		esac
	fi
	if [[ "$method" == systemd ]]; then
		existing=$(systemd_quota_interval) || {
			schedule=$(first_quota_cron_schedule) || schedule=""
			existing=$(quota_cron_interval "$schedule") || existing=""
		}
	else
		existing=$(first_quota_cron_schedule) || {
			interval=$(systemd_quota_interval) || interval=""
			existing=""
			if [[ -n "$interval" ]]; then existing=$(quota_interval_cron "$interval") || true; fi
		}
	fi

	echo "1) Every 1 minute"
	echo "2) Every 2 minutes"
	echo "3) Every 5 minutes"
	echo "4) Disable automatic quota checks"
	if [[ -n "$existing" ]]; then
		local displayed=$existing
		if [[ "$method" == systemd ]]; then displayed=$(format_seconds_label "$existing"); fi
		echo "Press Enter to keep the current interval ($displayed)."
	fi
	read -r -p "Select the quota check interval [1-4]: " choice || return 1
	case "$choice" in
	1) interval=60 ;;
	2) interval=120 ;;
	3) interval=300 ;;
	4)
		apply_quota_scheduler disabled
		return
		;;
	"") interval="" ;;
	*)
		echo 'Invalid interval choice.' >&2
		return 1
		;;
	esac
	if [[ -z "$interval" && -z "$existing" ]]; then
		interval=60
	fi
	if [[ "$method" == cron && -n "$interval" ]]; then
		existing=$(quota_interval_cron "$interval") || return 1
	fi
	if [[ "$method" == systemd && -n "$interval" ]]; then existing=$interval; fi

	deployment=$(pwd -P) || return 1
	if [[ "${deployment##*/}" == xray && -f "$deployment/user_limits.db" ]]; then
		deployment=${deployment%/*}
	fi
	if ! apply_quota_scheduler "$method" "$existing" "$deployment"; then
		echo 'Could not configure the quota scheduler. See the diagnostics above.' >&2
		return 1
	fi
}

show_xray_quota_auto_check_status() {
	local service='unknown|0' schedules="" count=0 interval schedule
	local cron_scope="" cron_account="" cron_deployment="" personal daemon="stopped"
	echo 'Automatic proxy quota check status'
	[[ ! -f xray/user_limits.db ]] || echo '  Xray quotas configured in this deployment'
	[[ ! -f hysteria/config/user_limits.db ]] || echo '  Hysteria 2 quotas configured in this deployment'
	if systemd_available; then
		service=$(quota_systemd_unit_state proxy-quota-check.service) || return 1
	fi
	if [[ -f "$PROXY_QUOTA_SERVICE_FILE" ]]; then
		interval=$(systemd_quota_interval) || interval=""
		if [[ -n "$interval" ]]; then interval=$(format_seconds_label "$interval"); fi
		if [[ "$service" == enabled* || "$service" == *'|1' ]]; then
			count=$((count + 1))
		fi
		printf '  Systemd service %s installed, enablement %s, running %s%s\n' \
			"${PROXY_QUOTA_SERVICE_FILE##*/}" "${service%%|*}" "$([[ "${service#*|}" == 1 ]] && echo yes || echo no)" "${interval:+, every $interval}"
	fi
	if cron_quota_running; then daemon=running; fi
	read_quota_cron_state || true
	if [[ "$cron_scope" == system && -f "$XRAY_QUOTA_CRON_FILE" ]]; then
		schedules=$(cron_quota_schedules <"$XRAY_QUOTA_CRON_FILE") || return 1
		while IFS= read -r schedule; do
			[[ -n "$schedule" ]] || continue
			interval=$(format_quota_cron_interval "$schedule") || interval=""
			printf '  System cron enabled, daemon %s, schedule %s%s\n' \
				"$daemon" "$schedule" "${interval:+ (every $interval)}"
			count=$((count + 1))
		done <<<"$schedules"
	fi
	if [[ "$cron_scope" == personal ]] && command -v crontab >/dev/null &&
		personal=$(read_visible_quota_crontab "$cron_account" 2>/dev/null); then
		schedules=$(cron_quota_schedules <<<"$personal") || return 1
		while IFS= read -r schedule; do
			[[ -n "$schedule" ]] || continue
			interval=$(format_quota_cron_interval "$schedule") || interval=""
			printf '  Personal cron for %s enabled, daemon %s, schedule %s%s\n' \
				"$cron_account" "$daemon" "$schedule" "${interval:+ (every $interval)}"
			count=$((count + 1))
		done <<<"$schedules"
	fi
	if [[ "$count" -eq 0 ]]; then
		echo '  Automatic checks: no enabled systemd or cron job found.'
		echo '  Set a check interval in quota menu option 6.'
	elif [[ "$count" -gt 1 ]]; then
		echo '  Multiple quota jobs are enabled. Use the quota configuration menu to select one.'
	fi
}

# --- User management ---

hysteria_user_files_available() {
	local name
	for name in hysteria.yaml quota-auth.sh auth-users user_limits.db user_limits.conf; do
		if [[ ! -f "hysteria/config/$name" ]]; then
			echo "A managed Hysteria 2 deployment is required to manage users." >&2
			return 1
		fi
	done
}

save_hysteria_user_change() (
	local action=$1 username=$2 limit=${3:-0}
	local auth="hysteria/config/auth-users" db="hysteria/config/user_limits.db"
	local links="hysteria/hysteria_links.txt" endpoint_file="hysteria/link-endpoint"
	local work endpoint="" records metadata path password now timezone bounds link index link_source=/dev/null
	local committed=0
	local -a files applied=()
	hysteria_user_files_available || return 1
	umask 077
	work=$(mktemp -d hysteria/.users.XXXXXX) || return 1
	trap '
		if [[ "$committed" -eq 0 ]]; then
			for ((index = ${#applied[@]} - 1; index >= 0; index--)); do
				path=${applied[index]}
				if [[ -f "$work/old/${path##*/}" ]]; then
					mv -f -- "$work/old/${path##*/}" "$path" || {
						echo "Could not restore $path. Remaining backups are in $work/old." >&2
						exit 1
					}
				else
					rm -f -- "$path" || exit 1
				fi
			done
		fi
		rm -rf -- "$work"
	' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	mkdir "$work/old" || return 1

	# Use an existing saved link if this deployment has no endpoint file yet.
	[[ ! -f "$links" ]] || link_source=$links
	if [[ -f "$endpoint_file" ]]; then
		IFS= read -r endpoint <"$endpoint_file" || return 1
	else
		endpoint=$(awk '/^hysteria2:\/\/[^@]+@/ { sub(/^[^@]+@/, ""); sub(/#.*/, ""); print; exit }' "$link_source") || return 1
		if [[ -n "$endpoint" ]]; then
			printf '%s\n' "$endpoint" >"$work/endpoint" &&
				mv -f -- "$work/endpoint" "$endpoint_file" || return 1
		fi
	fi
	if [[ "$action" == remove ]]; then
		if [[ ! "$username" =~ ^[a-z0-9_-]+$ ]] || ! grep -q "^$username|" "$auth" ||
			! get_quota_db_records | awk -F'|' -v name="$username" '$1 == name { found = 1 } END { exit !found }'; then
			echo "Hysteria 2 user $username is no longer present." >&2
			return 1
		fi
		checkpoint_xray_quota_usage
	fi
	records=$(get_quota_db_records) || return 1
	metadata=$(get_quota_accounting_metadata) || return 1

	if [[ "$action" == add ]]; then
		if [[ ! "$endpoint" =~ ^[^[:space:]@#]+$ ]]; then
			echo "No saved Hysteria 2 connection settings could be found." >&2
			return 1
		fi
		while true; do
			username="u$(openssl rand -hex 8)" || return 1
			if ! grep -q "^$username|" "$auth" "$db"; then break; fi
		done
		password=$(openssl rand -hex 32) || return 1
		now=$(date +%s) || return 1
		timezone=$(read_xray_quota_timezone) || return 1
		bounds=$(calculate_cycle_bounds "$now" "$now" "$timezone") || return 1
		records+="${records:+$'\n'}$username|$username|$limit|$now|${bounds%%|*}|${bounds##*|}|0|0|active"
		link="hysteria2://$username:$password@$endpoint#Hysteria%202-$username"
		{ awk '1' "$auth" && printf '%s|%s|%s\n' "$username" "$password" "$limit"; } >"$work/auth-users" || return 1
		{ awk '1' "$link_source" && printf '%s\n' "$link"; } >"$work/hysteria_links.txt" || return 1
		# Authentication only succeeds when both the quota record and credential exist.
		files=("$db" "$links" "$auth")
	else
		records=$(awk -F'|' -v name="$username" 'NF && $1 != name' <<<"$records") || return 1
		metadata=$(awk -F'|' -v name="$username" '$1 != "# quota-closed" || $3 != name' <<<"$metadata") || return 1
		awk -F'|' -v name="$username" '$1 != name' "$auth" >"$work/auth-users" || return 1
		awk -v prefix="hysteria2://$username:" 'index($0, prefix) != 1' "$link_source" >"$work/hysteria_links.txt" || return 1
		files=("$auth" "$db" "$links")
	fi
	write_quota_db_file "$work/user_limits.db" "$records" "$metadata" "" || return 1
	for path in "${files[@]}"; do
		if [[ -f "$path" ]]; then
			cp -p -- "$path" "$work/old/${path##*/}" || return 1
			apply_preserved_file_metadata "$path" "$work/${path##*/}"
		fi
	done
	for path in "${files[@]}"; do
		applied+=("$path")
		if ! mv -f -- "$work/${path##*/}" "$path"; then
			echo "Could not save the Hysteria 2 user change. Restoring the previous files." >&2
			return 1
		fi
	done
	committed=1

	if [[ "$action" == add ]]; then
		printf 'Added Hysteria 2 user %s\n\n%s\n' "$username" "$link"
	else
		local running users
		echo "Removed Hysteria 2 user $username."
		running=$($SUDO docker ps -q --filter 'name=^/hysteria$') || return 1
		if [[ -n "$running" ]]; then
			users=$(jq -cn --arg username "$username" '[$username]') || return 1
			if ! disconnect_hysteria_users "$users"; then
				echo "Could not verify that existing sessions ended. Restart Hysteria 2 to disconnect them." >&2
				return 1
			fi
		fi
	fi
)

add_hysteria_user() {
	hysteria_user_files_available || return 1
	local limit quota_data_dir=hysteria/config
	while true; do
		read -r -p "Monthly limit in GB [0 = unlimited]: " limit || return 1
		if limit=$(parse_decimal_range "${limit:-0}" 0 "$MAX_USER_LIMIT_GB"); then break; fi
		echo "Enter a whole number from 0 to $MAX_USER_LIMIT_GB."
	done
	with_hysteria_quota_lock save_hysteria_user_change add "" "$limit"
}

remove_hysteria_user() {
	hysteria_user_files_available || return 1
	local username quota_data_dir=hysteria/config
	username=$(select_quota_user) || return 0
	with_hysteria_quota_lock save_hysteria_user_change remove "$username"
}

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
	uuid=$(generate_uuid) || return 1

	read -p "Set monthly data limit for ${user_id}? [Y/n]: " set_limit || return 1
	local user_limit_gb=0
	if [[ -z "$set_limit" || "$set_limit" == "y" || "$set_limit" == "Y" ]]; then
		while true; do
			read -p "Enter monthly limit for ${user_id} in GB [Default: ${DEFAULT_USER_LIMIT_GB}]: " user_limit_gb || return 1
			user_limit_gb=${user_limit_gb:-$DEFAULT_USER_LIMIT_GB}
			if user_limit_gb=$(parse_decimal_range "$user_limit_gb" 1 "$MAX_USER_LIMIT_GB"); then
				break
			fi
			echo -e "${RED}Please enter an integer between 1 and ${MAX_USER_LIMIT_GB} GB.${NC}"
		done
	fi

	local timezone now_epoch
	timezone=$(read_xray_quota_timezone) || return 1
	now_epoch=$(date +%s)
	local cycle_bounds
	cycle_bounds=$(calculate_cycle_bounds "$now_epoch" "$now_epoch" "$timezone") || return 1
	local cycle_start="${cycle_bounds%%|*}"
	local cycle_end="${cycle_bounds##*|}"

	apply_add_user() {
		checkpoint_xray_quota_usage
		local existing_db
		existing_db=$(get_quota_db_records) || return 1
		existing_db+="${existing_db:+$'\n'}${user_id}|${uuid}|${user_limit_gb}|${now_epoch}|${cycle_start}|${cycle_end}|0|0|active"
		apply_xray_quota_client_update "$existing_db"
	}
	if ! with_xray_quota_lock apply_add_user; then
		return 1
	fi

	local server_addr remarks sni_domain xhttp_path private_key public_key
	read -p "Enter server IP/domain for new user's links (leave empty to skip link output): " server_addr || return 1

	if [[ -n "$server_addr" ]]; then
		require_valid_server_address "$server_addr" || return 1
		if ensure_jq; then
			read -p "Enter remarks prefix [Default: xray]: " remarks || return 1
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
					derived=$($SUDO docker run --rm "$XRAY_DOCKER_IMAGE" x25519 -i "$private_key")
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
					link="vless://${uuid}@${server_uri_host}:443?security=reality&sni=${sni_url}&fp=chrome&pbk=${public_key_url}&sid=${shortid}&type=xhttp&path=${xhttp_path_url}#${fragment_url}"
					echo "$link"
					(
						umask 077
						printf '\n%s\n' "$link" >>xray/vless_links.txt
					) || return 1
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
	apply_remove_user() {
		checkpoint_xray_quota_usage
		local records filtered_db filtered_metadata
		records=$(get_quota_db_records) || return 1
		target_uuid=$(awk -F'|' -v email="$target_email" '$1 == email { print $2; exit }' <<<"$records") || return 1
		[[ -n "$target_uuid" ]] || return 1
		filtered_db=$(awk -F'|' -v uuid="$target_uuid" 'NF && $2 != uuid' <<<"$records") || return 1
		filtered_metadata=$(get_quota_accounting_metadata | awk -F'|' -v uuid="$target_uuid" '$1 != "# quota-closed" || $3 != uuid') || return 1
		apply_xray_quota_client_update "$filtered_db" "$filtered_metadata"
	}
	if ! with_xray_quota_lock apply_remove_user; then
		return 1
	fi

	if ! remove_saved_user_links "xray/vless_links.txt" "vless://${target_uuid}@"; then
		echo -e "${YELLOW}Removed the Xray user, but could not update the saved links.${NC}" >&2
		return 1
	fi

	echo -e "${GREEN}Removed Xray user: ${target_email}${NC}"
}

apply_shadowsocks_config() {
	local config=$1 candidate=$2 backup
	make_temp_file backup || return 1
	cp -p "$config" "$backup" || return 1
	apply_preserved_file_metadata "$config" "$candidate"
	mv "$candidate" "$config" || return 1

	if ! reload_shadowsocks_container; then
		if cp -p "$backup" "$config" && reload_shadowsocks_container; then
			echo -e "${YELLOW}Previous Shadowsocks configuration restored.${NC}" >&2
		else
			echo -e "${RED}Could not restore the previous running Shadowsocks configuration.${NC}" >&2
		fi
		rm -f "$backup"
		return 1
	fi

	rm -f "$backup"
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
	user_psk=$(openssl rand -base64 32) || return 1

	local tmp_ss
	make_temp_file tmp_ss "$PWD/shadowsocks/.server.json.XXXXXX" || return 1
	if ! jq -e --arg n "$user_name" --arg p "$user_psk" '.users += [{"name": $n, "password": $p}]' "$ss_config" >"$tmp_ss"; then
		rm -f "$tmp_ss"
		return 1
	fi
	apply_shadowsocks_config "$ss_config" "$tmp_ss" || return 1

	local server_psk method ss_port server_addr remarks password base64 link
	server_psk=$(jq -r '.password' "$ss_config")
	method=$(jq -r '.method' "$ss_config")
	ss_port=$(jq -r '.server_port' "$ss_config")

	read -p "Enter server IP/domain for new user's SS link (leave empty to skip link output): " server_addr || return 1
	if [[ -n "$server_addr" ]]; then
		require_valid_server_address "$server_addr" || return 1
		read -p "Enter remarks prefix [Default: shadowsocks_rust]: " remarks || return 1
		remarks=${remarks:-shadowsocks_rust}
		local server_uri_host fragment_url
		server_uri_host=$(format_uri_host "$server_addr")
		fragment_url=$(url_encode_component "${remarks}-${user_name}")
		password="${server_psk}:${user_psk}"
		base64=$(base64url_encode "${method}:${password}")
		link="ss://${base64}@${server_uri_host}:${ss_port}#${fragment_url}"
		echo -e "\n${GREEN}New SS user link:${NC}"
		echo "$link"
		(
			umask 077
			printf '%s\n' "$link" >>shadowsocks/ss_links.txt
		) || return 1
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

	local entries users=() idx
	entries=$(jq -ce '.users[]?' "$ss_config") || {
		echo -e "${RED}No Shadowsocks users found or the configuration is invalid.${NC}"
		return 1
	}
	mapfile -t users <<<"$entries"
	for idx in "${!users[@]}"; do
		echo "$((idx + 1))) $(jq -r '.name' <<<"${users[$idx]}")"
	done

	read -p "Select user to remove [1-${#users[@]}]: " sel || return 1
	if ! sel=$(parse_decimal_range "$sel" 1 "${#users[@]}"); then
		echo -e "${RED}Invalid selection.${NC}"
		return 1
	fi

	local target_user target_password server_psk method credential tmp_ss
	target_user=$(jq -r '.name' <<<"${users[$((sel - 1))]}") || return 1
	target_password=$(jq -r '.password' <<<"${users[$((sel - 1))]}") || return 1
	server_psk=$(jq -r '.password' "$ss_config") || return 1
	method=$(jq -r '.method' "$ss_config") || return 1
	credential=$(base64url_encode "${method}:${server_psk}:${target_password}") || return 1

	make_temp_file tmp_ss "$PWD/shadowsocks/.server.json.XXXXXX" || return 1
	if ! jq -e --argjson idx "$((sel - 1))" 'del(.users[$idx])' "$ss_config" >"$tmp_ss"; then
		rm -f "$tmp_ss"
		return 1
	fi
	apply_shadowsocks_config "$ss_config" "$tmp_ss" || return 1

	if ! remove_saved_user_links "shadowsocks/ss_links.txt" "ss://${credential}@"; then
		echo -e "${YELLOW}Removed the Shadowsocks user, but could not update the saved links.${NC}" >&2
		return 1
	fi
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
		echo "5) Add Hysteria 2 user"
		echo "6) Remove Hysteria 2 user"
		echo "0) Back"
		read -p "Enter your choice [0-6]: " user_mgmt_choice || return 0

		case $user_mgmt_choice in
		1)
			add_xray_user || true
			;;
		2)
			remove_xray_user || true
			;;
		3)
			add_shadowsocks_user || true
			;;
		4)
			remove_shadowsocks_user || true
			;;
		5)
			add_hysteria_user || true
			;;
		6)
			remove_hysteria_user || true
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

remove_saved_user_links() {
	local path=$1 prefix=$2 filtered
	[[ -f "$path" ]] || return 0

	make_temp_file filtered "$PWD/${path%/*}/.links.XXXXXX" || return 1
	if ! awk -v prefix="$prefix" 'index($0, prefix) != 1' "$path" >"$filtered"; then
		rm -f "$filtered"
		return 1
	fi
	apply_preserved_file_metadata "$path" "$filtered"
	if ! mv "$filtered" "$path"; then
		rm -f "$filtered"
		return 1
	fi
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
	done <"$links_file"
}

show_links() {
	show_saved_links "xray/vless_links.txt" "vless_links.txt" "VLESS"
}

show_ss_links() {
	show_saved_links "shadowsocks/ss_links.txt" "ss_links.txt" "SS"
}

show_hysteria_links() {
	show_saved_links "hysteria/hysteria_links.txt" "" "Hysteria 2"
}

# --- Self-update subsystem ---

fetch_latest_script_version() {
	local cache_bust script_body
	cache_bust="?$(date +%s)"
	script_body=$(curl -fsSL --max-time 10 "https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh${cache_bust}" 2>/dev/null) || return 1
	sed -nE 's/^SCRIPT_VERSION="([0-9]+(\.[0-9]+)+)"$/\1/p' <<<"$script_body"
}

perform_script_update() {
	local cache_bust script_path script_dir tmp_script tmp_sha tmp_sig tmp_public_key
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
	if ! make_temp_file tmp_sig || ! make_temp_file tmp_public_key ||
		! printf '%s\n' "$RELEASE_PUBLIC_KEY" >"$tmp_public_key"; then
		rm -f "$tmp_script" "$tmp_sha"
		return 1
	fi
	echo -e "${YELLOW}Downloading update and verifying signature...${NC}"
	if ! curl -fsSL --max-time 20 "https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh${cache_bust}" >"$tmp_script"; then
		rm -f "$tmp_script" "$tmp_sha" "$tmp_sig"
		echo -e "${RED}Failed to download update; the current script was not changed.${NC}"
		return 1
	fi

	if ! curl -fsSL --max-time 10 "https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh.sha256${cache_bust}" >"$tmp_sha"; then
		rm -f "$tmp_script" "$tmp_sha" "$tmp_sig"
		echo -e "${RED}Failed to download checksum file (proxy.sh.sha256); update aborted for safety.${NC}"
		return 1
	fi

	if ! curl -fsSL --max-time 10 "https://raw.githubusercontent.com/Shawshank01/proxy_sh/main/proxy.sh.sig${cache_bust}" >"$tmp_sig"; then
		rm -f "$tmp_script" "$tmp_sha" "$tmp_sig"
		echo -e "${RED}Failed to download release signature (proxy.sh.sig); update aborted for safety.${NC}"
		return 1
	fi

	if ! openssl dgst -sha256 -verify "$tmp_public_key" -signature "$tmp_sig" "$tmp_script" >/dev/null 2>&1; then
		rm -f "$tmp_script" "$tmp_sha" "$tmp_sig"
		echo -e "${RED}Release signature verification failed; the current script was not changed.${NC}"
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
		rm -f "$tmp_script" "$tmp_sha" "$tmp_sig"
		echo -e "${RED}Cannot verify update integrity: sha256sum/shasum/openssl not found.${NC}"
		return 1
	fi

	if [[ -z "$expected_hash" || "$expected_hash" != "$actual_hash" ]]; then
		rm -f "$tmp_script" "$tmp_sha" "$tmp_sig"
		echo -e "${RED}Checksum verification failed!${NC}"
		echo -e "${RED}Expected: ${expected_hash:-None}${NC}"
		echo -e "${RED}Actual:   ${actual_hash:-None}${NC}"
		return 1
	fi

	if ! bash -n "$tmp_script"; then
		rm -f "$tmp_script" "$tmp_sha" "$tmp_sig"
		echo -e "${RED}Downloaded update failed syntax validation; the current script was not changed.${NC}"
		return 1
	fi

	local verified_runner_source=""
	if [[ -f "$XRAY_QUOTA_CRON_STATE" ]] ||
		grep -Fxq "$XRAY_QUOTA_SCHEDULER_MARKER" "$PROXY_QUOTA_SERVICE_FILE" 2>/dev/null; then
		if ! make_temp_file verified_runner_source ||
			! cp "$tmp_script" "$verified_runner_source" ||
			! openssl dgst -sha256 -verify "$tmp_public_key" -signature "$tmp_sig" "$verified_runner_source" >/dev/null 2>&1; then
			echo 'Could not stage the signed scheduler runner. Reconfigure it through the quota menu to refresh it.' >&2
			verified_runner_source=""
		fi
	fi

	apply_preserved_file_metadata "$script_path" "$tmp_script"
	if ! chmod u+x "$tmp_script" || ! mv -f "$tmp_script" "$script_path"; then
		rm -f "$tmp_script" "$tmp_sha" "$tmp_sig"
		echo -e "${RED}Failed to replace ${script_path}; the current script was not changed.${NC}"
		return 1
	fi
	rm -f "$tmp_sha" "$tmp_sig"

	if [[ -n "$verified_runner_source" ]] && ! refresh_verified_quota_runner "$verified_runner_source"; then
		echo 'The script updated, but the scheduler runner could not be refreshed.' >&2
	fi

	echo -e "${GREEN}Script updated and signature/checksum verified successfully! Restarting...${NC}"
	cleanup_script_tmp_dir
	exec bash "$script_path"
}

auto_check_script_update() {
	local latest_version
	latest_version=$(fetch_latest_script_version) || return 0
	[[ -n "$latest_version" ]] || return 0

	if [[ "$SCRIPT_VERSION" != "$latest_version" ]]; then
		echo -e "${YELLOW}A new version of this script is available: $latest_version (current: $SCRIPT_VERSION).${NC}"
		read -p "Do you want to update now? [Y/n]: " auto_update_confirm || return 1
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
	if ! latest_version=$(fetch_latest_script_version) || [[ -z "$latest_version" ]]; then
		echo -e "${RED}Could not check for updates. Please check your internet connection or the repository URL.${NC}"
		return 1
	fi

	if [[ "$SCRIPT_VERSION" == "$latest_version" ]]; then
		echo -e "${GREEN}You are already using the latest version of the script.${NC}"
		return
	fi

	echo -e "${YELLOW}A new version of the script is available: $latest_version${NC}"
	read -p "Do you want to update? [Y/n]: " update_confirm || return 1
	if [[ "$update_confirm" == "n" || "$update_confirm" == "N" ]]; then
		echo -e "${RED}Update cancelled.${NC}"
		return
	fi

	perform_script_update
}

# --- Entrypoint ---

run_main_menu() {
	local choice install_choice ver_choice update_choice links_choice delete_choice
	while true; do
		echo -e "${YELLOW}--- Proxy Installer v${SCRIPT_VERSION} ---${NC}"
		echo "Please choose an option:"
		echo "0) Update this script"
		echo "1) Environment Check (Check distro and install Docker)"
		echo "2) Install Proxy Server"
		echo "3) Update / Change version of existing container"
		echo "4) Change Xray Reality target domain"
		echo "5) Restore deployment from existing config"
		echo "6) Show proxy links"
		echo "7) Show proxy usage / Manage quotas"
		echo "8) Manage users (Add/Remove for Xray / Shadowsocks / Hysteria 2)"
		echo "9) Delete container and config"
		echo "10) Exit"
		read -r -p "Enter your choice [0-10]: " choice || return 0

		case $choice in
		0)
			update_script || true
			;;
		1)
			check_environment || true
			;;
		2)
			echo ""
			echo "Install Proxy Server"
			echo "1) Xray (VLESS-XHTTP-Reality)"
			echo "2) Hysteria 2"
			echo "3) Shadowsocks (ss-2022)"
			echo "0) Back"
			read -r -p "Enter your choice [0-3]: " install_choice || return 0
			case $install_choice in
			1) ensure_docker_compose && install_xray || true ;;
			2) ensure_docker_compose && install_hysteria || true ;;
			3) ensure_docker_compose && install_shadowsocks || true ;;
			0) ;;
			*) echo -e "${RED}Invalid choice.${NC}" ;;
			esac
			;;
		3)
			if ! ensure_docker_compose; then
				continue
			fi
			echo ""
			echo "Version / Update Management:"
			echo "1) Update existing containers to latest"
			echo "2) Downgrade / Change container version"
			echo "3) Update Hysteria 2 geodata"
			echo "4) Change Hysteria 2 bandwidth limits"
			echo "0) Back"
			read -r -p "Enter your choice [0-4]: " ver_choice || return 0
			case $ver_choice in
			1)
				echo "Which container do you want to update?"
				echo "1) Xray"
				echo "2) Hysteria 2"
				echo "3) Shadowsocks"
				echo "4) Xray and Shadowsocks"
				echo "0) Back"
				read -r -p "Enter your choice [0-4]: " update_choice || return 0
				case $update_choice in
				1)
					update_xray || true
					;;
				2)
					update_hysteria || true
					;;
				3)
					update_shadowsocks || true
					;;
				4)
					update_xray || true
					update_shadowsocks || true
					;;
				0) ;;
				*)
					echo -e "${RED}Invalid choice.${NC}"
					;;
				esac
				;;
			2)
				change_container_version || true
				;;
			3)
				update_hysteria_geodata || true
				;;
			4)
				change_hysteria_bandwidth || true
				;;
			0)
				;;
			*)
				echo -e "${RED}Invalid choice.${NC}"
				;;
			esac
			;;
		4)
			change_xray_reality_target || true
			;;
		5)
			if ! ensure_docker_compose; then
				continue
			fi
			restore_deployment || true
			;;
		6)
			echo ""
			echo "Show proxy links"
			echo "1) Xray (VLESS)"
			echo "2) Hysteria 2"
			echo "3) Shadowsocks"
			echo "0) Back"
			read -r -p "Enter your choice [0-3]: " links_choice || return 0
			case $links_choice in
			1) show_links || true ;;
			2) show_hysteria_links || true ;;
			3) show_ss_links || true ;;
			0) ;;
			*) echo -e "${RED}Invalid choice.${NC}" ;;
			esac
			;;
		7)
			if ! ensure_docker_compose; then
				continue
			fi
			manage_xray_quotas || true
			;;
		8)
			if ! ensure_docker_compose; then
				continue
			fi
			manage_proxy_users || true
			;;
		9)
			if ! ensure_docker_compose; then
				continue
			fi
			echo "Which container do you want to delete?"
			echo "1) Xray"
			echo "2) Hysteria 2"
			echo "3) Shadowsocks"
			read -r -p "Enter your choice [1-3]: " delete_choice || return 1
			case $delete_choice in
			1)
				delete_xray || true
				;;
			2)
				delete_hysteria || true
				;;
			3)
				delete_shadowsocks || true
				;;
			*)
				echo -e "${RED}Invalid choice.${NC}"
				;;
			esac
			;;
		10)
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
	--quota-scheduler-probe)
		prepare_scheduled_quota_check "$PWD"
		return
		;;
	--quota-scheduled-daemon)
		prepare_scheduled_quota_check "$PWD" || return 1
		run_xray_quota_daemon "${2:-60}"
		return
		;;
	--quota-scheduled-cron)
		local cron_scope cron_account cron_deployment
		read_quota_cron_state || return 1
		[[ "$(id -un)" == "$cron_account" ]] || return 1
		prepare_scheduled_quota_check "$cron_deployment" || return 1
		check_and_apply_proxy_quotas quiet
		return
		;;
	esac

	local target_dir=""
	local daemon_interval="60"
	case "${1:-}" in
	--quota-check)
		if [[ -n "${2:-}" && -d "$2" ]]; then
			target_dir="$2"
		elif [[ -d xray || -d hysteria ]]; then
			target_dir="$PWD"
		fi
		;;
	--quota-daemon)
		if [[ -n "${2:-}" && "${2:-}" =~ ^[0-9]+$ ]]; then
			daemon_interval="$2"
			if [[ -n "${3:-}" && -d "$3" ]]; then
				target_dir="$3"
			fi
		elif [[ -n "${2:-}" && -d "$2" ]]; then
			target_dir="$2"
		fi
		if [[ -z "$target_dir" && (-d xray || -d hysteria) ]]; then
			target_dir="$PWD"
		fi
		;;
	esac

	if [[ -n "$target_dir" ]]; then
		cd "$target_dir" || return 1
	else
		local script_dir
		script_dir=$(dirname "$(resolve_script_path)")
		if [[ "$script_dir" != "/usr/local/lib/proxy-sh" ]]; then
			cd "$script_dir" || return 1
		fi
	fi

	case "${1:-}" in
	--quota-check)
		if ! ensure_docker_compose; then
			return 1
		fi
		check_and_apply_proxy_quotas
		return
		;;
	--quota-daemon)
		if ! ensure_docker_compose; then
			return 1
		fi
		run_xray_quota_daemon "$daemon_interval"
		return
		;;
	--quota-check-status)
		show_xray_quota_auto_check_status
		return
		;;
	esac

	check_dependencies
	auto_check_script_update || true
	run_main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
