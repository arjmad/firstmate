#!/usr/bin/env bash
# fm-exclude-tools-lib.sh - shared parsing and runtime-support checks for the
# worker launch config files of this home's ship and scout workers: the lists
# that keep tools out of them, config/crew-exclude-tools and
# config/worker-denied-mcp-servers, and the Claude compaction window,
# config/crew-compact-window. Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# docs/configuration.md "Worker tool exclusions", "Worker-denied MCP
# servers", and "Worker compaction window" own the file formats and operator
# contracts; bin/fm-spawn.sh's header owns launch-flag mechanics.
# Name verification belongs inside the worker's loaded-tool registry, never
# in an out-of-band server connection from these launch-time checks.

# fm_config_name_list <config-dir> <file> <entry-noun>: print the comma-joined
# names in config/<file>, empty when the file is absent or lists nothing.
# Non-zero with the reason on stderr when the file or an entry is invalid; a
# present but dangling, nonregular, or unreadable file is invalid, so a home
# that declares a list never launches without it.
fm_config_name_list() {
  local config=$1 name=$2 noun=$3 file line names='' present
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
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if [ -n "${line//[A-Za-z0-9_.-]/}" ]; then
      echo "error: config/$name has a malformed entry '$line'; expected one $noun per line using only letters, digits, _ . and - (blank lines and # comment lines are allowed)" >&2
      return 1
    fi
    names="${names:+$names,}$line"
  done <"$file" || {
    echo "error: cannot read config/$name" >&2
    return 1
  }
  printf '%s' "$names"
}

# fm_exclude_tools_names <config-dir>: print the comma-joined names, empty when
# the file is absent or lists nothing. Non-zero with the reason on stderr when
# the file or an entry is invalid.
fm_exclude_tools_names() {
  fm_config_name_list "$1" crew-exclude-tools 'tool name'
}

# fm_exclude_tools_check <harness> <raw-launch 0|1> <config-dir>: succeed when
# this launch can honor the home's list (empty list, or a runtime that hides
# tools); otherwise refuse naming the file. Prints the names on stdout.
fm_exclude_tools_check() {
  local harness=$1 raw=$2 config=$3 names
  names=$(fm_exclude_tools_names "$config") || return 1
  if [ -n "$names" ]; then
    if [ "$raw" = 1 ]; then
      echo "error: config/crew-exclude-tools lists tools to hide, but a raw launch command cannot hide tools; remove the entries or launch a runtime that supports them (pi, pi-signed)" >&2
      return 1
    fi
    case "$harness" in
    pi | pi-signed) ;;
    *)
      echo "error: config/crew-exclude-tools lists tools to hide, but the $harness runtime cannot hide tools, so this launch is refused rather than running with them available; empty the file or launch a runtime that supports exclusion (pi, pi-signed)" >&2
      return 1
      ;;
    esac
  fi
  printf '%s' "$names"
}

# fm_worker_denied_mcp_servers_check <harness> <raw-launch 0|1> <backend> <config-dir>:
# for a Claude ship or scout launch, print the comma-joined server names
# config/worker-denied-mcp-servers lists, empty when the home lists none.
# Refuses when the file is invalid, or when it lists servers and this launch
# cannot carry Claude's deniedMcpServers setting: any raw command, which can
# reach claude behind a wrapper firstmate cannot see through, or T3 Code,
# which builds its own provider command. Names use only letters, digits, _
# and -, the server-name form Claude's setting accepts. Every other runtime
# does not read Claude's MCP configuration, so it neither reads nor refuses
# on the file.
fm_worker_denied_mcp_servers_check() {
  local harness=$1 raw=$2 backend=$3 config=$4 names
  [ "$raw" = 1 ] || [ "$harness" = claude ] || return 0
  names=$(fm_config_name_list "$config" worker-denied-mcp-servers 'MCP server name') || return 1
  [ -n "$names" ] || return 0
  case "$names" in
  *.*)
    echo "error: config/worker-denied-mcp-servers has a server name with '.'; Claude's deniedMcpServers accepts only letters, digits, _ and -" >&2
    return 1
    ;;
  esac
  if [ "$raw" = 1 ]; then
    echo "error: config/worker-denied-mcp-servers lists MCP servers a worker must not load, but a raw launch command cannot carry that denial; launch with a harness name instead" >&2
    return 1
  fi
  if [ "$backend" = t3code ]; then
    echo "error: config/worker-denied-mcp-servers lists MCP servers a worker must not load, but backend=t3code builds its own claude command and cannot carry that denial; choose another backend" >&2
    return 1
  fi
  printf '%s' "$names"
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
