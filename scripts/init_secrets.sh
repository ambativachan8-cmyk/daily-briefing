#!/usr/bin/env bash
# Credential setup for the VM. Prints names and outcomes only, never a value.
#
#   init_secrets.sh prepare     create ~/.secrets (0700) so you can copy agents.env into it
#   init_secrets.sh check       the file exists, is private, has the required names and two different tokens
#   init_secrets.sh install     check, then log the control plane into gh and give the agent account its own file
#   init_secrets.sh verify      show what each GitHub token can do, by requests that change nothing
#
# Two GitHub tokens, because the agents must not be able to set the required gates:
#   GH_TOKEN        control plane only: Contents R, Issues RW, Pull requests RW, Commit statuses RW, Metadata R
#   AGENT_GH_TOKEN  agents: Contents RW, Issues RW, Pull requests RW, Metadata R, and NO Commit statuses
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
REPO="ambativachan8-cmyk/daily-briefing"
DIR="${SECRETS_DIR:-$HOME/.secrets}"; FILE="$DIR/agents.env"
AGENT_HOME="${AGENT_HOME:-/home/agent}"

value_of() { sed -n "s/^$1=//p" "$FILE" | tail -n 1; }
has_value() { [ -n "$(value_of "$1")" ]; }

prepare() {
  install -d -m 700 "$DIR"
  chmod 700 "$DIR"
  echo "ready: $DIR (0700). Copy your filled-in agents/agents.env.example to $FILE"
}

check() {
  local bad=0 name
  [ -d "$DIR" ] || { echo "MISSING $DIR: run init_secrets.sh prepare" >&2; return 1; }
  [ "$(stat -c %a "$DIR")" = 700 ] || { chmod 700 "$DIR"; echo "fixed: $DIR mode set to 700"; }
  [ -f "$FILE" ] || { echo "MISSING $FILE" >&2; return 1; }
  [ "$(stat -c %u "$FILE")" = "$(id -u)" ] || { echo "WRONG OWNER on $FILE" >&2; return 1; }
  [ "$(stat -c %a "$FILE")" = 600 ] || { chmod 600 "$FILE"; echo "fixed: $FILE mode set to 600"; }
  if ! has_value GH_TOKEN; then echo "MISSING value: GH_TOKEN" >&2; bad=1; else echo "present: GH_TOKEN"; fi
  if ! has_value AGENT_GH_TOKEN; then
    echo "MISSING value: AGENT_GH_TOKEN (agents cannot reach GitHub until it is set; keep the dispatcher paused)" >&2
    bad=2
  elif [ "$(value_of AGENT_GH_TOKEN)" = "$(value_of GH_TOKEN)" ]; then
    echo "REFUSED: AGENT_GH_TOKEN must not equal GH_TOKEN: that token can set the required gates" >&2; return 1
  else
    echo "present: AGENT_GH_TOKEN"
  fi
  for name in NVIDIA_API_KEY GEMINI_API_KEY_HERMES GEMINI_API_KEY_OPENCLAW OPENROUTER_API_KEY; do
    if has_value "$name"; then echo "present: $name"; else echo "empty:   $name"; fi
  done
  return "$bad"
}

# A token with Commit statuses permission answers an invalid state with 422 and changes nothing; a token
# without it answers 403. So this needs no real status write.
can_set_status() {  # <token>
  local sha code
  sha="$(GH_TOKEN="$1" gh api "repos/$REPO/commits/main" --jq .sha)"
  code="$(GH_TOKEN="$1" gh api -i -X POST "repos/$REPO/statuses/$sha" -f state=not-a-state 2>/dev/null | head -n 1 | grep -oE '[0-9]{3}' | tail -n 1 || true)"
  case "$code" in
    422) echo yes;;
    403|404) echo no;;
    *) echo "unknown($code)";;
  esac
}

verify() {
  local control agent
  control="$(value_of GH_TOKEN)"
  echo "control token can read the repository: $(GH_TOKEN="$control" gh api "repos/$REPO" --jq .full_name 2>/dev/null || echo NO)"
  echo "control token can set commit statuses: $(can_set_status "$control")"
  if has_value AGENT_GH_TOKEN; then
    agent="$(value_of AGENT_GH_TOKEN)"
    echo "agent token can read the repository: $(GH_TOKEN="$agent" gh api "repos/$REPO" --jq .full_name 2>/dev/null || echo NO)"
    local result; result="$(can_set_status "$agent")"
    echo "agent token can set commit statuses: $result"
    [ "$result" = no ] || { echo "REFUSED: the agent token can set the required gates (or could not be tested)" >&2; return 1; }
  else
    echo "agent token: not set"
    return 2
  fi
}

install_secrets() {
  local rc=0
  check || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || return "$rc"
  # The control plane's gh login, and git over HTTPS through it. gh refuses to store a token while GH_TOKEN is set.
  value_of GH_TOKEN | env -u GH_TOKEN gh auth login --with-token --hostname github.com
  env -u GH_TOKEN gh auth setup-git
  env -u GH_TOKEN gh auth status >/dev/null && echo "control plane: gh authenticated"
  # The agent account gets model keys and its own token, never the control token.
  { grep -E '^(GEMINI_API_KEY_HERMES|GEMINI_API_KEY_OPENCLAW|OPENROUTER_API_KEY|NVIDIA_API_KEY|OLLAMA_API_KEY)=' "$FILE" || true
    printf 'GH_TOKEN=%s\n' "$(value_of AGENT_GH_TOKEN)"; } \
    | sudo -n -u agent -H sh -c "umask 077; mkdir -p '$AGENT_HOME/.secrets'; chmod 700 '$AGENT_HOME/.secrets'; cat > '$AGENT_HOME/.secrets/agents.env'; chmod 600 '$AGENT_HOME/.secrets/agents.env'"
  echo "agent account: $AGENT_HOME/.secrets/agents.env written (0600)"
  return "$rc"
}

case "${1:-}" in
  prepare) prepare;;
  check) check;;
  install) install_secrets;;
  verify) verify;;
  *) sed -n 2,11p "$0"; exit 2;;
esac
