#!/usr/bin/env bash
# fm-exclude-tools-lib.sh - shared parsing and runtime-support checks for the
# worker launch inputs of this home's ship and scout workers: the lists that
# keep tools out of them, config/crew-exclude-tools and the fleet-rendered
# worker-denied MCP server and MCP tool lists, the Claude compaction
# window, config/crew-compact-window, and the content MCP config a --content
# worker loads. Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# docs/configuration.md "Worker tool exclusions", "Worker-denied MCP
# servers", "Worker-denied MCP tools", "Content workers", and "Worker
# compaction window" own the file formats and operator contracts;
# bin/fm-spawn.sh's header owns
# launch-flag mechanics.
# Name verification belongs inside the worker's loaded-tool registry, never
# in an out-of-band server connection from these launch-time checks.

# fm_name_list_entries <file> <label> <entry-noun>: print the comma-joined
# names in a readable file, one per line, skipping blank and # comment lines.
# Non-zero with the reason on stderr, naming the file as <label>, when an
# entry is malformed or the file cannot be read.
fm_name_list_entries() {
  local file=$1 label=$2 noun=$3 line names=''
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if [ -n "${line//[A-Za-z0-9_.-]/}" ]; then
      echo "error: $label has a malformed entry '$line'; expected one $noun per line using only letters, digits, _ . and - (blank lines and # comment lines are allowed)" >&2
      return 1
    fi
    names="${names:+$names,}$line"
  done <"$file" || {
    echo "error: cannot read $label" >&2
    return 1
  }
  printf '%s' "$names"
}

# fm_config_name_list <config-dir> <file> <entry-noun>: print the comma-joined
# names in config/<file>, empty when the file is absent or lists nothing.
# Non-zero with the reason on stderr when the file or an entry is invalid; a
# present but dangling, nonregular, or unreadable file is invalid, so a home
# that declares a list never launches without it.
fm_config_name_list() {
  local config=$1 name=$2 noun=$3 file present
  file=$config/$name
  present=$(perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect config/$ARGV[1]: $!\n" }
  ' -- "$file" "$name") || return 1
  [ "$present" = 1 ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/$name must be a readable regular file" >&2
    return 1
  fi
  fm_name_list_entries "$file" "config/$name" "$noun"
}

# fm_exclude_tools_names <config-dir>: print the comma-joined names, empty when
# the file is absent or lists nothing. Non-zero with the reason on stderr when
# the file or an entry is invalid.
fm_exclude_tools_names() {
  fm_config_name_list "$1" crew-exclude-tools 'tool name'
}

# fm_exclude_tools_check <harness> <raw-launch 0|1> <config-dir>: succeed when
# this launch can honor the home's list (empty list, or a runtime that hides
# tools); otherwise refuse naming the file. Prints the names on stdout. A
# templated Claude launch also gets the worker-denied MCP tool patterns, or
# `mcp__*`, which hides every MCP tool, when that list cannot be read here, so
# this read fails closed whatever fm_worker_denied_mcp_servers_check's own
# read of the list later sees; that check refuses or falls back when the list
# cannot be carried or read.
fm_exclude_tools_check() {
  local harness=$1 raw=$2 config=$3 names tools
  names=$(fm_exclude_tools_names "$config") || return 1
  if [ "$harness" = claude ] && [ "$raw" != 1 ]; then
    tools=$(fm_worker_denied_mcp_tools_entries 2>/dev/null) || tools='mcp__*'
    [ -z "$tools" ] || names="${names:+$names,}$tools"
  fi
  if [ -n "$names" ]; then
    if [ "$raw" = 1 ]; then
      echo "error: config/crew-exclude-tools lists tools to hide, but a raw launch command cannot hide tools; remove the entries or launch a runtime that supports them (claude, pi, pi-signed)" >&2
      return 1
    fi
    case "$harness" in
    claude | pi | pi-signed) ;;
    *)
      echo "error: config/crew-exclude-tools lists tools to hide, but the $harness runtime cannot hide tools, so this launch is refused rather than running with them available; empty the file or launch a runtime that supports exclusion (claude, pi, pi-signed)" >&2
      return 1
      ;;
    esac
  fi
  printf '%s' "$names"
}

# fm_worker_denied_mcp_servers_file: print the path of the worker-denied MCP
# server list, the fleet-rendered ~/.config/fleet/claude/worker-denied-mcp-servers;
# FM_WORKER_DENIED_MCP_SERVERS_FILE overrides it for tests and for a home
# outside that fleet.
fm_worker_denied_mcp_servers_file() {
  printf '%s' "${FM_WORKER_DENIED_MCP_SERVERS_FILE:-$HOME/.config/fleet/claude/worker-denied-mcp-servers}"
}

# fm_worker_denied_mcp_tools_file: print the path of the worker-denied MCP
# tool list, the fleet-rendered ~/.config/fleet/claude/worker-denied-mcp-tools;
# FM_WORKER_DENIED_MCP_TOOLS_FILE overrides it for tests and for a home outside
# that fleet.
fm_worker_denied_mcp_tools_file() {
  printf '%s' "${FM_WORKER_DENIED_MCP_TOOLS_FILE:-$HOME/.config/fleet/claude/worker-denied-mcp-tools}"
}

# fm_worker_denied_mcp_tools_entries: print the comma-joined Claude tool
# patterns the worker-denied MCP tool list names, one `mcp__<server>__<tool>`
# per line where `*` matches any run of characters, skipping blank and #
# comment lines. Prints nothing only when the file does not exist. Non-zero
# with the reason on stderr when it cannot be inspected, or is present but
# dangling, not a readable regular file, or has an entry of any other shape.
fm_worker_denied_mcp_tools_entries() {
  local file line names='' present
  file=$(fm_worker_denied_mcp_tools_file)
  present=$(perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect $ARGV[0]: $!\n" }
  ' -- "$file") || return 1
  [ "$present" = 1 ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if ! [[ "$line" =~ ^mcp__[A-Za-z0-9_*-]+__[A-Za-z0-9_*-]+$ ]]; then
      echo "error: $file has a malformed entry '$line'; expected one mcp__<server>__<tool> pattern per line using only letters, digits, _ - and *" >&2
      return 1
    fi
    names="${names:+$names,}$line"
  done <"$file" || {
    echo "error: cannot read $file" >&2
    return 1
  }
  printf '%s' "$names"
}

# fm_worker_denied_mcp_servers_check <harness> <raw-launch 0|1> <backend>:
# for a Claude ship or scout launch, print the comma-joined server names the
# worker-denied MCP server list names, empty when it names none, or '*' when
# the list is missing, unreadable, or malformed: the worker is then denied
# every MCP server, with a warning naming the file, so a host that lacks the
# list never launches a worker with fewer denials. A present worker-denied MCP
# tool list that cannot be read falls back the same way, while an absent one
# denies no tool. Refuses when the launch must deny servers or tools but
# cannot carry Claude's MCP server policy settings or --disallowedTools: any
# raw command, which can reach claude behind a wrapper firstmate cannot see
# through, or T3 Code, which builds its own provider command. Names use only
# letters, digits, _ and -, the server-name form Claude's setting accepts.
# Every other runtime does not read Claude's MCP configuration, so it neither
# reads nor refuses on the list.
fm_worker_denied_mcp_servers_check() {
  local harness=$1 raw=$2 backend=$3 file names='' problem='' tools=''
  [ "$raw" = 1 ] || [ "$harness" = claude ] || return 0
  file=$(fm_worker_denied_mcp_servers_file)
  if [ -L "$file" ] && [ ! -e "$file" ]; then
    problem='is a dangling link'
  elif [ ! -e "$file" ]; then
    problem='is missing'
  elif [ ! -f "$file" ] || [ ! -r "$file" ]; then
    problem='is not a readable regular file'
  elif ! names=$(fm_name_list_entries "$file" "$file" 'MCP server name' 2>/dev/null); then
    problem='is unreadable or has an entry that is not one server name of letters, digits, _ and -'
  else
    case "$names" in
    *.*) problem="has a server name with '.', which Claude's deniedMcpServers does not accept" ;;
    esac
  fi
  local label="the worker-denied MCP server list $file"
  if [ -z "$problem" ] && ! tools=$(fm_worker_denied_mcp_tools_entries 2>/dev/null); then
    label="the worker-denied MCP tool list $(fm_worker_denied_mcp_tools_file)"
    problem='is unreadable or has an entry that is not one mcp__<server>__<tool> pattern'
  fi
  [ -z "$problem" ] || names='*'
  [ -n "$names" ] || [ -n "$tools" ] || return 0
  local need="$file names MCP servers to deny Claude workers"
  [ -n "$names" ] || need="$(fm_worker_denied_mcp_tools_file) names MCP tools to deny Claude workers"
  [ -z "$problem" ] || need="$label $problem, so Claude workers must be denied every MCP server"
  if [ "$raw" = 1 ]; then
    echo "error: $need, but a raw launch command cannot carry that denial; launch with a harness name instead" >&2
    return 1
  fi
  if [ "$backend" = t3code ]; then
    echo "error: $need, but backend=t3code builds its own claude command and cannot carry that denial; choose another backend" >&2
    return 1
  fi
  [ -z "$problem" ] \
    || echo "warning: $label $problem, so this Claude worker is denied every MCP server; render the list from the fleet configuration or set FM_WORKER_DENIED_MCP_SERVERS_FILE or FM_WORKER_DENIED_MCP_TOOLS_FILE" >&2
  printf '%s' "$names"
}

# fm_content_mcp_config_file: print the path of the content MCP config a
# --content Claude ship or scout loads through --mcp-config, the
# fleet-rendered ~/.config/fleet/claude/content.mcp.json;
# FM_CONTENT_MCP_CONFIG_FILE overrides it for tests and for a home outside
# that fleet.
fm_content_mcp_config_file() {
  printf '%s' "${FM_CONTENT_MCP_CONFIG_FILE:-$HOME/.config/fleet/claude/content.mcp.json}"
}

# fm_content_mcp_check <harness> <raw-launch 0|1> <backend> <hidden-tools>
# <denied-servers>: for a --content ship or scout, print the physical path of
# the content MCP config, after proving the launch can load every server it
# names with each server's sign-in tools (authenticate and
# complete_authentication) callable. <hidden-tools> is what
# fm_exclude_tools_check printed and <denied-servers> what
# fm_worker_denied_mcp_servers_check printed. Refuses, naming the reason, a
# runtime other than a templated claude launch, backend=t3code (which builds
# its own claude command), a missing or malformed config, a server name
# outside letters, digits, _ and -, a deny-every-server fallback, a denied
# content server, and any hidden-tool entry that matches a sign-in tool,
# because --disallowedTools has no exception syntax to reopen one.
fm_content_mcp_check() {
  local harness=$1 raw=$2 backend=$3 hidden=$4 denied=$5 file dir servers server tool pattern name whole_server
  local -a patterns=() denied_names=()
  if [ "$raw" = 1 ] || [ "$harness" != claude ]; then
    local runtime="the $harness runtime"
    [ "$raw" != 1 ] || runtime='a raw launch command'
    echo "error: --content loads the content MCP servers through Claude Code's --mcp-config, so it needs --harness claude; $runtime cannot load them" >&2
    return 1
  fi
  if [ "$backend" = t3code ]; then
    echo "error: --content needs --mcp-config on the claude command, but backend=t3code builds its own claude command; choose another backend" >&2
    return 1
  fi
  file=$(fm_content_mcp_config_file)
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: --content needs the content MCP config $file, which is missing or not a readable regular file; render it from the fleet configuration or set FM_CONTENT_MCP_CONFIG_FILE" >&2
    return 1
  fi
  if ! servers=$(jq -r '.mcpServers | if type == "object" and length > 0 then keys[] else error("no servers") end' "$file" 2>/dev/null); then
    echo "error: the content MCP config $file is not JSON with a non-empty mcpServers object" >&2
    return 1
  fi
  dir=$(cd "$(dirname "$file")" && pwd -P) || {
    echo "error: cannot resolve the directory of the content MCP config $file" >&2
    return 1
  }
  file="$dir/$(basename "$file")"
  if [ "$denied" = '*' ]; then
    echo "error: --content needs its MCP servers, but this Claude worker would be denied every MCP server because a worker-denied MCP list is unusable; fix that list first" >&2
    return 1
  fi
  [ -z "$denied" ] || IFS=, read -r -a denied_names <<<"$denied"
  [ -z "$hidden" ] || IFS=, read -r -a patterns <<<"$hidden"
  while IFS= read -r server; do
    if ! [[ "$server" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "error: the content MCP config $file names server '$server'; use only letters, digits, _ and - so its tool names can be checked" >&2
      return 1
    fi
    for name in ${denied_names[@]+"${denied_names[@]}"}; do
      [ "$name" != "$server" ] || {
        echo "error: --content loads MCP server $server, but the worker-denied MCP server list $(fm_worker_denied_mcp_servers_file) denies it" >&2
        return 1
      }
    done
    for tool in "mcp__${server}__authenticate" "mcp__${server}__complete_authentication"; do
      for pattern in ${patterns[@]+"${patterns[@]}"}; do
        # The entry is a glob on purpose: a wildcard and a whole-server
        # entry (mcp__<server>, no tool part) both hide the sign-in tool.
        whole_server=0
        case "$pattern" in
          mcp__*__*) ;;
          mcp__?*) whole_server=1 ;;
        esac
        # shellcheck disable=SC2053
        if [[ "$tool" == $pattern ]] || { [ "$whole_server" = 1 ] && [[ "$tool" == ${pattern}__* ]]; }; then
          echo "error: --content needs $tool callable for the content sign-in, but the hidden-tool entry '$pattern' (config/crew-exclude-tools or $(fm_worker_denied_mcp_tools_file)) would deny it; narrow that entry" >&2
          return 1
        fi
      done
    done
  done <<<"$servers"
  printf '%s' "$file"
}

# fm_crew_compact_window_check <harness> <config-dir>: for a Claude ship or
# scout launch, print the token count config/crew-compact-window declares,
# empty when the file is absent. The file holds # comment lines (and blank
# lines) plus exactly one integer from 100000 to 1000000, the range Claude
# Code accepts for CLAUDE_CODE_AUTO_COMPACT_WINDOW. Non-zero with the reason
# on stderr when the file is dangling, nonregular, unreadable, or holds
# anything else. Every other runtime neither reads nor refuses on the file.
fm_crew_compact_window_check() {
  local harness=$1 config=$2 value
  [ "$harness" = claude ] || return 0
  value=$(fm_config_name_list "$config" crew-compact-window 'token count') || return 1
  [ -n "$value" ] || {
    [ ! -e "$config/crew-compact-window" ] || {
      echo "error: config/crew-compact-window holds no token count; write one integer from 100000 to 1000000, or remove the file" >&2
      return 1
    }
    return 0
  }
  case "$value" in
  *,* | *[!0-9]* | 0*)
    echo "error: config/crew-compact-window must hold exactly one integer from 100000 to 1000000 (with # comment lines allowed), not '$value'" >&2
    return 1
    ;;
  esac
  if [ "${#value}" -gt 7 ] || [ "$value" -lt 100000 ] || [ "$value" -gt 1000000 ]; then
    echo "error: config/crew-compact-window holds $value; Claude Code accepts a compaction window from 100000 to 1000000 tokens" >&2
    return 1
  fi
  printf '%s' "$value"
}
