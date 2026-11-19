#!/usr/bin/env bash
set -euo pipefail

# Run on GNU/Linux as root in a disposable environment. Optionally set
# PROXY_INSTALLER_TEST_USER to a normal account with unattended test sudo.
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ "$EUID" -eq 0 && "$(uname -s)" == Linux ]]
fixture=$(mktemp -d /opt/proxy-sh-test.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
chmod 0755 "$fixture"
export PROXY_INSTALLER_FIXTURE=$fixture
mkdir -p "$fixture/bin" "$fixture/bundle" "$fixture/launcher-bin"
touch "$fixture/requests" "$fixture/sudo-calls"
chmod 0666 "$fixture/requests" "$fixture/sudo-calls"
application="$fixture/application"
launcher="$fixture/launcher-bin/proxy.sh"
revision=0123456789012345678901234567890123456789

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$fixture/private.pem" 2>/dev/null
chmod 0600 "$fixture/private.pem"
openssl pkey -in "$fixture/private.pem" -pubout >"$fixture/public.pem"
awk -v key="$fixture/public.pem" -v application="$application" -v launcher="$launcher" '
    /^INSTALLER_RELEASE_PUBLIC_KEY=/ {
        printf "INSTALLER_RELEASE_PUBLIC_KEY=%c", 39
        while ((getline line < key) > 0) {
            if (line ~ /^-----END PUBLIC KEY-----/) printf "%s%c\n", line, 39
            else print line
        }
        omit=1; next
    }
    omit && /^-----END PUBLIC KEY-----/ {omit=0; next}
    omit {next}
    {sub(/ \/opt\/proxy-sh \/usr\/local\/bin\/proxy\.sh$/, " " application " " launcher); print}
' "$repo/install.sh" >"$fixture/install.sh"

printf '%s\n' '#!/bin/bash' 'printf "%s|%s|%s\n" "$EUID" "$PWD" "$*"' >"$fixture/bundle/proxy.sh"
(
	cd "$fixture/bundle"
	sha256sum proxy.sh >proxy.sh.sha256
	openssl dgst -sha256 -sign "$fixture/private.pem" -out proxy.sh.sig proxy.sh
)
cat >"$fixture/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
url=${*: -1}
printf '%s\n' "$url" >>"$PROXY_INSTALLER_FIXTURE/requests"
if [[ "$url" == */commits/main ]]; then
	printf '0123456789012345678901234567890123456789\n'
	exit
fi
while [[ "$1" != -o ]]; do shift; done
cp -- "$PROXY_INSTALLER_FIXTURE/bundle/${url##*/}" "$2"
EOF
cat >"$fixture/bin/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
# Only the preflight Docker inspection is expected during installation.
[[ "$1 $2" == 'ps -a' ]]
if [[ -f "$PROXY_INSTALLER_FIXTURE/container-present" ]]; then echo xray_server; fi
EOF
cat >"$fixture/bin/sudo" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'sudo\n' >>"$PROXY_INSTALLER_FIXTURE/sudo-calls"
# Run the isolated fixture via sudo. Preserve the mocks in the root test shell.
[[ "${1:-}" != -- ]] || shift
exec /usr/bin/sudo -- env PATH="$PATH" PROXY_INSTALLER_FIXTURE="$PROXY_INSTALLER_FIXTURE" "$@"
EOF
chmod -R a+rX "$fixture/bin" "$fixture/bundle" "$fixture/install.sh"
chmod +x "$fixture/bin/"*

run_installer() {
	if [[ -n "${PROXY_INSTALLER_TEST_USER:-}" ]]; then
		runuser -u "$PROXY_INSTALLER_TEST_USER" -- env PATH="$fixture/bin:$PATH" \
			PROXY_INSTALLER_FIXTURE="$fixture" bash -s -- "$@" <"$fixture/install.sh"
	else
		PATH="$fixture/bin:$PATH" bash -s -- "$@" <"$fixture/install.sh"
	fi
}

cp "$fixture/bundle/proxy.sh" "$fixture/original"
printf '\n# tampered\n' >>"$fixture/bundle/proxy.sh"
if run_installer --release-commit "$revision"; then fail 'Installed tampered release'; fi
[[ ! -s "$fixture/sudo-calls" && ! -e "$application" && ! -e "$launcher" ]]
cp "$fixture/original" "$fixture/bundle/proxy.sh"

: >"$fixture/requests"
run_installer
[[ -f "$application/proxy.sh" && -x "$launcher" ]]
[[ "$(stat -c '%u:%a' "$application/proxy.sh")" == 0:755 ]]
[[ "$(stat -c '%u:%a' "$launcher")" == 0:755 ]]
if [[ -n "${PROXY_INSTALLER_TEST_USER:-}" ]]; then
	[[ -s "$fixture/sudo-calls" ]] || fail 'The non-root installation skipped sudo'
	test_uid=$(id -u "$PROXY_INSTALLER_TEST_USER")
	[[ "$(runuser -u "$PROXY_INSTALLER_TEST_USER" -- "$launcher" --quota-check-status)" == "$test_uid|$application|--quota-check-status" ]]
	[[ "$(runuser -u "$PROXY_INSTALLER_TEST_USER" -- env PATH="${launcher%/*}:$PATH" proxy.sh)" == "0|$application|" ]]
fi
[[ "$(cat "$fixture/requests")" == "$(printf '%s\n' \
	'https://api.github.com/repos/Shawshank01/proxy_sh/commits/main' \
	"https://raw.githubusercontent.com/Shawshank01/proxy_sh/$revision/"{proxy.sh,proxy.sh.sha256,proxy.sh.sig})" ]]

# A repeat install keeps a working, already-installed script and its files.
printf '\n# locally installed version\n' >>"$application/proxy.sh"
run_installer --release-commit "$revision"
grep -Fxq '# locally installed version' "$application/proxy.sh"

old="$fixture/old deployment"
mkdir -p "$old/xray" "$old/shadowsocks"
printf 'services: {}\n' | tee "$old/xray/docker-compose.yml" "$old/shadowsocks/docker-compose.yml" >/dev/null
printf '{}\n' | tee "$old/xray/server.jsonc" "$old/shadowsocks/server.json" >/dev/null
printf 'quota and profiles\n' >"$old/xray/user_limits.db"
printf 'legacy link\n' >"$old/vless_links.txt"
chmod -R a+rX "$old"
touch "$fixture/container-present"
if run_installer --release-commit "$revision" --migrate-from "$old"; then fail 'Imported live deployment'; fi
[[ ! -e "$application/xray" ]]
rm -f "$fixture/container-present"

run_installer --release-commit "$revision" --migrate-from "$old"
cmp "$old/xray/user_limits.db" "$application/xray/user_limits.db"
cmp "$old/vless_links.txt" "$application/xray/vless_links.txt"
cmp "$old/shadowsocks/server.json" "$application/shadowsocks/server.json"
[[ "$(stat -c '%u:%a' "$application/xray")" == 0:700 ]]
run_installer --release-commit "$revision"
grep -Fxq '# locally installed version' "$application/proxy.sh"
if run_installer --release-commit "$revision" --migrate-from "$old"; then fail 'Overwrote existing deployment'; fi
cmp "$old/xray/user_limits.db" "$application/xray/user_limits.db"
echo 'Installer regression tests passed.'
