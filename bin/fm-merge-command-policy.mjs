#!/usr/bin/env node
// Semantic policy for the merge guard: does a shell command merge a pull
// request directly through the GitHub CLI instead of bin/fm-pr-merge.sh?
//
// bin/fm-pr-merge.sh owns the current-head, green-check, and merge-authority
// guards. A raw `gh pr merge`, `gh-axi pr merge`, or `gh api` merge call from
// the primary firstmate shell skips every one of them. This policy blocks
// exactly that class of command; the environmental scoping to a primary home
// lives in the bin/fm-merge-pretool-check.sh transport, not here. See
// docs/merge-guard.md for the full contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "raw-pr-merge":
    "a raw PR merge from the primary firstmate shell is blocked because it skips the current-head, green-check, and merge-authority guards; merge with bin/fm-pr-merge.sh <task> <pr-url>, or for a brain PR with ~/nix/bin/brain-managed-refresh arjun --merge-pr <n>.",
};

const GH_COMMANDS = new Set(["gh", "gh-axi"]);
const SHELLS = new Set(["sh", "bash", "zsh"]);
const MAX_DEPTH = 12;

// gh flags that consume the following word as their value. Only these change
// which later word is positional; every other flag is treated as standalone.
const GH_VALUE_FLAGS = new Set([
  "-R", "--repo", "--hostname",
  "-X", "--method", "-f", "--raw-field", "-F", "--field", "-H", "--header",
  "--input", "-q", "--jq", "-t", "--template", "--cache", "-p", "--preview",
]);

// gh api REST endpoint of the pulls merge call, with or without a leading
// slash, a full API URL, placeholders, or a query string.
const REST_MERGE_ENDPOINT = /(?:^|\/)pulls\/[^/?#]+\/merge\/?(?:[?#].*)?$/;

// GraphQL mutations that merge, auto-merge, or enqueue a pull request.
const GRAPHQL_MERGE_MUTATION = /\b(?:mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest)\b/;

function basename(value) {
  return value.split("/").at(-1);
}

// Split a gh invocation's arguments into positional words and flags, consuming
// the value word of every flag in GH_VALUE_FLAGS.
function ghArguments(words) {
  const positionals = [];
  const flags = [];
  for (let i = 0; i < words.length; i += 1) {
    const value = words[i].value;
    if (value === "--") {
      positionals.push(...words.slice(i + 1).map((word) => word.value));
      break;
    }
    if (value.startsWith("-") && value !== "-") {
      if (GH_VALUE_FLAGS.has(value) && i + 1 < words.length) {
        flags.push({ name: value, value: words[i + 1].value });
        i += 1;
      } else {
        flags.push({ name: value, value: null });
      }
      continue;
    }
    positionals.push(value);
  }
  return { positionals, flags };
}

function asksForHelp(flags) {
  return flags.some((flag) => flag.name === "--help" || flag.name === "-h");
}

// The explicit HTTP method of a gh api call, or "" when none was given.
function apiMethod(flags) {
  let method = "";
  for (const flag of flags) {
    if ((flag.name === "-X" || flag.name === "--method") && flag.value !== null) method = flag.value;
    else if (flag.name.startsWith("--method=")) method = flag.name.slice("--method=".length);
    else if (/^-X./.test(flag.name)) method = flag.name.slice(2);
  }
  return method.toUpperCase();
}

// gh api switches its default method from GET to POST once a body is supplied.
function apiSendsBody(flags) {
  return flags.some((flag) => /^(?:-f|-F|--field|--raw-field|--input)(?:$|=)/.test(flag.name) || /^-[fF]./.test(flag.name));
}

function isRawMerge(args) {
  const { positionals, flags } = ghArguments(args);
  if (asksForHelp(flags)) return false;
  if (positionals[0] === "pr" && positionals[1] === "merge") {
    return !flags.some((flag) => flag.name === "--disable-auto");
  }
  if (positionals[0] !== "api" || positionals.length < 2) return false;
  const endpoint = positionals[1];
  if (endpoint === "graphql") {
    return args.some((word) => GRAPHQL_MERGE_MUTATION.test(word.value));
  }
  if (!REST_MERGE_ENDPOINT.test(endpoint)) return false;
  const method = apiMethod(flags) || (apiSendsBody(flags) ? "POST" : "GET");
  return method !== "GET" && method !== "HEAD";
}

// A literal `sh|bash|zsh -c <payload>` program, or null.
function shellPayload(position) {
  if (!position.command || !SHELLS.has(basename(position.command.value))) return null;
  for (let i = position.index + 1; i < position.words.length; i += 1) {
    if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(position.words[i].value)) continue;
    let payloadIndex = i + 1;
    if (position.words[payloadIndex]?.value === "--") payloadIndex += 1;
    const payload = position.words[payloadIndex];
    return payload && payload.literal && payload.subs.length === 0 ? payload.value : null;
  }
  return null;
}

// A literal `eval <words...>` program, or null.
function evalPayload(position) {
  if (!position.command || basename(position.command.value) !== "eval") return null;
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return null;
  return payloads.map((payload) => payload.value).join(" ");
}

// Every program nested inside one command-list node: subshell and brace
// groups, command substitutions, wrapper-embedded programs (env -S), and
// literal shell -c and eval payloads. Unlike a cwd change, a merge still lands
// when it runs in a subshell or a child shell, so all of them are inspected.
function nestedPrograms(tokens, position) {
  const programs = [...position.wrapperPayloads];
  for (const token of tokens) {
    if (token.type === "group") programs.push(token.content);
    if (token.type === "word") programs.push(...token.subs.map((substitution) => substitution.content));
  }
  const shell = shellPayload(position);
  if (shell !== null) programs.push(shell);
  const evaluated = evalPayload(position);
  if (evaluated !== null) programs.push(evaluated);
  return programs;
}

function programMerges(command, depth) {
  if (depth > MAX_DEPTH) return false;
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize. The merge guard's
  // threat model is agent mistakes - an accidental `gh pr merge 12` always
  // tokenizes - so it prioritizes zero false blocks over catching malformed or
  // deliberately obfuscated bypasses, which stay out of scope by design.
  if (lexed.error) return false;

  const { nodes } = splitProgram(lexed.tokens);
  for (const tokens of nodes) {
    const position = commandPosition(tokens);
    if (position.command && GH_COMMANDS.has(basename(position.command.value))) {
      if (isRawMerge(position.words.slice(position.index + 1))) return true;
    }
    for (const program of nestedPrograms(tokens, position)) {
      if (programMerges(program, depth + 1)) return true;
    }
  }
  return false;
}

function decision(command) {
  if (programMerges(command, 0)) return { decision: "deny", code: "raw-pr-merge", reason: REASONS["raw-pr-merge"] };
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
