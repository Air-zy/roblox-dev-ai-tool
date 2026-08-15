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
| the system prompt is built | `providers/Anthropic.lua:238` `systemBlocks` — identity first, user block if non-empty, cache_control on the last |
| the user's system prompt is stored | `Settings.lua:78` `Settings.system()`, default `DEFAULT_SYSTEM:33` (one line, edit-mode framing) |
| a request is assembled | `providers/Anthropic.lua:199` `streamMessage` -> `applyReasoning:104` -> tools+cache -> `withMessageCache:151` |
| a response is parsed | `providers/Anthropic.lua:345` `processSSEEvents` |
| which provider is live | `agent/Provider.lua` — `wire` and `auth`; nothing outside `providers/` names a vendor |
| the turn loop | `Agent.lua:466` `runTurn` |
| a turn's result is handled | `Agent.lua:674` `onComplete` -> assemble -> dispatch tools -> `continueTurn:516` |
| the user hits enter | `main.lua:792` `submit` -> `Commands.handle:184` -> `Agent.send:1003` |
| a tool runs | `Tools.lua:85` `dispatch` — never throws |
| tool definitions on the wire | `Tools.lua:58` `definitions` + `Agent.lua:219` `buildTools` |
| model / thinking / effort / search per model | `providers/Anthropic.lua:60` `MODEL_CAPS`; UI list at `:77` |
| beta headers | `providers/Anthropic.lua:48` — read the comment before adding one |
| history trimming | `Agent.lua:404` `clearOldToolResults`, gated by `cacheIsCold:377` |
| one result capped / a turn's batch capped | `Agent.lua:140` `forModel`, `:168` `capTurn` |
| open-editor hint on each message | `Agent.lua:967` `editorContext` — `""` when nothing is open; capped by `MAX_OPEN_DOCS:956`/`MAX_OPEN_CHARS:965` |
| login | `providers/AnthropicAuth.lua:198` `startLogin` -> `:234` `completeLogin`; refresh `:303`, used by `getAccessToken:371` |
| a shell line runs | `Shell.lua:3637` `Shell.run` -> `runCommand:3497`; entered from `Terminal:shell:761` |
| a line becomes tokens | `Shell.lua:86` `tokenize` |
| flags parsed / refused | `Shell.lua:230` `partition` against `SPECS:567` |
| the command table | `Shell.lua:845` `HANDLERS` |
| the list `/help` prints | `Shell.lua:3455` `Shell.COMMANDS` |
| heredocs / redirection | `Shell.lua:407` `extractHeredoc`, `:467` `takeRedirect`, `:531` `applyRedirect` |
| diff | `Shell.lua:3160` `diffOne`, handler at `:3220` |
| a path becomes an instance | `Fs.lua:283` `Fs.resolve` — also `.luau` suffixes and root case-folding |
| an instance becomes a path | `Fs.lua:265` `instancePath` |
| a script is read / written | `Fs.lua:69` `getSource`, `:116` `Fs.writeSource` |
| undo recording | `Fs.lua:632` `Fs.withUndo` — every mutation goes through it |
| root/service protection | `Fs.lua:651` `Fs.guardProtected` |
| modification times (we keep our own) | `Fs.lua:467` `Fs.watch` |
| ls / cat / stat / find / grep / tree | `Terminal.lua:113 / 133 / 206 / 250 / 315 / 402` |
| write / multiedit | `Terminal.lua:515 / 562` |
| Luau is executed | `studio/Exec.lua:424` `Exec.run`; PROLOGUE at `:56`, every entry one physical line |
| the run guard (off by default) | `studio/Exec.lua:31` `setRunGuard`, backed by `Settings.allowRun` |
| free models | `studio/Catalog.lua:186` `search`, `:247` `load` |
| regex compiled / matched | `text/Regex.lua:772` `compile`, `:743` `Program:find` |
| sed parsed / applied | `text/Sed.lua:195` `parseSedCommand`, `:102` `substitute` |
| property names / defaults | `studio/Props.lua:85` `names`, `:137` `default` |
| sessions | `Sessions.lua:172` `save`, `:323` `load`, `:375` `restoreLast` |
| text on screen | `Console.lua:232` `appendLine`, `:600` `createBubble`, `:890` `appendToolCall` |

## Per file

| File | Lines | Owns |
|---|---:|---|
| `fs/Shell.lua` | 4477 | The command line. Still the biggest — see below. |
| `agent/Agent.lua` | 1209 | Turn loop, conversation state, trimming, stop. |
| `ui/Console.lua` | 1015 | Bubbles, thinking drawers, tool-call blocks. |
| `text/Regex.lua` | 957 | BRE/ERE engine. Requires nothing. |
| `main.lua` | 930 | Widget, toolbar, popups. Owns `plugin`, hands it to Provider / Sessions / Settings — the only four that touch it. |
| `fs/Terminal.lua` | 798 | Commands as tree operations. No parsing. |
| `fs/Fs.lua` | 717 | Paths, `.Source`, undo, mtime, globs, mode bits. |
| `agent/providers/Anthropic.lua` | 708 | One request. Knows nothing about turns. |
| `ui/Sessions.lua` | 686 | Session list and persistence. |
| `ui/Settings.lua` | 579 | Preferences + panel. |
| `studio/Exec.lua` | 564 | Luau execution. Tool-only. |
| `agent/providers/AnthropicAuth.lua` | 484 | PKCE login, refresh, usage. |
| `studio/Catalog.lua` | 402 | Free model search / insert. Tool-only. |
| `ui/Markdown.lua` | 346 | Markdown to labels. |
| `text/Sed.lua` | 329 | sed engine. Pure text. |
| `main/Commands.lua` | 204 | Slash commands. |
| `studio/Props.lua` | 200 | API dump. The only network I/O in fs. |
| `util/Sha256.lua` | 170 | For PKCE. |
| `agent/Tools.lua` | 97 | Registry + dispatch. |
| `ui/Theme.lua` | 91 | Colours and `make`. |
| `agent/Provider.lua` | 23 | The active provider. |
| `agent/tools/*.lua` | 17-50 | One per tool. |

## Inside Shell.lua

| Lines | Region |
|---:|---|
| 1-63 | header, requires, aliases |
| 64-844 | parsing: `tokenize:86`, `partition:230`, `extractHeredoc:407`, `takeRedirect:467`, `SPECS:567` |
| 845-3005 | HANDLERS — 33 commands + private helpers |
| 3006-3456 | diff core, the last five handlers, `Shell.COMMANDS:3455` |
| 3457-3696 | pipelines, `runCommand:3497`, `Shell.run:3637` |
| 3697-end | `Shell.selfTest:3701` |

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
