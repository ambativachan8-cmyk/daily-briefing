#!/usr/bin/env bash
# Credential setup on a brand-new home directory, with simulated tokens and a stub `gh` that only records what
# it was asked to do. Run as `ubuntu` on a host prepared by install_gate.sh.
# It proves the order and permissions of the setup, and that no value ever reaches output or a command line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/init_secrets.sh"
W="$(mktemp -d)"; H="$W/home"; mkdir -p "$H/bin"
AGENT_DIR="/home/agent/fresh-setup-sim-$$"
CONTROL_VALUE="SIMCONTROL-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
AGENT_VALUE="SIMAGENT-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
FAILS=0
cleanup() { sudo -n -u agent rm -rf "$AGENT_DIR"; rm -rf "$W"; }
trap cleanup EXIT
pass() { echo "  PROVEN  $*"; }
fail() { echo "  FAILED  $*"; FAILS=$((FAILS + 1)); }

cat > "$H/bin/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$W/gh.log"
case "\$1 \$2" in "auth login") cat > "$W/gh-stdin"; echo "login token-from-env=\${GH_TOKEN:+set}" >> "$W/gh.log";; esac
exit 0
EOF
chmod +x "$H/bin/gh"
run() { env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" AGENT_HOME="$AGENT_DIR" bash "$SCRIPT" "$@" 2>&1; }

echo "== a fresh VM has no ~/.secrets"
out="$(run check)"; rc=$?
[ "$rc" != 0 ] && grep -q 'prepare' <<<"$out" && pass "check stops and names the next step" || fail "check on a fresh home: rc=$rc"
run prepare >/dev/null
[ "$(stat -c %a "$H/.secrets")" = 700 ] && pass "prepare creates ~/.secrets as 0700" || fail "directory mode $(stat -c %a "$H/.secrets")"
out="$(run check)"; rc=$?
[ "$rc" != 0 ] && grep -q 'MISSING .*agents.env' <<<"$out" && pass "check reports the missing file" || fail "missing file rc=$rc"

echo "== permissions a careless copy leaves behind"
printf 'GH_TOKEN=%s\nNVIDIA_API_KEY=SIMMODEL-1234567890\n' "$CONTROL_VALUE" > "$H/.secrets/agents.env"
chmod 644 "$H/.secrets/agents.env"; chmod 755 "$H/.secrets"
out="$(run check)"; rc=$?
[ "$(stat -c %a "$H/.secrets/agents.env")" = 600 ] && [ "$(stat -c %a "$H/.secrets")" = 700 ] && pass "file and directory modes are corrected" || fail "modes not corrected"
[ "$rc" = 2 ] && grep -q 'MISSING value: AGENT_GH_TOKEN' <<<"$out" && pass "a missing agent token is reported by name, with rc 2" || fail "missing agent token rc=$rc"
grep -q "$CONTROL_VALUE" <<<"$out" && fail "a value reached the output" || pass "no value in the output"

echo "== the two tokens must differ"
printf 'AGENT_GH_TOKEN=%s\n' "$CONTROL_VALUE" >> "$H/.secrets/agents.env"
out="$(run check)"; rc=$?
[ "$rc" = 1 ] && grep -q 'must not equal' <<<"$out" && pass "the same token for both is refused" || fail "same token rc=$rc"
sed -i '$d' "$H/.secrets/agents.env"
printf 'AGENT_GH_TOKEN=%s\n' "$AGENT_VALUE" >> "$H/.secrets/agents.env"

echo "== install: control login, git helper, then the agent's own file"
out="$(run install)"; rc=$?
[ "$rc" = 0 ] && pass "install succeeds" || fail "install rc=$rc: $out"
[ "$(cat "$W/gh-stdin" 2>/dev/null)" = "$CONTROL_VALUE" ] && pass "the control token goes to gh on stdin" || fail "control login input"
grep -q 'token-from-env=$' "$W/gh.log" && pass "GH_TOKEN is unset for the login, which gh requires" || fail "GH_TOKEN set during login"
first_setup="$(grep -n 'auth setup-git' "$W/gh.log" | cut -d: -f1)"; first_login="$(grep -n 'auth login' "$W/gh.log" | cut -d: -f1)"
[ -n "$first_setup" ] && [ "$first_login" -lt "$first_setup" ] && pass "login precedes setup-git (the old order left git unauthenticated)" || fail "gh step order"
grep -qE "$CONTROL_VALUE|$AGENT_VALUE" "$W/gh.log" && fail "a token reached a gh command line" || pass "no token on any gh command line"
grep -qE "$CONTROL_VALUE|$AGENT_VALUE" <<<"$out" && fail "a token reached the output" || pass "no token in the output"
mode="$(sudo -n -u agent stat -c %a "$AGENT_DIR/.secrets/agents.env")"; dirmode="$(sudo -n -u agent stat -c %a "$AGENT_DIR/.secrets")"
[ "$mode" = 600 ] && [ "$dirmode" = 700 ] && pass "the agent's file is 0600 in a 0700 directory" || fail "agent file modes $mode $dirmode"
sudo -n -u agent grep -q "GH_TOKEN=$AGENT_VALUE" "$AGENT_DIR/.secrets/agents.env" && pass "the agent receives its own token as GH_TOKEN" || fail "agent token"
sudo -n -u agent grep -q "$CONTROL_VALUE" "$AGENT_DIR/.secrets/agents.env" && fail "the control token reached the agent" || pass "the control token does not reach the agent"
sudo -n -u agent grep -q 'SIMMODEL' "$AGENT_DIR/.secrets/agents.env" && pass "model keys reach the agent" || fail "model keys"

echo "== automation stays off until the owner decides"
TIMER="$HERE/../scripts/install_dispatch_timer.sh"
mkdir -p "$H/.config"
timer() { env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" bash "$TIMER" "$@" 2>&1; }
out="$(timer)"; rc=$?
[ "$rc" = 0 ] && [ -e "$H/.config/dispatch-security-hold" ] && [ ! -e "$H/.config/systemd/user/dispatch.timer" ] && pass "a fresh install sets the hold and writes no timer" || fail "fresh timer install rc=$rc"
out="$(timer --enable)"; rc=$?
[ "$rc" = 3 ] && grep -q 'REFUSED' <<<"$out" && pass "--enable is refused while the hold exists" || fail "enable with hold rc=$rc"
rm -f "$H/.config/dispatch-security-hold"
sed -i '/^AGENT_GH_TOKEN=/d' "$H/.secrets/agents.env"
out="$(timer --enable)"; rc=$?
[ "$rc" = 3 ] && grep -q 'fix the tokens' <<<"$out" && [ ! -e "$H/.config/systemd/user/dispatch.timer" ] && pass "--enable is refused without a separate agent token" || fail "enable without agent token rc=$rc"

echo
echo "fresh setup check: $FAILS failed"
exit "$FAILS"
