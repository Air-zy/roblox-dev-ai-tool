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
| the system prompt is built | `providers/Anthropic.lua:259` `systemBlocks` — identity first, user block if non-empty, cache_control on the last |
| the user's system prompt is stored | `Settings.lua:78` `Settings.system()`, default `""` |
| a request is assembled | `providers/Anthropic.lua:220` `streamMessage` -> `applyReasoning:123` -> tools+cache -> `withMessageCache:170` |
| a response is parsed | `providers/Anthropic.lua:366` `processSSEEvents` |
| which provider is live | `agent/Provider.lua` — `wire` and `auth`; nothing outside `providers/` names a vendor |
| the turn loop | `Agent.lua:460` `runTurn` |
| a turn's result is handled | `Agent.lua:668` `onComplete` -> assemble -> dispatch tools -> `continueTurn` |
| the user hits enter | `main.lua:808` `submit` -> `Commands.handle:188` -> `Agent.send:988` |
| a tool runs | `Tools.lua:85` `dispatch` — never throws |
| tool definitions on the wire | `Tools.lua:58` `definitions` + `Agent.lua:207` `buildTools` |
| model / thinking / effort / search per model | `providers/Anthropic.lua:82` `MODEL_CAPS`; UI list at `:96` |
| beta headers | `providers/Anthropic.lua:66` — read the comment before adding one |
| history trimming | `Agent.lua:396` `clearOldToolResults`, gated by `cacheIsCold:369` |
| one result capped / a turn's batch capped | `Agent.lua:128` `forModel`, `:156` `capTurn` |
| open-editor hint on each message | `Agent.lua:954` `editorContext` — `""` when nothing is open |
| login | `providers/AnthropicAuth.lua:208` `startLogin` -> `:244` `completeLogin`; refresh `:313`, used by `getAccessToken:381` |
| a shell line runs | `Shell.lua:3641` `Shell.run` -> `runCommand:3501`; entered from `Terminal:shell:766` |
| a line becomes tokens | `Shell.lua:88` `tokenize` |
| flags parsed / refused | `Shell.lua:232` `partition` against `SPECS:569` |
| the command table | `Shell.lua:847` `HANDLERS` |
| the list `/help` prints | `Shell.lua:3459` `Shell.COMMANDS` |
| heredocs / redirection | `Shell.lua:409` `extractHeredoc`, `:469` `takeRedirect`, `:533` `applyRedirect` |
| diff | `Shell.lua:3164` `diffOne`, handler at `:3224` |
| a path becomes an instance | `Fs.lua:289` `Fs.resolve` — also `.luau` suffixes and root case-folding |
| an instance becomes a path | `Fs.lua:271` `instancePath` |
| a script is read / written | `Fs.lua:71` `getSource`, `:118` `Fs.writeSource` |
| undo recording | `Fs.lua:636` `Fs.withUndo` — every mutation goes through it |
| root/service protection | `Fs.lua:655` `Fs.guardProtected` |
| modification times (we keep our own) | `Fs.lua:465` `Fs.watch` |
| ls / cat / stat / find / grep / tree | `Terminal.lua:115 / 135 / 208 / 252 / 316 / 403` |
| write / multiedit | `Terminal.lua:518 / 565` |
| Luau is executed | `studio/Exec.lua:129` `Exec.run`; PROLOGUE at `:58`, every entry one physical line |
| the run guard (off by default) | `studio/Exec.lua:33` `setRunGuard`, backed by `Settings.allowRun` |
| free models | `studio/Catalog.lua:174` `search`, `:247` `load` |
| regex compiled / matched | `text/Regex.lua:782` `compile`, `:753` `Program:find` |
| sed parsed / applied | `text/Sed.lua:197` `parseSedCommand`, `:104` `substitute` |
| property names / defaults | `studio/Props.lua:85` `names`, `:137` `default` |
| sessions | `Sessions.lua:174` `save`, `:327` `load`, `:379` `restoreLast` |
| text on screen | `Console.lua:236` `appendLine`, `:608` `createBubble`, `:904` `appendToolCall` |

## Per file

| File | Lines | Owns |
|---|---:|---|
| `fs/Shell.lua` | 4475 | The command line. Still the biggest — see below. |
| `main.lua` | 948 | Widget, toolbar, popups. Owns `plugin`, hands it to Provider / Sessions / Settings — the only four that touch it. |
| `text/Regex.lua` | 969 | BRE/ERE engine. Requires nothing. |
| `ui/Console.lua` | 1029 | Bubbles, thinking drawers, tool-call blocks. |
| `agent/Agent.lua` | 1201 | Turn loop, conversation state, trimming, stop. |
| `fs/Terminal.lua` | 860 | Commands as tree operations. No parsing. |
| `fs/Fs.lua` | 725 | Paths, `.Source`, undo, mtime, globs, mode bits. |
| `agent/providers/Anthropic.lua` | 731 | One request. Knows nothing about turns. |
| `ui/Sessions.lua` | 694 | Session list and persistence. |
| `ui/Settings.lua` | 582 | Preferences + panel. |
| `agent/providers/AnthropicAuth.lua` | 494 | PKCE login, refresh, usage. |
| `studio/Catalog.lua` | 360 | Free model search / insert. Tool-only. |
| `ui/Markdown.lua` | 352 | Markdown to labels. |
| `studio/Exec.lua` | 353 | Luau execution. Tool-only. |
| `text/Sed.lua` | 331 | sed engine. Pure text. |
| `main/Commands.lua` | 208 | Slash commands. |
| `studio/Props.lua` | 202 | API dump. The only network I/O in fs. |
| `auth/Sha256.lua` | 170 | For PKCE. |
| `agent/Tools.lua` | 97 | Registry + dispatch. |
| `ui/Theme.lua` | 97 | Colours and `make`. |
| `agent/Provider.lua` | 23 | The active provider. |
| `agent/tools/*.lua` | 17-50 | One per tool. |

## Inside Shell.lua

| Lines | Region |
|---:|---|
| 1-60 | header, requires, aliases |
| 61-846 | parsing: `tokenize:88`, `partition:232`, `extractHeredoc:409`, `takeRedirect:469`, `SPECS:569` |
| 847-2850 | HANDLERS — 33 commands + private helpers |
| 2851-3460 | diff, `Shell.COMMANDS:3459` |
| 3461-3706 | pipelines, `runCommand:3501`, `Shell.run:3641` |
| 3707-end | `Shell.selfTest` |

`tokenize`/`partition` and the diff core are pure text and are the next
extractions; `HANDLERS` is not (below).

## Conventions

- Every mutation goes through `Fs.withUndo`. Bypassing it is data loss.
- `selfTest` is a convention, not a framework: `Regex`, `Props`, `Markdown`,
  `Sessions`, `Shell`, `Agent`, `Exec`, `Catalog` and `Terminal` export one, and
  `main.lua` runs them at startup. A module that gains logic gains a selfTest,
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
