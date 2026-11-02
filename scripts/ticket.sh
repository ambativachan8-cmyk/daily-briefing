#!/usr/bin/env bash
# Atomic ticket state change for agents: replaces every status:* and role:* label at once,
# so an issue always has exactly one of each.
#
#   ticket.sh move <issue> <status> <role>     e.g. ticket.sh move 1 testing tester
set -euo pipefail
REPO="ambativachan8-cmyk/daily-briefing"
[ "${1:-}" = "move" ] && [ $# -eq 4 ] || { echo "usage: ticket.sh move <issue> <status> <role>" >&2; exit 2; }
n="$2" status="status:$3" role="role:$4"
gh label list --repo "$REPO" --limit 100 --json name --jq '.[].name' | grep -qx "$status" || { echo "unknown label $status" >&2; exit 2; }
gh label list --repo "$REPO" --limit 100 --json name --jq '.[].name' | grep -qx "$role"   || { echo "unknown label $role" >&2; exit 2; }
args=()
for l in $(gh issue view "$n" --repo "$REPO" --json labels --jq '.labels[].name | select(startswith("status:") or startswith("role:"))'); do
  [ "$l" = "$status" ] || [ "$l" = "$role" ] || args+=(--remove-label "$l")
done
gh issue edit "$n" --repo "$REPO" "${args[@]}" --add-label "$status,$role" >/dev/null
gh issue view "$n" --repo "$REPO" --json labels --jq '"#'"$n"' labels: " + ([.labels[].name] | join(","))'
