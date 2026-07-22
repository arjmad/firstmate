# Local model-endpoint verification

Empirical evidence for the `config/model-endpoints.json` feature: routing a `claude`
crewmate at a local Anthropic-shaped proxy so a non-Anthropic model runs through the
unchanged `claude` CLI without a new harness.
Schema and mechanics are owned by [`configuration.md`](configuration.md) "Local model
endpoints", [`bin/fm-model-endpoint.sh`](../bin/fm-model-endpoint.sh), and
[`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
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

`tests/fm-spawn-model-endpoint.test.sh` pins all of the above, plus the fail-closed paths
(malformed config and an unresolvable token both abort before any window or meta is
created), and `tests/fm-model-endpoint.test.sh` pins the resolver's config parsing, the
0/3/2 exit-code contract, and the token-source priority.

## 4. Backend coverage

- tmux (reference): the launch line above was composed and sent through the real
  `fm-spawn.sh` tmux send path (fake tmux). The endpoint env prefix and `--strict-mcp-config`
  are ordinary characters in the launch literal; the token export rides the same
  `spawn_send_text_line` primitive as the existing `GOTMPDIR` export.
- herdr (this home's pinned backend): reasoned, not independently driven here. The endpoint
  override adds nothing to the transport layer - it only lengthens the launch literal and
  adds one more `export` line, both carried by the same `spawn_send_literal` /
  `spawn_send_text_line` primitives that already deliver the herdr-verified `GOTMPDIR`
  export and `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` prefix (see
  [`herdr-backend.md`](herdr-backend.md)). No herdr-specific code path changed.

### Not exercised here: a live herdr-supervised spawn

A real `fm-spawn.sh --backend herdr` launch of a proxied-model worker (creating and later
tearing down a herdr tab/pane) drives herdr lifecycle. The crewmate brief for this task is
not `--herdr-lab` enabled, and its hard safety gate forbids driving herdr lifecycle from an
unguarded brief, so that final live confirmation was deliberately left to firstmate. To run
it, add a `my-local-model` entry to `config/model-endpoints.json` (token via `auth_token_env`
or `auth_token_file`) and spawn a scout with `--harness claude --model my-local-model`; the
worker should report `harness=claude`, run on the proxied model, and wake the watcher at
each turn.
