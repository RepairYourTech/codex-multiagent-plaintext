# codex-multiagent-plaintext

Patched Codex desktop core that fixes **MultiAgentV2 subagents on third-party
providers** — children spawned via `spawn_agent` / `send_message` /
`followup_task` receive their task as provider-encrypted content that only
OpenAI models can read, so any child on an OpenAI-compatible provider
(DeepSeek, local routers, gateways, custom endpoints, ...) gets an **empty
task and silently does nothing**.

This implements the fix specified in
[openai/codex#37197](https://github.com/openai/codex/issues/37197) and
requested in [#46939](https://github.com/openai/codex/issues/46939), covering
the failure modes reported in
[#34833](https://github.com/openai/codex/issues/34833),
[#36376](https://github.com/openai/codex/issues/36376),
[#36586](https://github.com/openai/codex/issues/36586) and
[#37237](https://github.com/openai/codex/issues/37237).
No upstream fix has shipped yet; if one lands, this project becomes
unnecessary (see [Maintenance](#maintenance)).

**Unofficial.** Not affiliated with or endorsed by OpenAI. Patch and binaries
are Apache-2.0, same as [openai/codex](https://github.com/openai/codex).

This patch is meant to be used with
[opencodex](https://github.com/lidge-jun/opencodex) — a local proxy that lets
Codex use almost any LLM provider. opencodex (or any similar router) gets
third-party models **into** Codex; this patch makes MultiAgentV2 subagents on
those models actually **receive their tasks**. See
[Pairing with opencodex](#pairing-with-opencodex).

## What the patch does

- Adds an opt-in delivery policy; **encrypted stays the default**, so OpenAI ↔
  OpenAI sessions behave exactly as before:
  ```toml
  [features.multi_agent_v2]
  message_delivery = "plaintext"   # "encrypted" (default) | "plaintext"
  tool_namespace = "agents"        # non-reserved namespace; needed when the
                                   # PARENT model is served by OpenAI, because
                                   # the reserved `collaboration` namespace
                                   # enforces the encrypted schema server-side
  ```
- Plaintext mode removes the encrypted marker from the three collaboration
  tool schemas and classifies their calls as plaintext, so the task text
  reaches the child as readable `input_text` instead of an `encrypted_content`
  part that third-party providers drop.
- **Fail-closed with diagnostics** (the #37237 ask): when an *encrypted*
  delivery would target a non-OpenAI child, the tool call fails loudly
  **before** the child is created — no more silently-created empty agents.
- Real ciphertext is never re-labeled as plaintext.
- Environment overrides `CODEX_MULTI_AGENT_V2_MESSAGE_DELIVERY` /
  `CODEX_MULTI_AGENT_V2_TOOL_NAMESPACE` — used by the installer so the shared
  `~/.codex/config.toml` stays untouched (stock codex builds reject unknown
  keys, and router tools rewrite managed config blocks).

## Install (Linux, one command)

```bash
curl -fsSL https://raw.githubusercontent.com/RepairYourTech/codex-multiagent-plaintext/main/install.sh | bash
```

Or clone the repo and run `./install.sh` (uses the bundled binary if present,
otherwise downloads the release for your platform). The installer:

1. installs the patched core to `~/.local/share/codex-plaintext/bin/codex`,
2. symlinks your app's `codex-code-mode-host` next to it (**required** — the
   core launches its exec/browser command host from its own directory; without
   the sibling, `functions.exec` and the browser tool break),
3. writes a **user-level** `.desktop` override that launches the app with
   `CODEX_CLI_PATH` pointing at the patched core plus the plaintext env.

No root. Nothing outside your home directory is modified. Works with both the
community Linux distro and the official `chatgpt` package. Then **fully quit
and relaunch** the Codex desktop app.

### macOS / Windows

Grab the right binary from
[Releases](https://github.com/RepairYourTech/codex-multiagent-plaintext/releases)
or run `./build.sh` to build from source, then wire it manually:

- **macOS**: `launchctl setenv CODEX_CLI_PATH <path>/codex` (plus the two
  `CODEX_MULTI_AGENT_V2_*` vars, same values), place a copy of the app's
  `codex-code-mode-host` next to the binary, restart the app.
- **Windows**: set `CODEX_CLI_PATH` and the two env vars as user environment
  variables, place `codex-code-mode-host.exe` next to the patched exe,
  restart the app.

### Verify it works

Ask your app (parent on any model) to spawn a subagent **on a third-party
model** with the task *"Reply with exactly DELIVERY_OK"*, then report the
child's answer. Before the patch the child answers something like *"I don't
see a specific task"*; after it, the child replies `DELIVERY_OK`.

## Pairing with opencodex

[opencodex](https://github.com/lidge-jun/opencodex) is a MIT-licensed local
proxy (TypeScript on a bundled Bun runtime) that translates Codex's Responses
API to 40+ providers — Anthropic, Gemini, xAI, DeepSeek, Kimi, Qwen, Ollama,
OpenRouter, or any OpenAI-compatible endpoint — with model routing via
`provider/model`, failover combos, OAuth logins, and a web dashboard:

```bash
npm install -g @bitkyc08/opencodex
ocx start
```

The two projects solve complementary halves of the same problem:

- **opencodex** routes Codex sessions to third-party providers.
- **This patch** fixes MultiAgentV2 subagent delivery on those providers —
  without it, children spawned through any router receive an empty task and
  silently do nothing (their assignment travels as OpenAI-encrypted content
  the router's providers cannot read).

Install opencodex first, then run this installer, then use the DELIVERY_OK
test below to confirm cross-provider subagents work end-to-end. Note that the
patch itself is provider-agnostic: it works with any OpenAI-compatible
provider, whether routed through opencodex, another gateway, or configured
directly.

## Subagent concurrency

The installer also makes sure `features.multi_agent_v2.max_concurrent_threads_per_session`
is set in your global `~/.codex/config.toml`, **defaulting to 4 — one main agent
plus up to 3 concurrent subagents**. If you already have a value there, it is
left untouched; otherwise a timestamped `config.toml.bak-codex-plaintext-*`
backup is written next to it before editing. This is a stock codex key, so it
stays compatible with unpatched codex builds.

Want more subagents running at once? Raise it, e.g.:

```toml
[features.multi_agent_v2]
max_concurrent_threads_per_session = 8   # 1 main agent + 7 subagents
```

Keep in mind that every concurrent subagent is its own model conversation:
more parallelism burns tokens faster and can hit provider rate limits, so the
conservative default of 4 is usually what you want.

## Compatibility

Built and verified against core `codex-cli 0.155.0-alpha.9.2` (desktop
26.915-era). The installer warns if your app bundles a different core
version — mild skew usually works; rebuild the patch on your exact tag if
anything misbehaves (`./build.sh rust-v<your-version>` after rebasing the
patch, see below).

## Uninstall

```bash
rm -f  ~/.local/share/applications/codex-desktop.desktop   # or chatgpt.desktop
rm -rf ~/.local/share/codex-plaintext
```

Then fully quit and relaunch the app. macOS: `launchctl unsetenv` the three
variables. Your `~/.codex/config.toml` was never touched.

## Security & trust

The task text of multi-agent messages is delivered **in plaintext** to
whatever provider serves the child (that is the point). If that is
unacceptable for some workflow, keep the default and only spawn
OpenAI-served children. Don't trust random binaries: every release is
reproducible from this repo — `build.sh` clones the exact upstream tag,
applies `plaintext-delivery.patch`, and builds. Audit the patch (it's ~580
lines across feature config, tool schemas, call classification, and the V2
handlers) and build your own binary if you prefer.

## Maintenance

`plaintext-delivery.patch` is a `git diff` against upstream tag
`rust-v0.155.0-alpha.9.2`. To move to a newer core:

```bash
git clone --depth 1 --branch rust-v<new-tag> https://github.com/openai/codex.git
git -C codex apply --3-way plaintext-delivery.patch   # resolve any conflicts
cd codex/codex-rs && cargo build --release -p codex-cli && strip target/release/codex
```

The CI workflow (`.github/workflows/build.yml`) builds all platforms from a
tag via *Actions → build-release → Run workflow* and attaches the artifacts
to a release. When OpenAI ships an upstream config option (#46939), delete
this and use the stock knob.

## License

Apache-2.0. This project patches and redistributes build instructions for
[openai/codex](https://github.com/openai/codex); see `LICENSE` and `NOTICE`.
