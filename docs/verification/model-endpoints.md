# Local model-endpoint verification

Empirical evidence for the `config/model-endpoints.json` feature: routing a `claude`
crewmate at a local Anthropic-shaped proxy so a non-Anthropic model runs through the
unchanged `claude` CLI without a new harness.
Schema and mechanics are owned by [`configuration.md`](../configuration.md) "Local model
endpoints", [`bin/fm-model-endpoint.sh`](../../bin/fm-model-endpoint.sh), and
[`bin/fm-spawn.sh`](../../bin/fm-spawn.sh).
Operator-specific values (the real alias name, proxy port, and model ids) are
genericized in this record as `<alias>`, `http://127.0.0.1:<port>`, `my-local-model`,
and `my-local-model-small`; the commands and outputs are otherwise as run.

## Environment (2026-07-20)

- Date: 2026-07-20T21:05:31Z
- claude: 2.1.215 (Claude Code)
- jq: jq-1.7.1-apple
- curl: 8.7.1
- shellcheck: 0.11.0 (matches the `bin/fm-lint.sh` pin)
- herdr: 0.7.4
- Local proxy: CLIProxyAPI on `http://127.0.0.1:<port>`, Anthropic-shaped, upstream
  OAuth (the operator's `<alias>` shell alias)

Secret discipline for this record: the proxy auth token is a credential and appears
nowhere below. Probes that need it read it in-process from the `<alias>` alias and print
only the HTTP status and the non-secret model ids.

## 1. Proxy reachability and shape

```
$ curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://127.0.0.1:<port>/v1/models
HTTP 401

$ zsh -i -c '
    tok=$(alias <alias> | grep -oE "ANTHROPIC_AUTH_TOKEN=[^ ]+" | head -1 | cut -d= -f2)
    curl -s -o /tmp/models.json -w "HTTP %{http_code}\n" --max-time 8 \
      -H "Authorization: Bearer $tok" http://127.0.0.1:<port>/v1/models'
HTTP 200

$ jq -r '.data[].id' /tmp/models.json
<ten upstream model ids, including my-local-model and my-local-model-small>
```

The proxy is up, rejects unauthenticated `GET /v1/models` (401), answers 200 with the
Bearer token, and serves both target models (`my-local-model`, `my-local-model-small`).

## 2. Real end-to-end turn against the proxied model (supporting evidence)

The `<alias>` alias is exactly `claude --model my-local-model --strict-mcp-config` plus the
`ANTHROPIC_*` proxy env prefix. A print-mode turn proves the unchanged `claude` CLI drives
the proxied model through the local proxy:

```
$ timeout 120 zsh -i -c '<alias> -p "Reply with exactly one word: PROXYOK. Then stop."'
⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set ...
PROXYOK
```

`PROXYOK` came back from `my-local-model` via `127.0.0.1:<port>`, so the model + proxy +
claude CLI triad works end to end.

## 3. fm-spawn composes the identical launch, harness stays claude

Driven through the real `bin/fm-spawn.sh` with a fake terminal backend (the
`tests/fm-spawn-model-endpoint.test.sh` harness records the literal launch line and the
pre-launch text-line sends). For a `--model my-local-model` spawn against a
`config/model-endpoints.json` entry, the launch line fm-spawn sends is:

```
ANTHROPIC_BASE_URL='http://127.0.0.1:<port>' ANTHROPIC_DEFAULT_OPUS_MODEL='my-local-model' \
ANTHROPIC_DEFAULT_SONNET_MODEL='my-local-model' ANTHROPIC_DEFAULT_HAIKU_MODEL='my-local-model-small' \
CLAUDE_CODE_SUBAGENT_MODEL='my-local-model' ENABLE_TOOL_SEARCH='false' \
CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \
  --model 'my-local-model' --strict-mcp-config "$(cat '<brief>')"
```

That is byte-for-byte the working `<alias>` shape (base URL + slot mappings + `--model
my-local-model --strict-mcp-config`), with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`
preserved. `state/<id>.meta` records `harness=claude` and `model=my-local-model`, so the
busy signature, the claude Stop turn-end hook, the trust dialog, and watcher classification
all apply unchanged. The test also asserts the claude Stop hook
(`.claude/settings.local.json`) is still installed for the endpoint launch.

The verified launch has `--strict-mcp-config` and no `--mcp-config`, so it loads zero configured MCP servers rather than inheriting user/global or project-scoped servers.
The exact default capability boundary and the optional per-endpoint `mcp_config` grant are owned by [`configuration.md`](../configuration.md) "Local model endpoints".
Strict MCP governs MCP discovery only, so this launch shape does not prove that Claude-in-Chrome or other tooling configured outside MCP is absent.

### Secret discipline (grepped)

The auth token is exported as its own pre-launch line and appears in no durable record:

```
# pre-launch text-line sends (fake backend capture):
treehouse get
export GOTMPDIR=/tmp/fm-<id>/gotmp
export ANTHROPIC_AUTH_TOKEN='<token>'

$ grep -rn '<token>' state/            -> absent (meta + status)
$ grep -rn '<token>' config/           -> absent (only the env var NAME is stored)
$ grep '<token>' <launch-literal>      -> absent (not in the recorded launch string)
```

`tests/fm-spawn-model-endpoint.test.sh` pins all of the above, the default absence of `--mcp-config`, the opt-in `--mcp-config` launch shape, and the fail-closed paths before any launch or meta is created.
`tests/fm-model-endpoint.test.sh` pins the resolver's config parsing, readable MCP path record, missing-path refusal, 0/3/2 exit-code contract, and token-source priority.

## 4. Backend coverage

- tmux (reference): the launch line above was composed and sent through the real
  `fm-spawn.sh` tmux send path (fake tmux). The endpoint env prefix and `--strict-mcp-config`
  are ordinary characters in the launch literal; the token export rides the same
  `spawn_send_text_line` primitive as the existing `GOTMPDIR` export.
- herdr (this home's pinned backend): reasoned, not independently driven here. The endpoint
  override adds nothing to the transport layer - it only lengthens the launch literal,
  optionally lengthens it again with `--mcp-config`, and adds one more `export` line, all
  carried by the same `spawn_send_literal` / `spawn_send_text_line` primitives that already deliver the herdr-verified `GOTMPDIR`
  export and `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` prefix (see
  [`herdr-backend.md`](../herdr-backend.md)). No herdr-specific code path changed.
  Section 7 supersedes this bullet's transport detail: on herdr the token is no longer an
  `export` line at all.

### Not exercised here: a live herdr-supervised spawn

A real `fm-spawn.sh --backend herdr` launch of a proxied-model worker (creating and later
tearing down a herdr tab/pane) drives herdr lifecycle. The crewmate brief for this task is
not `--herdr-lab` enabled, and its hard safety gate forbids driving herdr lifecycle from an
unguarded brief, so that final live confirmation was deliberately left to firstmate. To run
it, add a `my-local-model` entry to `config/model-endpoints.json` (token via `auth_token_env`
or `auth_token_file`) and spawn a scout with `--harness claude --model my-local-model`; the
worker should report `harness=claude`, run on the proxied model, and wake the watcher at
each turn.

## 5. Per-endpoint MCP grant extension (2026-07-23)

- Date: 2026-07-23
- Base commit: `73e050b` (`fix(spawn): fail on metadata write errors (#14)`)
- Scope: resolver and launch-string behavior with the fake tmux transport used in section 3.

```
$ bash tests/fm-model-endpoint.test.sh
ok - mcp_config emits the configured readable path
ok - a relative mcp_config resolves from the effective FM_HOME
ok - a missing mcp_config fails closed before records are emitted
ok - an invalid mcp_config value fails closed

$ bash tests/fm-spawn-model-endpoint.test.sh
ok - endpoint model injects the env prefix + --strict-mcp-config and stays harness=claude
ok - an endpoint mcp_config adds one deliberate --mcp-config grant
ok - a missing endpoint mcp_config fails closed before any launch or meta is created
ok - an unreadable endpoint mcp_config fails closed before launch
```

The opt-in launch assertion is `--model 'my-local-model' --strict-mcp-config --mcp-config '<readable-path>'`.
The existing no-`mcp_config` case still asserts that no `--mcp-config` flag appears, preserving the zero-MCP default exactly.
No live Sol-worker Chrome probe was run, so the outside-MCP Chrome boundary remains explicitly unverified rather than inferred from the strict MCP flag.

## 6. Re-verification after the upstream merge (2026-07-27)

- Date: 2026-07-27
- Base commit: the merge of `upstream/main` `a5fe1bc` into this fork
- Scope: the composed launch string, with the same fake-backend harness used in section 3.

Upstream replaced `"$(cat <brief>)"` with the canonical operational-input encoder in every
adapter template, so the section 3 capture above is the pre-merge shape and is retained as
dated evidence of what was observed then. The endpoint prefix and MCP flags are unchanged;
only the brief argument moved. The launch string composed after the merge is:

```
ANTHROPIC_BASE_URL='http://127.0.0.1:<port>' ANTHROPIC_DEFAULT_OPUS_MODEL='my-local-model' \
ANTHROPIC_DEFAULT_SONNET_MODEL='my-local-model' ANTHROPIC_DEFAULT_HAIKU_MODEL='my-local-model-small' \
CLAUDE_CODE_SUBAGENT_MODEL='my-local-model' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
claude --dangerously-skip-permissions --model 'my-local-model' --strict-mcp-config \
  "$('<root>/bin/fm-operational-input.sh' encode launch-brief < '<brief>')"
```

The endpoint env prefix, `--strict-mcp-config`, and the encoder therefore compose in one
string; `state/<id>.meta` still records `harness=claude`, and the auth token is still
exported on its own pre-launch line and absent from the launch literal, meta, and config.

```
$ bash tests/fm-model-endpoint.test.sh          -> 22 assertions, exit 0
$ bash tests/fm-spawn-model-endpoint.test.sh    -> 11 assertions, exit 0
```

The two byte-exact non-endpoint baseline assertions in `tests/fm-spawn-model-endpoint.test.sh`
were retargeted at the new stock template in the same merge; they still require byte equality
and still forbid the endpoint prefix and both MCP flags on a non-endpoint launch.

## 7. Native launch environment on the herdr backend (2026-07-27)

- Date: 2026-07-27
- herdr: 0.7.5
- Scope: how the auth token and `GOTMPDIR` reach the worker on `backend=herdr`.

Herdr's own CLI documents a launch-environment flag on both container-creating verbs:

```
$ herdr tab create --help
      --env <KEY=VALUE>
          Set an environment variable for the launched process

$ herdr workspace create --help
      --env <KEY=VALUE>
          Set an environment variable for the launched process
```

The flag accumulates rather than replacing.
Passing it twice against a session name with no server reaches the socket connect and fails there, instead of the repeated-argument refusal a single-value argument would produce:

```
$ herdr tab create --workspace ws-does-not-exist --env FM_PROBE_A=1 --env FM_PROBE_B=2 \
    --no-focus --session fm-envprobe-nonexistent-9a3f
Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }
```

This probe is non-mutating by construction: the named session has no server, so no container is created.

Firstmate therefore passes both values it already knows before the pane exists through that flag, and skips the typed pre-launch export block entirely on this backend.
The token never reaches the pane's interactive shell, so it cannot appear in the pane's visible screen content or in Herdr's optional persisted pane history.
[`herdr-backend.md`](../herdr-backend.md) "Launch environment" owns that mechanism, including what still uses the typed path and what the other backends keep.
The endpoint's non-secret variables remain a prefix of the composed launch command, identical on every backend, so section 6's launch string is unchanged.

Pinned by `tests/fm-backend-herdr.test.sh`, whose last two cases drive the real `bin/fm-spawn.sh` with `--backend herdr` against a stateful fake CLI and assert both directions:

```
$ bash tests/fm-backend-herdr.test.sh
ok - fm_backend_herdr_env_flags: emits repeatable --env flags, one per pair, values preserved verbatim
ok - fm_backend_herdr_env_flags: no pairs builds no flags (an env-less create stays byte-identical)
ok - fm_backend_herdr_env_flags: refuses a non-KEY=VALUE entry loudly and withholds its value
ok - fm_backend_herdr_env_flags: refuses an invalid environment variable name
ok - fm_backend_herdr_create_task: places launch env on the pane process via repeatable --env
ok - fm_backend_herdr_create_task: an env-less create is unchanged (no stray --env)
ok - fm_backend_herdr_create_task: a malformed env pair refuses before any tab create (no half-configured pane)
ok - fm_backend_herdr_create_task: a refused tab create names the herdr version requirement instead of failing silently
ok - fm_backend_herdr_projection_create_task: launch env is scoped to the task tab, never the disposable workspace's seeded tab
ok - fm_backend_herdr_projection_create_task: a malformed env pair refuses before any herdr call and grants no cleanup authority
ok - fm_backend_herdr_projection_reclaim_task: the husk replacement tab carries launch env natively, and only that call sees it
ok - fm_backend_herdr_projection_reclaim_task: a malformed env pair refuses before any herdr call
ok - fm_backend_herdr_version_check: refuses a pre---env herdr (protocol 16) and names the 0.7.5 requirement
ok - fm_backend_herdr_version_check: stays client-only and session-independent, leaving the server half to the session-scoped server_ensure
ok - fm_backend_herdr_server_ensure: publishes the session server's protocol on the fast path and never refuses on it
ok - fm_backend_herdr_server_ensure: the poll path publishes the same way as the fast path
ok - fm_backend_herdr_server_ensure: an unreadable server protocol publishes empty so callers can tell unknown from below-floor
ok - herdr non-creating paths: capture and kill still work (and kill really closes) against a below-floor running server
ok - fm_backend_herdr_container_ensure: refuses a below-floor session server, so the floor still guards the paths that use --env
ok - fm_backend_herdr_container_ensure: a server at the floor proceeds normally
ok - fm-spawn (herdr): launch env goes native via tab create --env and is never typed at the pane shell
ok - fm-spawn (herdr): a spawn with no local endpoint still gets GOTMPDIR natively and no token env
-> 157 assertions, exit 0
```

The end-to-end case asserts that a `pane run` and a `pane send-text` did occur, then that no typed call carried the credential, an `ANTHROPIC_AUTH_TOKEN` export, a `GOTMPDIR` export, or the history-file suppression, so it cannot pass by the spawn simply typing nothing.
`tests/fm-spawn-model-endpoint.test.sh` continues to pin the typed path on the tmux transport unchanged.
Both assertions were confirmed to fail when the change is reverted in place: forcing the typed block back on reproduces `export GOTMPDIR` at the pane, and dropping the flag expansion from `tab create` reproduces the missing `--env`.

### Live confirmation in an isolated lab session

Every check below ran inside a `bin/fm-herdr-lab.sh` session, never against the captain's `default` session, and each teardown re-verified the identical default fleet state.
Generic values are used as elsewhere in this record: the real endpoint alias, proxy port, and model ids are the operator's own.

A pane created with `--env` carries that environment in the launched process, and neither value reaches the screen:

```
$ herdr tab create --workspace <ws> --cwd <dir> --label envprobe --no-focus \
    --env FM_LAB_PROBE=<probe> --env ANTHROPIC_AUTH_TOKEN=<fake> --session <lab>
$ herdr pane run <pane> "printenv > <dump>" --session <lab>

PASS: FM_LAB_PROBE present in the launched process environment
PASS: ANTHROPIC_AUTH_TOKEN present in the launched process environment
env entries captured: 61
screen bytes captured: 250
PASS: the token value never appeared in the pane's visible screen content
PASS: the probe value never appeared on screen either
```

A real `bin/fm-spawn.sh --backend herdr --harness claude --model <alias>` launch against the live proxy then completed a turn and reported its own environment.
The worker wrote the report to a file rather than the screen, so the credential was never printed and the file's existence is itself proof of a completed model turn:

```
TOKEN_LEN=48
BASEURL=http://127.0.0.1:<port>
GOTMP=/tmp/fm-<id>/gotmp

PASS: the proxied worker completed a turn and ran its tool (reached the proxy, no 401 retry loop)
PASS: ANTHROPIC_AUTH_TOKEN present in the launched process environment (length 48, value never printed)
PASS: GOTMPDIR correct inside the launched process
PASS: endpoint base URL present inside the launched process
PASS: the real credential does not appear in the pane's visible screen content
PASS: the real credential reached no durable record under state/
PASS: no 401 or unauthorized signature on the pane
```

Reading the screen back from a pane whose worktree `claude` had never seen holds the launch at the folder-trust dialog, so the pane's whole visible history from its first shell prompt can be captured.
That history is the prompt, the launch command, and the agent UI, with no pre-launch typing at all:

```
heimdall@heimdall <worktree> % ANTHROPIC_BASE_URL='http://127.0.0.1:<port>' ANTHROPIC_DEFAULT_OPUS_MODEL='<alias>' \
ANTHROPIC_DEFAULT_SONNET_MODEL='<alias>' ANTHROPIC_DEFAULT_HAIKU_MODEL='<alias-small>' \
CLAUDE_CODE_SUBAGENT_MODEL='<alias>' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude \
--dangerously-skip-permissions --model '<alias>' --strict-mcp-config "$('<root>/bin/fm-operational-input.sh' encode launch-brief < '<brief>')"

 Quick safety check: Is this a project you created or one you trust? ...

PASS: 'export ANTHROPIC_AUTH_TOKEN' does not appear on the pane screen
PASS: 'export GOTMPDIR' does not appear on the pane screen
PASS: 'unset HISTFILE' does not appear on the pane screen
PASS: the real credential does not appear on the pane screen
```

The non-secret endpoint prefix is still visible there, as expected: it is part of the launch command, not launch environment, and is composed identically on every backend.
The three lines that used to sit above that command are gone, which is the acceptance bar for enabling `experimental.pane_history`.
