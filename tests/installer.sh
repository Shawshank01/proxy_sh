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
    {sub(/application=\/opt\/proxy-sh launcher=\/usr\/local\/bin\/proxy\.sh$/, "application=" application " launcher=" launcher); print}
' "$repo/install.sh" >"$fixture/install.sh"

cat >"$fixture/bundle/proxy.sh" <<'EOF'
#!/bin/bash
if [[ -t 0 ]]; then
	read -r choice || exit 1
	set -- "$choice"
fi
printf '%s|%s|%s\n' "$EUID" "$PWD" "$*"
EOF
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
if [[ "$url" == */install.sh ]]; then
	cat "$PROXY_INSTALLER_FIXTURE/install.sh"
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

installer_user=()
if [[ -n "${PROXY_INSTALLER_TEST_USER:-}" ]]; then
	installer_user=(runuser -u "$PROXY_INSTALLER_TEST_USER" --)
fi
installer_command=("${installer_user[@]}" env PATH="$fixture/bin:$PATH" PROXY_INSTALLER_FIXTURE="$fixture")

run_installer() {
	setsid --wait "${installer_command[@]}" bash -s -- "$@" <"$fixture/install.sh"
}

cp "$fixture/bundle/proxy.sh" "$fixture/original"
printf '\n# tampered\n' >>"$fixture/bundle/proxy.sh"
if run_installer --release-commit "$revision"; then fail 'Installed tampered release'; fi
[[ ! -s "$fixture/sudo-calls" && ! -e "$application" && ! -e "$launcher" ]]
cp "$fixture/original" "$fixture/bundle/proxy.sh"

: >"$fixture/requests"
installer_url="https://raw.githubusercontent.com/Shawshank01/proxy_sh/$revision/install.sh"
output=$(printf '12\n' | "${installer_command[@]}" SHELL=/bin/bash timeout 20s script -q -e \
	-c "set -o pipefail; curl -fsSL $installer_url | bash" /dev/null | tr -d '\r')
grep -Fxq "0|$application|12" <<<"$output" || fail 'The piped installer did not open the menu on the terminal'
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
	"$installer_url" \
	'https://api.github.com/repos/Shawshank01/proxy_sh/commits/main' \
	"https://raw.githubusercontent.com/Shawshank01/proxy_sh/$revision/"{proxy.sh,proxy.sh.sha256,proxy.sh.sig})" ]]

# A repeat install keeps a working, already-installed script and its files.
printf '\n# locally installed version\n' >>"$application/proxy.sh"
output=$(run_installer --release-commit "$revision")
grep -Fxq 'Run proxy.sh to manage your deployment.' <<<"$output"
! grep -Fq "0|$application|" <<<"$output" || fail 'The installer opened the menu without a terminal'
grep -Fxq '# locally installed version' "$application/proxy.sh"

touch "$fixture/container-present"
if run_installer --release-commit "$revision"; then fail 'Ignored an existing container'; fi
[[ ! -e "$application/xray" ]]
mkdir -p "$application/xray"
printf 'services: {}\n' >"$application/xray/docker-compose.yml"
run_installer --release-commit "$revision"
grep -Fxq 'services: {}' "$application/xray/docker-compose.yml"
grep -Fxq '# locally installed version' "$application/proxy.sh"
echo 'Installer regression tests passed.'
