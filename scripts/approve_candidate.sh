#!/usr/bin/env bash
# The owner's approval to execute one exact PR revision. Run it yourself over SSH, as `ubuntu`:
#
#   ssh ubuntu@<vm> '~/agents/_src/scripts/approve_candidate.sh <pr> <full 40-character head SHA>'
#
# Read the diff first. Agents cannot run this: they have no access to the ubuntu account or to $CONTROL.
# A later push changes the head, and the approval no longer applies. Nothing here merges or runs code.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
unset GH_TOKEN
. "$(cd "$(dirname "$0")" && pwd)/gate_lib.sh"

[ $# -eq 2 ] || { echo "usage: approve_candidate.sh <pr> <full head sha>" >&2; exit 2; }
PR="$1"; SHA="$2"
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "PR must be a number" >&2; exit 2; }
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "approval needs the full 40-character SHA" >&2; exit 2; }

gate_dirs
FACTS="$(pr_facts "$PR")"
PROBLEM="$(candidate_problem "$FACTS")"
[ -z "$PROBLEM" ] || { echo "REFUSED: PR #$PR: $PROBLEM" >&2; exit 3; }
HEAD="$(jq -r .headRefOid <<<"$FACTS")"
[ "$HEAD" = "$SHA" ] || { echo "REFUSED: PR #$PR head is $HEAD, not $SHA" >&2; exit 3; }

FILE="$(approval_file "$PR" "$SHA")"
jq -n --arg repo "$REPO" --argjson pr "$PR" --arg base "$BASE_BRANCH" --arg head_sha "$SHA" \
  --arg head_ref "$(jq -r .headRefName <<<"$FACTS")" --arg at "$(date -u +%FT%TZ)" \
  --arg via "${SSH_CONNECTION:-local}" \
  '{repo:$repo, pr:$pr, base:$base, head_sha:$head_sha, head_ref:$head_ref, approved_at:$at, via:$via}' > "$FILE.tmp"
chmod 400 "$FILE.tmp"
mv -f "$FILE.tmp" "$FILE"
echo "approved PR #$PR ($(jq -r .headRefName <<<"$FACTS")) at $SHA against $BASE_BRANCH"
