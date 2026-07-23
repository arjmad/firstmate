#!/usr/bin/env bash
# Isolated real-Herdr E2E coverage for opt-in fleet workspace create, join,
# focus preservation, grid growth, and final recorded workspace retirement.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-fleet.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
mkdir -p "$FAKEBIN" "$STATE_DIR" "$TMP_ROOT/cwd-1" "$TMP_ROOT/cwd-2" "$TMP_ROOT/cwd-3" "$TMP_ROOT/cwd-4"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fleetview-titles-b29)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
trap 'PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"; rm -rf "$TMP_ROOT"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision the isolated Herdr lab"

# Route every production-adapter Herdr call through the guarded lab helper.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
   && [ "${args[$flag]}" = --session ] \
   && [ "${args[$last]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in
    --session|--session=*)
      echo "test wrapper: unexpected caller-supplied session flag" >&2
      exit 1
      ;;
  esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() {
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

CAPTAIN_JSON=$(lab workspace create --cwd "$TMP_ROOT" --label captain-control --no-focus) \
  || fail "could not create the lab control workspace"
CAPTAIN_WORKSPACE=$(printf '%s' "$CAPTAIN_JSON" | jq -r '.result.workspace.workspace_id // empty')
CAPTAIN_TAB=$(printf '%s' "$CAPTAIN_JSON" | jq -r '.result.tab.tab_id // empty')
[ -n "$CAPTAIN_WORKSPACE" ] && [ -n "$CAPTAIN_TAB" ] || fail "control workspace response lacked exact IDs"
lab tab focus "$CAPTAIN_TAB" >/dev/null || fail "could not focus the lab control tab"

export PATH="$FAKEBIN:$PATH"
export FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

FOCUS_BEFORE=$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION") \
  || fail "could not capture the control focus before fleet creation"
[ "$FOCUS_BEFORE" = "$CAPTAIN_WORKSPACE"$'\t'"$CAPTAIN_TAB" ] \
  || fail "unexpected initial control focus: $FOCUS_BEFORE"

PANES=()
for index in 1 2 3 4; do
  fm_backend_herdr_fleet_create_or_join "$STATE_DIR" batch "$TMP_ROOT/cwd-$index" \
    || fail "fleet member $index did not create or join"
  PANES+=("$FM_BACKEND_HERDR_FLEET_PANE_ID")
  fm_backend_herdr_set_task_display \
    "$FM_BACKEND_HERDR_FLEET_SESSION" "$FM_BACKEND_HERDR_FLEET_PANE_ID" \
    "member-$index · gpt-5.6-sol" gpt-5.6-sol || fail "fleet member $index display metadata failed"
done

[ "${PANES[0]}" != "${PANES[1]}" ] \
  && [ "${PANES[1]}" != "${PANES[2]}" ] \
  && [ "${PANES[2]}" != "${PANES[3]}" ] \
  || fail "fleet members did not receive unique pane IDs"

RECORD="$STATE_DIR/.herdr-fleet-batch"
[ -f "$RECORD" ] || fail "fleet create did not publish the durable record"
grep -Fx 'state=active' "$RECORD" >/dev/null || fail "fleet record is not active"

LAYOUT=$(lab pane layout --pane "${PANES[0]}") || fail "could not inspect the real fleet layout"
PANE_COUNT=$(printf '%s' "$LAYOUT" | jq -r '.result.layout.panes | length')
[ "$PANE_COUNT" = 4 ] || fail "expected four panes in the fleet grid, got $PANE_COUNT"
WORKSPACE_COUNT=$(lab workspace list | jq -r '[.result.workspaces[] | select(.label | startswith("firstmate/fleet-batch · f:"))] | length')
[ "$WORKSPACE_COUNT" = 1 ] || fail "expected exactly one token-bearing fleet workspace, got $WORKSPACE_COUNT"

FOCUS_AFTER=$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION") \
  || fail "could not capture focus after fleet joins"
[ "$FOCUS_AFTER" = "$FOCUS_BEFORE" ] || fail "fleet create/join changed focus from $FOCUS_BEFORE to $FOCUS_AFTER"
pass "real Herdr fleet create and three joins produce one four-pane grid without focus drift"

for pane in "${PANES[@]}"; do
  fm_backend_herdr_fleet_close_pane_focus_preserving "$HERDR_LAB_SESSION" "$pane" \
    || fail "could not close exact fleet pane $pane"
done
fm_backend_herdr_fleet_prune_recorded_workspace \
  "$RECORD" batch "$HERDR_LAB_SESSION" \
  "$FM_BACKEND_HERDR_FLEET_WORKSPACE_ID" "$FM_BACKEND_HERDR_FLEET_TAB_ID" \
  || fail "could not retire the recorded fleet workspace"
[ ! -e "$RECORD" ] || fail "fleet record remained after confirmed final workspace removal"

FOCUS_FINAL=$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION") \
  || fail "could not capture focus after fleet cleanup"
[ "$FOCUS_FINAL" = "$FOCUS_BEFORE" ] || fail "fleet cleanup changed focus from $FOCUS_BEFORE to $FOCUS_FINAL"
pass "real Herdr exact-pane cleanup removes the recorded fleet workspace and preserves focus"

VERSION=$(lab status --json | jq -r '.client.version // "unknown"')
printf 'evidence: herdr=%s panes=%s session=%s\n' "$VERSION" "$PANE_COUNT" "$HERDR_LAB_SESSION"
