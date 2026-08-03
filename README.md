# Claude Code for Roblox

A Roblox Studio plugin that puts an AI coding agent inside Studio. It talks to the
Anthropic Messages API over your Claude subscription (OAuth), and gives the model a
set of tools that treat the **DataModel as a filesystem** — `ls`, `cat`, `grep`,
`cd`, `edit`, `write`, and friends operate on Instances instead of files.

## Install

`main.lua` is the plugin **Script**; every file in `main/` is a **ModuleScript**
child of it. Build that hierarchy into a `.rbxmx` in your Studio plugins folder
(Rojo, or by hand).

Requires HTTP requests enabled (`Game Settings → Security → Allow HTTP Requests`).

## Use

1. Click the **Claude Code** toolbar button to open the widget.
2. `/login` → open the printed URL in a browser → `/code <pasted-code>`.
3. Type a message, or `/` for the command list.

Slash commands: `/login` `/code` `/logout` `/status` `/model` `/settings` `/sh`
`/clear` `/help`. The ⚙ button opens model, effort, web-search, run-code and
system-prompt settings; they persist via `plugin:SetSetting`.

## Tools the model gets

| Tool | Payload | Notes |
|---|---|---|
| `bash` | a command line | pipes, `;` `&&` `\|\|`, newlines, `>` `>>`, heredocs, globs |
| `edit` / `multiedit` | unique substring swaps | atomic; one undo record per batch |
| `write` | whole `.Source` | |
| `run` | Luau source | **off by default**, plugin-permission level, no timeout |
| `catalog` | search / load Free Models | `InsertService` |

Path mapping: `/` = `game`, `/Workspace/Parts/Brick` = absolute, `.` `..` as usual.
Scripts are listed with a `.luau` suffix. `-type f` is a script, `-type d` is
anything else. Every mutation is wrapped in a `ChangeHistoryService` recording,
so **Ctrl+Z works**.

Not a shell interpreter: no variables, control flow, `$?`, command substitution
or environment. `2>` and `2>&1` are accepted and ignored — errors come back as
ordinary output, so there is no second stream to redirect. Anything needing real
composition should use `run` rather than growing a language in `Shell`.

## Layout

```
main.lua        plugin entry: widget, toolbar, input row, autocomplete, wiring
main/
  Theme         palette, fonts, the `make(class, props)` helper
  Sha256        PKCE hashing
  OAuth         Anthropic OAuth + PKCE, token storage/refresh
  Claude        Messages API client — SSE streaming over CreateWebStreamClient
  Agent         conversation history + the streaming tool-use loop
  Fs            path resolution, .Source access, undo recording, glob matching
  Props         property names + default baselines, from the Roblox API dump
  Terminal      the commands, as operations on the DataModel
  Shell         the command line: tokenizer, pipes, redirection, heredocs
  Tools         tool registry — sorted, deduped, dispatches by name
  tools/        one file per tool: bash, edit, write, run, catalog
  Console       scrolling output, streaming assistant bubble, tool-call lines
  Markdown      Markdown → renderable blocks (Console draws them as real GUI objects)
  Settings      persisted prefs + the settings panel
  Commands      slash commands
```

Dependency flow is one-way, no cycles: `Fs`, `Props`, `Tools`, `Theme`, `Sha256`,
`OAuth` and `Claude` depend on nothing internal; `Shell → Fs, Tools`;
`Terminal → Fs, Props, Shell`; `Theme → Markdown → Console`; `Claude → Settings`;
`Agent` and `Commands` on top.

`Terminal` and `Shell` split on the seam that was already there: Terminal knows
how to *do* things to the DataModel, Shell knows how to read a line and work out
which of those to call. A new command is a `HANDLERS` entry in Shell; a new piece
of syntax is a change in Shell and nowhere else.

**Adding a tool is adding a file** in `tools/`, exporting
`{ name, description, input_schema, run(term, input) -> string }` (or an array of
those). The registry picks it up, `/help` lists it, and the shell knows to say
"that's a separate tool" if the model tries it as a command — no other file
changes. Tools are sorted by name because definitions render at the front of
every request and prompt caching is a prefix match: a reordered tool block
invalidates the system and conversation caches along with it.

## Self-tests

Run at startup in a background task, results go to the Output window:
`Sha256` (known vectors), `Markdown.selfTest()` (block parsing, inline escaping,
every streaming prefix leaves RichText balanced), `Terminal.selfTest()` (tokenizer,
flag parsing, globs, every command survives a bare invocation), `Props.selfTest()`
(API-dump schema, superclass walk, serialization filter).
