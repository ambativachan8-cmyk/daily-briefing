#!/usr/bin/env bash
# The tester's verdict in one step: PR comment with the real verify_pr output, then the commit
# status, then the ticket move. The status cannot go green without its evidence.
#
#   verify_pr.sh <pr> > /tmp/verify-<pr>.txt 2>&1
#   post_verdict.sh <pr> <issue> PASS|FAIL "<one line per criterion: your judgement>"
#
# Refuses a PASS if the evidence is for another commit or its checks failed.
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
REPO="ambativachan8-cmyk/daily-briefing"
PR="$1"; ISSUE="$2"; VERDICT="$3"; JUDGEMENT="$4"
FILE="/tmp/verify-$PR.txt"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHA="$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid)"

[ -s "$FILE" ] || { echo "no evidence: run verify_pr.sh $PR > $FILE first" >&2; exit 2; }
grep -q "^verify_pr head: $SHA$" "$FILE" || { echo "evidence in $FILE is not for head $SHA; rerun verify_pr.sh" >&2; exit 2; }
if [ "$VERDICT" = PASS ] && ! grep -qE "^verify_pr result: pytest=0 health=200 page=(ok|n/a) " "$FILE"; then
  echo "refusing PASS: verify_pr did not pass; post FAIL" >&2; exit 2
fi

BODY="$(mktemp)"
{ echo "[openclaw-tester] Test of ${SHA:0:7} — $VERDICT"; echo; echo "$JUDGEMENT"; echo
  echo '```'; cut -c1-1500 "$FILE"; echo '```'; } > "$BODY"
gh pr comment "$PR" --repo "$REPO" --body-file "$BODY" >/dev/null
rm -f "$BODY"

if [ "$VERDICT" = PASS ]; then state=success; next=ready-to-merge; else state=failure; next=test-failed; fi
gh api "repos/$REPO/statuses/$SHA" -f state="$state" -f context=agent/test \
  -f description="$VERDICT at ${SHA:0:7}; output in the PR comment" >/dev/null
"$HERE/ticket.sh" move "$ISSUE" "$next" manager >/dev/null
echo "posted $VERDICT for PR #$PR at ${SHA:0:7}; ticket #$ISSUE -> $next"
