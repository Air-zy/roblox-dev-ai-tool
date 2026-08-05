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
edit and multiedit swap unique substrings, write replaces a whole .Source, run
executes Luau, and catalog searches and loads free models. run is off by default
since it runs at plugin permission level with no timeout.

catalog loads through game:GetObjects, which does not sandbox anything, so
scripts inside a model arrive live and able to run. LoadAssetAsync would strip
that, but it gates on ownership and the setting that lifts the gate is off
limits to plugins. Every load reports how many scripts came with it, so look
before you run.

Paths are what you would expect. / is game, . and .. do the usual, service names
at the root ignore case but everything below it does not. Scripts are listed
with a .luau suffix, -type f means a script and -type d means anything else.
Changes go through ChangeHistoryService, so Ctrl+Z works.

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

The gap is compaction. MAX_TURNS stops a runaway loop at 40, it does not
summarise, so a long session grows until you /clear.

## Self-tests

They run at startup and print to Output: Sha256 against known vectors, Markdown
parsing plus every streaming prefix leaving RichText balanced, Terminal across
its commands, flags and globs, and Props against the API dump.
