# Architecture and operation

[Back to the project overview](README.md).

## Overview

A Studio plugin that puts a coding agent inside Studio. It gives the model tools
that treat the DataModel like a filesystem, so ls, cat, grep, cd, edit and write
all work on Instances.

Five providers, three of them OAuth:

- **Claude** — your Claude subscription, the same login Claude Code uses.
- **OpenAI** — your ChatGPT Codex subscription, through the same device OAuth,
  account-backed Responses endpoint and rolling limits as open-source Codex.
  Platform API keys are deliberately not accepted, so this provider has no
  separately billed per-token mode. Complete Responses output items, including
  encrypted reasoning and paired server IDs, survive sessions and Studio restarts.
- **OpenRouter** — for the free tier. OpenRouter fronts a rotating set of models
  that cost nothing, which is how to run this without a subscription. The model
  list is fetched and filtered to the free models that can call tools, because
  every capability here is a tool call and a model without them can only narrate
  what it would have done. Free models are capped at 50 requests/day, or 1000
  once you have bought $10 of credits at any point.
- **NVIDIA** — the other free tier, and the one that is a pasted key rather than
  a login: generate an `nvapi-` key at build.nvidia.com/settings/api-keys and
  hand it to `/code`. Nemotron, Kimi, DeepSeek and gpt-oss, capped by rate
  rather than by day, which suits an agent turn — many requests rather than one —
  far better than a daily allowance does. NVIDIA does not publish that rate or
  send a rate-limit header, and it is one budget for the whole key rather than
  per model, so switching model does not escape a 429. Settings shows what this
  plugin has sent in the last minute, which is the only figure anyone here can
  actually measure.
- **Gemini** — Google AI Studio, also a pasted key (from
  aistudio.google.com/apikey; new ones look like `AQ....`, and the older
  `AIza...` Standard keys stopped being accepted in September 2026). This one
  talks Google's native API rather than its
  OpenAI-compatible one, because Gemini 3 REQUIRES a thought signature back
  on every function call it makes and rejects the turn without it — which is the
  same opaque-blob contract a thinking block's signature already had. It is also
  the only provider whose model list carries real context windows, so the
  roster, the context bar and which models can reason are all read from your own
  account rather than written down here.

Switch with `/provider`, or from the Provider row in the model picker. Each
provider keeps its own model choice and its own sessions: a conversation is
shaped by whoever produced it, down to reasoning blocks only the issuing
provider can read, so opening one under the other is refused rather than
silently corrupted.

## Install

`main.lua` is the plugin Script and `main/` becomes its children, every
subfolder a Folder and every `.lua` a ModuleScript. With Rojo 7.5 or newer, run
`rojo build default.project.json --output ClaudeCodeForRoblox.rbxmx`, copy the
result into the Studio plugins folder, and restart Studio. You also need **Game
Settings > Security > Allow HTTP Requests** in the place you want to edit.

## Why these methods?
agenting AI models are already trained to be good at terminal, so instead of a bunch of tool for specific tasks a terminal can do.
A simple bash tool is self explanatory and the agent is already a pro at using bash. So a bash tool is super intuitive for this usecase...

## Use

Click the toolbar button and run /login. Claude and OpenRouter return a code to
paste with /code. OpenAI prints a one-time device code: enter it on the ChatGPT
page and approve access while the plugin polls and finishes automatically.
OpenAI never accepts an API key. On OpenRouter, /code also takes an `sk-or-...`
key directly; on NVIDIA and Gemini the pasted key is the whole flow. After that just
type. Enter sends, Shift+Enter adds a line, and / lists the commands.

The button at the top left opens the sessions drawer. Conversations are saved as
you go and the last one for the place you are in comes back when you reopen the
plugin, so a Studio crash costs you the turn that was running and nothing else.
Switch between them from the list, start a new one with +, and delete one with
the bin. The box at the top of the drawer filters the list by title as you type.

Clicking a session while a turn is running opens it read-only rather than
refusing. Nothing switches: the turn keeps its own conversation and still saves
into the session that asked for it, and its output is parked off screen rather
than thrown away, so clicking that session again — its row says how — brings the
whole thing back including whatever landed while you were reading. Typing does
the same. Starting, deleting and clearing a session still wait for the turn to
finish, because those do need the agent. /clear wipes the session you are in
rather than parking it. The drawer stays open and moves the console aside, so you
can read the list and keep going.

The magnifier next to it searches the conversation you are in: everything the
model said, everything you said, its reasoning and its tool calls and their
output, since all of that is in the conversation whether or not it is still on
screen. Click a result and the console scrolls to that message and flashes it,
loading more of the history first if the message is further back than the part
being drawn.

**Shift+Esc** opens it while you are typing, and there is no Ctrl+F. That is not
a choice: `UserInputService` is documented to fire "only when the Roblox client
window is in focus", which is the 3D view and never a plugin widget;
`ContextActionService` is client-LocalScript only; and `GuiObject.InputBegan`,
the one event that reaches a widget's children, loses to a focused TextBox —
which in this panel is nearly always one, since sending a message recaptures the
input box and every console line is an editable box so it can be selected and
copied. Esc is the only key a focused text box hands back, as the cause of the
focus it just gave up, and its modifiers ride along with it. So Shift+Esc.

The other two routes are `/find`, typed into the box that is swallowing the keys
— `/find cache breakpoint` opens the panel with that already searched — and
binding a chord of your own to "Find in chat" under File > Advanced > Customize
Shortcuts, which is the documented way a plugin gets a shortcut and the only one
Studio dispatches ahead of a text box.

Settings is at the bottom of that drawer: effort, web search, run code and system
prompt, plus what you have left — the 5 hour and weekly windows on Claude,
credits and the free-model request cap on OpenRouter, what this plugin has sent
in the last minute on NVIDIA, and where to look for live usage on OpenAI and
Gemini. The model has its own chip at the right of the input row, and the
provider is one page behind it. The widget floats over the viewport
rather than docking to an edge, and hides itself during playtests.

Plugins get no clipboard API, so instead anything worth copying is a text box
you can select and Ctrl+C, and code blocks have a select all button. Paragraphs
are the exception because they render through RichText, where selecting a bold
word would hand you the markup around it.

## Tools

bash runs a Bash-style language over Instances: pipes, ; && ||, redirects,
heredocs, variables, globs, brace expansion, command substitution, arithmetic,
`if`, `case`, functions, grouped commands, and `for`/`while`/`until` loops.
Compound commands can feed pipelines or have their own redirections. This is
an interpreter inside Studio, not an OS process or a complete GNU Bash port.
edit and multiedit swap unique substrings, write replaces a whole .Source
(creating the script if it is missing), run executes Luau, reload uncaches a
module so the next require reads it again, and catalog searches and loads free
models. run is off by default since it runs at plugin permission
level with no timeout.

`/sh <command>` runs that same shell yourself, through the same Terminal the
agent holds, so `cd` in one moves the other. Bare `/sh` stays there: every line
typed after it goes to the terminal until `exit`, with the cwd on the input row
and `$` in front of what you ran. That is a shell panel without the panel — the
console is already the scrollback and the input row is already the line editor,
so a second window would have been a second copy of both, and a plugin widget
delivers no arrow keys to hang a history off anyway. Slash commands still work
inside it, and a shell line is not blocked while a turn is streaming, since it
never goes near the turn. It used to refuse anything that
writes, on the reasoning that a mutation should arrive through Claude carrying
an undo recording — but the recording lives in the handlers, not on Claude's
path, so a write from either side was always recorded the same. What the
restriction actually bought was that every change stayed in the transcript,
which is not worth the owner of a place having less reach over it than the agent
working on it. Explorer already hands you a Delete key with no transcript at all.

run takes code, or a path to a script holding it. The path form exists so a
probe can be written once and iterated with edit instead of resent whole; the
source is inlined where code would go, so the file's own print is captured and
its error lines are its own. What it costs is `script`, which points at the
generated runner and not at the file — for running a real module in place,
`reload(m)` inside a chunk is still the answer. Scratch scripts belong in
/ServerStorage/tmp, which nothing creates for you. A chunk may return several
values — `return nil, "why"` shows both, not just the nil.

reload takes a list of module paths and swaps each for a clone of itself. It
runs nothing: `require` caches per Instance and never re-runs a module, so one
edited after it was first required keeps handing back the old value for the rest
of the session, which is what a probe in /ServerStorage/tmp hits the second time
it runs. A clone is a different Instance and therefore a different cache key, so
putting it where the original was makes every later require of that path reach
something that has never been run — this run and every one after it, which is
what the in-chunk `reload(m)` cannot do. Clone takes descendants, so a package
reloads whole and Rojo's init convention means naming the folder module is
usually enough. Only what is listed is reloaded, and a module that merely
requires one of these still holds the old copy's table, so the dependents belong
in the list too. What it costs is identity: the original is destroyed, so the
swap carries the editor's buffer rather than the .Source that Clone copies, and
a path the cwd sits inside is refused rather than leaving the terminal somewhere
that no longer exists.

catalog loads through game:GetObjects, which does not sandbox anything, so
scripts inside a model arrive live and able to run. LoadAssetAsync would strip
that, but it gates on ownership and the setting that lifts the gate is off
limits to plugins. Every load reports how many scripts came with it, so look
before you run.

curl fetches a URL and writes the body to stdout, so it composes with everything
else: `curl URL | grep -n thing`, `| sed -n '1,80p'`, or `> /ServerStorage/tmp/doc.luau`
to keep it. -X -H -d --json --data-urlencode -G and the header shorthands -e -b -r
--oauth2-bearer cover an API, -d @path reads the body out of a script the way `>`
writes one, -o and -O save instead of printing (`-o /dev/null` throws away),
-i and -I show headers, -m bounds the request, and -s -L -k -f --compressed are
accepted and do nothing because each asks for what already happens.

-w prints a report instead of the body, so the usual status-code check works:
`curl -s -o /dev/null -w "%{http_code}\n" URL`. It knows the variables a response
can answer — http_code, response_code, content_type, size_download, num_headers,
url, url_effective, time_total, speed_download — and refuses the rest by name,
because RequestAsync is one call returning one table and reports nothing about
the connection behind it, so time_connect and remote_ip have no value to give and
expanding them to nothing would print a measurement that was never taken. -w is
also the one case where a non-2xx is not an error: asking for the code is saying
you intend to read it.

The rest are refused with the reason, because RequestAsync takes a URL, a method,
headers, a body, a compression mode and a timeout, and nothing else is a knob that
exists. --connect-timeout because there is one timeout for the whole request and
-m is it, -v because there is no stderr to trace onto and it would land in the pipe
with the body, -x because the engine picks the route, -A and -H User-Agent because
Roblox locks that header along with Roblox-Id and derives Content-Length from the
body. The verb after -X is checked against the eight RequestAsync takes, and GET
and HEAD are refused a body, both because the engine fails the whole call rather
than dropping what it cannot use.

Three departures from real curl. Roblox's own domains are rejected before the
request, since HttpService blocks every one of them and create.roblox.com is the
first URL anyone tries; a mirror is the way in, which is how this plugin reads the
API dump. A non-2xx is an error rather than a body, because a 404 page flowing
down a pipe looks exactly like a page that fetched fine and had nothing to say.
And there is a 30 second timeout by default, which curl has no equivalent of: the
engine's own default is undocumented and reported at a minute or more, and a
request that hangs that long holds the turn it was called from, the same objection
that rules out `tail -f`. -m moves it, downward only, since RequestAsync refuses a
timeout above its own.

wget is the same request with the other default: it saves. `wget URL` writes a
script named from the last path segment, -O names one instead and -O - prints to
stdout, --spider is a HEAD that saves nothing, -S shows the headers, -q drops the
message, and --header --post-data --post-file --method -T are wget's spellings of
curl's. Where the file goes is settled before the fetch, so a URL with no name in
it costs no request. Refused is the half of wget that is wget: -r -m -p walk links
to rebuild a tree, and a DataModel is not a tree to rebuild into. Everything about
the request itself is the same code curl runs, so the two cannot drift on what a
404 means or which hosts are refused.

git speaks to GitHub's API rather than git's wire protocol, which is why a commit
is three requests and needs neither zlib nor a packfile: the object model is
already JSON, and the engine hashes SHA-1 natively, so the ids are real git ids
and get checked against the ones the host reports. `git config remote owner/repo`
and a fine-grained token with Contents access is the whole setup. status and diff
compare the place against the remote by blob id, add/reset keep an index of paths,
commit builds the tree and moves the branch, and pull writes files back in —
refusing to overwrite an uncommitted change unless -f says so, and never deleting
anything. `git status` shows the index as its own section and `git diff --staged`
renders it, since the index is what commit sends and it is the one thing worth
reading before making one. `git log` takes a path to narrow it to the commits that
touched one file, and `git show <sha> [path]` prints a commit with the host's own
rendering of its patch — the only read here that does no diffing, because GitHub
returns the hunks already in unified format. There is no clone of a whole history
and no local objects, so checkout and rebase have nothing to work with and say so.

`git clone owner/repo [dest]` is the other direction: someone else's repository
read into this place. A github.com URL works wherever a slug does, so what is on
the clipboard is what you paste, and `--branch` takes a branch or a tag,
defaulting to whatever the repository's HEAD is. Scripts come across by default
and `-A` takes the rest with them: .Source holds any text, so a README arrives as
a ModuleScript named README.md that cat, grep and sed read with no special case,
and it commits back under its own name. The default is scripts only for the sake
of requests rather than capability — one blob apiece against sixty an hour
unauthenticated, and Knit is 61 files of which 6 are Luau. A file with no
extension at all is left behind even under -A: `LICENSE` as an Instance name
cannot be told from a script's, so taking it would rename it to LICENSE.luau on
the way back out. With no destination it clones into the cwd the way git
does, except at the root, where nothing can be created beside a service: there it
lands in /ServerStorage/tmp instead, which is also the right place for a
repository nobody has decided where to keep yet. The path is in the output either
way, and `mv` moves it. Rojo's init convention is honoured, so `src/init.luau`
makes src itself the ModuleScript and a cloned library is one you can require.
That, and curl, are why there is no unzip here.

Paths are what you would expect. / is game, . and .. do the usual, service names
at the root ignore case but everything below it does not. Scripts are listed
with a .luau suffix, -type f means a script and -type d means anything else.
Tags and attributes are the two things about an instance that no property holds,
so they get their own spellings: `find / -tag Enemy` selects by tag, and `stat`
lists both when there are any.
Changes go through ChangeHistoryService, so Ctrl+Z works.

Patterns are real regular expressions, from a real engine in `text/Regex.luau` —
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

A search that finds nothing exits 1; a command-handler error exits 2. `true`,
`false`, `!`, and `$?` work with `&&`/`||`. Pipelines pass only stdout to the
next stage, retain diagnostics on stderr, and use the last stage's status.
`2>/dev/null` silences diagnostics without changing that status. Both streams
reach the console in the order they were written, so a diagnostic appears beside
the command that produced it rather than in a block after everything else. A
standalone
search can still explain a miss for a human, but that prose is omitted in pipes
and when a following `||` handles the miss: `grep X f | wc -l` reports zero.

`test` and `[` are that guard. `-e -f -d -s` ask about a path, `-z -n = !=` about
a string, `-eq -ne -lt -le -gt -ge` about numbers, and `!` negates. Use
`if [ x ]; then ...; fi`, or chain `[ x ] && [ y ]`, which is why
`-a` and `-o` are refused with that as the reason. `-r -w -x` are refused too —
an Instance has no permissions, and `-f` is the readable question.

Each command declares the flags it takes, in SPECS. A flag that has no meaning
against a DataModel is refused with the reason rather than a list of what is
allowed: ls -o says an Instance has no owner, tail -f says these handlers run
inside the response stream. Three of them do map onto something real and are
implemented rather than refused — an inode is GetDebugId, the mode bits are
Disabled, Archivable and Locked, and a size is source bytes or a descendant
count. Modification time has no property behind it at all, so it is observed:
edits this plugin makes, edits you make in the Script Editor, and anything
parented after we loaded. Everything else reads "-" under ls -t and sorts last.

The whole line is parsed before any command runs. Words expand only when their
command executes, so skipped branches do not run substitutions. Both `$(...)`
and backticks capture stdout; expanded punctuation stays data and is never
re-parsed as shell syntax. Single quotes suppress expansion, double quotes keep
values together, and unquoted expansions split on `IFS` and expand pathname
patterns. Heredocs expand parameters and substitutions unless their delimiter
is quoted; `<<-` strips leading tabs.

Variables and function definitions belong to the Terminal and survive shell
calls. `HOME` starts at `/`; `PWD` and `OLDPWD` are ordinary exported variables that
`cd` maintains. `NAME=value`, `export`, `unset`,
function arguments (`$1`, `$#`, `"$@"`), and function-local `local` are supported.
`export` marks shell variables, not the host computer's environment. Pipelines,
subshells and command substitutions use isolated variable/cwd state; brace
groups and functions share the caller's state. None of this state is persisted
across Studio restarts.

`while IFS= read -r line; do ...; done` consumes one input line per iteration;
`break`, `continue`, `return` and `exit` control execution. Loops share a yielding
10,000-step budget. Arithmetic such as `$((1 + 2))` uses a dedicated integer
parser, with exact results restricted to ±(2^53−1), not Luau code execution.

`printf` supports reusable formats, `-v`, `%s`, `%b`, `%c`, `%q`, integer and
floating-point conversions, flags, widths, precisions and escapes. Its format
parser and 64-bit integer conversion are explicit; only floating-point digits
use Luau formatting, with validated arguments. Floats are finite IEEE-754
doubles with precision at most 99, not Bash's long doubles. See
[BASH_FIDELITY.md](BASH_FIDELITY.md) for the exact limits and test commands.

`seq` is what makes a COUNTED loop possible without either: `for i in $(seq 1
20); do mkdir Part$i; done`. It takes LAST, FIRST LAST or FIRST STEP LAST the way
seq(1) does, with -s for the separator and -w to zero-pad, and it refuses past a
thousand values rather than truncating, since half a sequence is the wrong
sequence and the loop built from one quietly does the wrong number of things.

`!` before a pipeline inverts its status, which is worth something now that a
miss reports one: `! grep -q X f && echo absent`. `cd` prints nothing; `cd -`
reads `$OLDPWD` and prints where it landed, as bash does. Globs expand in every unquoted argument, including
`echo *.luau`; quoted wildcards remain literal. `*`, `?`, bracket ranges and
multi-segment paths work; dotfiles need an explicit leading dot and an unmatched
pattern stays literal. `{probe,verify}.luau` and `{1..3}` expand before variables.
`ls`, `cat` and `grep` accept multiple expanded paths; `du` and `tree` still
require one root and refuse multiple operands explicitly.

Copy destinations distinguish files from containers even though a Roblox script
can have children. `cp -n source existingScript` leaves it untouched. Overwriting
a script updates its contents while preserving the destination's class, identity
and unrelated children. `cp -T` addresses the destination itself, rejecting
file/directory mismatches; `cp -rT sourceFolder destinationFolder` merges entries
without creating duplicate siblings. Copy plans validate conflicts before
mutation and preserve editor buffers. `rm -rf` removes the named node as well
as its descendants, including script roots; `/`, services and the cwd remain
protected.

Text files are ModuleScripts with explicit filenames. Writes to `.txt`, `.json`,
`.md`, or other non-code extensions skip Luau syntax diagnostics. `.lua`, `.luau`
and extensionless scripts are still checked after writes. `cat` only reads; it
does not parse text as Luau. Source writes retain the existing CRLF-to-LF
normalization used by the Script Editor integration.

## Layout

```
main.lua          widget, toolbar, input row, wiring
main/
  Commands.lua    slash commands
  agent/
    Provider.lua  which provider is live; nothing outside providers/ names one
    providers/
      Stream.lua         one streaming request: retries, cancel, SSE framing
      Retry.lua          what is worth retrying, and how long to wait
      ToolJson.lua       decoding arguments the model wrote
      Pkce.lua           verifier, challenge, state
      Anthropic.lua      Messages API client, SSE streaming
      AnthropicAuth.lua  PKCE login, token storage and refresh
      OpenAI.lua         Responses API client, and the translation both ways
      OpenAIAuth.lua     ChatGPT device OAuth, refresh and Codex plan limits
      OpenRouter.lua     chat/completions client, and the translation both ways
      OpenRouterAuth.lua PKCE login, or a pasted key
      Nvidia.lua         NIM chat/completions client, and the same translation
      NvidiaAuth.lua     a pasted nvapi- key, and nothing else
      Gemini.lua         native generateContent client, and the translation both ways
      GeminiAuth.lua     a pasted AI Studio key
    Agent.lua     history and the tool-use loop
    Tools.lua     tool registry
    tools/        one file per tool
  fs/
    Fs.lua        paths, .Source access, undo, globs
    Terminal.lua  the commands themselves
    Shell.lua     command table, flags, DataModel-to-stream adapter
    ShellSyntax.lua    lexer and compound-command grammar
    ShellWords.lua     variables, substitutions, arithmetic, braces, globs
    ShellRuntime.lua   shell state, control flow, pipelines, redirections
    ShellBuiltins.lua  printf format parsing and rendering
    ShellTests.lua     language and filesystem regression fixtures
  studio/
    Props.lua     property names and defaults
    Exec.lua      runs Luau                (run tool only)
    Catalog.lua   free model search / load (catalog tool only)
  text/
    Regex.lua     BRE/ERE engine
    Sed.lua       sed engine
  ui/
    Theme.lua     palette, fonts, the make helper
    Markdown.lua  markdown to renderable blocks
    Console.lua   output, streaming reply, tool calls
    Settings.lua  prefs, panel, usage bars
    Sessions.lua  session list, save/load/restore
  util/
    Sha256.lua    PKCE hashing
```

Requires inside a folder are just script.Parent:WaitForChild. Only five files
reach across folders, which is the point: a sixth means the grouping is wrong.
Terminal knows how to do things to the DataModel and Shell knows how to read a
line and pick which one, so a new command is one entry in Shell and new syntax
touches nothing else.

Adding a provider is a pair of files under providers/ plus an entry in
Provider.luau's REGISTRY. The transport is not part of that pair: Stream.luau
owns the socket, the attempt counting and the latches that stop a retry
re-rendering text the first attempt already put on screen, and there is exactly
one copy of it. A provider supplies a request and reads frames.

What a provider does own is translation. The conversation this plugin keeps is
Anthropic-shaped — typed content blocks, reasoning carrying a signature, tool
calls inline, a batch of tool results in one message — and Agent, Sessions and
Find all read that shape. OpenRouter and OpenAI convert at their own edges
rather than teaching four more modules another shape. Provider-owned reasoning
state rides inside the existing opaque signature field, so it is replayed
without Agent or session storage interpreting it.

Adding a tool means adding a file in tools/ that exports name, description,
input_schema and run. The registry finds it and /help lists it. They stay sorted
by name because tool definitions sit at the front of every request, and prompt
caching is a prefix match, so reordering them throws away the cache behind it.

## Context

Every turn resends the whole conversation, so one call that dumps 3000 lines
keeps costing for the rest of the session. Against that: the system prompt and
tools and the conversation all cache for an hour, grep and find
return locations rather than content, output is capped and tells you the command
that gets the rest, `ls /` collapses the hundred-odd empty services Studio
instantiates whether the place uses them or not (`ls -a /` still lists them),
and tool descriptions stay near empty because a model already knows what ls
does, it just cannot know this is a DataModel.

Walks breathe. Luau is single-threaded and this plugin shares that thread with
the editor, so find, grep, tree and `ls -R` yield a frame whenever they have
held it for one. A big place makes those commands slow; it no longer makes
Studio stop drawing.

The gap is compaction. Old tool output is blanked once it is stale, but nothing
summarises, so a long session grows until you /clear. The tool loop itself is
uncapped, the same as Claude Code: it runs while the model keeps asking for
tools, and Stop or Escape ends it.

## Self-tests

`/selftest` runs them: Sha256 against the FIPS vectors, PKCE against the RFC 7636
vector, retry classification and backoff, tool-argument repair, every provider's
request translation, Markdown parsing plus every streaming prefix leaving
RichText balanced, Terminal across its commands, flags and globs, Regex, Sed and
Git underneath it, and Props against the API dump. Every provider's tests run,
not only the live one — a translation bug in the provider you are not using would
otherwise surface the moment you switched, which is the worst time to find one.

They used to run at startup, all of them, on the frame the widget opened: about
1800 lines of test code, thirty-odd Instances built and torn down, and half a
dozen plugin-setting writes, before anything was on screen. Nothing has changed
between two opens of a plugin you did not edit, so that cost bought nothing and
is gone. The set is not trimmed, only moved — a "cheap subset" is the version
that quietly stops covering things while still looking like it covers them.

Console's test is last because what it tests is the console, and it finishes by
clearing it; the conversation is redrawn from storage immediately after.

For shell development outside Studio, `node tests/run.mjs <path-to-luau>
<path-to-bash>` runs the real modules against a small test-only Roblox boundary,
the full `Shell.selfTest`, copy-buffer/failure checks, and Bash differential
tests. The runner is [tests/run.mjs](tests/run.mjs). This does not verify Studio's
actual undo/redo, UI, network services, or engine-only Git checks; `/selftest`
remains the integration check in Studio.
