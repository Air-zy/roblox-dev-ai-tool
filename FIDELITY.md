# FIDELITY — the shell, measured against real bash

Scope: `fs/Shell.lua`, `fs/Terminal.lua`, `fs/Fs.lua`, `text/Regex.lua`,
`text/Sed.lua`. The `bash` tool and `/sh` are the same call — `Shell.run`.

Keep this honest or delete it. The point of the file is the **Lies** section;
everything else is context for it.

The tool description says "real bash shell over a live in-memory vfs". That
first word is a claim, and this is the audit of it.

---

## 1. The shape

```
raw line
  → extractHeredoc          << EOF lifted BEFORE tokenizing
  → stderr scrub            &>> &> 2>&1 1>&2 >&- rewritten/dropped
  → expandSubstitutions     $(...) run on the RAW text, spliced, re-split
  → tokenize                quotes, escapes; > >> < split as words; tracks quoting
  → METACHARACTERS gate     a bare & is refused, a quoted one is data
  → parseStatements         ; && ||  →  statements, each a | pipeline
  → runPipeline             stage output becomes next stage's stdin
  → runCommand              takeRedirect (> >> 2> <) → flag gate → HANDLERS[cmd]
```

**37 commands**: `[ basename cat cd chmod command cp curl cut diff dirname du
echo egrep fgrep file find git grep head help ln ls mkdir mv pwd rm rmdir sed
seq sort stat tail test touch tr tree uniq wc wget which whoami`

Not a filesystem underneath — a DataModel. A "file" is a `LuaSourceContainer`
and its `.Source`; a "directory" is any other `Instance`. `find -type f` is
`IsA("LuaSourceContainer")`; `-type d` is the negation, not `Folder`.

---

## 2. What is genuinely faithful

Not a short list, and worth stating before the divergences.

| Area | Detail |
|---|---|
| Quoting | Only `$ " \ \`` escape inside double quotes; single quotes are literal. Matches bash exactly. |
| Regex | Real BRE/ERE engine (`text/Regex.lua`), not Lua patterns in costume. `grep` is BRE, `-E`/`egrep` is ERE, `-F`/`fgrep` is literal — and `egrep`/`fgrep` are *definitions*, not aliases, so `egrep '[0-9]'` is a class. |
| Flag bundling | `-rn` is `-r -n`; a value letter ends its bundle (`-nA3` = `-n -A 3`). `head -20` and `-` stay operands. |
| `head`/`tail` signs | `head -n -5` (all but last 5) and `tail -n +5` (from line 5) both carry the sign. `-c` is bytes. Multi-file `==> path <==` headers match coreutils. |
| Pipeline status | The pipeline's status is the last stage's. `&&`/`||` short-circuit. `!` inverts status only. |
| grep exit semantics | "errored" and "found nothing" are separate flags. `grep X f \| wc -l` still runs `wc`; `grep X f \|\| echo miss` still fires. |
| `-m`/`-A`/`-B`/`-C` | `-m` caps matches before the context window opens; `-C` is both sides, `-A`/`-B` per side, last wins. `--` separators only appear between *context* groups. |
| Unmatched globs | Passed through untouched (nullglob off), so the command names them. |
| Redirection | `>` `>>` `<` `2>` `2>>`, glued or spaced, in any combination and any order. A quoted one is an argument. `<` beats a pipe feeding the same command. |
| `cut` | LIST syntax (`1`, `1,3`, `2-`, `-3`, `2-4`), always file order with duplicates collapsed; TAB default delimiter; `-s`; empty fields are real fields. |
| `test`/`[` | `]` required; `!` chains; `-eq` on a non-number is an error, not a false — as bash has it. |
| Heredocs | `<<-` strips leading tabs from body *and* terminator. No expansion, so `<<EOF` and `<<'EOF'` are correctly identical (there are no parameters). |
| `$(...)` | Runs on the raw line pre-tokenize, whitespace-collapses when unquoted, splices whole inside `"`. |
| `seq` | GNU decimal inference, `first + i*step` (never an accumulator), `-w` pads after the sign. |
| Catastrophic backtracking | 200k step budget per line, and the refusal *names the pattern shape*. Without it Studio freezes — Luau cannot preempt a running chunk. |

---

## 3. Lies — divergences that can produce a wrong answer silently

Ranked as first written up. Eight are now closed; the entries are kept rather
than deleted because what was wrong, and why the fix took the shape it did, is
the part worth not re-deriving. §3.6 and half of §3.9 remain, and both are
deliberate — see §8.

### 3.1 ~~`miss()` prose flows down pipes~~ — FIXED

There is no stderr, so status prose was returned on stdout and pipes carried it
as data:

```
grep foo . | wc -l    →  1        real bash: 0
grep foo . | grep bar →  searched the string "no matches"
```

Now `miss()` marks its text as prose, and `runPipeline` hands a downstream
stage `""` instead — which is what real grep hands it. The last stage still
prints the sentence, because there is nobody else to tell. `ls`'s
`(empty) /Path [Folder]` goes through the same path.

The exception is deliberate: `grep -c` returning `0` found nothing **and** is
the number that was asked for, so it sets `unmatched` directly and never
reaches `miss()`. `grep -c X . | sort -n` still gets its zero.

This needed a second fix to land. `Fs.splitLines("")` returned `{""}` — one
blank line — so a correctly-blanked stage still made `wc -l` answer 1. Empty
text is zero lines; a file holding only `"\n"` is still one, and that path is
untouched.

### 3.2 ~~Truncation trailers are in-band too~~ — FIXED

Every cap appended its warning to the same stream, so `cat big.luau | wc -l`
answered 1001 and `grep -rn X . | wc -l` answered 101.

They now go through `note()`, and `runPipeline` collects them from **every**
stage and appends them once at the end. Accumulating rather than dropping is
the point: in bash, stderr reaches the terminal from any stage while only
stdout is piped, and simply stripping a non-final stage's note would have
made `cat big.luau | wc -l` answer a clean 1000 with nothing anywhere saying
the file has 3182 lines. Hiding the truncation is worse than mis-counting it.

`Terminal:cat` returns the marker as a third value for this; `grep`, `find`
and `ls` set it directly.

### 3.3 ~~`-name` is a case-insensitive *substring*~~ — FIXED

```
find . -name Main   used to match  Main, mainframe, DOMAIN, Remainder
```

`-name` is a glob everywhere else, and a glob with no wildcard matches exactly
one string. `Fs.nameMatcher` now takes `exact` and `caseSensitive`; `-name` sets
both, `-iname` sets only `exact` — which is the first time the two have differed
at all. Before, they were the same function, so one of the pair was a lie
whichever way you read it.

The loose form is kept where it belongs: the bare `find Handler` shorthand is
this harness's own invention and is meant to be forgiving. `ls *.luau` and
`--include=` still fold case too, deliberately — that is what makes `.lua` and
`.luau` name the same script.

### 3.4 ~~Glued redirection without a space is silently literal~~ — FIXED

`>` was an ordinary character to the tokenizer, so only two of the four
spellings bash accepts actually redirected:

```
echo hi > f.luau      wrote f.luau        echo hi> f.luau   printed "hi> f.luau"
echo hi >f.luau       wrote f.luau        echo hi>f.luau    printed "hi>f.luau"
```

A redirect that writes nothing, reports nothing, and produces output that
looks like it worked. `>` and `>>` are now word delimiters in the tokenizer,
as they are in bash, with one clause that has to be there: a bare `1` or `2`
immediately before the arrow belongs to the operator. Without it,
`find x 2>/dev/null` would split into `2` — searched for as an instance name —
and a `>` aimed at the bit bucket, silently discarding the real output. A
*quoted* digit is still data, so `echo "2">f` echoes the character.

### 3.5 ~~`2>/dev/null` is consumed but suppresses nothing~~ — FIXED

The token was recognised and thrown away, on the reasoning that there is no
stderr stream to aim it at. Recognising it was necessary — otherwise
`find x 2>/dev/null` searches for an instance literally named `2>/dev/null` —
but discarding it made the most reflexive way there is to quiet a probe quietly
do nothing.

There is still no stderr stream and there does not need to be one. `failed`
already means *"this errored and its whole output is the message"* — the
invariant the pipeline is built on — so a failing command's output **is** stderr,
and `2>` is somewhere to send it. `2>/dev/null` discards it; `2>err.luau` writes
it; a command that succeeded has nothing to send, so `2>` can never eat a real
answer.

Two consequences that had to be got right:

- The **status survives**. Silencing an error must not make it read as success,
  or `2>/dev/null` becomes a way to turn every failure into a silent pass.
- The **pipeline no longer stops**. `failed` halts a pipeline only to stop an
  error flowing on as data; once the message has been routed away there is
  nothing to stop for, and `find /Nope 2>/dev/null | wc -l` is 0, not an
  abandoned pipeline.

### 3.6 `>` adds a trailing newline — WON'T FIX, and here is why

`applyRedirect` appends `\n` when the body does not end in one.

```
echo -n hi > f.luau   → 3 bytes    real bash: 2
echo hi > f.luau      → 3 bytes    real bash: 3   ✓
```

Only the `-n` form differs, and the append is not the bug — it is compensating
for one. Every command here returns a string with **no trailing newline**; that
is the shell-wide convention the console rendering and every selfTest `want`
depend on. bash's `echo hi` emits `"hi\n"` and the redirect writes bytes
verbatim; ours emits `"hi"`, so without the append `echo hi > f.luau` would
write a file with no final newline — wrong for Luau source and wrong against
bash at the same time.

The faithful fix is at the other end: make `echo` emit its own trailing newline
and stop compensating in `applyRedirect`. That changes the convention for every
command, and it breaks immediately on things like `echo aaab | tr -s a`, which
would return `"ab\n"` where the assertion wants `"ab"`. Dozens of cases move,
the console gains a trailing blank line everywhere, and the whole payment buys
one byte in one flag combination that is already documented as inert.

Left alone deliberately. If the no-trailing-newline convention is ever revisited
for another reason, this comes with it.

### 3.7 ~~`cat a b` invents headers~~ — FIXED

`cat` printed `head`'s `==> path <==` banner over each file. No cat anywhere
does that, and `cat a b > merged.luau` wrote the banners *into* the script.
Now a byte-exact concatenation with nothing between files, pinned by a
selfTest case; the banner survives on `head`/`tail`, where it belongs
(`head -n 999999 a b`, `tail -n +1 a b`).

One deliberate remainder: an unreadable file still reports `cat: <err>` inline
rather than through `fail()`, because `fail()` stops the pipeline and
`cat good.luau missing.luau | wc -l` has to still count the good one. That
message travels as data — the §3.1 seam again, not a separate bug.

### 3.8 ~~Multi-statement output is prefixed with `$ cmd`~~ — FIXED

```
echo a; echo b   →   $ echo a      now:   a
                     a                    b
                     $ echo b
                     b
```

Statements concatenate, and one that printed nothing leaves no blank line — so
`cd /Workspace && ls` is the listing and nothing else, where it used to be an
empty labelled block followed by a labelled listing.

The label carried a diagnostic worth naming before deleting: it re-quoted every
token, so an agent could see that `grep -E 'a|b'` had *not* had its quotes eaten.
That argument does not survive contact with when the label appeared — only ever
with two or more statements, while a lone command, which is where the worry
actually arises, was never labelled. The tokenizer selfTest cases pin the same
property down permanently. `requote` and `label` are deleted.

One residue, and it is deliberate: a fired `||` drops the miss prose that fired
it, so `grep X f || echo absent` prints exactly `absent` as bash does. An *error*
message survives the fallback, because in bash that goes to stderr and stays on
screen. Real data with a false status — `grep -c X f` returning `0` — survives
too.

### 3.9 `wc -l` counts editor lines, not newlines — HALF FIXED

`splitLines("")` returned one blank line, so an empty script counted as 1.
Fixed (see §3.1) — empty text is zero lines.

What remains is deliberate: a file whose last line has no newline counts that
line, where GNU `wc -l` counts newline *characters* and answers 0. This is
documented in `Fs.splitLines` as the editor's reading, and it is the one a
model asking "how long is this file" wants.

### 3.10 ~~Stray `>` steals from unexpected places~~ — FIXED

Worse than first written up. `takeRedirect` matched any token shaped like an
arrow, and a **quoted** `>` is that token:

```
grep '>' f.luau   →  pattern silently dropped, and f.luau TRUNCATED
```

It searched for nothing, said nothing, and destroyed the file it was pointed
at. Present at HEAD before any of this work — verified by running the old
tokenizer against it, not by reading.

The quoted-position set that the METACHARACTERS gate already used now rides on
the argv array, is copied per stage by `parseStatements` (positions shift when
argv is cut into stages), and `takeRedirect` skips a quoted arrow. A loop body
rebuilt by `expandVar` arrives without the set, which degrades to the old
behaviour rather than to a new failure.

### 3.11 ~~A quoted or backslashed separator still split the line~~ — FIXED

§3.10 taught `takeRedirect` that a quoted `>` is data. `parseStatements` was
never told the same thing about `;` `&&` `||` `|`, and it is reading the same
set off the same argv:

```
echo ';'                              →  two statements, the second empty
find . -name X -exec cat {} \; | sed  →  find, then a SECOND statement "| sed"
```

Two halves, and both had to move. `parseStatements` compared the token text
alone, so a token whose text was `;` was a separator no matter where it came
from. And `tokenize`'s unquoted-backslash branch put the escaped character
straight into the word **without setting `sawQuote`**, so `\;` produced a token
byte-identical to the operator and carrying no mark to tell them apart.

The reported case came in as `cd D && find . -name X -exec cat {} \; | sed -n
'1,120p'`, and what ran was `cd`, then `find` without its `-exec`, then `sed`
with no input — three outputs, none of them the one asked for.

The same escape reached §3.10's destructive case by the other door:
`echo \> f.luau` marked nothing, so the arrow was taken as a redirection, the
argument was dropped and **f.luau was truncated**. Fixing the flag closes both.

One bash behaviour falls out for free: an escaped digit is a word, not a stream
number, so `echo \2>f` writes `2` to `f` rather than being read as fd 2.

## 4. Honest divergences (announced, refuse rather than fake)

These are correct calls, listed so they are not mistaken for the section above.

- **No stderr.** Stated everywhere. The cause of §3.1/§3.2, not itself a lie.
- **No `$?`, no variables (except a loop's own), no assignment, no arithmetic,
  no backticks, no `if`/`while`/`until`, no functions, no `~`, no brace
  expansion, no `PATH`.** All refused by name with the alternative given.
- **stdin whitelist** — 11 commands (`cat grep egrep fgrep head tail wc sort
  uniq sed tr`). `ls | ls` is an error, not a silent ignore. Better than bash's
  silence.
- **`UNSUPPORTED` table** — `awk chown sudo ps kill man exit quit compgen unzip
  tar xargs while until do done` each fail with a specific reason and a working
  substitute, instead of "command not found". `awk`'s now names `cut` for a
  column, which is the half of it that had no spelling at all before.
- **`find -exec` runs**, in both the `\;` and `+` forms, with `{}` substituted.
  It used to be refused for "there is no process to run", which was the wrong
  reason: there is no process to run in this shell at all — `cat`, `grep` and
  `sed` are Lua functions in `HANDLERS`, and one of those is the only thing
  anyone puts after `-exec`. It is a dispatch per result. `-execdir` and `-ok`
  stay refused and now point at it. One divergence: a failing invocation stops
  the rest, the way a pipeline does, because `failed` means the output IS the
  message and letting it run on would mix an error into the results as data.
- **`for` is the only loop**, deliberately: nothing here can change a condition
  between iterations, so `while` runs zero times or forever, and forever is a
  frozen Studio.
- **Globs are trailing-component only** (`splitGlob`) — `/A*/foo` does not
  expand. No `**`. No `{a,b}`.
- **`$(...)` refuses to splice shell punctuation** (`; | & ' " \`), because
  splicing happens on the text pre-tokenize. bash splices post-parse and has no
  such problem. Refusing is the honest version of the difference.
- **`$(...)` depth 4.**
- **`&` backgrounding** is the only metacharacter left with no meaning: there is
  no process table, no job control, no `wait`, and a tool call returns one
  string.
- **`seq` refuses past 1000** rather than truncating — half a sequence is the
  wrong sequence.
- **`ls /` collapses empty services** with a count and a way to see them
  (`ls -a /`). Studio instantiates 100+ services whether the place uses them or
  not.
- **`stat` omits `%U %G %y`** rather than inventing owner/group/date.
- **`ln` is an ObjectValue**, and nothing resolves through one.

---

## 5. Output cutting — the full ladder

Four independent caps, and none of them is a bare cut. Every one names what it
dropped and how to see it.

| Cap | Value | Where | On overflow |
|---|---|---|---|
| `MAX_CAT_LINES` | 1000 lines | `Terminal.lua:105` | `… TRUNCATED: 1000 of 3182 lines shown. Page the rest with `sed -n '1001,2000p' /Path`` — the exact next command, pre-computed |
| `MAX_RESULTS` | 100 hits | `Terminal.lua:99` | `… N more matches (narrow the path or the pattern)` — **the walk continues past the cap** so N is a real number, not a shrug |
| `MAX_LIST` | 100 rows | `Shell.lua:68` | `… N more from "Workspace" on (narrow it: `ls /A*`, or `ls \| grep <name>`)` — names the *first casualty*, so "Workspace is missing" is visible rather than "the boring tail" |
| `MAX_SEQ` | 1000 values | `Shell.lua:1111` | refuses outright |

Then two more on the wire, in `agent/Agent.lua`:

| Cap | Value | Behaviour |
|---|---|---|
| `MODEL_RESULT_CHARS` | 100 000 | per tool_result. Head, not tail (shell output front-loads). `safeCut` backs up to the last newline if that keeps >50% of the budget, else steps off UTF-8 continuation bytes — a cut landing mid-codepoint makes `JSONEncode` reject the whole request. Marker: `... [N characters truncated] ...` plus the narrower commands to re-run with. |
| `MODEL_TURN_CHARS` | 200 000 | per *turn*, across all parallel tool_results in the one user message. Smallest-first fair share: results already under their share release the remainder, so one huge `tree` beside three small listings gets nearly the whole budget instead of a quarter. Only binds from the third large result onward. |

**Answer to "is it just a pure cut?"** — no. Every cap is announced, four of the
six carry the exact narrowing command, and `MAX_RESULTS`/`MAX_LIST` carry a
count that is *true* rather than "≥100". The console still shows the user
everything; only the copy going on the wire is cut.

The one flaw is §3.2: the trailers ride on stdout, so they are also data.

---

## 6. Performance — 10k nested instances

### grep

Per script, in `Terminal:grep` → `Fs.getSource` → `Fs.grepLines` →
`Fs.matchSpans` → `Regex.Program:find`.

**Good:**
- Patterns compile **once per command**, not per line.
- Two fast paths in `Regex.compile`: a wholly-literal pattern never enters the
  engine (`string.find` plain), and otherwise a **required-substring prefilter**
  is extracted from the top-level char run and `string.find`-ed first. This is
  what real grep does with Boyer-Moore. Prefilter is skip-only — it can produce
  false negatives for the *skip*, never change a match.
- `anchored` — a leading `^` tries exactly one start position.
- Step budget is per `find()` over the whole scan, so it cannot reset per start.
- `Fs.breather()` yields a frame every 1/60s of held thread — a 10k-instance
  walk does not freeze Studio.
- `MAX_RESULTS` caps *emission*, not the walk, and `-m` is applied per file
  before the context window opens.

**Costs at 10k:**

1. **One `FindScriptDocument` engine call per script, per grep.** Marked
   `ponytail:` in `Fs.lua:63`. Stateless by design (a cached open-set can drift,
   and stale text is the exact failure the branch exists to remove). At 10k
   scripts this is 10k round trips into the editor before a single byte is
   matched. The upgrade path is named in the comment:
   `TextDocumentDidOpen`/`DidClose` maintaining a set.
2. ~~**`matchSpans` finds every match on a line even when only "did it match" is
   needed.**~~ **FIXED.** `matchSpans` now takes a `first` flag and returns after
   the first span; `grepLines` passes it whenever `-o` is off, which is every
   caller but one. The waste was proportional to how *much* a file matched — so
   it was worst on exactly the searches that find something.
3. ~~**No case-insensitive fast path.**~~ **FIXED.** The *literal* path still has
   to stay off under `-i` (it returns match bounds straight from `string.find`,
   so it must compare real bytes), but the *prefilter* only ever decides whether
   to skip a line: the needle is lowercased at compile, the subject at match, and
   a false negative is impossible because both fold identically. Before this,
   `grep -i` had no fast path at all and ran the full backtracker over every line
   of every script in the place. `Regex.selfTest` now runs its
   prefilter-equivalence sweep under both case settings and asserts the
   insensitive prefilter is actually present.
4. ~~**`instancePath` per hit** walks to `game` with `table.insert(parts, 1, ...)`
   — O(depth²).~~ **FIXED.** Appended and reversed once, which is O(depth). The
   insert-at-front shifted every element already collected, so a depth-100 path
   did 5000 moves to build 100 components — and `find -path`/`-regex` pay it per
   node, not per hit.
5. ~~`getSource` is called **twice** per instance in the `-L` path (once in the
   walk, once in the re-walk).~~ **FIXED**, and it was worse than "twice": the
   re-walk's only question was *"is this a file"*, and it asked it with
   `getSource(inst)`, which answers by handing back a **copy of the whole
   script**. So `grep -L X /` read every source in the place a second time to
   produce a boolean that `getSource`'s own first line already had. `isScript` is
   that line, and agrees exactly. The same loop also built `instancePath` twice
   per instance, once to look up and once to emit; it is built once now.

Rough shape: 10k scripts × ~200 lines is 2M line-matches. With a prefilter hit
that is 2M `string.find` calls — Luau will do that, but not instantly, and the
`FindScriptDocument` calls are likely the larger half.

### find

`Terminal:find` is a recursive `GetChildren()` walk (not `GetDescendants()`) so
`-maxdepth` stops early rather than building the whole list and filtering.
Breathes. The cap counts past itself deliberately.

**Costs:**
- `-path`/`-ipath`/`-regex` call `instancePath(inst)` **per node** — O(n·depth)
  string building for the whole subtree, now that `instancePath` itself is linear
  in depth rather than quadratic. `-name` does not (it reads `.Name`), so `-name`
  is still the cheap one, and `-tag` is cheaper again: one `HasTag`, no string.
- Tests are a flat OR of AND-groups evaluated per node with closure calls. Fine.
- ~~`-delete` sorts by `#instancePath(a) > #instancePath(b)`.~~ **FIXED** — real
  depth, measured once per instance into a table. It was rebuilding every path
  twice per comparison, and string length was only a *proxy* for depth that a
  long name beside a deep path could invert — which matters, because the one
  thing this ordering has to guarantee is that a child is never left behind its
  destroyed parent.

### ls

- ~~**`ls -S` calls `Fs.size` inside the `table.sort` comparator.**~~ **FIXED** —
  the rank is computed once per row before the sort. `Fs.size` on a container is
  `#inst:GetDescendants()`, so on a `Workspace` with 10k parts the comparator was
  walking those parts O(n log n) times to order one listing, making the flag that
  exists to find the big thing the slowest command in the shell. (`ls -t` was
  always fine — `Fs.mtime` is a table lookup.)
- `ls -R /` re-resolves a path string per container; breathes, so it is slow
  rather than fatal.

### Memory

Slowness is not what runs Studio out of memory. ALLOCATION between two frames
is, and a huge place has the process near its ceiling before this plugin
allocates anything at all — so the number that matters is how much garbage a
command makes without yielding, not how long it takes.

`Fs.size` is the shared primitive, and on a container it is
`#inst:GetDescendants()`: the engine builds a table holding a pointer to every
instance in the subtree, to return one integer. At `/Workspace` in a big place
that is a several-hundred-thousand-entry table per call. Three commands called
it in a loop.

- **`ls -S` called it inside `table.sort`'s comparator** — fixed above, and it
  was the worst allocation site in the codebase for a second reason: `table.sort`
  is the one loop here that *cannot breathe*, so the collector got no scheduled
  step for the entire sort. `ls -S` is also precisely what gets reached for on
  "what is big in this place", which is the question a big place invites.
- **`du` did not breathe at all** — **FIXED.** Every other recursive walk (find,
  grep, tree, `ls -R`) yields a frame once it has held the thread for one; du
  held it for the whole walk, and it is the walk with the largest per-node
  allocation.
- **`find -size`** calls it per node, inside a walk that does breathe. Left as
  is: the yield is what makes it survivable, and there is no cheaper way to ask
  the engine how big a subtree is.

Reads are the other half. `.Source` hands back a full copy of the script, and
`splitLines` then concatenated a newline onto it — copying the whole file a
**second** time — before allocating one string per line. **FIXED:** a plain
`find(source, "\n", pos, true)` scan, same lines out, one copy less per file
read. `grep -r /` over 10k scripts still allocates every source once; that is
the read itself, and it breathes.

Not profiled in Studio. These are allocation counts read off the code, and they
say which commands are capable of it, not which one did it.

### Regex engine

Backtracking with continuations, `MAX_STEPS = 200000` per line. Marked
`ponytail:` — a legitimate but expensive pattern is refused rather than served
slowly; the upgrade path (Thompson NFA) is linear but cannot do backreferences,
which is why every real grep still ships a backtracker. Correct call.

---

## 7. Studio APIs not being used

Researched against the engine reference. Only the ones that would actually pay.

### Confirmed available, would pay

**`StudioService.ActiveScript`** — **DONE.** `Instance`, read-only. Returns the
script currently being edited.

`agent/Agent.lua` used to say *"There is no focus API. ScriptDocument cannot say
which tab is in front"* — wrong about the API, not about `ScriptDocument`.
`Fs.activeScript()` reads it, `Fs.openDocuments()` puts that document first and
flags it, and `editorContext()` renders it `[ACTIVE]`. Still a list, because the
other open files are real context and `nil` is a real answer whenever the
viewport is in front — but the entry that survives the 6-entry/600-char cap is
now always the one that matters, rather than whichever `GetScriptDocuments`
happened to return first.

**`ScriptDocument:GetText(startLine, startChar, endLine, endChar)`,
`:GetLine(n)`, `:GetLineCount()`** — ranged reads on an *open* document.
Today `cat`/`head`/`sed -n '10,40p'` on an open script pull the entire buffer
via `GetEditorSource` and slice in Luau. `GetLineCount()` alone would let
`Terminal:cat` decide about `MAX_CAT_LINES` without materializing a 3000-line
string. Only helps open documents, so it is a fast path, not a replacement.

**`ScriptDocument:GetSelectedText()` / `HasSelectedText()`** — "fix *this*"
where the user has literally highlighted it. `editorContext()` currently reports
cursor line + viewport, which is a proxy for the same question.

**`CollectionService`** — **DONE, as a predicate.** `find -tag Enemy` is
`Fs.hasTag` per node, and `stat` lists an instance's tags sorted. Tags were a
first-class DataModel concept with no bash analogue and no spelling in the shell
at all, so the only way to find everything tagged `Enemy` was to already know
where it was.

What is *not* taken is the indexed half: `GetTagged` is the only lookup in the
whole shell that could beat a walk (**O(matches)**, not O(10k)). Seeding
`Terminal:find` from it means rebuilding the depth bounds and the deterministic
tree ordering off an unordered list, and it only holds while `-tag` is the entire
expression — so it is marked `ponytail:` on `Fs.hasTag` rather than done.

**`Instance:GetAttributes()`** — **DONE.** The xattr analogue, on `stat`, sorted
and rendered through the same `Fs.formatValue` that `cat` uses for properties.
Omitted entirely when empty, along with the tag line: `Tags: (none)` on every
stat is a line on the wire for the rare instance that has any.

### Available, probably not worth it

- **`ScriptEditorService:RegisterScriptAnalysisCallback`** — publish the
  `vendor/LuauParser` syntax check as real editor diagnostics. Nice product
  feature, zero shell fidelity value.
- **`ScriptDocument:ReviewableTextEditsAsync(changes)`** — surfaces edits in
  Studio's review UI instead of applying them. A real alternative to
  `UpdateSourceAsync` for the `edit` tool, and it puts a human in the loop.
  Behaviour change, not a bug fix — worth a decision, not a patch.
- **`ScriptEditorService.TextDocumentDidOpen/DidClose`** — the named upgrade
  path for the `FindScriptDocument`-per-read cost in §6. The comment argues
  against it (drift), and that argument holds until a place is big enough to
  feel the cost.
- **`StudioService:PromptImportFileAsync()`** — a real file picker. Would give
  the shell an actual host-filesystem read. Large scope, and it needs a human
  click every time, so it is not a `cat`.
- **`ScriptEditorService:OpenScriptDocumentAsync(script)`** — an `edit`/`code`
  command that opens a file for the user.

### Checked, no

`Selection`, `ChangeHistoryService`, `HttpService`, `LogService`,
`InsertService`, `MarketplaceService`, `EncodingService`, `RunService`,
`StudioService:GetUserId` are all already wired. `AssetService`'s editable
image/mesh APIs, `AnalyticsService`, physics queries — nothing shell-shaped.

---

## 8. Summary

The shell is not pretending. Roughly two-thirds of what it does not do is
refused **by name, with the working substitute in the error message**, which is
a higher standard than bash itself holds.

Eight of the ten divergences are closed, and the ones that mattered went together
because they were one problem. There is still no stderr stream, but there is now
a **channel** for everything that would have used one:

- `miss()` marks prose — a false status spelled out for a human, dropped for a
  downstream stage and dropped again by a `||` that supersedes it.
- `note()` marks a warning about the output — collected from every stage and
  printed once at the end, the way stderr reaches a terminal from anywhere in a
  pipeline.
- `2>` routes a failure's message, because `failed` already meant "the output IS
  the message".

`runPipeline` and `runStatements` are the only places that know which is which.

Two of the ten were worse than the write-up, and neither was visible from
reading — both were found by running the old code:

- **§3.10** a quoted `>` parsed as a redirection, so `grep '>' f.luau` dropped
  its pattern *and truncated the file it was searching*. Silent and destructive.
- **§3.4** two of the four spellings of `echo hi>f` printed instead of writing.

What is left:

- **§3.6** `>` appends a trailing newline. Won't fix — it compensates for the
  shell-wide "returned strings carry no trailing newline" convention, and the
  real fix moves every command and every test to buy one byte in one flag
  combination.
- **§3.9** a last line without a newline still counts as a line. Deliberate: the
  editor's reading, not GNU's, and the one a model asking "how long is this file"
  wants.

Performance: all five cheap wins are taken — first-span-only matching, a
case-folded prefilter for `grep -i`, precomputed sort keys for `ls -S` and
`find -delete`, and a linear `instancePath`. What remains is the one already
marked `ponytail:` in the source:
`FindScriptDocument` runs once per script per grep, by design, because a cached
open-document set can drift and stale text is the exact failure that branch
exists to prevent. `TextDocumentDidOpen`/`DidClose` is the named upgrade path if
a place ever gets big enough to feel it.

Memory is tracked separately, in §6 "Memory", because it is a different
question: not how long a command takes but how much it allocates without
yielding, which is what ends a session in a huge place. The two sites that could
not yield are closed (`ls -S` inside `table.sort`, `du`'s walk), and reads cost
one whole-file copy less apiece. `Fs.size` on a container is still
`#GetDescendants()`, which is the ceiling rather than a bug.

### Verification

None of this was checked by reading alone. `luau-compile` parses every file, and
these run against the real source, sliced out of it rather than retyped:

| What | How |
|---|---|
| `Regex.selfTest()` | in full, including a new prefilter-equivalence sweep under both case settings |
| tokenizer | every `Shell.selfTest` case, including the 8 new redirect ones |
| `tokenize` → `parseStatements` → `takeRedirect` | the quoted-`>` and `2>`/`1>`/`>>` matrix |
| `runPipeline` / `runStatements` | 13 assertions against the real functions with a stub command layer |
| `Fs.nameMatcher` | loose and exact forms, both case settings |
| `Agent.historyBuckets` | the tool_result-in-a-user-message classification |

Studio's startup self-tests are still the real gate; this is what catches things
before they get there.
