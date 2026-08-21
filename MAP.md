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
        agent/Provider          which provider is live
          providers/Anthropic       one request, SSE back
          providers/AnthropicAuth   PKCE, refresh, usage
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
```

## Where does X happen

| Question | Answer |
|---|---|
| the system prompt is built | `providers/Anthropic.lua:455` `systemBlocks` — identity first, user block if non-empty, cache_control on the last |
| the user's system prompt is stored | `Settings.lua:85` `Settings.system()`, default `DEFAULT_SYSTEM:35` (one line, edit-mode framing) |
| a request is assembled | `providers/Anthropic.lua:410` `streamMessage` -> `applyReasoning:251` -> tools+cache -> `withMessageCache:302` |
| a response is parsed | `providers/Anthropic.lua:590` `processSSEEvents` |
| a tool call's arguments are decoded | `providers/Anthropic.lua:380` `decodeToolInput` — strict first, then `escapeControlChars:358` for a raw newline the model owed a `\n` |
| effort / thinking / the output ceiling | `providers/Anthropic.lua:251` `applyReasoning` against `MODEL_CAPS:76`; the ceiling is `maxOutput` on the same table. `Settings` picks a level and nothing else — no per-effort token maths lives there |
| which provider is live | `agent/Provider.lua` — `wire` and `auth`; nothing outside `providers/` names a vendor |
| the turn loop | `Agent.lua:513` `runTurn` |
| Stop | `Agent.lua:631` `stopCurrent`, reached through `Agent.stop`. The queued continuation re-checks `cancelRequested` after its wait (`continueTurn:612`), and `committed:591` is what keeps Stop from rolling back a turn already in the history |
| a turn's result is handled | `Agent.lua:751` `onComplete` -> assemble -> dispatch tools -> `continueTurn:590` |
| the user hits enter | `main.lua:833` `submit` -> `Commands.handle:184` -> `Agent.send:1102` |
| a tool runs | `Tools.lua:106` `dispatch` — never throws |
| tool definitions on the wire | `Tools.lua:78` `definitions` + `Agent.lua:219` `buildTools` |
| model / thinking / effort / search per model | `providers/Anthropic.lua:76` `MODEL_CAPS`; UI list at `:224` |
| beta headers | `providers/Anthropic.lua:49` — read the comment before adding one |
| history trimming | `Agent.lua:451` `clearOldToolResults`, gated by `cacheIsCold:395` |
| one result capped / a turn's batch capped | `Agent.lua:140` `forModel`, `:168` `capTurn` |
| open-editor hint on each message | `Agent.lua:1057` `editorContext` — `""` when nothing is open; capped by `MAX_OPEN_DOCS:1046`/`MAX_OPEN_CHARS:1055` |
| login | `providers/AnthropicAuth.lua:219` `startLogin` -> `:262` `completeLogin`; refresh `:342`, used by `getAccessToken:406` |
| a shell line runs | `Shell.lua:4486` `Shell.run` -> `runTokens:4417` -> `runStatements:4294` -> `runCommand:4156`; entered from `Terminal:shell:761` |
| a line becomes tokens | `Shell.lua:86` `tokenize` |
| flags parsed / refused | `Shell.lua:230` `partition` against `SPECS:578` |
| the command table | `Shell.lua:942` `HANDLERS` |
| `for` loops | `Shell.lua:4334` `parseLoop`, `:4419` `runLoop`, `:4402` `expandVar` |
| the list `/help` prints | `Shell.lua:4114` `Shell.COMMANDS` |
| heredocs / redirection | `Shell.lua:407` `extractHeredoc`, `:467` `takeRedirect`, `:542` `applyRedirect` |
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
| write / multiedit | `Terminal.lua:515 / 562` |
| Luau is executed | `studio/Exec.lua:424` `Exec.run`; PROLOGUE at `:56`, every entry one physical line |
| the run guard (off by default) | `studio/Exec.lua:31` `setRunGuard`, backed by `Settings.allowRun` |
| free models | `studio/Catalog.lua:186` `search`, `:247` `load` |
| regex compiled / matched | `text/Regex.lua:772` `compile`, `:743` `Program:find` |
| sed parsed / applied | `text/Sed.lua:195` `parseSedCommand`, `:102` `substitute` |
| property names / defaults | `studio/Props.lua:90` `names`, `:137` `default` |
| sessions | `Sessions.lua:172` `save`, `:380` `load`, `:484` `restoreLast` |
| another session is read mid-turn | `Sessions.lua:388` the peek branch of `load` — no `Agent.restore`, `currentId` never moves. Parked blocks in `previewHolder:239`, put back by `endPeek:259` or dropped by `dropPeek:250` |
| where a new console block is parented | `Console.lua:32` `sink` — `output` normally, a detached holder during a peek. `detach:196` / `reattach:208` / `discard:225`, and `onScreen:230` for anything the reader asked to see |
| the session list is filtered | `Sessions.lua:489` `query`, box at `:508`, applied in `draw` |
| a conversation is searched | `Find.lua:66` `Find.scan` — every block type, thinking and tool output included. Each hit carries the message it is in; the panel is `:126` `Find.mount` |
| clicking a result reaches the message | `Find` hands the index to `Sessions.reveal:420`, which grows a short replay until the message is drawn, then `Console.jumpToMessage:223`. Anchors are a `msg` attribute set by `Console.setMessage:194` and resolved at-or-below by `anchorFor:206` |
| Ctrl+F reaches the plugin | three ways in, because no single one covers every focus state: `main.lua:534` `root.InputBegan` (widget focused), `:519` the bindable PluginAction (anywhere), `:916` UserInputService (viewport). None sees a chord typed into the input box — that is what `/find` in `Commands.lua:180` is for |
| a session is written to disk | the busy -> idle edge in `main.lua:819`, plus `onCheckpoint:241` — fired by `Agent.send` as the message goes in, and by `continueTurn(true):590` after each batch of tool results |
| text on screen | `Console.lua:256` `appendLine`, `:624` `createBubble`, `:931` `appendToolCall` |

## Per file

| File | Lines | Owns |
|---|---:|---|
| `fs/Shell.lua` | 5557 | The command line. Still the biggest — see below. |
| `agent/Agent.lua` | 1354 | Turn loop, conversation state, trimming, stop. |
| `ui/Console.lua` | 1326 | Bubbles, thinking drawers, tool-call blocks, the detached sink. |
| `text/Regex.lua` | 958 | BRE/ERE engine. Requires nothing. |
| `main.lua` | 1011 | Widget, toolbar, popups. Owns `plugin`, hands it to Provider / Sessions / Settings — the only four that touch it. |
| `fs/Terminal.lua` | 811 | Commands as tree operations. No parsing. |
| `fs/Fs.lua` | 791 | Paths, `.Source`, undo, mtime, globs, mode bits. |
| `agent/providers/Anthropic.lua` | 1278 | One request. Knows nothing about turns. |
| `ui/Sessions.lua` | 855 | Session list, filter, peek and persistence. |
| `ui/Settings.lua` | 578 | Preferences + panel. |
| `studio/Exec.lua` | 565 | Luau execution. Tool-only. |
| `agent/providers/AnthropicAuth.lua` | 514 | PKCE login, refresh, usage. |
| `studio/Catalog.lua` | 402 | Free model search / insert. Tool-only. |
| `ui/Find.lua` | 385 | Conversation search + the find panel. |
| `ui/Markdown.lua` | 346 | Markdown to labels. |
| `text/Sed.lua` | 330 | sed engine. Pure text. |
| `main/Commands.lua` | 205 | Slash commands. |
| `studio/Props.lua` | 201 | API dump. The only network I/O in fs. |
| `util/Sha256.lua` | 170 | For PKCE. |
| `agent/Tools.lua` | 119 | Registry + dispatch. |
| `ui/Theme.lua` | 91 | Colours and `make`. |
| `agent/Provider.lua` | 23 | The active provider. |
| `agent/tools/*.lua` | 17-50 | One per tool. |

## Inside Shell.lua

| Lines | Region |
|---:|---|
| 1-63 | header, requires, aliases |
| 64-941 | parsing: `tokenize:86`, `partition:230`, `extractHeredoc:407`, `takeRedirect:467`, `SPECS:578` |
| 942-3352 | HANDLERS — 33 commands + private helpers |
| 3353-4162 | diff core, the last handlers, curl/wget, `Shell.COMMANDS:4161` |
| 4163-4363 | pipelines and statements, `runCommand:4203`, `runStatements:4341` |
| 4364-4544 | loops: `parseLoop:4381`, `expandVar:4461`, `runLoop:4478`, `runTokens:4501` |
| 4545-4585 | `Shell.run:4545` |
| 4586-end | `Shell.selfTest:4586` |

`tokenize`/`partition` and the diff core are pure text and are the next
extractions; `HANDLERS` is not (below).

## Conventions

- Every mutation goes through `Fs.withUndo`. Bypassing it is data loss.
- `selfTest` is a convention, not a framework: `Regex`, `Props`, `Markdown`,
  `Sessions`, `Find`, `Console`, `Shell`, `Agent`, `Exec`, `Catalog` and
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
| 2 | move `onComplete` block assembly + `clearOldToolResults` from Agent into the provider |
| 3 | neutral tool schema in `Tools.lua`; provider maps to `input_schema` |
| 4 | `Settings` asks `Provider` for the model list rather than reaching into `wire` |
| 5 | record provider on a session, refuse cross-provider restore |
| 6 | extract `Diff` and `Argv` from Shell into `text/` |
| 8 | rename `Terminal:run` -> `Terminal:exec` (`Shell.run` already means a command line) |

`HANDLERS` does not split: its 33 commands share a dozen file-local helpers, so
grouping them means threading a context table through every signature or copying
helpers — the failure already paid for twice with `classFor` and `ensureScript`.

Nothing here has run in Studio yet. The startup self-tests are the real gate.
