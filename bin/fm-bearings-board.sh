#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build [--if-changed] <data.json>
#   fm-bearings-board.sh path
#
# build      Validate the payload, drop the Captain's Call cards whose subject
#            already landed, give every surviving decision card the standard
#            reconcile choice, and inject the result into a fresh copy of the
#            shipped template at the stable board path. Establish the Lavish
#            session on that board and PROVE it is live BEFORE binding and
#            arming its answer source, so a registered poll can never race a
#            session that does not exist or attach to one that has ended.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, then includes lavish-axi's session output and
#            the remaining status:
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
#            With --if-changed, a build whose effective payload (after the
#            steps above, ignoring `generated`) matches the last published one,
#            while its session is still listed open and its source still has a
#            live listener, prints `board: <path>` and `unchanged: <path>` and
#            touches nothing, so a heartbeat refresh never reloads a board the
#            captain may be typing on; an ended session or a dead listener gets
#            the full build instead, and so does a new local day, because the
#            page groups due work against its own today. The fingerprint covers the template too and is
#            kept beside the board as bearings-board.sha256, written only once
#            a build has proved its listener.
# path       Print the stable board path for this home.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board from a dead one. build requires the server's fresh
# session listing to show the canonical board open and refuses rather than
# arming an ended session. After a reopen it retires the pre-reopen source
# generation through the guarded adapter path, arms a fresh registration, and
# accepts only the replacement listener as live. A registered board with no
# live owner also gets a replacement before build returns, because
# `already-armed` is not the same fact as `listening`.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# A decision card must also offer a real choice: at least two authored options
# (the injected reconcile choice does not count), a `recommend_value` naming one
# of them, and `allow_freeform: true`. Merge and credential cards keep their own
# shapes. The check runs after stale cards are dropped, also refuses a decision
# card that repeats an option value, and alone checks a decision card's
# recommendation. The refusal names each weak card's key and what it lacks, so the
# composer fixes the payload rather than the board shipping a Done-only card.
#
# THE LAYOUT IS INBOX FIRST. Beside `captains_call` (the Decisions group), the
# payload carries:
#   inbox[]   everything else waiting on the captain, each {key, group, title,
#             ask, repo, inputs[], actions[]} plus optional since, pr_url and
#             close. group `blocking` is a worker blocked on him (key = that
#             task id); group `due` is a captain hold due on `due` (YYYY-MM-DD,
#             key = the held task id). inputs[] are value boxes {name, label,
#             type number|date|datetime-local|text, default?}; actions[] are
#             two or three {value, label, hint, effect, reads[]} plus until, at
#             or brief as the effect needs. inbox_item_gaps below owns the
#             effect set and every refusal, named per key.
#   later[]   captain-owned rows not due this week, each {id, title, repo,
#             group dated|held|unheld, back?}; a dated row needs its `back`
#             date, and `unheld` is a row he owns that no hold gates.
#   prune     optional: the weekly backlog prune card, {slot, title, ask,
#             candidates[], more?}. slot is the current weekly slot (YYYY-MM-DD)
#             and candidates are one to FM_BEARINGS_PRUNE rows, each {id,
#             title, repo, touched (YYYY-MM-DD)}, every id once, copied from
#             the snapshot's board.prune; more counts the rows held back. build
#             records exactly that list through bin/fm-backlog-prune.sh offer
#             and sets the card's `key` to the offer key it prints (a composed
#             key is replaced), so every answer names one recorded list. The
#             card's three answers are fixed by the template, not composed:
#             drop-all, drop-picked (values.picked = 1-based positions) and
#             keep, each with effect `prune`.
# An Underway row may carry progress {done, total, step?} from the worker's own
# step list (bin/fm-progress.sh), and every Recently Landed row carries
# `outcome`, the short result sentence the board shows instead of the title.
# A Charted Next row may carry `wait` (date, outside, work, none) and
# `wait_date`, which the board groups its queue by; `dispatchable` marks the
# rows ready to start now.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    return 1
  fi
}

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def name_marker: has("name") and (.name | nonempty_string);
    def valid_filed:
      . as $filed
      | type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      and (if test("T")
        then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
        else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
        end);
    def optional_filed:
      (has("filed") | not) or (.filed == null) or (.filed | valid_filed);
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
    def optional_subject:
      (has("subject") | not)
      or (.subject
        | type == "object"
          and (keys | sort) == ["artifact", "version"]
          and (.artifact | slug(128))
          and (.version | version));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and optional_subject
      and (if has("subject") then .type == "decision" else true end)
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.type == "decision"
            or (.recommend_value as $recommend
              | ([.options[].value] | index($recommend) != null)))))
      and ([.options[].value] | index("reconcile") == null)
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def count: type == "number" and . >= 0 and (floor == .);
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string)
      and ((has("progress") | not) or (.progress == null)
        or (.progress | type == "object"
          and (.done | count) and (.total | count) and .total > 0 and .done <= .total
          and ((has("step") | not) or (.step | type == "string"))));
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.outcome | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_string("artifact")
      and optional_subject;
    def valid_date:
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
      and (try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == .) catch false);
    def valid_datetime:
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$")
      and (.[0:10] | valid_date)
      and ((.[11:13] | tonumber) < 24) and ((.[14:16] | tonumber) < 60);
    def optional_date($name): (has($name) | not) or (.[$name] | valid_date);
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and optional_filed
      and ((has("wait") | not) or (.wait == "date" or .wait == "outside" or .wait == "work" or .wait == "none"))
      and optional_date("wait_date")
      and (if .kind == "warning" then .dispatchable == false else true end);
    def inbox_input:
      type == "object" and (.name | slug(64)) and (.label | nonempty_string)
      and (.type == "number" or .type == "date" or .type == "datetime-local" or .type == "text")
      and optional_string("default");
    def inbox_action:
      type == "object" and (.value | slug(128)) and (.label | nonempty_string)
      and (.hint | type == "string") and (.effect | type == "string")
      and (.reads | type == "array") and ([.reads[] | type == "string"] | all)
      and optional_date("until")
      and ((has("at") | not) or (.at | valid_datetime))
      and optional_string("brief");
    def inbox_item:
      type == "object"
      and (.key | slug(128))
      and (.group == "blocking" or .group == "due")
      and (if .group == "due" then (.due | valid_date) else (has("due") | not) end)
      and repo_marker
      and (.title | nonempty_string)
      and (.ask | nonempty_string)
      and optional_string("since")
      and optional_https_url("pr_url")
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and (.inputs | type == "array") and ([.inputs[] | inbox_input] | all)
      and (.actions | type == "array") and ([.actions[] | inbox_action] | all);
    def prune_card:
      type == "object"
      and (.slot | valid_date)
      and (.title | nonempty_string) and (.ask | nonempty_string)
      and (.candidates | type == "array") and (.candidates | length) > 0
      and ([.candidates[] | type == "object" and (.id | slug(128)) and repo_marker
            and (.title | nonempty_string) and (.touched | valid_date)] | all)
      and ([.candidates[].id] | length) == ([.candidates[].id] | unique | length)
      and ((has("more") | not) or (.more | count));
    def later_item:
      type == "object" and (.id | slug(128)) and repo_marker
      and (.title | nonempty_string)
      and (.group == "dated" or .group == "held" or .group == "unheld")
      and (if .group == "dated" then (.back | valid_date) else optional_date("back") end);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.inbox | type == "array")
    and (.later | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ([.captains_call[] | call_item] | all)
    and ([.inbox[] | inbox_item] | all)
    and ([.later[] | later_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
    and ((has("prune") | not) or (.prune == null) or (.prune | prune_card))
  ' "$1" >/dev/null
}

# Name every surviving decision card that does not offer a real choice, with
# its key and each missing part, joined on one line. It reads the effective
# payload, so a stale card build drops never refuses the board, and the
# reconcile choice build injects is not counted as an authored option.
decision_card_gaps() {  # <effective-payload.json>
  jq -r '
    [.captains_call[]
      | select(.type == "decision")
      | . as $card
      | [.options[].value | select(. != "reconcile")] as $values
      | [
          (if ($values | length) < 2
            then "at least two authored options (has \($values | length))" else empty end),
          (if ($values | length) != ($values | unique | length)
            then "distinct option values" else empty end),
          (if ($card.recommend_value | type) != "string" or ($values | index($card.recommend_value)) == null
            then "a recommend_value naming one of its options" else empty end),
          (if $card.allow_freeform != true then "allow_freeform true" else empty end)
        ] as $gaps
      | select($gaps | length > 0)
      | "\($card.key): needs \($gaps | join(", "))"]
    | join("; ")
  ' "$1"
}

# Name every inbox item whose actions do not say plainly what the fleet does,
# with its key and each problem, joined on one line. An action's effect is one
# of a closed set, each a route the board-wake handler owns (bearings skill):
#   resume-worker  steer the blocked worker with the answer
#   close          close the held item (or lift its hold, with close: release)
#   hold-until     re-hold the item until a date: its own `until`, or the one
#                  date input it reads (the keyed intake defers it)
#   remind-at      bring the item back at a time: its own `at`, or the one
#                  datetime-local input it reads (firstmate schedules it)
#   dispatch       start fleet work from its one-line `brief`
#   draft          prepare something for the captain's review, never sent or paid
#   send-mail      send mail under firstmate's normal account rules
#   record         write the values it reads to their owning record
# A blocking item is a worker waiting on the captain, not a captain hold, so it
# may not close or re-hold anything.
INBOX_EFFECTS='resume-worker close hold-until remind-at dispatch draft send-mail record'
inbox_item_gaps() {  # <payload.json>
  jq -r --arg effects "$INBOX_EFFECTS" '
    ($effects | split(" ")) as $effects
    | . as $payload
    | ([.captains_call[].key] + [.inbox[].key]) as $keys
    | [.inbox[]
      | . as $item
      | [.inputs[].name] as $names
      | [.actions[].value] as $values
      | ([.actions[].reads[]] | unique) as $read
      | [
          (if ([$keys[] | select(. == $item.key)] | length) > 1
            then "a key no other item or card uses" else empty end),
          (if (.actions | length) < 2 or (.actions | length) > 3
            then "two or three actions (has \(.actions | length))" else empty end),
          (if ($values | length) != ($values | unique | length)
            then "distinct action values" else empty end),
          (if ($values | index("reconcile")) != null
            then "no action named reconcile, which is reserved" else empty end),
          (if ($names | length) != ($names | unique | length)
            then "distinct input names" else empty end),
          (.actions[]
            | . as $action
            | (if (.hint | test("[^[:space:]]")) | not
                then "a hint on action \(.value)" else empty end),
              (if ($effects | index($action.effect)) == null
                then "a known effect on action \(.value) (has \(.effect))" else empty end),
              (.reads[] as $r | select(($names | index($r)) == null)
                | "an input named \($r) for action \($action.value)"),
              (if $item.group == "blocking"
                  and (.effect == "close" or .effect == "hold-until")
                then "no \(.effect) on action \(.value), since a blocking item is not a captain hold" else empty end),
              (if .effect == "hold-until"
                  and ((has("until") | not) == ([.reads[] as $r | $item.inputs[] | select(.name == $r and .type == "date")] | length != 1)
                    or (.reads | length) > 1)
                then "either an until date or one date input on action \(.value)" else empty end),
              (if .effect == "remind-at"
                  and ((has("at") | not) == ([.reads[] as $r | $item.inputs[] | select(.name == $r and .type == "datetime-local")] | length != 1)
                    or (.reads | length) > 1)
                then "either an at time or one datetime-local input on action \(.value)" else empty end),
              (if .effect == "dispatch" and ((.brief // "") | test("[^[:space:]]") | not)
                then "a one-line brief on dispatch action \(.value)" else empty end),
              (if .effect != "hold-until" and has("until")
                then "no until on non-hold-until action \(.value)" else empty end),
              (if .effect != "remind-at" and has("at")
                then "no at on non-remind-at action \(.value)" else empty end)),
          (.inputs[].name as $n | select(($read | index($n)) == null)
            | "an action that reads input \($n)")
        ] as $gaps
      | select($gaps | length > 0)
      | "\($item.key): needs \($gaps | join(", "))"]
    | join("; ")
  ' "$1"
}

# --- Lavish session liveness -------------------------------------------------
# Verified against lavish-axi 0.1.61. `lavish-axi <file>` EXITS 0 even when it
# refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` and the same session id, so an exit-code check alone
# cannot tell a live board from a dead one. The establish status is an initial
# signal only; the server's fresh session listing must also show the canonical
# board open before the build may bind or arm its source.

board_realpath() {  # <board>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
lavish_session_listed_open() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

lavish_board_live() {  # <establish output> <canonical-board-path>
  lavish_session_listed_open "$2"
}

# Establish the board session and PROVE it is live before anything arms a poll
# on it. A session the captain ended is reopened once - the captain asked for
# this board, which is exactly the attention `--reopen` exists for - and a
# session that is still not live after that refuses the build rather than
# arming a poll that can never attach.
establish_board_session() {  # <board>
  local board=$1 real out status version
  BOARD_SESSION_REOPENED=0
  real=$(board_realpath "$board") || fail "cannot resolve the board path: $board"
  out=$(lavish-axi "$board") || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    printf 'session: live\n'
    return 0
  fi
  out=$(lavish-axi "$board" --reopen) || fail "cannot reopen the ended board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    BOARD_SESSION_REOPENED=1
    printf 'session: reopened\n'
    return 0
  fi
  status=$(lavish_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
effective_payload() {  # <data.json> <dest.json>
  local data=$1 dest=$2 landed_keys key reason drop='' tmp landed=0 prune_key
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  prune_key=$(record_prune_offer "$data") || return 1
  jq --argjson dropped "$tmp" --arg prune_key "$prune_key" '
    .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if .type == "decision"
        then .options += [{
          value: "reconcile",
          label: "Reconcile",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]
    | if $prune_key != "" then .prune.key = $prune_key else del(.prune) end' "$data" > "$dest" || return 1
}

# Record the prune card's exact list and print its offer key, or nothing when
# the payload carries no card. A refused offer (a slot that is not the current
# one) refuses the build rather than shipping a card no answer can name.
record_prune_offer() {  # <data.json>
  local slot ids
  jq -e '(.prune // null) != null' "$1" >/dev/null 2>&1 || return 0
  slot=$(jq -r '.prune.slot' "$1") || return 1
  ids=$(jq -r '.prune.candidates[].id' "$1") || return 1
  # shellcheck disable=SC2086 # ids are validated backlog-id slugs
  "$SCRIPT_DIR/fm-backlog-prune.sh" offer "$slot" $ids
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
source_owner() {  # <source-id>
  "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
await_source_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}

command_build() {
  local data board json tmp sid extracted effective owner version pre_reopen_owner gaps
  local if_changed=0 fingerprint fingerprint_file
  if [ "${1-}" = --if-changed ]; then if_changed=1; shift; fi
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  data=$1
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work or record its prune offer"
  fi
  if ! gaps=$(decision_card_gaps "$effective"); then
    rm -f -- "$effective"
    fail "cannot check the board's decision cards: $data"
  fi
  if [ -n "$gaps" ]; then
    rm -f -- "$effective"
    fail "decision cards must offer a real choice: $gaps"
  fi
  if ! gaps=$(inbox_item_gaps "$effective"); then
    rm -f -- "$effective"
    fail "cannot check the board's inbox items: $data"
  fi
  if [ -n "$gaps" ]; then
    rm -f -- "$effective"
    fail "inbox items must say what each action does: $gaps"
  fi
  json=$(jq -c . "$effective") || { rm -f -- "$effective"; fail "cannot compact the board data"; }
  # The page groups due work against its own today, so a new day is a change.
  fingerprint=$({ cat -- "$TEMPLATE"; date +%Y-%m-%d; jq -cS 'del(.generated)' "$effective"; } \
    | sha256_stdin) || fingerprint=''
  [ "${#fingerprint}" -eq 64 ] || { rm -f -- "$effective"; fail "cannot fingerprint the board data (shasum or sha256sum is required)"; }
  rm -f -- "$effective"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  fingerprint_file=${board%.html}.sha256
  if [ "$if_changed" = 1 ] && [ -f "$board" ] && [ -f "$fingerprint_file" ] \
    && [ "$(cat "$fingerprint_file")" = "$fingerprint" ] \
    && command -v lavish-axi >/dev/null 2>&1 \
    && lavish_session_listed_open "$(board_realpath "$board")" \
    && sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board" 2>/dev/null) \
    && [ "$(source_owner "$sid")" = live ]; then
    printf 'board: %s\nunchanged: %s\n' "$board" "$board"
    return 0
  fi
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the board"
  fi
  # A failed publish below must not leave a fingerprint that would let the
  # next --if-changed skip it, so the old one goes now and the new one is
  # written only once the board is listening.
  rm -f -- "$fingerprint_file" || fail "cannot clear the board fingerprint"
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_board_session "$board"
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$board" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if ! lavish_session_listed_open "$(board_realpath "$board")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$board"

  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(source_owner "$sid")
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm a fresh board source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  fi
  # Registered is not listening. A board whose source has no live owner gets a
  # replacement started now rather than at the next supervision cycle, which is
  # what keeps a rebuilt board from sitting silent behind `already-armed`.
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
  (umask 077; printf '%s\n' "$fingerprint" > "$fingerprint_file") \
    || fail "cannot record the board fingerprint"
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
