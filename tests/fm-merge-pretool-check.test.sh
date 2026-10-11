#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2088
# Behavior tests for the merge-guard PreToolUse seatbelt (docs/merge-guard.md).
#
# bin/fm-merge-command-policy.mjs is the single owner of the block/allow
# decision; it reuses the shell classifier owned by
# bin/fm-arm-command-policy.mjs. bin/fm-merge-pretool-check.sh is the stable
# transport: it scopes the guard to a primary home through
# bin/fm-primary-scope-lib.sh, then drives every harness entry form. This suite
# proves the decision matrix, the harness-output shaping, the primary-home
# scoping, the fail-open transport behavior, the prefilter fast path, the
# end-to-end raw-merge regression, and each tracked harness registration by
# running the registered hook or extension against a primary-shaped fixture.
# No model is prompted; live per-harness evidence lives in docs/merge-guard.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-merge-pretool-check)

# A primary-shaped home: plain (non-worktree) git repo, AGENTS.md, and bin/
# with the transport, its two sourced libraries, and both policy files
# (fm-merge-command-policy.mjs imports the shared classifier).
install_merge_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-merge-pretool-check.sh" "$ROOT/bin/fm-hook-host-lib.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-merge-command-policy.mjs" \
    "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  chmod +x "$dir/bin/fm-merge-pretool-check.sh" "$dir/bin/fm-merge-command-policy.mjs"
}

make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_merge_scripts "$dir"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree - the shape bin/fm-spawn.sh hands crewmate and
# scout tasks. Without a secondmate marker the guard must be inert there.
make_linked_worktree_fixture() {
  local base=$1 dir=$2 branch=$3
  fm_git_worktree "$base" "$dir" "$branch"
  : > "$dir/AGENTS.md"
  install_merge_scripts "$dir"
  printf '%s\n' "$dir"
}

PRIMARY=$(make_primary_fixture "$TMP_ROOT/primary")
CHECK="$PRIMARY/bin/fm-merge-pretool-check.sh"
MERGE_PAYLOAD_COMMAND='gh-axi pr merge https://github.com/arjmad/nova/pull/148 --squash'

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

# BLOCK: a raw GitHub CLI merge that bypasses bin/fm-pr-merge.sh.
matrix_case B01 deny 'gh pr merge 148'
matrix_case B02 deny "$MERGE_PAYLOAD_COMMAND"
matrix_case B03 deny 'gh pr merge https://github.com/arjmad/nova/pull/148 --squash --delete-branch'
matrix_case B04 deny 'gh -R arjmad/nova pr merge 148'
matrix_case B05 deny 'gh pr -R arjmad/nova merge 148'
matrix_case B06 deny 'gh pr merge --auto --squash 148'
matrix_case B07 deny '/opt/homebrew/bin/gh pr merge 148'
matrix_case B08 deny '~/.local/state/firstmate/toolchain/bin/gh-axi pr merge 148'
matrix_case B09 deny 'GH_TOKEN=x gh pr merge 148'
matrix_case B10 deny 'env GH_TOKEN=x gh pr merge 148'
matrix_case B11 deny 'command gh pr merge 148'
matrix_case B12 deny 'timeout 30 gh pr merge 148'
matrix_case B13 deny 'gh pr view 148 && gh pr merge 148 --squash'
matrix_case B14 deny 'gh pr merge 148 | tee merge.log'
matrix_case B15 deny '(cd projects/nova && gh pr merge 148)'
matrix_case B16 deny "bash -c 'gh pr merge 148'"
matrix_case B17 deny "eval 'gh pr merge 148'"
matrix_case B18 deny 'out=$(gh pr merge 148)'
matrix_case B19 deny 'g"h" pr merge 148'
matrix_case B20 deny "gh pr \$'\\x6derge' 148"
matrix_case B21 deny $'gh pr view 148\ngh pr merge 148'
matrix_case B22 deny 'gh api -X PUT repos/arjmad/nova/pulls/148/merge'
matrix_case B23 deny 'gh api --method PUT /repos/arjmad/nova/pulls/148/merge -f merge_method=squash'
matrix_case B24 deny 'gh api repos/arjmad/nova/pulls/148/merge -f merge_method=squash'
matrix_case B25 deny 'gh api -XPUT repos/{owner}/{repo}/pulls/148/merge'
matrix_case B26 deny 'gh api --method=put repos/arjmad/nova/pulls/148/merge'
matrix_case B27 deny "gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:\"x\"}) { clientMutationId } }'"
matrix_case B28 deny "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input:{pullRequestId:\"x\"}) { clientMutationId } }'"
matrix_case B29 deny "gh api graphql -f query='mutation { enqueuePullRequest(input:{pullRequestId:\"x\"}) { clientMutationId } }'"

# ALLOW: the sanctioned merge paths, reads, and the token merge as data.
matrix_case A01 allow 'bin/fm-pr-merge.sh nova-148 https://github.com/arjmad/nova/pull/148'
matrix_case A02 allow '~/nix/bin/brain-managed-refresh arjun --merge-pr 12'
matrix_case A03 allow 'gh pr view 148'
matrix_case A04 allow 'gh-axi pr view 148'
matrix_case A05 allow 'gh pr list --search merge'
matrix_case A06 allow 'gh pr merge --help'
matrix_case A07 allow 'gh pr merge 148 --disable-auto'
matrix_case A08 allow 'gh api repos/arjmad/nova/pulls/148/merge'
matrix_case A09 allow 'gh api -X GET repos/arjmad/nova/pulls/148/merge'
matrix_case A10 allow 'gh api repos/arjmad/nova/pulls/148'
matrix_case A11 allow "gh api graphql -f query='query { repository(owner:\"o\",name:\"r\") { pullRequest(number:1) { mergeable } } }'"
matrix_case A12 allow 'echo "gh pr merge 148"'
matrix_case A13 allow "grep -rn 'gh pr merge' docs"
matrix_case A14 allow "printf '%s\\n' 'gh pr merge 148'"
matrix_case A15 allow 'git merge main'
matrix_case A16 allow 'git merge-base HEAD main'
matrix_case A17 allow 'gh issue merge 148'
matrix_case A18 allow 'gh pr status'
matrix_case A19 allow 'git status'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-merge-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    cursor)
      payload=$(jq -cn --arg command "$cmd" '{cursor_version:"1.0",tool_name:"Shell",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --cursor >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  if [ "$entry" = cursor ]; then
    [ "$rc" -eq 0 ] || fail "$id via cursor deny must exit 0, got $rc"
    jq -e '.permission == "deny" and (.user_message | test("\\[raw-pr-merge\\]"))' "$out_file" >/dev/null 2>&1 \
      || fail "$id via cursor deny must print Cursor's decision object: $(cat "$out_file")"
    return
  fi
  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[raw-pr-merge\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the raw-pr-merge reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok cursor opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "merge-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 6 harness entry forms, block/allow all correct"
}

# --- refusal text -----------------------------------------------------------

test_refusal_names_sanctioned_paths() {
  local out rc message
  out=$("$CHECK" --claude --command "$MERGE_PAYLOAD_COMMAND" 2>&1); rc=$?
  expect_code 2 "$rc" "the guard must deny the raw merge"
  message=$(printf '%s' "$out" | jq -r '.systemMessage')
  assert_contains "$message" 'bin/fm-pr-merge.sh <task> <pr-url>' "refusal must name the sanctioned merge script"
  assert_contains "$message" 'brain-managed-refresh arjun --merge-pr <n>' "refusal must name the brain PR merge path"
  [ "$(printf '%s\n' "$message" | wc -l | tr -d ' ')" = 1 ] || fail "refusal must be one line: $message"
  pass "merge-guard: one-line refusal names bin/fm-pr-merge.sh and brain-managed-refresh"
}

# --- primary-home scoping ---------------------------------------------------

expect_fires() {  # <dir> <label>
  local out rc
  out=$("$1/bin/fm-merge-pretool-check.sh" --claude --command 'gh pr merge 148' 2>&1); rc=$?
  expect_code 2 "$rc" "$2"
  assert_contains "$out" '[raw-pr-merge]' "$2 must carry the reason code"
}

expect_inert() {  # <dir> <label>
  local out rc
  out=$("$1/bin/fm-merge-pretool-check.sh" --claude --command 'gh pr merge 148' 2>&1); rc=$?
  expect_code 0 "$rc" "$2"
  [ -z "$out" ] || fail "$2 produced output: $out"
}

test_fires_in_secondmate_homes() {
  local plain linked
  plain=$(make_primary_fixture "$TMP_ROOT/secondmate-plain")
  printf 'sm-merge-1\n' > "$plain/.fm-secondmate-home"
  expect_fires "$plain" "a git-cloned secondmate home is a primary home"
  linked=$(make_linked_worktree_fixture "$TMP_ROOT/secondmate-base" "$TMP_ROOT/secondmate-linked" fm/secondmate-lease)
  printf 'sm-merge-2\n' > "$linked/.fm-secondmate-home"
  expect_fires "$linked" "a treehouse-leased secondmate home is a primary home"
  pass "merge-guard: fires in secondmate homes, plain clone or linked worktree"
}

test_inert_in_child_worktrees() {
  local child marked
  child=$(make_linked_worktree_fixture "$TMP_ROOT/child-base" "$TMP_ROOT/child-wt" fm/merge-guard-test)
  expect_inert "$child" "a crewmate/scout linked worktree must stay inert"
  marked=$(make_linked_worktree_fixture "$TMP_ROOT/child2-base" "$TMP_ROOT/child2-wt" fm/merge-guard-test-2)
  printf 'bad marker!\n' > "$marked/.fm-secondmate-home"
  expect_inert "$marked" "an invalid secondmate marker must not pull a worktree into scope"
  pass "merge-guard: inert in crewmate/scout task worktrees"
}

test_inert_outside_firstmate() {
  local repo nogit
  repo="$TMP_ROOT/not-firstmate"
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  install_merge_scripts "$repo"
  expect_inert "$repo" "a repo without AGENTS.md is not a firstmate home"
  nogit="$TMP_ROOT/no-git"
  mkdir -p "$nogit"
  : > "$nogit/AGENTS.md"
  install_merge_scripts "$nogit"
  expect_inert "$nogit" "a directory outside git is not a firstmate home"
  pass "merge-guard: inert outside a firstmate checkout and outside git"
}

# --- end-to-end raw-merge regression ---------------------------------------

# A fake gh records every merge it receives. Run directly, the raw merge from
# the incident reaches gh; through the guard the same command is denied before
# it can run, while the sanctioned script's own gh merge still reaches gh,
# because the guard sees only the tool command, never the script's children.
test_e2e_raw_merge_regression() {
  local fakebin log out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/e2e")
  log="$TMP_ROOT/e2e/gh.log"
  cat > "$fakebin/gh-axi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
EOF
  cat > "$TMP_ROOT/e2e/fm-pr-merge.sh" <<EOF
#!/usr/bin/env bash
gh-axi pr merge "\$2" --squash
EOF
  chmod +x "$fakebin/gh-axi" "$TMP_ROOT/e2e/fm-pr-merge.sh"

  PATH="$fakebin:$PATH" bash -c "$MERGE_PAYLOAD_COMMAND"
  grep -q 'pr merge' "$log" || fail "baseline: the raw merge did not reach gh"
  : > "$log"

  out=$("$CHECK" --claude --command "$MERGE_PAYLOAD_COMMAND" 2>&1); rc=$?
  expect_code 2 "$rc" "guard must deny the raw merge command from the incident"
  assert_contains "$out" '[raw-pr-merge]' "raw-merge block must carry the reason code"

  out=$("$CHECK" --claude --command "$TMP_ROOT/e2e/fm-pr-merge.sh nova-148 https://github.com/arjmad/nova/pull/148" 2>&1); rc=$?
  expect_code 0 "$rc" "guard must allow the sanctioned merge script"
  [ -z "$out" ] || fail "sanctioned merge allow must be silent: $out"
  PATH="$fakebin:$PATH" "$TMP_ROOT/e2e/fm-pr-merge.sh" nova-148 https://github.com/arjmad/nova/pull/148
  grep -q 'pr merge https://github.com/arjmad/nova/pull/148' "$log" \
    || fail "the sanctioned script's own gh merge must still reach gh"
  pass "merge-guard: reproduces the raw merge and denies it, while the sanctioned script still merges"
}

# --- fail-open transport behavior ------------------------------------------

test_fail_open_transport() {
  local fakebin tool tool_path out rc
  out=$("$CHECK" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  out=$(printf 'not json at all' | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"

  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  out=$(PATH="$fakebin" "$CHECK" --command 'gh pr merge 148' 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"

  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh git dirname cat printf sed tr node; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '{"tool_input":{"command":"gh pr merge 148"}}' | PATH="$fakebin" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "merge-guard: fails open on empty or unparseable stdin, missing node, and missing jq"
}

test_prefilter_skips_node_without_merge_substring() {
  local fakebin marker tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/prefilter")
  marker="$TMP_ROOT/prefilter/node-called"
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/node" <<EOF
#!/usr/bin/env bash
: > "$marker"
exit 0
EOF
  chmod +x "$fakebin/node"
  out=$(PATH="$fakebin" "$CHECK" --command 'gh pr view 148' 2>&1); rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no merge substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "merge-guard: prefilter fast-allows (skips node) when no merge substring is present"
}

test_policy_cli_direct() {
  local policy
  policy="$ROOT/bin/fm-merge-command-policy.mjs"
  [ "$(node "$policy" --command 'gh pr merge 148' | cut -f1,2)" = "$(printf 'deny\traw-pr-merge')" ] \
    || fail "policy CLI must deny a raw gh pr merge with the raw-pr-merge code"
  [ "$(node "$policy" --command 'gh pr view 148')" = allow ] \
    || fail "policy CLI must allow a PR read"
  [ "$(node "$policy")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  pass "merge-guard: fm-merge-command-policy.mjs CLI honors the deny/allow output contract"
}

# --- per-harness registration ----------------------------------------------

# A primary fixture carrying the tracked hook configuration, so each test below
# runs the exact registered command or extension rather than the transport.
WIRED=$(make_primary_fixture "$TMP_ROOT/wired")
mkdir -p "$WIRED/.claude" "$WIRED/.codex" "$WIRED/.cursor" "$WIRED/.grok/hooks" "$WIRED/.opencode/plugins"
cp "$ROOT/.claude/settings.json" "$WIRED/.claude/"
cp "$ROOT/.codex/hooks.json" "$WIRED/.codex/"
cp "$ROOT/.cursor/hooks.json" "$WIRED/.cursor/"
cp "$ROOT/.grok/hooks/fm-primary-merge-check.json" "$WIRED/.grok/hooks/"
cp "$ROOT/.opencode/plugins/fm-primary-merge-check.js" "$WIRED/.opencode/plugins/"

registered_command() {  # <config> <jq filter selecting command strings>
  local commands count
  commands=$(jq -r "$2" "$1")
  count=$(printf '%s\n' "$commands" | grep -c 'fm-merge-pretool-check.sh')
  [ "$count" = 1 ] || fail "$1 must register fm-merge-pretool-check.sh exactly once, found $count"
  printf '%s\n' "$commands" | grep 'fm-merge-pretool-check.sh'
}

test_claude_registration() {
  local cmd payload out rc
  cmd=$(registered_command "$WIRED/.claude/settings.json" '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command')
  payload=$(jq -cn --arg command "$MERGE_PAYLOAD_COMMAND" '{tool_name:"Bash",tool_input:{command:$command}}')
  out=$(printf '%s' "$payload" | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$WIRED" sh -c "$cmd" 2>/dev/null); rc=$?
  expect_code 2 "$rc" "the Claude Bash PreToolUse registration must deny"
  [ -z "$out" ] || fail "the Claude registration must keep stdout empty on deny: $out"
  pass "merge-guard: the tracked Claude Bash PreToolUse hook denies the raw merge"
}

test_codex_registration() {
  local cmd payload rc
  cmd=$(registered_command "$WIRED/.codex/hooks.json" '.hooks.PreToolUse[].hooks[].command')
  payload=$(jq -cn --arg command "$MERGE_PAYLOAD_COMMAND" '{tool_name:"Bash",tool_input:{command:$command}}')
  (cd "$WIRED" && printf '%s' "$payload" | sh -c "$cmd" >/dev/null 2>&1); rc=$?
  expect_code 2 "$rc" "the Codex PreToolUse registration must deny"
  pass "merge-guard: the tracked Codex PreToolUse hook denies the raw merge"
}

test_cursor_registration() {
  local cmd payload out rc
  cmd=$(registered_command "$WIRED/.cursor/hooks.json" '.hooks.preToolUse[] | select(.matcher == "Shell") | .command')
  payload=$(jq -cn --arg command "$MERGE_PAYLOAD_COMMAND" '{cursor_version:"1.0",tool_name:"Shell",tool_input:{command:$command}}')
  out=$(printf '%s' "$payload" | CURSOR_PROJECT_DIR="$WIRED" sh -c "$cmd" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "the Cursor registration answers through its decision object"
  printf '%s' "$out" | jq -e '.permission == "deny"' >/dev/null 2>&1 \
    || fail "the Cursor preToolUse registration must deny: $out"
  pass "merge-guard: the tracked Cursor preToolUse hook denies the raw merge"
}

test_grok_registration() {
  local cmd payload out rc
  cmd=$(registered_command "$WIRED/.grok/hooks/fm-primary-merge-check.json" '.hooks.PreToolUse[].hooks[].command')
  payload=$(jq -cn --arg command "$MERGE_PAYLOAD_COMMAND" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
  out=$(printf '%s' "$payload" | GROK_WORKSPACE_ROOT="$WIRED" sh -c "$cmd" 2>/dev/null); rc=$?
  expect_code 2 "$rc" "the Grok PreToolUse registration must deny"
  assert_contains "$out" '"decision":"deny"' "the Grok registration must print its decision object"
  pass "merge-guard: the tracked Grok PreToolUse hook denies the raw merge"
}

test_opencode_registration() {
  local out
  out=$(WIRED="$WIRED" COMMAND="$MERGE_PAYLOAD_COMMAND" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(`${process.env.WIRED}/.opencode/plugins/fm-primary-merge-check.js`).href);
const plugin = await mod.FmPrimaryMergeCheck({ directory: process.env.WIRED, worktree: process.env.WIRED });
const before = plugin["tool.execute.before"];
await before({ tool: "bash" }, { args: { command: "gh pr view 148" } });
try {
  await before({ tool: "bash" }, { args: { command: process.env.COMMAND } });
} catch (error) {
  if (!String(error.message).includes("[raw-pr-merge]")) throw new Error(`unexpected refusal: ${error.message}`);
  process.exit(0);
}
throw new Error("OpenCode plugin allowed the raw merge");
EOF
  ) || fail "the OpenCode plugin must throw on the raw merge and allow a read: $out"
  pass "merge-guard: the tracked OpenCode plugin denies the raw merge"
}

# Pi and omp piggyback on the primary turn-end extension. Import each real
# extension from a fixture beside the real transport and call its tool_call
# handler the way the harness does.
run_extension_tool_call() {  # <harness dir: .pi|.omp>
  local harness=$1 dir
  dir="$TMP_ROOT/ext$harness"
  make_primary_fixture "$dir" >/dev/null
  mkdir -p "$dir/$harness/extensions" "$dir/.pi/extensions/lib" "$dir/state" "$dir/node_modules/typebox"
  cp "$ROOT/$harness/extensions/fm-primary-turnend-guard.ts" "$dir/$harness/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$dir/.pi/extensions/lib/"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$dir/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$dir/node_modules/typebox/index.js"
  EXT="$dir/$harness/extensions/fm-primary-turnend-guard.ts" FM_HOME="$dir" COMMAND="$MERGE_PAYLOAD_COMMAND" \
    node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
const toolCall = handlers.get("tool_call");
const read = await toolCall({ type: "tool_call", toolName: "bash", input: { command: "gh pr view 148" } });
if (read?.block) throw new Error(`a PR read was blocked: ${JSON.stringify(read)}`);
const merge = await toolCall({ type: "tool_call", toolName: "bash", input: { command: process.env.COMMAND } });
if (!merge?.block || !String(merge.reason).includes("[raw-pr-merge]")) {
  throw new Error(`the raw merge was not blocked: ${JSON.stringify(merge)}`);
}
EOF
}

test_pi_and_omp_registration() {
  local harness out
  for harness in .pi .omp; do
    out=$(run_extension_tool_call "$harness") || fail "the $harness extension tool_call must block the raw merge: $out"
  done
  pass "merge-guard: the tracked Pi and omp tool_call handlers deny the raw merge"
}

# Delegated to bin/fm-lint.sh, the single owner of the lint definition.
test_scripts_are_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-merge-pretool-check.sh" 2>&1) \
    || fail "bin/fm-merge-pretool-check.sh is not lint-clean under the pinned definition: $out"
  pass "bin/fm-merge-pretool-check.sh is clean under bin/fm-lint.sh"
}

test_full_acceptance_matrix
test_refusal_names_sanctioned_paths
test_fires_in_secondmate_homes
test_inert_in_child_worktrees
test_inert_outside_firstmate
test_e2e_raw_merge_regression
test_fail_open_transport
test_prefilter_skips_node_without_merge_substring
test_policy_cli_direct
test_claude_registration
test_codex_registration
test_cursor_registration
test_grok_registration
test_opencode_registration
test_pi_and_omp_registration
test_scripts_are_shellcheck_clean
