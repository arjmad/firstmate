#!/usr/bin/env bash
# tests/fm-lavish-patch.test.sh - firstmate's local overlay on lavish-axi's
# browser chrome, owned by bin/fm-lavish-patch.mjs, and its two seats in
# bin/fm-bootstrap.sh (the locked session-start pass and `install lavish-axi`).
#
# The guarantees under test:
#   - apply appends the overlay to an upstream dist/chrome.css and
#     dist/chrome-client.js found through the PATH symlink npm installs, says so
#     once, keeps each file's mode, and leaves valid JavaScript.
#   - A second apply is silent and changes nothing; an older overlay revision
#     is replaced, never stacked.
#   - remove restores upstream's bytes exactly, including a file that had no
#     trailing newline.
#   - Fail closed: when upstream no longer carries what the overlay relies on,
#     or ships its own panel collapse, apply prints one LAVISH_PATCH skip line,
#     exits 3, and writes nothing.
#   - No lavish-axi package on PATH (absent, or a stub that is not an npm
#     install) is silent, and FM_LAVISH_PATCH=0 turns apply off.
#   - Bootstrap applies it on the locked local pass only, converges silently,
#     and applies it straight after `install lavish-axi`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-lavish-patch)
PATCH="$ROOT/bin/fm-lavish-patch.mjs"

# patch <prefix> <args...>: run the patch with only <prefix>/bin ahead of the
# base PATH, the way a home's toolchain prefix sits on the login PATH.
patch() {
  local prefix=$1
  shift
  env -u FM_LAVISH_PATCH_PACKAGE -u FM_LAVISH_PATCH PATH="$prefix/bin:$BASE_PATH" "$prefix/bin/node" "$PATCH" "$@"
}

new_package() {  # <case> [version] -> echoes the toolchain prefix
  local prefix="$TMP_ROOT/$1"
  fm_fake_lavish_package "$prefix" "${2:-0.1.90}" >/dev/null || fail "could not build the fake lavish-axi package"
  printf '%s\n' "$prefix"
}

dist() {  # <prefix>
  printf '%s\n' "$1/lib/node_modules/lavish-axi/dist"
}

snapshot() {  # <prefix> <dir>: copy both patched files aside
  mkdir -p "$2"
  cp -p "$(dist "$1")/chrome.css" "$(dist "$1")/chrome-client.js" "$2/"
}

same_files() {  # <prefix> <dir>
  cmp -s "$(dist "$1")/chrome.css" "$2/chrome.css" && cmp -s "$(dist "$1")/chrome-client.js" "$2/chrome-client.js"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

test_apply_appends_the_overlay_once() {
  local prefix out rc pristine
  prefix=$(new_package apply)
  pristine="$TMP_ROOT/apply-pristine"
  snapshot "$prefix" "$pristine"
  assert_equals "unpatched 0.1.90" "$(patch "$prefix" status)" "a fresh install reads as unpatched"

  out=$(patch "$prefix" apply); rc=$?
  expect_code 0 "$rc" "apply"
  assert_equals "BOOTSTRAP_INFO: lavish-axi 0.1.90 chrome patch applied" "$out" "apply should report the write once"
  assert_equals "applied 0.1.90" "$(patch "$prefix" status)" "status after apply"
  for f in chrome.css chrome-client.js; do
    head -c "$(wc -c < "$pristine/$f")" "$(dist "$prefix")/$f" | cmp -s - "$pristine/$f" \
      || fail "apply must keep upstream's $f content ahead of the overlay"
    assert_contains "$(cat "$(dist "$prefix")/$f")" "$(cat "$ROOT/bin/lavish-patch/$f")" "apply should append the $f overlay"
    assert_equals 640 "$(file_mode "$(dist "$prefix")/$f")" "apply should keep $f's mode"
  done
  "$prefix/bin/node" --check "$(dist "$prefix")/chrome-client.js" || fail "the patched chrome-client.js must stay valid JavaScript"

  snapshot "$prefix" "$TMP_ROOT/apply-once"
  out=$(patch "$prefix" apply); rc=$?
  expect_code 0 "$rc" "second apply"
  assert_equals "" "$out" "a second apply must be silent"
  same_files "$prefix" "$TMP_ROOT/apply-once" || fail "a second apply must not change either file"
  pass "apply: appends the overlay once, keeps upstream bytes and modes, then stays silent"
}

test_older_revision_is_replaced_not_stacked() {
  local prefix old out
  prefix=$(new_package stale)
  # An older firstmate checkout: the same script with a different overlay.
  old="$TMP_ROOT/old-checkout/bin"
  mkdir -p "$old/lavish-patch"
  cp "$PATCH" "$old/"
  printf '/* an older overlay revision */\n' > "$old/lavish-patch/chrome.css"
  printf '// an older overlay revision\n' > "$old/lavish-patch/chrome-client.js"
  env PATH="$prefix/bin:$BASE_PATH" "$prefix/bin/node" "$old/fm-lavish-patch.mjs" apply >/dev/null
  assert_equals "stale 0.1.90" "$(patch "$prefix" status)" "an older overlay revision reads as stale"

  out=$(patch "$prefix" apply)
  assert_equals "BOOTSTRAP_INFO: lavish-axi 0.1.90 chrome patch applied" "$out" "apply over a stale revision"
  assert_not_contains "$(cat "$(dist "$prefix")/chrome.css" "$(dist "$prefix")/chrome-client.js")" "older overlay revision" \
    "the older revision must be replaced"
  patch "$prefix" remove >/dev/null
  assert_equals "unpatched 0.1.90" "$(patch "$prefix" status)" "remove after a replaced revision"
  pass "apply: an older overlay revision is replaced, never stacked"
}

test_remove_restores_upstream_bytes() {
  local prefix pristine
  prefix=$(new_package remove)
  # Upstream's file need not end with a newline; the overlay must not eat or add one.
  printf 'const panel = document.getElementById("panel");' > "$(dist "$prefix")/chrome-client.js"
  pristine="$TMP_ROOT/remove-pristine"
  snapshot "$prefix" "$pristine"
  patch "$prefix" apply >/dev/null
  assert_equals "removed 0.1.90" "$(patch "$prefix" remove)" "remove reports what it stripped"
  same_files "$prefix" "$pristine" || fail "remove must restore upstream's bytes exactly"
  assert_equals 640 "$(file_mode "$(dist "$prefix")/chrome.css")" "remove should keep the mode"
  assert_equals "unpatched 0.1.90" "$(patch "$prefix" remove)" "a second remove has nothing to strip"
  pass "remove: restores upstream's exact bytes, with or without a trailing newline"
}

test_fails_closed_when_upstream_moved() {
  local prefix out rc pristine
  prefix=$(new_package moved 0.2.0)
  sed 's/var(--panel-w)/var(--conversation-width)/' "$(dist "$prefix")/chrome.css" > "$TMP_ROOT/moved.css"
  cat "$TMP_ROOT/moved.css" > "$(dist "$prefix")/chrome.css"
  pristine="$TMP_ROOT/moved-pristine"
  snapshot "$prefix" "$pristine"
  out=$(patch "$prefix" apply); rc=$?
  expect_code 3 "$rc" "apply on a moved upstream"
  assert_contains "$out" "LAVISH_PATCH: skipped: lavish-axi 0.2.0 dist/chrome.css no longer contains" "a moved upstream is one skip line"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the skip is exactly one line"
  same_files "$prefix" "$pristine" || fail "a skipped apply must write nothing"
  assert_contains "$(patch "$prefix" status)" "incompatible 0.2.0:" "status names the incompatibility"

  prefix=$(new_package template 0.2.0)
  sed 's/id="moreWrap"/id="overflowMenu"/' "$(dist "$prefix")/cli.mjs" > "$TMP_ROOT/template.mjs"
  cat "$TMP_ROOT/template.mjs" > "$(dist "$prefix")/cli.mjs"
  out=$(patch "$prefix" apply); rc=$?
  expect_code 3 "$rc" "apply on a changed chrome template"
  assert_contains "$out" "LAVISH_PATCH: skipped: lavish-axi 0.2.0 dist/cli.mjs no longer contains" "a changed template is a skip"
  pass "apply: fails closed with one skip line when upstream no longer matches"
}

test_steps_aside_when_upstream_ships_collapse() {
  local prefix out rc pristine
  prefix=$(new_package upstreamed 0.2.0)
  printf '%s\n' 'var toggle = '"'"'<button class="sidebar-toggle" id="sidebarToggle"></button>'"'"';' >> "$(dist "$prefix")/cli.mjs"
  pristine="$TMP_ROOT/upstreamed-pristine"
  snapshot "$prefix" "$pristine"
  out=$(patch "$prefix" apply); rc=$?
  expect_code 3 "$rc" "apply once upstream ships a collapse"
  assert_contains "$out" "ships its own conversation-panel collapse" "an upstream collapse is reported"
  assert_contains "$out" "drop this patch" "the skip says the patch can be dropped"
  same_files "$prefix" "$pristine" || fail "apply must not layer a second collapse over upstream's"
  pass "apply: steps aside once upstream ships its own panel collapse"
}

test_absent_and_disabled_are_silent() {
  local stub out rc prefix
  stub="$TMP_ROOT/stub/bin"
  mkdir -p "$stub"
  fm_fake_version_tool "$stub" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.90
  ln -sf "$(command -v node)" "$stub/node"
  out=$(env -u FM_LAVISH_PATCH_PACKAGE PATH="$stub:$BASE_PATH" "$stub/node" "$PATCH" apply); rc=$?
  expect_code 0 "$rc" "apply with a non-npm lavish-axi"
  assert_equals "" "$out" "a lavish-axi that is not an npm package is silent"
  assert_equals "absent" "$(env -u FM_LAVISH_PATCH_PACKAGE PATH="$stub:$BASE_PATH" "$stub/node" "$PATCH" status)" "status without a package"
  rm -f "$stub/lavish-axi"
  assert_equals "" "$(env -u FM_LAVISH_PATCH_PACKAGE PATH="$stub:$BASE_PATH" "$stub/node" "$PATCH" apply)" "no lavish-axi at all is silent"

  prefix=$(new_package disabled)
  out=$(env FM_LAVISH_PATCH=0 PATH="$prefix/bin:$BASE_PATH" "$prefix/bin/node" "$PATCH" apply); rc=$?
  expect_code 0 "$rc" "disabled apply"
  assert_equals "" "$out" "FM_LAVISH_PATCH=0 is silent"
  assert_equals "unpatched 0.1.90" "$(patch "$prefix" status)" "FM_LAVISH_PATCH=0 writes nothing"
  pass "apply: no package and FM_LAVISH_PATCH=0 are silent no-ops"
}

# run_bootstrap <prefix> <home> [env...]: bootstrap with every tool faked
# except node and the fake lavish-axi package, local phase only.
run_bootstrap() {
  local prefix=$1 home=$2 fakebin
  shift 2
  fakebin="$TMP_ROOT/bootstrap-fakebin"
  if [ ! -d "$fakebin" ]; then
    mkdir -p "$fakebin"
    fm_fake_exit0 "$fakebin" tmux chrome-devtools-axi gh treehouse no-mistakes gh-axi tasks-axi quota-axi herdr
  fi
  env FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip PATH="$prefix/bin:$fakebin:$BASE_PATH" "$@" \
    bash "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_applies_on_the_locked_pass_only() {
  local prefix home out
  prefix=$(new_package bootstrap)
  home="$TMP_ROOT/bootstrap-home"
  mkdir -p "$home/state" "$home/data" "$home/config"

  out=$(run_bootstrap "$prefix" "$home" FM_BOOTSTRAP_DETECT_ONLY=1)
  assert_not_contains "$out" "chrome patch" "a read-only session must not patch Lavish: $out"
  assert_equals "unpatched 0.1.90" "$(patch "$prefix" status)" "detect-only wrote nothing"

  out=$(run_bootstrap "$prefix" "$home")
  assert_contains "$out" "BOOTSTRAP_INFO: lavish-axi 0.1.90 chrome patch applied" "the locked local pass applies the patch: $out"
  out=$(run_bootstrap "$prefix" "$home")
  assert_not_contains "$out" "chrome patch" "a patched install keeps bootstrap silent: $out"
  assert_not_contains "$out" "LAVISH_PATCH" "a patched install keeps bootstrap silent: $out"
  pass "bootstrap: patches Lavish on the locked local pass only and converges silently"
}

test_bootstrap_install_applies_after_installing() {
  local prefix home fakebin out
  prefix=$(new_package install)
  home="$TMP_ROOT/install-home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin="$TMP_ROOT/install-fakebin"
  mkdir -p "$fakebin"
  fm_fake_exit0 "$fakebin" npm
  out=$(env FM_HOME="$home" PATH="$prefix/bin:$fakebin:$BASE_PATH" bash "$ROOT/bin/fm-bootstrap.sh" install lavish-axi 2>&1)
  assert_contains "$out" "installing lavish-axi:" "install runs the install command: $out"
  assert_contains "$out" "BOOTSTRAP_INFO: lavish-axi 0.1.90 chrome patch applied" "install applies the patch: $out"
  assert_equals "applied 0.1.90" "$(patch "$prefix" status)" "status after install"
  pass "bootstrap: install lavish-axi applies the chrome patch straight away"
}

test_apply_appends_the_overlay_once
test_older_revision_is_replaced_not_stacked
test_remove_restores_upstream_bytes
test_fails_closed_when_upstream_moved
test_steps_aside_when_upstream_ships_collapse
test_absent_and_disabled_are_silent
test_bootstrap_applies_on_the_locked_pass_only
test_bootstrap_install_applies_after_installing
