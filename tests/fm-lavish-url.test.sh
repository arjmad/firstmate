#!/usr/bin/env bash
# Behavior tests for bin/fm-lavish-url.sh: a Lavish session URL becomes the
# tailnet HTTPS origin `tailscale serve` publishes for its port, read from a
# fake tailscale CLI, and every other URL passes through unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

URL_SH="$ROOT/bin/fm-lavish-url.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-url)
command -v jq >/dev/null 2>&1 || fail "fm-lavish-url.sh reads tailscale's JSON with jq, which was not found"

NAME=heimdall.tail0000.ts.net
SESSION=0123456789abcdef

# A fake tailscale whose `serve status --json` prints <dir>/serve.json, or
# fails when that file is absent.
FAKE="$TMP_ROOT/tailscale"
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
[ "$*" = "serve status --json" ] || exit 2
[ -f "$FM_TEST_SERVE" ] || exit 1
cat "$FM_TEST_SERVE"
SH
chmod +x "$FAKE"

# The serve config Heimdall declares: Lavish's 4387 behind HTTPS 8443, plus an
# unrelated service, a plain-HTTP origin, and a non-loopback proxy.
SERVE="$TMP_ROOT/serve.json"
jq -n --arg n "$NAME" '{
  TCP: {"8443": {HTTPS: true}, "8787": {HTTPS: true}, "9000": {HTTP: true}, "9443": {HTTPS: true}},
  Web: {
    ($n + ":8443"): {Handlers: {"/": {Proxy: "http://127.0.0.1:4387"}}},
    ($n + ":8787"): {Handlers: {"/": {Proxy: "http://127.0.0.1:8787"}}},
    ($n + ":9000"): {Handlers: {"/": {Proxy: "http://127.0.0.1:5000"}}},
    ($n + ":9443"): {Handlers: {"/": {Proxy: "http://10.0.0.5:6000"}}}
  }
}' > "$SERVE"

run_url() {  # <args>...; stdin passes through
  FM_TAILSCALE="$FAKE" FM_TEST_SERVE="$SERVE" "$URL_SH" "$@"
}

test_session_url_takes_the_serve_origin() {
  local out
  out=$(run_url "http://$NAME:4387/session/$SESSION")
  [ "$out" = "https://$NAME:8443/session/$SESSION" ] || fail "MagicDNS session URL was not rewritten: $out"
  out=$(run_url "http://127.0.0.1:4387/session/$SESSION?nogate=1")
  [ "$out" = "https://$NAME:8443/session/$SESSION?nogate=1" ] || fail "loopback session URL with a query was not rewritten: $out"
  out=$(run_url "http://HEIMDALL.tail0000.ts.net:4387/session/$SESSION")
  [ "$out" = "https://$NAME:8443/session/$SESSION" ] || fail "host case changed the verdict: $out"
  pass "a Lavish session URL on a served port takes the tailnet HTTPS origin"
}

test_other_urls_pass_through() {
  local url out
  for url in \
    "http://$NAME:9999/session/$SESSION" \
    "http://other.example:4387/session/$SESSION" \
    "http://$NAME:4387/" \
    "http://$NAME:5000/session/$SESSION" \
    "http://$NAME:6000/session/$SESSION" \
    "https://$NAME:8443/session/$SESSION" \
    "http://$NAME:4387/session/not-a-session"; do
    out=$(run_url "$url")
    [ "$out" = "$url" ] || fail "$url was rewritten to $out"
  done
  pass "an unserved port, another host, a plain-HTTP or non-loopback origin, and a non-session URL pass through"
}

test_text_on_stdin_rewrites_every_session_url() {
  local out
  out=$(printf 'board: /tmp/b.html\n  b.html,open,"http://%s:4387/session/%s",0\nsee http://127.0.0.1:4387/session/%s and http://x.example/\n' \
    "$NAME" "$SESSION" "$SESSION" | run_url)
  assert_contains "$out" "\"https://$NAME:8443/session/$SESSION\",0" "the quoted listing URL was not rewritten"
  assert_contains "$out" "see https://$NAME:8443/session/$SESSION and http://x.example/" "the inline URL was not rewritten"
  assert_contains "$out" "board: /tmp/b.html" "other lines changed"
  pass "stdin text keeps its shape while each session URL is rewritten"
}

test_no_tailscale_or_serve_changes_nothing() {
  local url="http://$NAME:4387/session/$SESSION" out
  out=$(FM_TAILSCALE="$TMP_ROOT/missing" "$URL_SH" "$url")
  [ "$out" = "$url" ] || fail "a missing tailscale CLI changed the URL: $out"
  out=$(FM_TAILSCALE="$FAKE" FM_TEST_SERVE="$TMP_ROOT/no-serve.json" "$URL_SH" "$url")
  [ "$out" = "$url" ] || fail "a failed serve read changed the URL: $out"
  printf 'not json' > "$TMP_ROOT/bad.json"
  out=$(FM_TAILSCALE="$FAKE" FM_TEST_SERVE="$TMP_ROOT/bad.json" "$URL_SH" "$url")
  [ "$out" = "$url" ] || fail "unreadable serve JSON changed the URL: $out"
  pass "with no tailscale, no serve config, or unreadable JSON the URL is unchanged"
}

test_port_443_origin_has_no_port() {
  local out serve="$TMP_ROOT/serve-443.json"
  jq -n --arg n "$NAME" '{TCP: {"443": {HTTPS: true}}, Web: {($n + ":443"): {Handlers: {"/": {Proxy: "http://localhost:4387/"}}}}}' > "$serve"
  out=$(FM_TAILSCALE="$FAKE" FM_TEST_SERVE="$serve" "$URL_SH" "http://$NAME:4387/session/$SESSION")
  [ "$out" = "https://$NAME/session/$SESSION" ] || fail "a 443 origin kept its port: $out"
  pass "an origin on 443 prints without a port"
}

test_funnel_origin_is_never_handed_out() {
  local out serve="$TMP_ROOT/serve-funnel.json"
  jq --arg n "$NAME" '. + {AllowFunnel: {($n + ":8443"): true}}' "$SERVE" > "$serve"
  out=$(FM_TAILSCALE="$FAKE" FM_TEST_SERVE="$serve" "$URL_SH" "http://$NAME:4387/session/$SESSION")
  [ "$out" = "http://$NAME:4387/session/$SESSION" ] || fail "a Funnel (public) origin was handed out: $out"
  pass "a serve origin with Funnel on is never used"
}

test_text_without_a_session_url_skips_tailscale() {
  local out log="$TMP_ROOT/calls.log" fake="$TMP_ROOT/tailscale-logged"
  printf '#!/usr/bin/env bash\nprintf x >> %q\nexit 1\n' "$log" > "$fake"
  chmod +x "$fake"
  out=$(printf 'board: /tmp/b.html\nsession: live\n' | FM_TAILSCALE="$fake" "$URL_SH")
  [ "$out" = "$(printf 'board: /tmp/b.html\nsession: live')" ] || fail "text without a session URL changed: $out"
  [ ! -e "$log" ] || fail "tailscale was read for text with no session URL"
  pass "text with no session URL passes through without reading tailscale"
}

test_session_url_takes_the_serve_origin
test_other_urls_pass_through
test_text_on_stdin_rewrites_every_session_url
test_no_tailscale_or_serve_changes_nothing
test_port_443_origin_has_no_port
test_funnel_origin_is_never_handed_out
test_text_without_a_session_url_skips_tailscale
