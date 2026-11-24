#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/proxy.sh"
fixture=$(mktemp -d)
fixture=$(cd -- "$fixture" && pwd -P)
trap 'cleanup_script_tmp_dir; rm -rf -- "$fixture"' EXIT
SUDO=""
unset SUDO_USER
export QUOTA_TEST_SPOOL="$fixture/spool"
mkdir -p "$fixture/bin" "$fixture/etc/cron.d" "$fixture/etc/systemd" "$fixture/etc/proxy-sh" \
	"$fixture/lib" "$fixture/run" "$fixture/services" "$QUOTA_TEST_SPOOL"

XRAY_QUOTA_RUNNER="$fixture/lib/quota-check.sh"
XRAY_QUOTA_CRON_STATE="$fixture/etc/proxy-sh/quota-cron.conf"
XRAY_QUOTA_CRON_FILE="$fixture/etc/cron.d/xray-quota-check"
XRAY_QUOTA_SERVICE_FILE="$fixture/etc/systemd/xray-quota-check.service"
XRAY_QUOTA_TIMER_FILE="$fixture/etc/systemd/xray-quota-check.timer"
XRAY_QUOTA_SCHEDULER_LOCK="$fixture/run/scheduler.lock"
deployment="$fixture/deploy with spaces 15% complete"
mkdir -p "$deployment/xray"
cd "$deployment"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# The real checks reject a user-controlled ancestor and symlink.
if trusted_root_quota_directory "$fixture"; then fail 'Trusted a temporary directory'; fi
ln -s "$repo/proxy.sh" "$fixture/symlink"
if root_owned_quota_path "$fixture/symlink"; then fail 'Trusted a symlink'; fi

# Redirect privileged operations to fixture files and simulated services.
trusted_root_quota_directory() { [[ -d "$1" ]]; }
root_owned_quota_path() { [[ -e "$1" && ! -L "$1" ]]; }
quota_scheduler_account() { id -un; }
quota_scheduler_probe_as() {
	[[ "$1" == "$(id -un)" && "$2" == "$deployment" ]] || return 1
	[[ -f "$XRAY_QUOTA_RUNNER" ]] || return 1
	printf 'probe\n' >>"$fixture/activity"
}
install_quota_scheduler_file() {
	if [[ "$2" == "$XRAY_QUOTA_CRON_FILE" && -f "$fixture/fail-cron-write" ]]; then
		rm "$fixture/fail-cron-write"
		return 1
	fi
	printf 'install %s\n' "${2##*/}" >>"$fixture/activity"
	cp -- "$1" "$2" && chmod "$3" "$2"
}

systemd_available() { return 0; }
systemctl() {
	local action=$1 unit=${*: -1}
	shift
	case "$action" in
	is-enabled)
		if [[ -f "$fixture/services/$unit.enabled" ]]; then
			[[ "$1" == --quiet ]] || echo enabled
			return 0
		fi
		[[ "$1" == --quiet ]] || echo disabled
		return 1
		;;
	is-active)
		[[ -f "$fixture/services/$unit.active" ]]
		return
		;;
	esac

	printf '%s %s\n' "$action" "$*" >>"$fixture/activity"
	case "$action" in
	enable) touch "$fixture/services/$unit.enabled" ;;
	disable)
		rm -f "$fixture/services/$unit.enabled"
		if [[ "$1" == --now ]]; then rm -f "$fixture/services/$unit.active"; fi
		;;
	restart)
		if [[ -f "$fixture/fail-restart" ]]; then
			rm "$fixture/fail-restart"
			return 1
		fi
		touch "$fixture/services/$unit.active"
		;;
	start) touch "$fixture/services/$unit.active" ;;
	stop) rm -f "$fixture/services/$unit.active" ;;
	daemon-reload) : ;;
	*) fail "Unexpected systemctl action $action" ;;
	esac
}

cat >"$fixture/bin/crontab" <<'EOF'
#!/bin/sh
user=$(id -un)
if [ "$1" = "-u" ]; then user=$2; shift 2; fi
path="$QUOTA_TEST_SPOOL/$user"
if [ "$1" = "-l" ]; then
	if [ -f "$path" ]; then cat "$path"; exit; fi
	printf 'no crontab for %s\n' "$user" >&2
	exit 1
fi
cp -- "$1" "$path"
EOF
chmod +x "$fixture/bin/crontab"
export PATH="$fixture/bin:$PATH"
account=$(id -un)
personal="$QUOTA_TEST_SPOOL/$account"

printf 'legacy runner\n' >"$XRAY_QUOTA_RUNNER"
printf '[Timer]\nOnUnitActiveSec=2min\n' >"$XRAY_QUOTA_TIMER_FILE"
printf '[Service]\nType=oneshot\nExecStart=/bin/bash legacy --quota-check\n' >"$XRAY_QUOTA_SERVICE_FILE"
printf '*/5 * * * * root /bin/bash legacy --quota-check\n' >"$XRAY_QUOTA_CRON_FILE"
printf '15 * * * * housekeeping --quota-check\n*/3 * * * * /bin/bash legacy --quota-check %s\n' \
	"$XRAY_QUOTA_CRON_MARKER" >"$personal"
touch "$fixture/services/xray-quota-check.timer.enabled" "$fixture/services/xray-quota-check.timer.active" \
	"$fixture/services/cron.service.active"
cp "$XRAY_QUOTA_SERVICE_FILE" "$fixture/original-service"
cp "$XRAY_QUOTA_TIMER_FILE" "$fixture/original-timer"
cp "$XRAY_QUOTA_CRON_FILE" "$fixture/original-cron"
cp "$personal" "$fixture/original-personal"
: >"$fixture/activity"

show_xray_quota_auto_check_status >"$fixture/status"
grep -q 'Legacy systemd timer .*every 2 minutes' "$fixture/status"
grep -Fq 'System cron enabled, daemon running, schedule */5 * * * * (every 5 minutes)' "$fixture/status"
grep -q 'Multiple quota jobs are enabled' "$fixture/status"
[[ ! -s "$fixture/activity" ]]
cmp "$XRAY_QUOTA_SERVICE_FILE" "$fixture/original-service"
cmp "$XRAY_QUOTA_TIMER_FILE" "$fixture/original-timer"
cmp "$XRAY_QUOTA_CRON_FILE" "$fixture/original-cron"
cmp "$personal" "$fixture/original-personal"

# Failure while starting the replacement preserves both former jobs.
touch "$fixture/fail-restart"
if configure_xray_quota_auto_check <<<$'1\n' >/dev/null 2>&1; then fail 'Expected systemd failure'; fi
cmp "$XRAY_QUOTA_SERVICE_FILE" "$fixture/original-service"
cmp "$XRAY_QUOTA_TIMER_FILE" "$fixture/original-timer"
cmp "$XRAY_QUOTA_CRON_FILE" "$fixture/original-cron"
cmp "$personal" "$fixture/original-personal"
grep -Fxq 'legacy runner' "$XRAY_QUOTA_RUNNER"
[[ -f "$fixture/services/xray-quota-check.timer.active" ]]
if grep -q 'disable --now xray-quota-check.timer' "$fixture/activity"; then fail 'Disabled the timer too early'; fi

# Explicit migration keeps the two-minute interval and takes down the
# timer and cron only once systemd passes verification.
configure_xray_quota_auto_check <<<$'1\n'
grep -Fxq "WorkingDirectory=${deployment//%/%%}/." "$XRAY_QUOTA_SERVICE_FILE"
grep -Fxq "ExecStart=/bin/bash $XRAY_QUOTA_RUNNER --quota-scheduled-daemon 120" "$XRAY_QUOTA_SERVICE_FILE"
show_xray_quota_auto_check_status >"$fixture/status"
grep -Fq 'Systemd service installed, enablement enabled, running yes, every 2 minutes' "$fixture/status"
[[ -f "$fixture/services/xray-quota-check.service.active" && ! -e "$XRAY_QUOTA_TIMER_FILE" && ! -e "$XRAY_QUOTA_CRON_FILE" ]]
grep -Fxq '15 * * * * housekeeping --quota-check' "$personal"
if grep -Fq "$XRAY_QUOTA_CRON_MARKER" "$personal"; then fail 'Legacy cron entry remains'; fi

cp "$XRAY_QUOTA_SERVICE_FILE" "$fixture/active-service"
touch "$fixture/fail-cron-write"
if configure_xray_quota_auto_check <<<$'2\n' >/dev/null 2>&1; then fail 'Expected cron setup failure'; fi
cmp "$XRAY_QUOTA_SERVICE_FILE" "$fixture/active-service"
[[ -f "$fixture/services/xray-quota-check.service.active" && ! -e "$XRAY_QUOTA_CRON_STATE" ]]

# Cron reads the deployment path from the root-owned registration.
configure_xray_quota_auto_check <<<$'2\n'
read_quota_cron_state
[[ "$cron_scope" == system && "$cron_account" == "$account" && "$cron_deployment" == "$deployment" ]]
(
	mkdir -p hysteria/config
	touch xray/user_limits.db hysteria/config/user_limits.db
	prepare_scheduled_quota_check() { [[ "$1" == "$deployment" ]]; }
	check_and_apply_xray_quotas() { [[ "$1" == quiet ]] && printf '%s\n' "$quota_data_dir"; }
	[[ "$(main --quota-scheduled-cron)" == $'xray\nhysteria/config' ]]
	rm xray/user_limits.db
	[[ "$(main --quota-scheduled-cron)" == hysteria/config ]]
	touch xray/user_limits.db
	rm hysteria/config/user_limits.db
	[[ "$(main --quota-scheduled-cron)" == xray ]]
)
grep -q '^\*/2 \* \* \* \* .*--quota-scheduled-cron' "$XRAY_QUOTA_CRON_FILE"
if grep -Fq "$deployment" "$XRAY_QUOTA_CRON_FILE"; then fail 'Embedded the deployment path in the cron command'; fi
[[ ! -e "$XRAY_QUOTA_SERVICE_FILE" && ! -f "$fixture/services/xray-quota-check.service.active" ]]

# A verified-update runner refresh on a cron-only deployment keeps its job.
printf 'new runner from a verified update\n' >"$fixture/verified"
cp "$XRAY_QUOTA_CRON_FILE" "$fixture/active-cron"
refresh_verified_quota_runner "$fixture/verified"
cmp "$XRAY_QUOTA_RUNNER" "$fixture/verified"
cmp "$XRAY_QUOTA_CRON_FILE" "$fixture/active-cron"

# The personal crontab fallback replaces only entries marked for proxy-sh.
apply_quota_scheduler disabled
rmdir "${XRAY_QUOTA_CRON_FILE%/*}"
apply_quota_scheduler cron '*/5 * * * *' "$deployment"
read_quota_cron_state
[[ "$cron_scope" == personal && "$cron_deployment" == "$deployment" ]]
grep -q '^\*/5 \* \* \* \* PATH=.*--quota-scheduled-cron' "$personal"
grep -Fxq '15 * * * * housekeeping --quota-check' "$personal"
apply_quota_scheduler disabled
[[ ! -e "$XRAY_QUOTA_CRON_STATE" && ! -d "$XRAY_QUOTA_SCHEDULER_LOCK" ]]
grep -Fxq '15 * * * * housekeeping --quota-check' "$personal"
(
	rm -f xray/user_limits.db
	touch hysteria/config/user_limits.db
	show_xray_quota_auto_check_status >"$fixture/status"
	grep -Fq 'Hysteria 2 quotas configured in this deployment' "$fixture/status"
	grep -Fq 'Automatic checks: no enabled systemd or cron job found.' "$fixture/status"
)

echo 'Quota scheduler regression tests passed.'
