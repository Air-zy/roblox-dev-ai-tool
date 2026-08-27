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
          providers/ToolJson        decoding arguments the model wrote
          providers/Pkce            verifier, challenge, state
          providers/Anthropic       Messages API; one request, SSE back
          providers/AnthropicAuth   PKCE, refresh, usage
          providers/OpenRouter      chat/completions; translation both ways
          providers/OpenRouterAuth  PKCE (no refresh: the key is the credential)
        agent/Tools             registry; tools/ is one file per tool
    ui/Console -> ui/Markdown -> ui/Theme
    ui/Find                     search the open conversation
    ui/Settings
    fs/Terminal                 commands as DataModel operations
      fs/Shell                  command line: tokens, flags, pipes, HANDLERS
      fs/Fs                     paths, .Source, undo, mtime, globs
      studio/Props              property names + defaults (API dump)
      studio/Exec               executes Luau      (run tool only)
      studio/Catalog            free models        (catalog tool only)
      text/Regex                BRE/ERE engine
      text/Sed                  sed engine
      git/Git                   object ids, path mapping, working-tree walk
      vendor/LuauParser         Luau grammar; the syntax check on write
```

## Where does X happen

| Question | Answer |
|---|---|
| the system prompt is built | `providers/Anthropic.lua:305` `systemBlocks` — identity first, user block if non-empty, cache_control on the last. OpenRouter has no identity block and builds a plain system message in `toChatMessages:273` |
| the user's system prompt is stored | `Settings.lua:85` `Settings.system()`, default `DEFAULT_SYSTEM:35` (one line, edit-mode framing) |
| a request is assembled | `providers/Anthropic.lua:259` `streamMessage` -> `applyReasoning:160` -> tools+cache -> `withMessageCache:211`. OpenRouter: `streamMessage:396` -> `toChatMessages:273` + `toChatTools:370` |
| a response is parsed | `providers/Anthropic.lua:~420` `onFrame`, dispatching on the SSE `event:` name. OpenRouter: `OpenRouter.lua:599` `onFrame`, which has no `event:` lines at all — every frame is a `data:` chunk |
| the socket, the retries, the latches | `providers/Stream.lua:56` `Stream.open` — `fail:135` is the one decision point, `processFrames:240` splits frames, `start:255` opens each attempt. There is exactly ONE copy of this; providers supply a request and read frames |
| when a failure is worth retrying | `providers/Retry.lua` — `isRetryable`, `isOverload`, `delay`, `retryAfterSeconds`. Header names stay with the provider that spells them |
| a tool call's arguments are decoded | `providers/ToolJson.lua:57` `ToolJson.decode` — strict first, then `escapeControlChars:34` for a raw newline the model owed a `\n`. Shared: the failure is the model's, not the wire's |
| effort / thinking / the output ceiling | `providers/Anthropic.lua:160` `applyReasoning` against `MODEL_CAPS:80`; the ceiling is `maxOutput` on the same table. OpenRouter sends `reasoning.effort` and NO `max_tokens` — the model's own ceiling is the right default across several hundred models. `Settings` picks a level and nothing else |
| Anthropic blocks <-> OpenAI messages | `providers/OpenRouter.lua:273` `toChatMessages` out, `:599` `onFrame` back. The internal conversation is Anthropic-shaped; OpenRouter converts at its own edge so Agent, Sessions and Find never learn a second shape |
| a thinking block's signature, on OpenRouter | a JSON envelope holding `reasoning_details` (or plain reasoning text). Written in `assemble` inside `streamMessage`, read back by `reasoningFrom:263`. Opaque to everything else, which is what the signature contract already said |
| which provider is live | `agent/Provider.lua` — `REGISTRY:20`, `use:64`, `list:47`. Read `Provider.wire.x` AT THE POINT OF USE: the pair is replaced on a switch, and a `local Wire = Provider.wire` would keep talking to the old one |
| the free model list | `providers/OpenRouter.lua:160` `refreshModels` — fetched, filtered to free AND tool-capable, cached in plugin settings for a day. The seed list at `:77` is only a fallback |
| the turn loop | `Agent.lua:510` `runTurn` |
| Stop | `Agent.lua:~628` `stopCurrent`, reached through `Agent.stop`. The queued continuation re-checks `cancelRequested` after its wait (`continueTurn:618`), and `committed:592` is what keeps Stop from rolling back a turn already in the history |
| a turn's result is handled | `Agent.lua:782` `onComplete` -> assemble -> dispatch tools -> `continueTurn:618` |
| the user hits enter | `main.lua:839` `submit` -> `Commands.handle:236` -> `Agent.send:1134` |
| a tool runs | `Tools.lua:106` `dispatch` — never throws |
| tool definitions on the wire | `Tools.lua:78` `definitions` + `Agent.lua:218` `buildTools` |
| model / thinking / effort / search per model | `providers/Anthropic.lua:80` `MODEL_CAPS`; UI list at `:125`. OpenRouter has neither: no caps table, and its list is fetched |
| beta headers | `providers/Anthropic.lua:53` — read the comment before adding one |
| history trimming | `Agent.lua:448` `clearOldToolResults`, gated by `cacheIsCold:~392` |
| one result capped / a turn's batch capped | `Agent.lua:139` `forModel`, `:167` `capTurn` |
| open-editor hint on each message | `Agent.lua:1098` `editorContext` — `""` when nothing is open; capped by `MAX_OPEN_DOCS`/`MAX_OPEN_CHARS` just above it |
| login | `providers/AnthropicAuth.lua:~160` `startLogin` -> `completeLogin`; refresh, used by `getAccessToken`. OpenRouter: `OpenRouterAuth.lua:69` `startLogin` -> `:88` `completeLogin`, which also accepts a pasted `sk-or-` key. No refresh there — the credential is a key and does not expire |
| the usage rows in Settings | each `auth.fetchUsage()` returns rows ALREADY FORMATTED (`{label, value, bar?}`). Anthropic reports two rolling utilisation windows, OpenRouter reports credits and the free request cap; `main.lua` `usageRows` just draws whatever it is handed |
| a shell line runs | `Shell.lua:4762` `Shell.run` -> `runLine:4770` -> `runTokens:4632` -> `runStatements:4436` -> `runCommand:4237`; entered from `Terminal:shell:761` |
| a line becomes tokens | `Shell.lua:86` `tokenize` |
| flags parsed / refused | `Shell.lua:230` `partition` against `SPECS:574` |
| the command table | `Shell.lua:933` `HANDLERS` |
| `for` loops | `Shell.lua:4476` `parseLoop`, `:4573` `runLoop`, `:4556` `expandVar`; grouped into ONE pipeline stage by `parseStatements:4341`, run from `runLoopStage:4600` |
| the list `/help` prints | `Shell.lua:4190` `Shell.COMMANDS` |
| `$(...)` | `Shell.lua:4700` `expandSubstitutions`, `:4644` `takeSubstitution` — on the raw line, before `tokenize` |
| the `$ cmd` echo of a multi-command line | `Shell.lua:4416` `label`, quoting via `requote:4404` |
| heredocs / redirection | `Shell.lua:407` `extractHeredoc`, `:467` `takeRedirect`, `:538` `applyRedirect` |
| diff | `Shell.lua:3306` `diffOne`, handler at `:3366` |
| a path becomes an instance | `Fs.lua:304` `Fs.resolve` — also `.luau` suffixes and root case-folding |
| an instance becomes a path | `Fs.lua:265` `instancePath` |
| a script is read / written | `Fs.lua:69` `getSource`, `:116` `Fs.writeSource` |
| undo recording | `Fs.lua:672` `Fs.withUndo` — every mutation goes through it |
| root/service protection | `Fs.lua:691` `Fs.guardProtected` |
| modification times (we keep our own) | `Fs.lua:507` `Fs.watch` |
| ls / cat / stat / find / grep / tree | `Terminal.lua:113 / 133 / 206 / 250 / 315 / 402` |
| a walk stays off the main thread's back | `Fs.lua:645` `Fs.breather` — one call per node in `Terminal:find:281`, `:grep:348`, `:tree:426` and `ls -R` (`Shell.lua:1183`) |
| the root listing collapses empty services | `Shell.lua:1178` `hideEmpty`; `ls -a /` is the complete form |
| write / multiedit | `Terminal.lua:556 / 603` |
| the syntax check on a write | `Fs.lua:156` `Fs.syntaxErrors`, appended by `Terminal.lua:550` `withSyntax`. Never rejects a write, only annotates one |
| Luau is executed | `studio/Exec.lua:424` `Exec.run`; PROLOGUE at `:56`, every entry one physical line |
| the run guard (off by default) | `studio/Exec.lua:31` `setRunGuard`, backed by `Settings.allowRun` |
| free models | `studio/Catalog.lua:186` `search`, `:247` `load` |
| regex compiled / matched | `text/Regex.lua:772` `compile`, `:743` `Program:find` |
| sed parsed / applied | `text/Sed.lua:195` `parseSedCommand`, `:102` `substitute` |
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

## Per file

| File | Lines | Owns |
|---|---:|---|
| `fs/Shell.lua` | 6588 | The command line. The biggest thing here we actually wrote — see below. |
| `agent/Agent.lua` | 1352 | Turn loop, conversation state, trimming, stop. |
| `ui/Console.lua` | 1355 | Bubbles, thinking drawers, tool-call blocks, the detached sink. |
| `text/Regex.lua` | 957 | BRE/ERE engine. Requires nothing. |
| `vendor/LuauParser.lua` | 7718 | VENDORED, do not edit. Luau's own Parser.cpp ported to Luau. Two patched require lines, see the header. `LuauSyntax` 1043 and `LuauConfusables` 1790 sit beside it. |
| `main.lua` | 1168 | Widget, toolbar, popups, shell mode on the input row. Owns `plugin`, hands it to Provider / Sessions / Settings / Git — the only five that touch it. |
| `fs/Terminal.lua` | 829 | Commands as tree operations. No parsing. |
| `fs/Fs.lua` | 843 | Paths, `.Source`, undo, mtime, globs, mode bits. |
| `agent/providers/OpenRouter.lua` | 842 | chat/completions, and the translation both ways. |
| `agent/providers/Anthropic.lua` | 824 | One request. Knows nothing about turns. |
| `agent/providers/Stream.lua` | 391 | The socket, the retries, the latches. One copy. |
| `ui/Sessions.lua` | 888 | Session list, filter, peek and persistence. |
| `ui/Settings.lua` | 603 | Preferences + panel. |
| `studio/Exec.lua` | 564 | Luau execution. Tool-only. |
| `agent/providers/AnthropicAuth.lua` | 507 | PKCE login, refresh, usage rows. |
| `agent/providers/OpenRouterAuth.lua` | 273 | PKCE login, or a pasted key. Credits. |
| `agent/providers/Retry.lua` | 229 | What is worth retrying, and how long to wait. |
| `agent/providers/ToolJson.lua` | 103 | Decoding arguments the model wrote. |
| `agent/providers/Pkce.lua` | 70 | verifier / challenge / state. |
| `studio/Catalog.lua` | 401 | Free model search / insert. Tool-only. |
| `ui/Find.lua` | 423 | Conversation search + the find panel. |
| `ui/Markdown.lua` | 346 | Markdown to labels. |
| `text/Sed.lua` | 329 | sed engine. Pure text. |
| `main/Commands.lua` | 279 | Slash commands, and `runShell`, shared by `/sh` and shell mode. |
| `studio/Props.lua` | 200 | API dump. The only network I/O in fs. |
| `git/Git.lua` | 818 | Object ids, the path mapping, the index, the tree payload, the remote-tree filters clone reads. No I/O — the requests live in Shell beside curl's. |
| `util/Sha256.lua` | 181 | For PKCE. |
| `agent/Tools.lua` | 118 | Registry + dispatch. |
| `ui/Theme.lua` | 99 | Colours and `make`. |
| `agent/Provider.lua` | 115 | The active provider, the registry, and the switch. |
| `agent/tools/*.lua` | 17-50 | One per tool. |

## Inside Shell.lua

| Lines | Region |
|---:|---|
| 1-67 | header, requires, aliases |
| 68-979 | parsing: `tokenize:94`, `partition:238`, `extractHeredoc:420`, `takeRedirect:480`, `SPECS:610` |
| 980-4518 | HANDLERS — 39 commands + private helpers |
| 4519-5321 | the GitHub calls, `materialize:4623` (pull and clone share it), and `HANDLERS.git:4699` — add/clone/commit/config/diff/log/pull/reset/show/status |
| 5322-5355 | `Shell.COMMANDS:5329` |
| 5356-5868 | pipelines, statements, loops, `$(...)`: `runCommand:5356` |
| 5869-5920 | `Shell.run:5869` -> `runLine` |
| 5921-end | `Shell.selfTest:5921` |

`tokenize`/`partition` and the diff core are pure text and are the next
extractions; `HANDLERS` is not (below).

## Conventions

- Every mutation goes through `Fs.withUndo`. Bypassing it is data loss.
- `selfTest` is a convention, not a framework: `Regex`, `Props`, `Markdown`,
  `Sessions`, `Find`, `Console`, `Shell`, `Agent`, `Exec`, `Catalog`, `Git` and
  `Terminal` export one, and `main.lua` runs them at startup. A module that gains logic gains a selfTest,
  and `Terminal.selfTest` chains the fs-side ones.
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
| 3 | neutral tool schema in `Tools.lua`; provider maps to `input_schema`. Half-done by accident — `OpenRouter.toChatTools:370` already maps it, so `Tools.definitions` is the only thing still emitting Anthropic's spelling |
| 6 | extract `Diff` and `Argv` from Shell into `text/` |
| 8 | rename `Terminal:run` -> `Terminal:exec` (`Shell.run` already means a command line) |

Done since this list was written: **4** (`Settings` no longer reaches into
`wire` for anything but `DEFAULT_MODEL` and `acceptsModelId`, both of which are
provider API rather than internals) and **5** (sessions carry their provider and
refuse a cross-provider restore).

`HANDLERS` does not split: its 33 commands share a dozen file-local helpers, so
grouping them means threading a context table through every signature or copying
helpers — the failure already paid for twice with `classFor` and `ensureScript`.

Nothing here has run in Studio yet. The startup self-tests are the real gate.
