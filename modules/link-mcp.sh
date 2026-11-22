# Usage: agent-tools-link-mcp <claude|codex> <state-file> <cli> <wanted-file>
#
# Registers MCP servers through the harness's own CLI, which owns the file
# they live in (~/.claude.json, ~/.codex/config.toml) and rewrites it at will.
# The wanted file is JSON: {"remove": [argv...], "servers": {name: {"fingerprint", "add": [argv...]}}}.
# The state file records each server registered, as "<name>\t<fingerprint>".
# A recorded server that is no longer wanted is removed; a server of the same
# name that someone else registered is replaced, since its name is declared.
#
# `codex mcp add --url` saves the server and then waits for a browser OAuth
# login when the server offers one. An add therefore runs without stdin under
# a time limit, and counts as done when the server is there afterwards.

kind=$1
state=$2
cli=$3
wanted=$4
add_timeout=${AGENT_TOOLS_MCP_ADD_TIMEOUT:-20}

if ! command -v "$cli" > /dev/null; then
  echo "agent-tools: $cli is not installed; MCP servers for it are left as they are" >&2
  exit 0
fi

present() {
  case $kind in
    claude) jq --exit-status --arg name "$1" '.mcpServers // {} | has($name)' "$HOME/.claude.json" > /dev/null 2>&1 ;;
    codex) "$cli" mcp get "$1" < /dev/null > /dev/null 2>&1 ;;
  esac
}

mapfile -t remove < <(jq --raw-output '.remove[]' "$wanted")
remove_server() {
  present "$1" || return 0
  "$cli" "${remove[@]}" "$1" < /dev/null > /dev/null || echo "agent-tools: could not remove MCP server $1 from $cli" >&2
}

declare -A recorded=()
if [[ -f $state ]]; then
  while IFS=$'\t' read -r name fingerprint; do
    [[ -n $name && -n $fingerprint ]] || continue
    recorded[$name]=$fingerprint
  done < "$state"
fi

declare -A kept=()
for name in "${!recorded[@]}"; do
  jq --exit-status --arg name "$name" '.servers | has($name)' "$wanted" > /dev/null || remove_server "$name"
done

while IFS=$'\t' read -r name fingerprint; do
  if [[ ${recorded[$name]:-} == "$fingerprint" ]] && present "$name"; then
    kept[$name]=$fingerprint
    continue
  fi
  remove_server "$name"
  mapfile -t add < <(jq --raw-output --arg name "$name" '.servers[$name].add[]' "$wanted")
  timeout "$add_timeout" "$cli" "${add[@]}" < /dev/null > /dev/null 2>&1 || true
  if present "$name"; then
    kept[$name]=$fingerprint
  else
    echo "agent-tools: could not add MCP server $name to $cli" >&2
  fi
done < <(jq --raw-output '.servers | to_entries[] | "\(.key)\t\(.value.fingerprint)"' "$wanted")

if ((${#kept[@]})); then
  mkdir -p "$(dirname "$state")"
  for name in "${!kept[@]}"; do
    printf '%s\t%s\n' "$name" "${kept[$name]}"
  done | sort > "$state"
else
  rm -f "$state"
fi
