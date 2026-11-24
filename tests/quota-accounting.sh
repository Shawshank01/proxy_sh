#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/proxy.sh"
work_dir=$(mktemp -d)
trap 'cleanup_script_tmp_dir; rm -rf -- "$work_dir"' EXIT
SUDO=""
cd "$work_dir"
mkdir xray

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_equal() {
	[[ "$1" == "$2" ]] || fail "Expected '$1', got '$2'"
}

assert_equal "$(date -ud '2024-02-29 12:00' +%s)" "$(add_months_clamped_epoch "$(date -ud '2024-01-31 12:00' +%s)" 1 UTC)"
assert_equal "$(date -ud '2024-03-31 12:00' +%s)" "$(add_months_clamped_epoch "$(date -ud '2024-01-31 12:00' +%s)" 2 UTC)"
assert_equal "$(date -ud '2024-02-29 08:09:08' +%s)" "$(add_months_clamped_epoch "$(date -ud '2024-01-31 08:09:08' +%s)" 1 UTC)"
assert_equal "$(date -ud '2026-03-08 07:30' +%s)" "$(quota_wall_time_epoch '2026-03-08 02:30:00' America/New_York)"
assert_equal "$(date -ud '2026-11-01 05:30' +%s)" "$(quota_wall_time_epoch '2026-11-01 01:30:00' America/New_York)"
assert_equal "$(date -ud '2026-10-03 15:45' +%s)" "$(quota_wall_time_epoch '2026-10-04 02:15:00' Australia/Lord_Howe)"
assert_equal "$(date -ud '2026-10-25 00:30' +%s)" "$(quota_wall_time_epoch '2026-10-25 01:30:00' Europe/Dublin)"
assert_equal 'Etc/GMT-8' "$(normalize_timezone_input 'UTC+08' UTC)"
assert_equal 'Etc/GMT+7' "$(normalize_timezone_input '-07' UTC)"
assert_equal 'UTC' "$(normalize_timezone_input '+0' Europe/Dublin)"
assert_equal 'Europe/Dublin' "$(normalize_timezone_input 'Invalid/Timezone' Europe/Dublin 2>/dev/null)"
assert_equal 'UTC' "$(normalize_timezone_input 'UTC+99' UTC 2>/dev/null)"

jan=$(date -ud '2026-01-01' +%s)
feb=$(date -ud '2026-02-01' +%s)
mar=$(date -ud '2026-03-01' +%s)
fixture_now=$((jan + 600))
fixture_boot_epoch=$jan
fixture_generation="container-a"
fixture_counter=0
fixture_stats_error=""
fixture_container_stopped=0
fixture_reload_status=0

date() {
	if [[ "$#" -eq 1 && "$1" == '+%s' ]]; then
		printf '%s\n' "$fixture_now"
	else
		command date "$@"
	fi
}

collect_xray_user_stats() {
	: >"$1"
	if [[ "$fixture_container_stopped" -eq 1 ]]; then
		printf '|||\n'
	elif [[ -n "$fixture_stats_error" ]]; then
		printf '|||%s\n' "$fixture_stats_error"
	else
		printf 'user|uplink|%s\n' "$fixture_counter" >"$1"
		printf '%s|%s|%s|\n' "$fixture_generation" "$fixture_now" "$fixture_boot_epoch"
	fi
}

reload_xray_container() {
	return "$fixture_reload_status"
}

seed() {
	printf 'TIMEZONE=UTC\n' >xray/user_limits.conf
	jq -n --arg status "$4" '
        {inbounds:[{protocol:"vless", settings:{clients:
            (if $status == "active" then [{id:"uuid",email:"user",flow:""}] else [] end)}}]}
	' >xray/server.jsonc
	save_quota_db_content "user|uuid|$1|$jan|$jan|$feb|$2|$3|$4" "${5:-}"
}

assert_usage() {
	local usage baseline status
	IFS='|' read -r _ _ _ _ _ _ usage baseline status <<<"$(get_quota_db_records)"
	assert_equal "$1|$2|$3" "$usage|$baseline|$status"
}

assert_closed_usage() {
	local usage
	usage=$(awk -F'|' '$1 == "# quota-closed" {print $6}' xray/user_limits.db)
	assert_equal "$1" "$usage"
}

# Upgrade a nine-field database, then grow the new counter past the old one.
seed 0 300 100 active
fixture_counter=160
check_and_apply_xray_quotas quiet
assert_usage 360 160 active
fixture_now=$((fixture_now + 60))
fixture_counter=220
check_and_apply_xray_quotas quiet
assert_usage 420 220 active
fixture_now=$((fixture_now + 60))
fixture_generation="container-a-after-restart"
fixture_boot_epoch=$((fixture_now - 1))
fixture_counter=500
check_and_apply_xray_quotas quiet
assert_usage 920 500 active
check_and_apply_xray_quotas quiet
assert_usage 920 500 active

# During a missed cutoff, retain the outgoing baseline and assign the later
# straddling delta to the closing cycle.
fixture_now=$((feb + 60))
fixture_stats_error="interrupted query"
check_and_apply_xray_quotas quiet 2>/dev/null
assert_usage 0 500 active
assert_closed_usage 920
fixture_stats_error=""
fixture_counter=600
check_and_apply_xray_quotas quiet
assert_usage 0 600 active
assert_closed_usage 1020
fixture_now=$((fixture_now + 60))
fixture_counter=605
check_and_apply_xray_quotas quiet
assert_usage 5 605 active
assert_equal 5 "$(quota_daemon_sleep_seconds 60 "$((mar - 5))")"
assert_equal 60 "$(quota_daemon_sleep_seconds 60 "$((mar - 120))")"

# A process started after the cutoff has counters entirely in the new cycle.
seed 0 900 500 active "# quota-sample|container-a|$((feb - 60))"
fixture_generation=container-b
fixture_boot_epoch=$((feb + 1))
fixture_counter=710
check_and_apply_xray_quotas quiet
assert_usage 710 710 active
assert_closed_usage 900

# A checkpoint can record a new cycle before deployment code restarts Xray.
# Normal enforcement then re-enables the user and clears the pending action.
seed 1 1073741824 0 suspended "# quota-sample|container-a|$((feb - 60))"
fixture_counter=0
with_xray_quota_lock checkpoint_xray_quota_usage
assert_usage 0 0 suspended
check_and_apply_xray_quotas quiet
assert_usage 0 0 active
assert_closed_usage 1073741824
grep -Fxq "# quota-closed|user|uuid|$jan|$feb|1073741824|0" xray/user_limits.db

# A failed enforcement reload restores the old access state and preserves
# the bytes sampled from the outgoing run. Retrying cannot charge twice.
seed 1 0 0 active
fixture_now=$((jan + 600))
fixture_boot_epoch=$jan
fixture_generation=container-a
fixture_counter=1073741824
fixture_reload_status=1
if check_and_apply_xray_quotas quiet >/dev/null 2>&1; then
	fail 'expected a reload failure'
fi
assert_usage 1073741824 1073741824 active
fixture_reload_status=0
check_and_apply_xray_quotas quiet
assert_usage 1073741824 1073741824 suspended

# Resetting usage keeps the sampled counter baseline.
seed 0 20 100 active "# quota-sample|container-a|$fixture_now"
fixture_counter=110
with_xray_quota_lock _reset_xray_user_usage user
assert_usage 0 110 active
fixture_counter=115
check_and_apply_xray_quotas quiet
assert_usage 5 115 active

# Opening quota status samples traffic, but applying a quota is a separate action.
seed 1 0 0 active
fixture_counter=1073741824
show_proxy_quota_status >status
assert_usage 1073741824 1073741824 active
grep -Fq 'status=active | usage=1.00GB / 1GB (100%)' status
cp xray/user_limits.db saved.db
fixture_now=$((feb + 60))
fixture_container_stopped=1
show_proxy_quota_status >status
grep -Fxq 'Live usage unavailable. Showing the last saved snapshot.' status
cmp saved.db xray/user_limits.db
fixture_container_stopped=0
fixture_stats_error='query failed'
show_proxy_quota_status >status
grep -Fxq 'Live usage unavailable. Showing the last saved snapshot.' status
cmp saved.db xray/user_limits.db
fixture_stats_error=""

(
	configure_xray_quota_auto_check() { printf '%s\n' configured >>scheduler-calls; }
	prompt_install_quota_scheduler 0 </dev/null >prompt
	[[ ! -s prompt && ! -e scheduler-calls ]]
	prompt_install_quota_scheduler 1 <<<$'invalid\nn' >prompt
	grep -Fxq 'Choose y or n.' prompt
	[[ ! -e scheduler-calls ]]
	prompt_install_quota_scheduler 1 <<< ''
	grep -Fxq configured scheduler-calls
)

echo 'Quota accounting regression tests passed.'
