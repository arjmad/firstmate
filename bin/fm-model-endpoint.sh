#!/usr/bin/env bash
# Resolve a crewmate model name to a local Anthropic-shaped endpoint override.
#
# This is the generic "this model resolves to this local endpoint" mechanism:
# it lets firstmate route a claude crewmate/scout at a local OpenAI-compatible
# proxy that speaks the Anthropic API shape (so non-Anthropic models can be
# driven through the unchanged `claude` CLI) WITHOUT introducing a new harness.
# The resolved model still launches as `harness=claude`; the only launch
# differences are an endpoint env prefix, a separately-exported auth token,
# `--strict-mcp-config`, and an optional deliberately granted `--mcp-config`.
# fm-spawn.sh consumes this and owns the launch wiring.
#
# Usage:
#   fm-model-endpoint.sh resolve [--with-token] <model>
#
# It reads config/model-endpoints.json (local, gitignored) from the effective
# config dir (FM_CONFIG_OVERRIDE, else $FM_HOME/config, else <repo>/config). The
# file maps a model name to a local endpoint spec:
#
#   {
#     "endpoints": {
#       "<model-name>": {
#         "base_url": "http://127.0.0.1:8080",   # required, becomes ANTHROPIC_BASE_URL
#         "auth_token_env": "SOME_TOKEN_VAR",    # token source (one of the three below)
#         "auth_token_file": "/path/to/token",   #   tried in this priority order,
#         "auth_token": "<literal-token>",       #   first non-empty wins
#         "strict_mcp_config": true,             # optional bool, default true -> --strict-mcp-config
#         "mcp_config": "/path/to/.mcp.json",    # optional deliberate MCP grant -> --mcp-config
#         "env": {                               # optional extra NON-SECRET env vars,
#           "ANTHROPIC_DEFAULT_OPUS_MODEL": "my-local-model",   # set as an inline launch prefix
#           "ANTHROPIC_DEFAULT_SONNET_MODEL": "my-local-model",
#           "ANTHROPIC_DEFAULT_HAIKU_MODEL": "my-local-model-small",
#           "CLAUDE_CODE_SUBAGENT_MODEL": "my-local-model"
#         }
#       }
#     }
#   }
#
# Secret discipline: the auth token is NEVER printed unless --with-token is
# passed, is NEVER written to task meta or a status line by fm-spawn, and (when
# a literal) lives only in the gitignored config file. ANTHROPIC_AUTH_TOKEN is
# rejected inside `env`; it must come from a token source so fm-spawn can export
# it off the recorded launch string. ANTHROPIC_BASE_URL is set from base_url and
# is likewise rejected inside `env`.
#
# Output (stdout), one TAB-separated record per line, on a match:
#   strict_mcp_config<TAB><0|1>
#   mcp_config<TAB><absolute-readable-path> # only when configured
#   env<TAB>ANTHROPIC_BASE_URL<TAB><base_url>
#   env<TAB><KEY><TAB><VALUE>            # one per entry in the config's env map
#   token<TAB><resolved-token>          # ONLY when --with-token and resolvable
#
# Exit codes (the fail-closed contract fm-spawn relies on):
#   0  model matched a configured endpoint; records printed.
#   3  no config file (absent or empty) OR model not listed; launch normally.
#   2  config present but malformed, matched entry invalid, configured mcp_config
#      missing/unreadable, or (with --with-token) token unresolvable; fm-spawn
#      ABORTS the spawn rather than risk launching an endpoint model against the
#      real Anthropic API.
#   64 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/model-endpoints.json"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  resolve) shift ;;
  *) echo "error: unknown subcommand '${1:-}' (expected: resolve)" >&2; exit 64 ;;
esac

WITH_TOKEN=0
MODEL=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-token) WITH_TOKEN=1; shift ;;
    --) shift; break ;;
    -*) echo "error: unknown option $1" >&2; exit 64 ;;
    *) break ;;
  esac
done
MODEL=${1:-}
[ "$#" -le 1 ] || { echo "error: resolve takes a single <model>" >&2; exit 64; }
[ -n "$MODEL" ] || { echo "error: resolve requires a <model>" >&2; exit 64; }

# No config, or an empty/whitespace-only file: no endpoint routing, launch
# normally. An empty file is treated as absent so a stray `touch` never blocks
# every claude spawn; a non-empty but unparseable file is malformed (exit 2).
[ -f "$CONFIG_FILE" ] || exit 3
if ! grep -q '[^[:space:]]' "$CONFIG_FILE" 2>/dev/null; then
  exit 3
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq is required to read $CONFIG_FILE" >&2; exit 2; }

# Structural validation + non-secret record emission happen in jq. Any jq
# failure (unparseable JSON or an error() from an invalid entry) maps to exit 2.
# A null entry for this model prints the __NOMATCH__ sentinel and exits 0.
jq_status=0
records=$(jq -r --arg model "$MODEL" --arg with "$WITH_TOKEN" '
  def is_env_name: test("^[A-Za-z_][A-Za-z0-9_]*$");
  if (type != "object") then error("model-endpoints.json root is not a JSON object")
  else
    (.endpoints // {}) as $eps
    | if (($eps | type) != "object") then error("endpoints must be an object")
      else
        ($eps[$model]) as $e
        | if ($e == null) then "__NOMATCH__"
          elif (($e | type) != "object") then error("endpoint entry for " + $model + " is not an object")
          else
            (if (($e.base_url | type) != "string") or ($e.base_url == "")
               then error("base_url missing or empty for " + $model)
             elif ($e.base_url | test("[\t\n]")) then error("base_url must not contain tab or newline")
             else $e.base_url end) as $base
            | (if ($e | has("strict_mcp_config"))
                 then (if (($e.strict_mcp_config | type) != "boolean")
                         then error("strict_mcp_config must be a boolean")
                       else $e.strict_mcp_config end)
               else true end) as $strict
            | (if ($e | has("mcp_config"))
                 then (if (($e.mcp_config | type) != "string") or ($e.mcp_config == "")
                         then error("mcp_config must be a non-empty string")
                       elif ($e.mcp_config | test("[[:cntrl:]]"))
                         then error("mcp_config must not contain control characters")
                       else $e.mcp_config end)
               else null end) as $mcp
            | (($e.env // {}) as $env0
               | if (($env0 | type) != "object") then error("env must be an object") else $env0 end) as $env
            | ([ ("auth_token_env","auth_token_file","auth_token")
                 | select((($e[.]?) | type) == "string" and ($e[.] != ""))
                 | if ($e[.] | test("[\t\n\r\u000b\u000c]"))
                     then error(. + " for " + $model + " must not contain tab, newline, or other control whitespace")
                   else . end ]) as $tsrc
            | if (($tsrc | length) == 0)
                then error("no token source for " + $model + ": set auth_token_env, auth_token_file, or auth_token")
              else
                ("strict_mcp_config\t" + (if $strict then "1" else "0" end)),
                (if $mcp == null then empty else ("mcp_config\t" + $mcp) end),
                ("env\tANTHROPIC_BASE_URL\t" + $base),
                ($env | to_entries[]
                  | if ((.key | is_env_name) | not) then error("invalid env key: " + .key)
                    elif (.key == "ANTHROPIC_AUTH_TOKEN") then error("ANTHROPIC_AUTH_TOKEN must come from a token source, not env")
                    elif (.key == "ANTHROPIC_BASE_URL") then error("ANTHROPIC_BASE_URL is set from base_url, not env")
                    elif ((.value | type) != "string") then error("env value for " + .key + " must be a string")
                    elif (.value | test("[\t\n]")) then error("env value for " + .key + " must not contain tab or newline")
                    else ("env\t" + .key + "\t" + .value) end),
                (if $with == "1"
                   then ("auth_token_env","auth_token_file","auth_token")
                        | select((($e[.]?) | type) == "string" and ($e[.] != ""))
                        | ("tokensrc\t" + . + "\t" + $e[.])
                 else empty end)
              end
          end
      end
  end
' "$CONFIG_FILE") || jq_status=$?

if [ "$jq_status" -ne 0 ]; then
  echo "error: $CONFIG_FILE is malformed or the entry for '$MODEL' is invalid" >&2
  exit 2
fi

case "$records" in
  __NOMATCH__) exit 3 ;;
esac

# Resolve the token in bash so a file-backed source and an env-backed source are
# handled uniformly, and so a literal token is never re-derived from jq's view
# of the environment. Sources arrive in priority order (env, file, literal);
# the first that yields a non-empty single-line value wins.
token=
token_seen=0
mcp_error=
emit=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  kind=${line%%$'\t'*}
  case "$kind" in
    mcp_config)
      operand=${line#mcp_config$'\t'}
      case "$operand" in
        /*) ;;
        *) operand="$FM_HOME/$operand" ;;
      esac
      if [ ! -f "$operand" ] || [ ! -r "$operand" ]; then
        mcp_error="configured mcp_config for '$MODEL' is missing or unreadable: $operand"
      else
        emit+=("mcp_config"$'\t'"$operand")
      fi
      ;;
    tokensrc)
      token_seen=1
      [ -z "$token" ] || continue
      rest=${line#tokensrc$'\t'}
      src=${rest%%$'\t'*}
      operand=${rest#*$'\t'}
      val=
      case "$src" in
        auth_token_env)
          val=$(printenv "$operand" 2>/dev/null || true)
          # Only the first line, no surrounding whitespace surprises downstream.
          val=${val%%$'\n'*}
          ;;
        auth_token_file)
          if [ -f "$operand" ]; then
            IFS= read -r val < "$operand" 2>/dev/null || true
            val=${val%$'\r'}
          fi
          ;;
        auth_token)
          val=$operand
          ;;
      esac
      case "$val" in
        *$'\t'*|*$'\n'*) val= ;;  # a token with a tab/newline is unusable; skip it
      esac
      [ -z "$val" ] || token=$val
      ;;
    *)
      emit+=("$line")
      ;;
  esac
done <<EOF
$records
EOF

# Fail closed BEFORE emitting anything, so a spawn that will abort never prints
# even the non-secret records.
if [ -n "$mcp_error" ]; then
  echo "error: $mcp_error" >&2
  exit 2
fi
if [ "$WITH_TOKEN" -eq 1 ] && { [ "$token_seen" -eq 0 ] || [ -z "$token" ]; }; then
  echo "error: could not resolve a non-empty auth token for '$MODEL' from the configured source" >&2
  exit 2
fi

for line in "${emit[@]}"; do
  printf '%s\n' "$line"
done
[ "$WITH_TOKEN" -eq 0 ] || printf 'token\t%s\n' "$token"

exit 0
