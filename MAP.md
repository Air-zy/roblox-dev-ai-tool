# MAP

Where things are. Line numbers are real as of writing; if one drifts, the symbol
name beside it is what to grep for.

Keep this honest or delete it. A map that lies costs more than no map.

## Layers

Nothing is circular. `Terminal` requires `Shell`; `Shell` never requires
`Terminal` — handlers take a terminal as `self` instead.

```
main.lua                        window, toolbar, popups, usage panel
  Commands                      slash commands
    ui/Sessions                 session list, save/load/restore
      agent/Agent               the turn loop
        agent/Provider          which provider is live; the picker
          providers/Stream          one streaming request, retried, cancellable
          providers/Retry           when to come back, and how long to wait
          providers/ToolJson        decoding arguments the model wrote, encoding them back
          providers/Pkce            verifier, challenge, state
          providers/Anthropic       Messages API; one request, SSE back
          providers/AnthropicAuth   PKCE, refresh, usage
          providers/OpenAI          Responses API; translation both ways
          providers/OpenAIAuth      ChatGPT device OAuth and subscription limits
          providers/ChatCompletions chat/completions wire + translation, OpenRouter and Nvidia
          providers/OpenRouter      its body, cache breakpoints, free model list
          providers/OpenRouterAuth  PKCE (no refresh: the key is the credential)
          providers/Nvidia          NIM chat/completions; the same translation
          providers/KeyAuth         a pasted key: the auth module Gemini and NVIDIA share
          providers/NvidiaAuth      KeyAuth plus a send-rate meter
          providers/Gemini          native generateContent; thought signatures
          providers/GeminiAuth      KeyAuth, and nothing else
        agent/Tools             registry; tools/ is one file per tool
    ui/Console -> ui/Markdown -> ui/Theme
      ui/SourceDiff             a tool call's source changes, as text
    ui/Find                     search the open conversation
    ui/Settings
    fs/Terminal                 commands as DataModel operations
      fs/Shell                  command line: tokens, flags, pipes, HANDLERS
      fs/Fs                     paths, .Source, undo, mtime, globs
      studio/Props              property names + defaults (API dump)
      studio/Exec               executes Luau      (run tool only, required on first use)
      studio/Catalog            free models        (catalog tool only, required on first use)
      text/Regex                BRE/ERE engine
      text/Diff                 line alignment, hunk grouping
      text/Sed                  sed engine
      text/Awk                  awk language: lexer, parser, interpreter
      git/Git                   object ids, path mapping, working-tree walk
      vendor/LuauParser         Luau grammar; the syntax check on write
```

## Where does X happen

| Question | Answer |
|---|---|
| the system prompt is built | `providers/Anthropic.lua:305` `systemBlocks` — identity first, user block if non-empty, cache_control on the last. OpenRouter and Nvidia build a system message in `ChatCompletions.toMessages`; OpenAI sends `instructions` |
| the user's system prompt is stored | `Settings.lua:85` `Settings.system()`, default `DEFAULT_SYSTEM:35` (one line, edit-mode framing) |
| a request is assembled | `providers/Anthropic.lua` `streamMessage` -> `applyReasoning` -> tools+cache -> `withMessageCache`. OpenRouter and Nvidia use `ChatCompletions.toMessages` + `toTools`; OpenAI uses `toResponseInput` + `toResponseTools` |
| a response is parsed | each wire module's `onFrame`; OpenAI dispatches Responses event types, Anthropic dispatches SSE event names, and `ChatCompletions` reads chat-completion data chunks for OpenRouter and Nvidia |
| the socket, the retries, the latches | `providers/Stream.lua:56` `Stream.open` — `fail:135` is the one decision point, `processFrames:240` splits frames, `start:255` opens each attempt. There is exactly ONE copy of this; providers supply a request and read frames |
| when a failure is worth retrying | `providers/Retry.lua` — `isRetryable`, `isOverload`, `delay`, `retryAfterSeconds`. Header names stay with the provider that spells them |
| a tool call's arguments are decoded | `providers/ToolJson.lua:38` `ToolJson.decode` — strict first, then `escapeControlChars:18` for a raw newline the model owed a `\n`. Shared: the failure is the model's, not the wire's |
| effort / thinking / the output ceiling | `providers/Anthropic.lua:160` `applyReasoning` against `MODEL_CAPS:80`; the ceiling is `maxOutput` on the same table. OpenRouter sends `reasoning.effort` and NO `max_tokens` — the model's own ceiling is the right default across several hundred models. `Settings` picks a level and nothing else |
| Anthropic blocks <-> chat-completion messages | `providers/ChatCompletions.lua:33` `toMessages` out, `:304` `onFrame` back. The internal conversation is Anthropic-shaped; the wire converts at its own edge so Agent, Sessions and Find never learn a second shape |
| a thinking block's signature, on OpenRouter | a JSON envelope holding `reasoning_details` (or plain reasoning text). Written in `assemble` inside `ChatCompletions.stream`, read back by `reasoningFrom:23`. Opaque to everything else, which is what the signature contract already said |
| a thinking block's signature, on OpenAI | a JSON envelope holding the complete Responses output sequence, including encrypted reasoning and the server IDs of its paired following items; `toResponseInput` replays it verbatim for the same model and falls back to visible blocks after a model switch |
| which provider is live | `agent/Provider.lua` — `REGISTRY:20`, `use:64`, `list:47`. Read `Provider.wire.x` AT THE POINT OF USE: the pair is replaced on a switch, and a `local Wire = Provider.wire` would keep talking to the old one |
| the free model list | `providers/OpenRouter.lua:106` `refreshModels` — fetched, filtered to free AND tool-capable, cached in plugin settings for a day. The seed list at `:38` is only a fallback |
| the turn loop | `Agent.lua:510` `runTurn` |
| Stop | `Agent.lua:~628` `stopCurrent`, reached through `Agent.stop`. The queued continuation re-checks `cancelRequested` after its wait (`continueTurn:618`), and `committed:592` is what keeps Stop from rolling back a turn already in the history |
| a turn's result is handled | `Agent.lua:782` `onComplete` -> assemble -> dispatch tools -> `continueTurn:618` |
| the user hits enter | `main.lua:839` `submit` -> `Commands.handle:236` -> `Agent.send:1134` |
| a tool runs | `Tools.lua:118` `dispatch` — never throws; returns the model result, and the source changes the call applied as a second value the console draws a diff from |
| tool definitions on the wire | `Tools.lua:78` `definitions` + `Agent.lua:218` `buildTools` |
| model / thinking / effort / search per model | `providers/Anthropic.lua:80` `MODEL_CAPS`; UI list at `:125`. OpenRouter has neither: no caps table, and its list is fetched |
| beta headers | `providers/Anthropic.lua:53` — read the comment before adding one |
| history trimming | `Agent.lua:448` `clearOldToolResults`, gated by `cacheIsCold:~392` |
| one result capped / a turn's batch capped | `Agent.lua:139` `forModel`, `:167` `capTurn` |
| login | `providers/AnthropicAuth.lua` owns PKCE and refresh. OpenRouter owns its PKCE/key exchange. OpenAI uses Codex's ChatGPT device OAuth and refresh-token flow; it rejects API keys. NVIDIA and Gemini store a pasted project key |
| the usage rows in Settings | each `auth.fetchUsage()` returns rows ALREADY FORMATTED (`{label, value, bar?}`). Anthropic reports two rolling utilisation windows, OpenRouter reports credits and the free request cap; `main.lua` `usageRows` just draws whatever it is handed |
| a shell line runs | `Shell.lua:5838` `Shell.run` -> `ShellRuntime.lua:514` `Runtime.run` -> `execute:116`, which hands each simple command back through `runtimeApi:5787` to `runCommand`; entered from `Terminal:shell:1308` |
| a line becomes an AST | `ShellSyntax.lua:90` `Syntax.lex`, `:161` `Syntax.parse` |
| flags parsed / refused | `Shell.lua:138` `partition` against `SPECS:449` |
| the command table | `Shell.lua:863` `HANDLERS` |
| loops, `if`, `case`, functions | parsed by `Syntax.parse`, run by `ShellRuntime.lua:116` `execute` |
| the list `/help` prints | `Shell.lua:5722` `Shell.COMMANDS` |
| `$(...)`, `$((...))`, braces, globs | `ShellWords.lua:306` `Words.expand`, `:11` `Words.arithmetic` |
| heredocs / redirection | parsed by `Syntax.parse`, applied in `ShellRuntime.lua` `execute`; the file reads and writes go through `runtimeApi` |
| diff | alignment and hunk grouping in `text/Diff.lua` (`Diff.align`, `Diff.hunks`); the flags, the `@@` formatting and the handler stay in `Shell.lua:3860` `diffOne` and `:3920` `HANDLERS.diff` |
| a path becomes an instance | `Fs.lua:304` `Fs.resolve` — also `.luau` suffixes and root case-folding |
| an instance becomes a path | `Fs.lua:265` `instancePath` |
| a script is read / written | `Fs.lua:69` `getSource`, `:116` `Fs.writeSource` |
| undo recording | `Fs.lua:672` `Fs.withUndo` — every mutation goes through it |
| root/service protection | `Fs.lua:691` `Fs.guardProtected` |
| modification times (we keep our own) | `Fs.lua:507` `Fs.watch` |
| ls / cat / stat / find / grep / tree | `Terminal.lua:113 / 133 / 206 / 250 / 315 / 402` |
| a walk stays off the main thread's back | `Fs.lua:645` `Fs.breather` — one call per node in `Terminal:find:281`, `:grep:348`, `:tree:426` and `ls -R` (`Shell.lua:1213`) |
| the root listing collapses empty services | `Shell.lua:1206` `hideEmpty`; `ls -a /` is the complete form |
| write / multiedit | `Terminal.lua:556 / 603` |
| the syntax check on a write | `Fs.lua:156` `Fs.syntaxErrors`, appended by `Terminal.lua:550` `withSyntax`. Never rejects a write, only annotates one |
| Luau is executed | `studio/Exec.lua:424` `Exec.run`; PROLOGUE at `:56`, every entry one physical line |
| the run guard (off by default) | `studio/Exec.lua:31` `setRunGuard`, backed by `Settings.allowRun`, held in `Terminal` until Exec loads |
| free models | `studio/Catalog.lua:186` `search`, `:247` `load` |
| regex compiled / matched | `text/Regex.lua:772` `compile`, `:743` `Program:find` |
| sed parsed / applied | `text/Sed.lua:195` `parseSedCommand`, `:102` `substitute` |
| awk parsed / run | `text/Awk.lua:185` `lex`, `:343` `parse`, `:2631` `Awk.run`; records `:1617` `readRecord`, fields `:1484` `splitWith`, the time limit `:1398` `tick`. The handler is `Shell.lua:4151` `HANDLERS.awk`, and `exitStatus:424` is how it reports a status or an error beside its output |
| property names / defaults | `studio/Props.lua:90` `names`, `:137` `default` |
| sessions | `Sessions.lua:172` `save`, `:396` `load`, `:516` `restoreLast` |
| a session is bound to its provider | stamped on the index Entry in `save`, checked in `load:396`, filtered in `restoreLast:516`. Missing means Claude, so nothing written before this needs migrating. A cross-provider restore is refused: thinking signatures are only readable by the provider that issued them |
| another session is read mid-turn | `Sessions.lua:388` the peek branch of `load` — no `Agent.restore`, `currentId` never moves. Parked blocks in `previewHolder:239`, put back by `endPeek:259` or dropped by `dropPeek:250` |
| where a new console block is parented | `Console.lua:32` `sink` — `output` normally, a detached holder during a peek. `detach:273` / `reattach:285` / `discard:302`, and `onScreen:307` for anything the reader asked to see |
| a block gets its LayoutOrder | `Console.lua:42` `takeOrder` — a counter, never a child count. The holder a peek detaches holds three fewer children than the frame it came from, so counting numbered a block below ones already on screen |
| the session list is filtered | `Sessions.lua:489` `query`, box at `:508`, applied in `draw` |
| a conversation is searched | `Find.lua:69` `Find.scan` — every block type, thinking and tool output included. Each hit carries the message it is in; the panel is `:126` `Find.mount` |
| clicking a result reaches the message | `Find` hands the index to `Sessions.reveal:420`, which grows a short replay until the message is drawn, then `Console.jumpToMessage:235`. Anchors are a `msg` attribute set by `Console.setMessage:206` and resolved at-or-below by `anchorFor:218` |
| a key reaches the plugin | it mostly does not — read the comment at `main.lua:517` before adding a shortcut, it carries the doc citations and the three rounds of trying already spent. UIS is client-window-only, ContextActionService likewise, `GuiObject.InputBegan` is the only in-widget event and a focused TextBox beats it, and a focused TextBox is the normal state here. What works: Shift+Esc, read off the `cause` of `inputBox.FocusLost:875`, and the bindable `PluginAction:531` |
| an icon renders as a tofu box | the name has no ligature in `BuilderIcons-Regular.ttf`. The font has NO single-character ligatures, which is what made a plain `x` a square for as long as the settings panel has had a close button. See the note at `Theme.lua:39` |
| a session is written to disk | the busy -> idle edge in `main.lua:819`, plus `onCheckpoint:241` — fired by `Agent.send` as the message goes in, and by `continueTurn(true):590` after each batch of tool results |
| text on screen | `Console.lua:256` `appendLine`, `:624` `createBubble`, `:931` `appendToolCall` |
| a tool call shows what it changed | captured on the Terminal, keyed by coroutine (`beginCapture`/`endCapture`, scope opened by `Tools.dispatch`). Hooks: `:write`/`:multiedit` (which every shell write routes through), `:remove` (read before the detach), and `transfer` (after it settles, so a rollback records nothing). `mv` and `reload` record nothing — same Instance, same text — except what an `mv` displaced. Handed back as `Tools.dispatch`'s second return, drawn by `Console.appendToolCall`'s `setChanges` through `ui/SourceDiff`. NOT stored: the patch lives in the block and dies with it, and catalog inserts and `run` are outside capture |

## Per file

| File | Lines | Owns |
|---|---:|---|
| `fs/Shell.lua` | 7239 | The command line. The biggest thing here we actually wrote — see below. |
| `agent/Agent.lua` | 1842 | Turn loop, conversation state, trimming, stop. |
| `ui/Console.lua` | 1355 | Bubbles, thinking drawers, tool-call blocks, the detached sink. |
| `text/Regex.lua` | 957 | BRE/ERE engine. Requires nothing. |
| `vendor/LuauParser.lua` | 7718 | VENDORED, do not edit. Luau's own Parser.cpp ported to Luau. Two patched require lines, see the header. `LuauSyntax` 1043 and `LuauConfusables` 1790 sit beside it. |
| `main.lua` | 1168 | Widget, toolbar, popups, shell mode on the input row. Owns `plugin`, hands it to Provider / Sessions / Settings / Git — the only five that touch it. |
| `fs/Terminal.lua` | 839 | Commands as tree operations. No parsing. |
| `fs/Fs.lua` | 843 | Paths, `.Source`, undo, mtime, globs, mode bits. |
| `agent/providers/OpenAI.lua` | 920 | Responses API, and the translation both ways. |
| `agent/providers/ChatCompletions.lua` | 415 | The chat/completions wire and translation, shared by OpenRouter and Nvidia. |
| `agent/providers/OpenRouter.lua` | 354 | Its request body, cache breakpoints and free model list. |
| `agent/providers/Nvidia.lua` | 460 | NIM chat/completions. Two reasoning switches, one per model. |
| `agent/providers/Gemini.lua` | 1027 | Native generateContent. Carries thought signatures across turns. |
| `agent/providers/Anthropic.lua` | 824 | One request. Knows nothing about turns. |
| `agent/providers/Stream.lua` | 552 | The socket, the retries, the latches. One copy. |
| `ui/Sessions.lua` | 888 | Session list, filter, peek and persistence. |
| `ui/Settings.lua` | 603 | Preferences + panel. |
| `studio/Exec.lua` | 564 | Luau execution. Tool-only. |
| `agent/providers/AnthropicAuth.lua` | 507 | PKCE login, refresh, usage rows. |
| `agent/providers/OpenAIAuth.lua` | 520 | ChatGPT device OAuth, refresh and Codex subscription-limit rows. |
| `agent/providers/OpenRouterAuth.lua` | 273 | PKCE login, or a pasted key. Credits. |
| `agent/providers/KeyAuth.lua` | 90 | The pasted-key auth module, shared by Gemini and NVIDIA. |
| `agent/providers/NvidiaAuth.lua` | 62 | KeyAuth, and a rolling send-rate meter. |
| `agent/providers/GeminiAuth.lua` | 27 | KeyAuth. No flow to speak of. |
| `agent/providers/Retry.lua` | 229 | What is worth retrying, and how long to wait. |
| `agent/providers/ToolJson.lua` | 101 | Decoding arguments the model wrote, and encoding them back. |
| `agent/providers/Pkce.lua` | 70 | verifier / challenge / state. |
| `studio/Catalog.lua` | 401 | Free model search / insert. Tool-only. |
| `ui/Find.lua` | 423 | Conversation search + the find panel. |
| `ui/SourceDiff.lua` | 141 | A tool call's source changes as text: counts, the header line, the capped patch body. Pure — no GUI, so the CLI regressions cover it. |
| `ui/Markdown.lua` | 346 | Markdown to labels. |
| `text/Diff.lua` | 157 | Line alignment (LCS over the differing middle) and hunk grouping. Pure text; requires nothing. |
| `text/Sed.lua` | 329 | sed engine. Pure text. |
| `text/Awk.lua` | 2754 | awk: lexer, parser, tree-walking interpreter, printf. Requires only Regex; file I/O comes in as callbacks. |
| `main/Commands.lua` | 279 | Slash commands, and `runShell`, shared by `/sh` and shell mode. |
| `studio/Props.lua` | 200 | API dump. The only network I/O in fs. |
| `git/Git.lua` | 818 | Object ids, the path mapping, the index, the tree payload, the remote-tree filters clone reads. No I/O — the requests live in Shell beside curl's. |
| `agent/Tools.lua` | 118 | Registry + dispatch. |
| `ui/Theme.lua` | 99 | Colours and `make`. |
| `agent/Provider.lua` | 115 | The active provider, the registry, and the switch. |
| `agent/tools/*.lua` | 17-50 | One per tool. |

## Inside Shell.lua

| Lines | Region |
|---:|---|
| 1-137 | header, requires, aliases |
| 138-862 | `partition:138`, `SPECS:449` and the shared helpers |
| 863-4984 | HANDLERS + private helpers |
| 4985-5715 | `materialize:4985` (pull and clone share it) and `HANDLERS.git:5061` |
| 5716-5786 | `Shell.COMMANDS:5722`, `runCommand` |
| 5787-5846 | `runtimeApi:5787`, `Shell.run:5838` |
| 5847-end | `Shell.selfTest:5847` |

The language itself (lexing, parsing, expansion, execution) is in `ShellSyntax`,
`ShellWords` and `ShellRuntime`; `HANDLERS` does not split (below).

## Conventions

- Every mutation goes through `Fs.withUndo`. Bypassing it is data loss.
- `selfTest` is a convention, not a framework: `Pkce`, `Regex`, `Awk`, `Props`,
  `Markdown`, `Sessions`, `Find`, `Console`, `Shell`, `Agent`, `Exec`, `Catalog`,
  `Git` and `Terminal` export one, and `/selftest` in `Commands` runs them — on
  demand, not at startup, where ~1800 lines of them ran on the frame the widget
  opened. A module that gains logic gains a selfTest, and `Terminal.selfTest`
  chains the fs-side ones.
- Scripts render as `name.luau`. `Fs.displayName` adds it, `Fs.resolve` strips
  it, name matching tries both.
- `Exec`'s PROLOGUE entries are each one physical line — its length is the
  offset that translates error line numbers back to the caller's code.
- A tool description is paid on every request. Explanations belong in error
  messages, which cost nothing until a call needs them.

## Remaining

Refactor steps not yet done.

| # | Step |
|---|---|
| 2 | move `onComplete` block assembly + `clearOldToolResults` from Agent into the provider. Still open, and now clearly worth it: `Agent.lua:~820` still walks Anthropic block types by name, which is why OpenRouter has to speak that shape |
| 3 | neutral tool schema in `Tools.lua`; provider maps to `input_schema`. Half-done by accident — OpenRouter and OpenAI already map it, so `Tools.definitions` is the only thing still emitting Anthropic's spelling |
| 6 | extract `Argv` from Shell into `text/`. `Diff` is DONE: `text/Diff.lua` owns the aligner and hunk grouping; Shell keeps -w/-b/-i and the unified formatting, which are `diff` options rather than properties of an alignment |
| 8 | rename `Terminal:run` -> `Terminal:exec` (`Shell.run` already means a command line) |

Done since this list was written: **4** (`Settings` no longer reaches into
`wire` for anything but `DEFAULT_MODEL` and `acceptsModelId`, both of which are
provider API rather than internals) and **5** (sessions carry their provider and
refuse a cross-provider restore).

`HANDLERS` does not split: its 33 commands share a dozen file-local helpers, so
grouping them means threading a context table through every signature or copying
helpers — the failure already paid for twice with `classFor` and `ensureScript`.

Nothing here has run in Studio yet. The startup self-tests are the real gate.
