#!/usr/bin/env bash
# Publishes one verdict on GitHub: PR comment, required commit status, ticket move. Only the dispatcher
# calls this, as `ubuntu`, using the final message of an agent run it launched itself. Agents have no way to
# reach it, and their token cannot set commit statuses.
#
#   post_verdict.sh review|test <pr> <issue> <full sha> PASS|FAIL <file with the agent's reasoning>
#
# A PASS is refused unless the exact head is still approved and has an intact PASS receipt.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
unset GH_TOKEN
. "$(cd "$(dirname "$0")" && pwd)/gate_lib.sh"

[ $# -eq 6 ] || { echo "usage: post_verdict.sh review|test <pr> <issue> <full sha> PASS|FAIL <file>" >&2; exit 2; }
GATE="$1"; PR="$2"; ISSUE="$3"; SHA="$4"; VERDICT="$5"; FILE="$6"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "REFUSED: not a full SHA" >&2; exit 3; }
case "$VERDICT" in PASS|FAIL) ;; *) echo "REFUSED: verdict must be PASS or FAIL" >&2; exit 3;; esac
case "$GATE" in
  review) CONTEXT=agent/review; WHO=hermes-reviewer; PASS_STAGE=testing; PASS_ROLE=tester; FAIL_STAGE=changes-requested; FAIL_ROLE=manager;;
  test)   CONTEXT=agent/test;   WHO=openclaw-tester; PASS_STAGE=ready-to-merge; PASS_ROLE=manager; FAIL_STAGE=test-failed; FAIL_ROLE=manager;;
  *) echo "REFUSED: unknown gate" >&2; exit 3;;
esac

HEAD="$(authorize_candidate "$PR")" || exit 3
[ "$HEAD" = "$SHA" ] || { echo "REFUSED: verdict is for $SHA but the approved head is $HEAD" >&2; exit 3; }
if [ "$VERDICT" = PASS ] && ! receipt_passes "$SHA"; then
  echo "REFUSED: no intact PASS receipt for $SHA" >&2; exit 3
fi

BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT
{ echo "[control-plane] Verdict of $WHO for $SHA: $VERDICT"
  echo; echo "Published by the control plane from the agent run it launched for this exact head. Comments never change a gate."
  echo; sanitize < "$FILE"; } > "$BODY"
publish_comment "$PR" "$BODY" || exit 3

RECEIPT_ID="$( { sha256sum "$(receipt_file "$SHA")" 2>/dev/null || echo none; } | cut -c1-12)"
if [ "$VERDICT" = PASS ]; then
  publish_status "$SHA" "$CONTEXT" success "$VERDICT at ${SHA:0:7}; receipt $RECEIPT_ID"
  "$GATE_SCRIPTS/ticket.sh" move "$ISSUE" "$PASS_STAGE" "$PASS_ROLE" >/dev/null
else
  publish_status "$SHA" "$CONTEXT" failure "$VERDICT at ${SHA:0:7}; receipt $RECEIPT_ID"
  "$GATE_SCRIPTS/ticket.sh" move "$ISSUE" "$FAIL_STAGE" "$FAIL_ROLE" >/dev/null
fi
echo "published $CONTEXT=$VERDICT for PR #$PR at $SHA; ticket #$ISSUE moved"
