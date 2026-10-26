#!/usr/bin/env bash
# fm-lavish-url.sh - the phone-openable form of a Lavish session URL.
#
# Lavish prints and saves its session URL as http://<link host>:<port>/session/<id>,
# and a phone browser that forces https for tailnet names cannot open it. When
# this host's `tailscale serve` publishes an HTTPS origin whose root proxies to
# that Lavish port on loopback, the session is reachable at
# https://<serve name>[:<serve port>]/session/<id>, and that is the URL firstmate
# prints or passes on. The serve config is the authority (declared in the host's
# own configuration, read live with `tailscale serve status --json`), so nothing
# here names a host or port.
#
# A URL is rewritten only when its host is the serve name or a loopback address
# and a serve origin proxies its port; anything else - no tailscale, no serve
# entry, another port, a non-session URL - passes through unchanged, so this
# never turns a working link into a broken one. Lavish's own saved session URL
# is left alone: bin/fm-procevent-lavish.sh reads the server address from it.
#
# Usage:
#   fm-lavish-url.sh <url>...   Print each URL in its phone-openable form.
#   fm-lavish-url.sh            Copy stdin to stdout, rewriting every Lavish
#                               session URL in the text.
#
# FM_TAILSCALE names the only tailscale CLI to use; unset, it is tailscale on
# PATH, then the macOS app's bundled CLI. The serve read is bounded to 5 seconds.
set -u

case "${1-}" in
  -h|--help)
    awk 'NR == 1 { next } /^set -u/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

tailscale_cli() {
  local cli
  local -a candidates=(tailscale /Applications/Tailscale.app/Contents/MacOS/tailscale)
  [ -z "${FM_TAILSCALE:-}" ] || candidates=("$FM_TAILSCALE")
  for cli in "${candidates[@]}"; do
    command -v "$cli" >/dev/null 2>&1 && { printf '%s\n' "$cli"; return 0; }
  done
  return 1
}

# One "<lavish port>\t<serve name>\t<serve port>" line per HTTPS serve origin
# whose root proxies to a loopback port, or nothing.
serve_map() {
  local cli json
  cli=$(tailscale_cli) || return 0
  json=$(perl -e 'alarm shift; exec @ARGV' 5 "$cli" serve status --json 2>/dev/null) || return 0
  printf '%s' "$json" | jq -r '
    . as $root
    | ($root.Web // {}) | to_entries[]
    | (.key | capture("^(?<name>[A-Za-z0-9.-]+):(?<port>[0-9]+)$")?) as $origin
    | select($origin != null)
    | select($root.TCP[$origin.port].HTTPS == true)
    | (.value.Handlers["/"].Proxy // "" | capture("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\]):(?<port>[0-9]+)/?$")?) as $target
    | select($target != null)
    | [$target.port, ($origin.name | ascii_downcase), $origin.port] | @tsv
  ' 2>/dev/null || true
}

MAP=$(serve_map)

rewrite() {
  FM_LAVISH_SERVE_MAP=$MAP perl -pe '
    BEGIN {
      our %serve;
      for my $line (split /\n/, $ENV{FM_LAVISH_SERVE_MAP} // "") {
        my ($port, $name, $public) = split /\t/, $line;
        $serve{$port} = [$name, $public] if defined $public && !exists $serve{$port};
      }
    }
    s{\bhttp://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):([0-9]+)(/session/[0-9a-f]{16}(?:\?[^\s"\x27<>`]*)?)}{
      my ($host, $port, $path) = ($1, $2, $3);
      my $entry = $serve{$port};
      if ($entry && (lc($host) eq $entry->[0] || $host =~ /\A(?:127\.0\.0\.1|localhost|\[::1\])\z/)) {
        "https://" . $entry->[0] . ($entry->[1] eq "443" ? "" : ":" . $entry->[1]) . $path;
      } else {
        "http://$host:$port$path";
      }
    }ge;
  '
}

if [ "$#" -gt 0 ]; then
  printf '%s\n' "$@" | rewrite
else
  rewrite
fi
