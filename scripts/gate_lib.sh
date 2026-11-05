# Shared rules of the control plane. Sourced by dispatch.sh, verify_pr.sh, approve_candidate.sh and
# post_verdict.sh, which run as the `ubuntu` user. Agents run as the `agent` user and candidate code as
# the `candidate` user; neither can read or write anything below $CONTROL. See security/README.md.

GATE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="ambativachan8-cmyk/daily-briefing"
OWNER="${REPO%%/*}"
BASE_BRANCH="main"
CONTROL="$HOME/control"
AGENT_HOME="${AGENT_HOME:-/home/agent}"

gate_dirs() {
  umask 077
  mkdir -p "$CONTROL/approvals" "$CONTROL/receipts" "$CONTROL/transcripts" "$CONTROL/notified" "$CONTROL/returns"
  chmod 700 "$CONTROL"
}

# Run a command as the unprivileged agent user. Its output returns to the control plane, which keeps it.
as_agent() {
  if [ -n "${AGENT_EXEC:-}" ]; then
    # shellcheck disable=SC2086
    $AGENT_EXEC "$@"
  else
    sudo -n -u agent -H env -i HOME="$AGENT_HOME" USER=agent LOGNAME=agent LANG=C.UTF-8 \
      XDG_RUNTIME_DIR="/run/user/$(id -u agent)" \
      PATH="$AGENT_HOME/.local/bin:$AGENT_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" "$@"
  fi
}

refuse() { echo "REFUSED: $*" >&2; return 3; }

# ---- which tickets exist at all -------------------------------------------------------------------
# A managed ticket is authored by the owner's account, carries a type:* label, at most one role:* and one
# status:* label, and is not parked. Everything else is invisible to routing, so an outsider's issue, a
# parked ticket or a stray note can never start an agent. Prints "<number> <label,label,...>", oldest first.
managed_tickets() {
  gh issue list --repo "$REPO" --state open --limit 100 --json number,title,labels,author \
    --jq "[.[]
        | ([.labels[].name]) as \$l
        | select(.author.login == \"$OWNER\")
        | select(any(\$l[]; . == \"blocked\") | not)
        | select(any(\$l[]; startswith(\"type:\")))
        | select(([\$l[] | select(startswith(\"role:\"))] | length) <= 1)
        | select(([\$l[] | select(startswith(\"status:\"))] | length) <= 1)
      ] | sort_by(.number) | .[] | \"\\(.number) \\([.labels[].name] | join(\",\"))\""
}

# ---- which PR belongs to a ticket -----------------------------------------------------------------
# The one open, same-repository PR from the owner's account that closes exactly this ticket and targets
# the expected base. Forks are ignored, so one can never rank ahead of the real PR. Two same-repository PRs
# for one ticket, or one PR that closes several tickets, are ambiguous: no PR is selected.
eligible_pr() {
  local n="$1" prs count pr
  prs="$(gh pr list --repo "$REPO" --state open --limit 100 \
    --json number,isCrossRepository,headRepositoryOwner,baseRefName,author,closingIssuesReferences)"
  count="$(jq --argjson n "$n" --arg o "$OWNER" '[.[] | select(any(.closingIssuesReferences[]?; .number == $n))
      | select(.isCrossRepository == false and .headRepositoryOwner.login == $o)] | length' <<<"$prs")"
  [ "$count" = 1 ] || { [ "$count" = 0 ] || echo "ticket #$n: $count same-repository PRs claim it; ambiguous, none selected" >&2; return 1; }
  pr="$(jq -r --argjson n "$n" --arg o "$OWNER" --arg b "$BASE_BRANCH" '[.[] | select(any(.closingIssuesReferences[]?; .number == $n))
      | select(.isCrossRepository == false and .headRepositoryOwner.login == $o)][0]
      | select(.baseRefName == $b and .author.login == $o and (.closingIssuesReferences | length) == 1) | .number' <<<"$prs")"
  [ -n "$pr" ] || { echo "ticket #$n: its PR has an unexpected base or author, or closes several tickets; none selected" >&2; return 1; }
  echo "$pr"
}

# ---- owner approval, enforced when code is about to run -------------------------------------------
pr_facts() {
  gh pr view "$1" --repo "$REPO" \
    --json number,state,isCrossRepository,headRepositoryOwner,baseRefName,headRefName,headRefOid,author
}

# Prints the reason this PR may not be treated as a candidate, or nothing.
candidate_problem() {  # <facts json>
  jq -r --arg o "$OWNER" --arg b "$BASE_BRANCH" '
    if .state != "OPEN" then "PR is not open"
    elif .isCrossRepository != false then "fork PR"
    elif .headRepositoryOwner.login != $o then "head is not in this repository"
    elif .baseRefName != $b then "base is \(.baseRefName), expected \($b)"
    elif .author.login != $o then "PR author is not the owner account"
    elif (.headRefOid | test("^[0-9a-f]{40}$") | not) then "head is not a full SHA"
    else empty end' <<<"$1"
}

approval_file() { echo "$CONTROL/approvals/pr-$1-$2.json"; }

# Prints the approved full head SHA, or refuses. This is the only door to candidate execution and to
# gate publication, and it reads GitHub live each time, so a pushed or retargeted PR loses its approval.
authorize_candidate() {  # <pr>
  local pr="$1" facts problem sha file
  facts="$(pr_facts "$pr")" || { refuse "cannot read PR #$pr"; return; }
  problem="$(candidate_problem "$facts")"
  [ -z "$problem" ] || { refuse "PR #$pr: $problem"; return; }
  sha="$(jq -r .headRefOid <<<"$facts")"
  file="$(approval_file "$pr" "$sha")"
  [ -f "$file" ] && [ ! -L "$file" ] || { refuse "PR #$pr head $sha has no owner approval"; return; }
  [ "$(stat -c '%u' "$file")" = "$(id -u)" ] || { refuse "approval for PR #$pr has the wrong owner"; return; }
  jq -e --argjson p "$pr" --arg s "$sha" --arg b "$BASE_BRANCH" --arg r "$REPO" \
    '.pr == $p and .head_sha == $s and .base == $b and .repo == $r' "$file" >/dev/null \
    || { refuse "approval for PR #$pr does not match its head, base or repository"; return; }
  echo "$sha"
}

# ---- receipts: the only evidence that establishes success -----------------------------------------
receipt_file() { echo "$CONTROL/receipts/$1.json"; }
runner_hash() { cat "$GATE_SCRIPTS/verify_pr.sh" "$GATE_SCRIPTS/gate_lib.sh" | sha256sum | cut -d' ' -f1; }

write_receipt() {  # <sha> <pr> <PASS|FAIL> <pytest_exit> <canary_exit> <health> <page> <head_after> <transcript> <reason>
  local sha="$1" tmp file
  file="$(receipt_file "$sha")"; tmp="$file.$$"
  jq -n --arg repo "$REPO" --argjson pr "$2" --arg base "$BASE_BRANCH" --arg head_sha "$sha" --arg verdict "$3" \
    --argjson pytest_exit "$4" --argjson canary_exit "$5" --arg health "$6" --arg page "$7" --arg head_after "$8" \
    --arg transcript_sha256 "$(sha256sum "$9" | cut -d' ' -f1)" --arg runner_sha256 "$(runner_hash)" \
    --arg reason "${10}" --arg finished "$(date -u +%FT%TZ)" \
    '{repo:$repo, pr:$pr, base:$base, head_sha:$head_sha, verdict:$verdict, pytest_exit:$pytest_exit,
      canary_exit:$canary_exit, health:$health, page:$page, head_after:$head_after, reason:$reason,
      transcript_sha256:$transcript_sha256, runner_sha256:$runner_sha256, finished:$finished}' > "$tmp"
  chmod 400 "$9" "$tmp"
  mv -f "$tmp" "$file"
}

# Exit 0 only for an intact PASS receipt that belongs to this exact SHA and was made by the current runner.
receipt_passes() {  # <sha>
  local sha="$1" file transcript
  file="$(receipt_file "$sha")"; transcript="$CONTROL/transcripts/$sha.txt"
  [ -f "$file" ] && [ -f "$transcript" ] || return 1
  jq -e --arg s "$sha" --arg t "$(sha256sum "$transcript" | cut -d' ' -f1)" --arg r "$(runner_hash)" '
    .head_sha == $s and .head_after == $s and .verdict == "PASS" and .pytest_exit == 0 and .canary_exit == 1
    and .health == "200" and .page == "ok" and .transcript_sha256 == $t and .runner_sha256 == $r' "$file" >/dev/null
}

# ---- publishing -----------------------------------------------------------------------------------
# Candidate and model text is data. It reaches GitHub with control characters removed, mentions and code
# fences defused, and only if it holds no value from the secrets file.
sanitize() {  # stdin -> stdout
  python3 -I -c '
import re, sys
text = sys.stdin.buffer.read().decode("utf-8", "replace")
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
text = text.replace("```", "'"'''"'").replace("@", "@​")
sys.stdout.write(text)'
}

holds_secret() {  # <file>: exit 0 if the file contains any value from the secrets file
  python3 -I - "$1" "$HOME/.secrets/agents.env" <<'PY'
import sys
text = open(sys.argv[1], "rb").read()
values = []
try:
    for line in open(sys.argv[2], "rb"):
        if b"=" in line and not line.startswith(b"#"):
            value = line.split(b"=", 1)[1].strip()
            if len(value) >= 8:
                values.append(value)
except OSError:
    pass
sys.exit(0 if any(v in text for v in values) else 1)
PY
}

publish_comment() {  # <pr> <file>
  if holds_secret "$2"; then
    echo "REFUSED: text for PR #$1 contains a configured secret; not published" >&2
    return 3
  fi
  gh pr comment "$1" --repo "$REPO" --body-file "$2" >/dev/null
}

# The two required gates are published here and nowhere else. Agents hold a token without
# Commit statuses permission, so this is the only code on the host that can set them.
publish_status() {  # <sha> <agent/review|agent/test> <success|failure> <description>
  gh api "repos/$REPO/statuses/$1" -f state="$3" -f context="$2" -f description="$4" >/dev/null
}
