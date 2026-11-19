#!/bin/bash
set -euo pipefail

# Copyright (C) 2026 Michifumi
# Licensed under GNU GPL version 2. See LICENSE.

INSTALLER_REPOSITORY=Shawshank01/proxy_sh
INSTALLER_RELEASE_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
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

bootstrap_error() {
	printf 'proxy-sh installer: %s\n' "$*" >&2
	return 1
}

bootstrap_usage() {
	cat <<'EOF'
Usage: bash install.sh [--release-commit SHA] [--migrate-from DIRECTORY]

Installs the signed script in /opt/proxy-sh and the proxy.sh command
in /usr/local/bin. Requires GNU/Linux, curl, OpenSSL, and sudo for
non-root users.

--release-commit SHA   Install from a specific, signed Git commit.
--migrate-from DIR     Import an existing deployment while it is offline.
                       Disable its quota scheduler and use Compose down
                       in each old service directory before importing.
EOF
}

bootstrap_fetch() {
	curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 "$@"
}

bootstrap_verify_bundle() {
	local bundle=$1 checksum expected actual
	printf '%s\n' "$INSTALLER_RELEASE_PUBLIC_KEY" >"$bundle/public.pem" || return 1
	openssl dgst -sha256 -verify "$bundle/public.pem" -signature "$bundle/proxy.sh.sig" \
		"$bundle/proxy.sh" >/dev/null 2>&1 || return 1
	checksum=$(cat -- "$bundle/proxy.sh.sha256") || return 1
	[[ "$checksum" =~ ^([0-9a-f]{64})\ \ proxy\.sh$ ]] || return 1
	expected=${BASH_REMATCH[1]}
	actual=$(sha256sum -- "$bundle/proxy.sh") || return 1
	[[ "${actual%% *}" == "$expected" ]] && bash -n "$bundle/proxy.sh"
}

bootstrap_owned_path() {
	local path=$1 owner mode
	[[ ! -L "$path" ]] || return 1
	read -r owner mode < <(stat -c '%u %a' -- "$path") || return 1
	[[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] && (((8#$mode & 022) == 0))
}

bootstrap_trusted_directory() {
	local path=$1
	[[ "$path" == "$(realpath -e -- "$path")" ]] || return 1
	while :; do
		[[ -d "$path" ]] && bootstrap_owned_path "$path" || return 1
		[[ "$path" != / ]] || return 0
		path=$(dirname -- "$path")
	done
}

bootstrap_ensure_directory() {
	local path=$1
	if [[ ! -e "$path" && ! -L "$path" ]]; then
		bootstrap_trusted_directory "$(dirname -- "$path")" || return 1
		install -d -m 0755 -- "$path" || return 1
	fi
	bootstrap_trusted_directory "$path"
}

bootstrap_install_file() {
	local source=$1 destination=$2 temporary
	temporary=$(mktemp "${destination%/*}/.proxy-sh.XXXXXX") || return 1
	if ! install -m 0755 -- "$source" "$temporary" || ! mv -fT -- "$temporary" "$destination"; then
		rm -f -- "$temporary"
		return 1
	fi
}

bootstrap_has_deployment() {
	[[ -f "$1/xray/docker-compose.yml" || -f "$1/shadowsocks/docker-compose.yml" ]]
}

bootstrap_check_offline() {
	local service=$1 container=$2 migration_source=$3 names table account
	if command -v docker >/dev/null; then
		names=$(timeout 10s env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_CONFIG \
			docker ps -a --filter "name=^/$container$" --format '{{.Names}}') || {
			bootstrap_error "Cannot confirm that $container is offline. Make the system Docker daemon available and retry."
			return 1
		}
		if [[ -n "$names" ]]; then
			bootstrap_error "Run sudo docker compose down in the original $service directory before importing."
			return 1
		fi
	fi
	if [[ "$service" == xray ]]; then
		if [[ -e /etc/systemd/system/xray-quota-check.service || -e /etc/systemd/system/xray-quota-check.timer ||
			-e /etc/cron.d/xray-quota-check || -e /etc/proxy-sh/quota-cron.conf ]]; then
			bootstrap_error 'Disable the previous Xray quota scheduler from the original installation before importing.'
			return 1
		fi
		if command -v crontab >/dev/null; then
			for account in root "${SUDO_USER:-root}" "$(stat -c %U -- "$migration_source")"; do
				if table=$(LC_ALL=C crontab -u "$account" -l 2>&1); then
					if [[ "$table" == *'# proxy-sh:xray-quota-check'* ]]; then
						bootstrap_error "Disable the previous Xray quota job in $account's crontab before importing."
						return 1
					fi
				elif [[ "$table" != *'no crontab for '* ]]; then
					bootstrap_error "Cannot inspect the quota crontab for $account."
					return 1
				fi
			done
		fi
	fi
}

bootstrap_stage_deployment() {
	local migration_source=$1 destination=$2 staging=$3 service container config link unsupported
	for service in xray shadowsocks; do
		[[ -e "$migration_source/$service" || -L "$migration_source/$service" ]] || continue
		if [[ "$service" == xray ]]; then
			container=xray_server config=server.jsonc link=vless_links.txt
		else
			container=ssserver config=server.json link=ss_links.txt
		fi
		if ! [[ -f "$migration_source/$service/docker-compose.yml" && -f "$migration_source/$service/$config" ]]; then
			bootstrap_error "The original $service directory needs its Compose file and $config."
			return 1
		fi
		if [[ -e "$destination/$service" || -L "$destination/$service" ]]; then
			bootstrap_error "$destination/$service already exists. Choose which deployment to keep before importing."
			return 1
		fi
		bootstrap_check_offline "$service" "$container" "$migration_source" || return 1
		unsupported=$(find "$migration_source/$service" ! -type f ! -type d -print -quit) || return 1
		if [[ -n "$unsupported" ]]; then
			bootstrap_error "Review and replace the symlink or special file at $unsupported before importing."
			return 1
		fi
		if [[ -e "$migration_source/$service/.user_limits.lock.d" ]]; then
			bootstrap_error 'An old quota check holds a directory lock. Wait for it to finish before importing.'
			return 1
		fi

		# A private root-owned directory protects credentials while retaining
		# the read modes used by the existing container bind mounts.
		cp -R --preserve=mode -- "$migration_source/$service" "$staging/$service" || return 1
		unsupported=$(find "$staging/$service" ! -type f ! -type d -print -quit) || return 1
		if [[ -n "$unsupported" ]]; then
			bootstrap_error "The source changed during import. Review $migration_source/$service and retry."
			return 1
		fi
		chmod -R go-w -- "$staging/$service" && chmod 0700 -- "$staging/$service" || return 1
		rm -f -- "$staging/$service/.user_limits.lock" || return 1
		if [[ -f "$migration_source/$link" && ! -L "$migration_source/$link" &&
			! -e "$staging/$service/$link" ]]; then
			install -m 0600 -- "$migration_source/$link" "$staging/$service/$link" || return 1
		fi
	done
}

bootstrap_write_launcher() {
	local application=$1
	cat <<EOF
#!/bin/bash
# proxy-sh launcher managed by install.sh
set -euo pipefail
cd -- "$application"
if [[ "\$EUID" -eq 0 || "\${1:-}" == --quota-check-status ]]; then
	exec /bin/bash "$application/proxy.sh" "\$@"
fi
exec /usr/bin/sudo -- /bin/bash "$application/proxy.sh" "\$@"
EOF
}

bootstrap_install_as_root() (
	local downloaded=$1 migration_source=$2 calling_directory=$3 application=$4 launcher=$5
	umask 077
	if [[ "$EUID" -ne 0 ]]; then
		bootstrap_error 'Administrative permissions are required to install the launcher.'
		return 1
	fi

	local private_bundle staged="" locked=0
	private_bundle=$(mktemp -d /tmp/proxy-sh-root.XXXXXX) || return 1
	trap '
		if [[ -n "$staged" ]]; then rm -rf -- "$staged"; fi
		if [[ "$locked" -eq 1 ]]; then rmdir -- "$application/.install.lock"; fi
		rm -rf -- "$private_bundle"
	' EXIT
	cp -- "$downloaded/proxy.sh" "$downloaded/proxy.sh.sha256" "$downloaded/proxy.sh.sig" "$private_bundle/" &&
		bootstrap_verify_bundle "$private_bundle" || {
		bootstrap_error 'The release failed its privileged verification. No files were installed.'
		return 1
	}

	if [[ -z "$migration_source" ]] && ! bootstrap_has_deployment "$application" &&
		[[ "$calling_directory" != "$application" ]] && bootstrap_has_deployment "$calling_directory"; then
		bootstrap_error 'Found an existing deployment here. Use the documented --migrate-from procedure to import it.'
		return 1
	fi
	bootstrap_ensure_directory "$application" && bootstrap_ensure_directory "${launcher%/*}" || {
		bootstrap_error 'Installation paths must be root-owned and protected from group and world writes.'
		return 1
	}

	if ! mkdir -- "$application/.install.lock"; then
		bootstrap_error "Another installer holds $application/.install.lock."
		return 1
	fi
	locked=1

	bootstrap_write_launcher "$application" >"$private_bundle/launcher" || return 1
	if [[ -e "$launcher" || -L "$launcher" ]]; then
		if ! [[ -f "$launcher" ]] || ! bootstrap_owned_path "$launcher" ||
			! cmp -s "$private_bundle/launcher" "$launcher"; then
			bootstrap_error "$launcher is already in use. Review it before installing the proxy.sh command."
			return 1
		fi
	fi
	local installed_script="$application/proxy.sh"
	if [[ -e "$installed_script" || -L "$installed_script" ]]; then
		if ! [[ -f "$installed_script" ]] || ! bootstrap_owned_path "$installed_script"; then
			bootstrap_error "$installed_script must be a regular, trusted root-owned file."
			return 1
		fi
	fi

	local service existing_containers
	if [[ -n "$migration_source" ]]; then
		staged=$(mktemp -d "$application/.import.XXXXXX") || return 1
		bootstrap_stage_deployment "$migration_source" "$application" "$staged" || return 1
	elif command -v docker >/dev/null && ! bootstrap_has_deployment "$application" &&
		existing_containers=$(timeout 10s env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_CONFIG \
			docker ps -a --filter 'name=^/(xray_server|ssserver)$' --format '{{.Names}}' 2>/dev/null) &&
		[[ -n "$existing_containers" ]]; then
		bootstrap_error 'Found an existing proxy container. Use the documented --migrate-from procedure to import its deployment.'
		return 1
	fi

	if [[ ! -f "$installed_script" ]]; then
		bootstrap_install_file "$private_bundle/proxy.sh" "$installed_script" || return 1
	fi
	if [[ ! -f "$launcher" ]]; then
		bootstrap_install_file "$private_bundle/launcher" "$launcher" || return 1
	fi

	if [[ -n "$staged" ]]; then
		for service in xray shadowsocks; do
			[[ -d "$staged/$service" ]] || continue
			mv -nT -- "$staged/$service" "$application/$service" || return 1
			if [[ -d "$staged/$service" ]]; then
				bootstrap_error "$application/$service was created during import. Review both deployments."
				return 1
			fi
		done
		printf 'Imported the deployment. Open proxy.sh and choose 6 to restore it, then configure quota checks if needed.\n'
	else
		printf 'Installed the proxy.sh command. Open it to manage your deployment.\n'
	fi
)

bootstrap_main() (
	local revision="" migration_source="" calling_directory tool
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			bootstrap_usage
			return 0
			;;
		--release-commit)
			[[ $# -ge 2 && "$2" =~ ^[0-9a-fA-F]{40}$ ]] || {
				bootstrap_error 'Provide a full commit SHA.'
				return 1
			}
			revision=${2,,}
			shift 2
			;;
		--migrate-from)
			[[ $# -ge 2 && -d "$2" ]] || {
				bootstrap_error 'Provide the existing deployment directory.'
				return 1
			}
			migration_source=$(cd -P -- "$2" && pwd -P) || return 1
			bootstrap_has_deployment "$migration_source" || {
				bootstrap_error 'No existing Compose deployment found.'
				return 1
			}
			shift 2
			;;
		*)
			bootstrap_usage >&2
			return 1
			;;
		esac
	done

	[[ "$(uname -s)" == Linux ]] || {
		bootstrap_error 'This installer supports GNU/Linux.'
		return 1
	}
	for tool in curl openssl sha256sum timeout; do
		command -v "$tool" >/dev/null || {
			bootstrap_error "Install $tool before running this installer."
			return 1
		}
	done
	local -a admin=()
	if [[ "$EUID" -ne 0 ]]; then
		command -v sudo >/dev/null || {
			bootstrap_error 'sudo is required for a non-root install.'
			return 1
		}
		admin=(sudo --)
	fi

	umask 077
	local downloaded artifact
	downloaded=$(mktemp -d /tmp/proxy-sh-download.XXXXXX) || return 1
	trap 'rm -rf -- "$downloaded"' EXIT
	calling_directory=$(pwd -P) || return 1
	if [[ -z "$revision" ]]; then
		revision=$(bootstrap_fetch -H 'Accept: application/vnd.github.sha' \
			"https://api.github.com/repos/$INSTALLER_REPOSITORY/commits/main") || return 1
	fi
	[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
		bootstrap_error 'Could not resolve a full release commit SHA.'
		return 1
	}

	for artifact in proxy.sh proxy.sh.sha256 proxy.sh.sig; do
		bootstrap_fetch -o "$downloaded/$artifact" \
			"https://raw.githubusercontent.com/$INSTALLER_REPOSITORY/$revision/$artifact" || return 1
	done
	if ! bootstrap_verify_bundle "$downloaded"; then
		bootstrap_error 'Release verification failed. If a release is being published, retry once its signature is available.'
		return 1
	fi

	printf 'Verified proxy.sh at %s.\n' "$revision"
	{
		printf 'set -euo pipefail\nINSTALLER_RELEASE_PUBLIC_KEY=%q\n' "$INSTALLER_RELEASE_PUBLIC_KEY"
		declare -f bootstrap_error bootstrap_verify_bundle bootstrap_owned_path bootstrap_trusted_directory \
			bootstrap_ensure_directory bootstrap_install_file bootstrap_has_deployment bootstrap_check_offline \
			bootstrap_stage_deployment bootstrap_write_launcher bootstrap_install_as_root
		printf '\nbootstrap_install_as_root "$@"\n'
	} | "${admin[@]}" /bin/bash -s -- "$downloaded" "$migration_source" "$calling_directory" /opt/proxy-sh /usr/local/bin/proxy.sh
)

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
	bootstrap_main "$@"
fi
