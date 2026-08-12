# Claude Code for Roblox

A Studio plugin that puts a coding agent inside Studio. It runs on your Claude
subscription (OAuth login, no API key) and gives the model tools that treat the
DataModel like a filesystem, so ls, cat, grep, cd, edit and write all work on
Instances.

## Install

main.lua is the plugin Script and main/ becomes its children, every subfolder a
Folder and every .lua a ModuleScript. Build that into a .rbxmx in your plugins
folder, with Rojo or by hand. You also need Game Settings, Security, Allow HTTP
Requests.

## Use

Click the toolbar button, run /login, open the URL it prints, then paste the
code back with /code. After that just type. Enter sends, Shift+Enter adds a
line, and / lists the commands.

The button at the top left opens the sessions drawer. Conversations are saved as
you go and the last one for the place you are in comes back when you reopen the
plugin, so a Studio crash costs you the turn that was running and nothing else.
Switch between them from the list, start a new one with +, and delete one with
the bin. /clear wipes the session you are in rather than parking it. The drawer
stays open and moves the console aside, so you can read the list and keep going.

Settings is at the bottom of that drawer: effort, web search, run code and system
prompt, plus your plan usage for the 5 hour and weekly windows. The model has its
own chip at the right of the input row. The widget floats over the viewport
rather than docking to an edge, and hides itself during playtests.

Plugins get no clipboard API, so instead anything worth copying is a text box
you can select and Ctrl+C, and code blocks have a select all button. Paragraphs
are the exception because they render through RichText, where selecting a bold
word would hand you the markup around it.

## Tools

bash runs a command line with pipes, ; && ||, redirects, heredocs and globs.
edit and multiedit swap unique substrings, write replaces a whole .Source
(creating the script if it is missing), run executes Luau, and catalog searches
and loads free models. run is off by default since it runs at plugin permission
level with no timeout.

run takes code, or a path to a script holding it. The path form exists so a
probe can be written once and iterated with edit instead of resent whole; the
source is inlined where code would go, so the file's own print is captured and
its error lines are its own. What it costs is `script`, which points at the
generated runner and not at the file — for running a real module in place,
`reload(m)` inside a chunk is still the answer. Scratch scripts belong in
/ServerStorage/tmp, which nothing creates for you. A chunk may return several
values — `return nil, "why"` shows both, not just the nil.

catalog loads through game:GetObjects, which does not sandbox anything, so
scripts inside a model arrive live and able to run. LoadAssetAsync would strip
that, but it gates on ownership and the setting that lifts the gate is off
limits to plugins. Every load reports how many scripts came with it, so look
before you run.

Paths are what you would expect. / is game, . and .. do the usual, service names
at the root ignore case but everything below it does not. Scripts are listed
with a .luau suffix, -type f means a script and -type d means anything else.
Changes go through ChangeHistoryService, so Ctrl+Z works.

Patterns are real regular expressions, from a real engine in `fs/Regex.luau` —
not Lua patterns in a costume. Plain `grep` and `sed` are POSIX **BRE**, `-E`
`egrep` and `find -regex` are **ERE**, `-F` and `fgrep` are fixed strings, and
`-P` adds lazy quantifiers, `(?:)`, backreferences and lookahead. Groups,
alternation, `{n,m}`, bracket classes with POSIX names, anchors and the GNU
`\d \w \s \b` escapes all work. sed's replacement side is sed's: `\1`-`\9` and
`&`. The only thing deliberately refused is lookbehind, because a variable-length
one needs a different engine and guessing would return wrong matches quietly.

Two consequences worth knowing. Backtracking has catastrophic cases, and Luau
cannot preempt a running chunk, so the matcher has a step budget — a pattern like
`(a+)+$` comes back as an error instead of freezing Studio. And because plain
grep is BRE, `.` is a metacharacter there exactly as it is everywhere else:
`grep game.Workspace` also matches `gameXWorkspace`, and `\.` or `-F` is how you
ask for the literal.

Each command declares the flags it takes, in SPECS. A flag that has no meaning
against a DataModel is refused with the reason rather than a list of what is
allowed: ls -o says an Instance has no owner, tail -f says these handlers run
inside the response stream. Three of them do map onto something real and are
implemented rather than refused — an inode is GetDebugId, the mode bits are
Disabled, Archivable and Locked, and a size is source bytes or a descendant
count. Modification time has no property behind it at all, so it is observed:
edits this plugin makes, edits you make in the Script Editor, and anything
parented after we loaded. Everything else reads "-" under ls -t and sorts last.

It is not a real shell. No variables, control flow or command substitution. When
something needs real composition it should use run instead of growing a language
inside Shell.

## Layout

```
main.lua          widget, toolbar, input row, wiring
main/
  Commands.lua    slash commands
  agent/
    Claude.lua    Messages API client, SSE streaming
    Agent.lua     history and the tool-use loop
    Tools.lua     tool registry
    tools/        one file per tool
  fs/
    Fs.lua        paths, .Source access, undo, globs
    Props.lua     property names and defaults
    Terminal.lua  the commands themselves
    Shell.lua     tokenizer, pipes, redirection, heredocs
  ui/
    Theme.lua     palette, fonts, the make helper
    Markdown.lua  markdown to renderable blocks
    Console.lua   output, streaming reply, tool calls
    Settings.lua  prefs, panel, usage bars
  auth/
    Sha256.lua    PKCE hashing
    OAuth.lua     OAuth, token storage and refresh
```

Requires inside a folder are just script.Parent:WaitForChild. Only five files
reach across folders, which is the point: a sixth means the grouping is wrong.
Terminal knows how to do things to the DataModel and Shell knows how to read a
line and pick which one, so a new command is one entry in Shell and new syntax
touches nothing else.

Adding a tool means adding a file in tools/ that exports name, description,
input_schema and run. The registry finds it and /help lists it. They stay sorted
by name because tool definitions sit at the front of every request, and prompt
caching is a prefix match, so reordering them throws away the cache behind it.

## Context

Every turn resends the whole conversation, so one call that dumps 3000 lines
keeps costing for the rest of the session. Against that: the system prompt and
tools cache for an hour and the conversation for five minutes, grep and find
return locations rather than content, output is capped and tells you the command
that gets the rest, and tool descriptions stay near empty because a model
already knows what ls does, it just cannot know this is a DataModel.

The gap is compaction. Old tool output is blanked once it is stale, but nothing
summarises, so a long session grows until you /clear. The tool loop itself is
uncapped, the same as Claude Code: it runs while the model keeps asking for
tools, and Stop or Escape ends it.

## Self-tests

They run at startup and print to Output: Sha256 against known vectors, Markdown
parsing plus every streaming prefix leaving RichText balanced, Terminal across
its commands, flags and globs, and Props against the API dump.
