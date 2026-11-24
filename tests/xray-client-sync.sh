#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/proxy.sh"
fixture_dir=$(mktemp -d)
trap 'cleanup_script_tmp_dir; rm -rf -- "$fixture_dir"' EXIT
SUDO=""
cd "$fixture_dir"
mkdir xray
db=xray/user_limits.db
config=xray/server.jsonc

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

reload_xray_container() {
	printf 'reload\n' >>"$fixture_dir/reloads"
	if [[ -f "$fixture_dir/fail-once" ]]; then
		rm -f "$fixture_dir/fail-once"
		return 1
	fi
}

managed=01234567-89ab-cdef-0123-456789abcdef
manual=abcdefab-cdef-abcd-efab-cdefabcdefab
managed_row="managed|$managed|1|100|100|200|10|10"
managed_profile='{"id":"0123456789ABCDEF0123456789ABCDEF","email":"managed","flow":"xtls-rprx-vision","level":3,"custom":{"text":"a|b\nc","enabled":true}}'
manual_profile='{"id":"abcdefab-cdef-abcd-efab-cdefabcdefab","email":"managed","level":7,"custom":[1,2]}'
jq -n --argjson managed "$managed_profile" --argjson manual "$manual_profile" '
    {inbounds:[
        {protocol:"vless", tag:"mixed", settings:{clients:[$manual, $managed], decryption:"none"}},
        {protocol:"tunnel", tag:"another-inbound", settings:{address:"127.0.0.1"}}
    ]}
' >"$config"
save_quota_db_content "$managed_row|active" "# quota-sample|run-a|150"
chmod 0640 "$config" "$db"
cp "$config" starting.jsonc

assert_clients() {
	jq -e --argjson expected "$1" '.inbounds[0].settings.clients == $expected' "$config" >/dev/null ||
		fail "Unexpected VLESS clients"
}

assert_profile() {
	local line
	line=$(sed -n 's/^# vless-client //p' "$db")
	[[ -n "$line" ]] || fail "Missing saved client profile"
	jq -e --argjson expected "$managed_profile" '. == $expected' <<<"$line" >/dev/null ||
		fail "Saved profile differs from the original client"
}

# UUID matching tolerates case and optional hyphens. A manual entry can share the
# same email label and still keep its own client configuration.
finalize_quota_db_update "$managed_row|suspended" 1
assert_clients "[$manual_profile]"
assert_profile
jq -e --slurpfile starting starting.jsonc '
    .inbounds[1] == $starting[0].inbounds[1] and
    .inbounds[0].settings.decryption == $starting[0].inbounds[0].settings.decryption
' "$config" >/dev/null
[[ "$(stat -c %a "$db")" == 640 && "$(stat -c %a "$config")" == 640 ]]

# Accounting-only writes must carry client profiles forward.
save_quota_db_content "$managed_row|suspended" "# quota-sample|run-b|160"
assert_profile
grep -Fxq '# quota-sample|run-b|160' "$db"

# A failed re-enable restores both the suspended row and its saved profile.
cp "$db" suspended.db
cp "$config" suspended.jsonc
: >fail-once
if finalize_quota_db_update "$managed_row|active" 1 >/dev/null 2>&1; then
	fail "Expected the forced reload to fail"
fi
cmp "$db" suspended.db
cmp "$config" suspended.jsonc
assert_profile

finalize_quota_db_update "$managed_row|active" 1
assert_clients "[$manual_profile,$managed_profile]"
if grep -q '^# vless-client ' "$db"; then fail 'Retained an active client profile'; fi

# An explicit remove uses the previous ownership database and deletes the
# final managed user without touching the manual client.
select_quota_user() { printf '%s\n' "$selected_user"; }
printf 'vless://%s@host:443#managed\nvless://%s@host:443#manual\n' "$managed" "$manual" >xray/vless_links.txt
selected_user=managed remove_xray_user >/dev/null
assert_clients "[$manual_profile]"
[[ -z "$(get_quota_db_records)" ]]
grep -Fxq "vless://$manual@host:443#manual" xray/vless_links.txt
if grep -q "$managed" xray/vless_links.txt; then fail 'Removed user still has a saved link'; fi

# Removing an already suspended client deletes the archived settings and
# quota row without restarting Xray if the live array is unchanged.
cat suspended.db >"$db"
cat suspended.jsonc >"$config"
cp "$config" before.config
cp reloads before.reloads
selected_user=managed remove_xray_user >/dev/null
cmp "$config" before.config
cmp reloads before.reloads
[[ -z "$(get_quota_db_records)" ]]
if grep -q '^# vless-client ' "$db"; then fail 'Removed user still has an archived profile'; fi

# A freshly added quota ID cannot take ownership of a live manual client.
cp "$db" before.db
if with_xray_quota_lock apply_xray_quota_client_update "new|$manual|1|100|100|200|0|0|active" >/dev/null 2>&1; then
	fail 'Accepted a managed ID colliding with a manual client'
fi
cmp "$db" before.db
cmp "$config" before.config
cmp reloads before.reloads

# Refuse ambiguous duplicate IDs for managed clients and preserve both files.
cat suspended.db >"$db"
jq --argjson managed "$managed_profile" --arg id "$managed" '
    .inbounds[0].settings.clients += [$managed, ($managed | .id = $id)]
' suspended.jsonc >"$config"
cp "$db" before.db
cp "$config" before.config
if finalize_quota_db_update "$managed_row|active" 1 >/dev/null 2>&1; then
	fail 'Accepted duplicate managed clients'
fi
cmp "$db" before.db
cmp "$config" before.config
cmp reloads before.reloads

echo 'Xray client synchronization regression tests passed.'
