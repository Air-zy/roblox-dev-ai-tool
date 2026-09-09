# FIDELITY — the shell, measured against real bash

Scope: `fs/Shell.lua`, `fs/ShellSyntax.lua`, `fs/ShellWords.lua`,
`fs/ShellRuntime.lua`, `fs/ShellBuiltins.lua`, `fs/Terminal.lua`, `fs/Fs.lua`,
`text/Regex.lua`, `text/Sed.lua`. The `bash` tool and `/sh` are the same call —
`Shell.run`.

Keep this honest or delete it. The point of the file is the **Lies** section;
everything else is context for it.

The tool description says "Bash-style shell over a live in-memory vfs". That
first phrase is a claim, and this is the audit of it. It used to say "real bash
shell"; the wording was changed because it was the stronger claim and this
document is what has to back it.

---

## 1. The shape

```
raw line
  → Syntax.lex        quotes, escapes, operators, heredoc bodies lifted per line
  → Syntax.parse      full AST: if/case/while/until/for/functions/{ }/( )/pipelines
  → Runtime.execute   walks the AST
      → Words.expand  per word, immediately before the command runs:
                      brace → tilde → parameter/command/arithmetic → split → glob
      → redirects     descriptors opened in order, then routed per output chunk
      → HANDLERS[cmd] receives fully expanded argv; never sees shell syntax
```

The order is the load-bearing part. **The whole line is parsed before any
command runs**, so a missing `fi` cannot apply half of it. **Expansion happens
after parsing and its results never re-enter the lexer**, so a filename
containing `;` is a filename and cannot become a second command. The previous
design spliced `$(...)` into the raw text *before* tokenizing, which is why it
had to refuse any substitution output containing `; | & ' " \` — that whole
class of refusal is gone with the design that caused it.

**54 commands**, from `help`:

```
: [ basename break cat cd chmod command continue cp curl cut diff dirname du
echo egrep exit export false fgrep file find git grep head help ln local ls
mkdir mv printf pwd read return rm rmdir sed seq sort stat tail test touch tr
tree true uniq unset wc wget which whoami
```

Not a filesystem underneath — a DataModel. A "file" is a `LuaSourceContainer`
and its `.Source`; a "directory" is any other `Instance`. `find -type f` is
`IsA("LuaSourceContainer")`; `-type d` is the negation, not `Folder`.

---

## 2. What is genuinely faithful

Not a short list, and worth stating before the divergences. Everything in this
table is pinned by a test — see **Verification**.

| Area | Detail |
|---|---|
| Grammar | `if/elif/else/fi`, `case/esac`, `for`, `while`, `until`, `{ }`, `( )`, `name() { }` and `function name { }`, `!`, `&&`/`\|\|`/`;`, pipelines. Compound commands take redirections and feed pipes. |
| Quoting | Only `$ " \ \`` escape inside double quotes; single quotes are literal. Matches bash exactly. |
| Expansion order | Brace, then tilde, then parameter/command/arithmetic, then field splitting on `IFS`, then pathname. Values are never re-lexed. |
| Parameters | `$1 $# $@ $* $?`, `${x}`, `${#x}`, `${x-d} ${x:-d} ${x=d} ${x:=d} ${x+s} ${x:+s} ${x?m} ${x:?m}`. `"$@"` expands to one word per argument and to nothing when empty. |
| Arithmetic | Own integer parser, not Luau execution. bash precedence including `**` right-associative, C truncation on `/` and `%`, `&& \|\| ?:` short-circuit (so `$((0 && 1/0))` is 0, not a division error). Exact to ±(2^53−1). |
| Globbing | `*`, `?`, `[a-z]`, `[!x]`, across multiple path segments. Dotfiles need an explicit leading dot. Unmatched patterns pass through untouched (nullglob off). Matching is dynamic-programming, so `*a*a*a*` cannot backtrack exponentially. |
| Brace expansion | `{a,b}`, nesting, `{1..9}`, `{01..10}` zero-padded, `{a..z}`, `{1..9..2}`. Before parameters, and quoted braces stay literal. |
| Variables | Per-Terminal, surviving shell calls. `NAME=value`, `export`, `unset`, `local`, prefix assignments (`X=1 cmd` restores, bare `X=1` persists), `local X` with no `=` declares it unset. |
| Scoping | Subshells, pipeline stages and command substitutions fork: they see the caller's variables and functions, and their changes do not escape. Brace groups and functions share the caller's state. `exit`/`return`/`break` inside a fork end that fork only. |
| Streams | Two of them, ordered. `>` `>>` `<` `2>` `2>>` `&>` `2>&1` `>&2` `>&-` `<<` `<<-`, glued or spaced, in any order. `2>/dev/null` silences without changing status. |
| Output order | stdout and stderr reach the console interleaved in write order, so a diagnostic appears beside the command that produced it. No newline is injected between them, so `printf abc; cat missing` is byte-identical to bash's. |
| `read` | `-r`, `IFS` splitting, leading/trailing whitespace rules, the remainder-to-the-last-name rule, and a false status at EOF so `while read \|\| [ -n "$line" ]` terminates. |
| `printf` | Own format grammar: reusable formats, `-v`, `%s %b %c %q %d %i %u %o %x %X %e %f %g`, `*` widths, precisions, flags, escapes, 64-bit integer conversion. Only float digit conversion defers to Luau. |
| Heredocs | `<<` expands parameters and substitutions; `<<'EOF'` does not; `<<-` strips leading tabs from body and terminator. |
| Regex | Real BRE/ERE engine (`text/Regex.lua`), not Lua patterns in costume. `grep` is BRE, `-E`/`egrep` is ERE, `-F`/`fgrep` is literal — and `egrep`/`fgrep` are *definitions*, not aliases, so `egrep '[0-9]'` is a class. |
| Flag bundling | `-rn` is `-r -n`; a value letter ends its bundle (`-nA3` = `-n -A 3`). `head -20` and `-` stay operands. |
| `head`/`tail` signs | `head -n -5` (all but last 5) and `tail -n +5` (from line 5) both carry the sign. `-c` is bytes. Multi-file `==> path <==` headers match coreutils. |
| Pipeline status | The pipeline's status is the last stage's. `&&`/`\|\|` short-circuit. `!` inverts status only. |
| grep exit semantics | "errored" and "found nothing" are separate. `grep X f \| wc -l` still runs `wc`; `grep X f \|\| echo miss` still fires; `grep -c X f` prints `0` and exits 1. |
| `-m`/`-A`/`-B`/`-C` | `-m` caps matches before the context window opens; `-C` is both sides, `-A`/`-B` per side, last wins. `--` separators only appear between *context* groups. |
| `cut` | LIST syntax (`1`, `1,3`, `2-`, `-3`, `2-4`), always file order with duplicates collapsed; TAB default delimiter; `-s`; empty fields are real fields. |
| `test`/`[` | `]` required; `!` chains; `-eq` on a non-number is an error, not a false — as bash has it. |
| `cd` | Silent. `PWD` and `OLDPWD` are ordinary exported variables it maintains; `cd -` reads `$OLDPWD` and prints where it landed. |
| `find` | `-delete` and `-exec` bind to the `-o` branch they were written in, and the first matching branch claims the node. `-delete` unlinks and refuses a non-empty directory, as `rmdir` does. |
| `seq` | GNU decimal inference, `first + i*step` (never an accumulator), `-w` pads after the sign. |
| Catastrophic backtracking | 200k step budget per line, and the refusal *names the pattern shape*. Without it Studio freezes — Luau cannot preempt a running chunk. |

---

## 3. Lies — divergences that can produce a wrong answer silently

Two remain, and they are the same root cause.

The list was longer. A 20-area conformance pass run **first-hand through the
`bash` tool inside Studio** (`bashShellAudit.md`) found ten more that a CLI
harness could not see; all ten are closed and in the ledger below.

One of its findings does not survive checking, and is recorded here so it is not
re-filed: it reported `$((-2**2))` as 4 where bash gives -4. Bash gives **4** —
unary minus binds tighter than `**` there, unlike ksh93 and Python — so the
implementation is correct and the differential vector covering it is right.

### 3.1 A partially-failing command cannot report data and an error at once

This is the live one, and it has two faces because two handlers chose opposite
halves of an impossible pair.

```
cat alpha.luau missing        prints the file, then "cat: no child named …",
                              exits 0.  GNU cat: exits 1.
cat alpha.luau missing 2>/dev/null | wc -c   →  58
```

The error survives `2>/dev/null` and is counted by `wc`, which means it is on
**stdout, as data** — the §3.1 of the old write-up, reopened in the one place
that was left alone when it was closed everywhere else.

```
head -2 alpha.luau missing    prints ONLY the error, exits 2.
                              GNU head: prints the good file, error on stderr, exits 1.
```

Here the status is honest and the data is gone instead.

**Cause.** A handler returns one string plus a boolean. `fail()` means "this
errored and its entire output is the message", which is what `runtimeApi`
converts to an fd-2 chunk. There is no way for a handler to say *"here are 30
good bytes on fd 1, and also this error on fd 2, and exit 1"*, so a handler with
several operands must pick: keep the data and lie about the status (`cat`), or
keep the status and drop the data (`head`).

**Same cause, smaller face:** within a *single* command, stdout and stderr
concatenate rather than interleave, because the handler returns each stream
whole. Ordering is correct *between* commands, statements, loop iterations and
pipeline stages — the runtime carries `{fd, text}` chunks — and it stops being
correct exactly at the handler boundary. Marked `ponytail:` in
`ShellRuntime.simple`.

**Upgrade path**, for both: handlers write chunks to a sink instead of returning
a pair. The runtime side already models it; only the 42 handlers and `fail()`
have to move.

### 3.2 `wc -l` counts editor lines, not newline characters

A file whose last line has no newline counts that line. GNU `wc -l` counts
newline *characters* and answers one fewer.

```
printf 'a\nb' > g.luau ; wc -l g.luau   →  2      GNU: 1
```

Deliberate, and documented in `Fs.splitLines` as the editor's reading: it is the
answer a model asking "how long is this file" wants, and it agrees with what the
Script Editor shows in the gutter. An empty file is 0 lines; a file holding only
`"\n"` is 1. Left as the only counting rule in the shell, rather than having
`wc` disagree with `sed -n '$='` and the editor.

### Closed

Kept as a ledger, not as prose — what was wrong is worth not re-deriving, but
the fixes are old enough now that the reasoning lives in the code comments.

| Was | Now |
|---|---|
| `miss()` prose flowed down pipes | prose is a separate channel, dropped for a downstream stage and by a `\|\|` that supersedes it |
| Truncation trailers rode on stdout | they are stderr, and reach the console from any pipeline stage |
| `-name` was a case-insensitive substring | a glob, exact; `-iname` is the case-folding one |
| Glued `echo hi>f` printed instead of writing | `>` `>>` `<` are word delimiters, with the `1`/`2` stream-digit clause |
| `2>/dev/null` was parsed and discarded | a real fd, routed per chunk |
| `>` appended a trailing newline | bytes are written verbatim; `echo -n hi > f` is 2 bytes |
| `cat a b` invented `==>` headers | byte-exact concatenation |
| Multi-statement output was prefixed `$ cmd` | statements concatenate, as bash |
| A quoted `>` was parsed as a redirection, truncating the file being searched | quoting survives into the parser; expansion cannot produce an operator at all |
| A quoted or backslashed `;` `&&` `\|` still split the line | same |
| `( exit 5 )` ended the whole line | flow is contained at every fork |
| `local`/`return` failed inside a pipeline stage in a function | forks carry the function scope, with their own save slots |
| `local X` with no `=` showed the caller's value | declares it unset |
| `cd` printed its destination every time | silent; `cd -` prints, as bash |
| `$PWD` ignored assignment, `OLDPWD` never existed | both are ordinary exported variables |
| `find -delete` destroyed unmatched children of a matched directory | refuses a non-empty directory |
| `find -delete`/`-exec` fired for every branch of an `-o` | bind to the branch they were written in |
| `diff -r` compared one level and stopped | descends, name-sorted, and reports file/directory mismatches |
| A path named whichever duplicate sibling came first, so `find -name x` matched one instance and `rm x` destroyed another | mutation refuses an ambiguous path; reading still follows the first match. `ls -R` descends by instance instead of re-resolving what it printed |
| A substitution writing to stderr aborted the line and discarded output already printed | its stderr is queued for the enclosing command; stdout substitutes and the line continues |
| `$((++i))` parsed as two unary pluses: wrong value, no increment, no error | `++`/`--` pre and post, and `= += -= *= /= %= <<= >>= &= \|= ^= **=` |
| `diff` exited 0 whether or not the inputs differed, so `if diff` could never fire | 0 same, 1 different, 2 trouble, as GNU |
| `rmdir -p` exited 0 after failing on a non-empty parent, and climbed past the path it was given into the cwd | removes the named components only, and reports the one it could not |
| `touch`/`rm`/`mkdir`/`rmdir`/`cp`/`mv`/`sed -i`/`find -delete` announced on stdout, so `X=$(touch f)` captured `created …` | the announcement is stderr; a capture and a pipe get nothing |
| `grep PATTERN file` added a path header and `N: ` prefixes the piped spelling did not | one named file prints the bare line; `-n` numbers it, `-H` re-adds the path |
| `C=temp export C=operand` restored `outer`, undoing the operand export had just written | a prefix assignment in front of a POSIX special builtin persists |
| Tilde expanded in `A=~/x` but not `export B=~/x`, `local C=~/x` or `D=x:~/z` | expands at the head of an assignment value and after each unquoted colon |
| `tree` stopped at depth 2 with no marker, rendering a populated directory as empty | unlimited like GNU, with a row cap that names what it dropped |
| `mkdir existing` printed "already exists" and exited 0, so `mkdir d && cd d` entered someone else's d | refuses with `File exists`; `-p` is still the idempotent form |

---

## 4. Honest divergences — announced, refuse rather than fake

Correct calls, listed so they are not mistaken for the section above.

- **`&` and job control do not exist.** No process table, no `wait`, and a tool
  call returns one string. The parser names it rather than ignoring it.
- **A miss prints prose.** `grep zzz f` says `no matches` and exits 1 where bash
  prints nothing. `find` and `ls` print the same kind of sentence on an empty
  result but exit 0, as GNU does — their status reports errors, not the match
  count, so `set -e` does not abort a correct search that found nothing. The
  prose is the divergence here; the status is not. The prose is dropped for a
  downstream stage and by a `||` that handles it, so `grep X f | wc -l` is 0 and
  `grep X f || echo absent` prints exactly `absent`.
- **`UNSUPPORTED` table** — `awk chown sudo ps kill man quit compgen unzip tar
  xargs` each fail with a specific reason and a working substitute, instead of
  "command not found".
- **`find` with no test is refused**, even with `-delete` or `-maxdepth`: a path
  on its own means "everything under here", and that is not a set to delete or
  print by accident. `ls -R` is the listing.
- **`find -delete` together with `-exec` is refused.** GNU interleaves them in
  expression order; this find has one action pass per branch, and running half
  of what was written silently is worse than saying so.
- **`find -exec` stops on a failing invocation**, the way a pipeline does,
  because `fail()` means the output IS the message. `-execdir` and `-ok` are
  refused and point at `-exec`.
- **`seq` refuses past 1000** rather than truncating — half a sequence is the
  wrong sequence, and the loop built from one quietly does the wrong number of
  things.
- **`ls /` collapses empty services** with a count and a way to see them
  (`ls -a /`). Studio instantiates 100+ services whether the place uses them or
  not.
- **`ls -R` traverses script children.** A Script, LocalScript or ModuleScript
  can own a subtree, so recursive listing descends into it. Plain `ls script`
  still lists the script itself, as does `ls -dR script`.
- **A mutation announces what it did, on stderr.** `touch`, `rm`, `mkdir`,
  `rmdir`, `cp`, `mv`, `sed -i` and `find -delete` are silent on success in
  POSIX; here they say what changed, because a transcript that does not is
  unreadable. On stderr, so a capture or a pipe gets the value and not the
  announcement — that half was a real bug (§3 ledger) and is fixed.
- **`grep` across several files prints the path once as a header**, then
  `N: line`, rather than GNU's `path:line` per line. DataModel paths are deep: a
  40-hit grep over 6 scripts spends ~430 characters on paths this way against
  ~1800 flat, and a tool result is re-sent every remaining turn. **One** named
  file gets GNU's bare line, with `-n` and `-H` meaning what they do there.
- **A command-handler error exits 2 where GNU exits 1.** The shell keeps "found
  nothing" (1) and "the command failed" (2) apart on purpose — it is what lets
  `grep X f || echo miss` fall back while a genuine error still stops a `&&`
  chain. Collapsing them onto 1 would make an error indistinguishable from an
  empty search.
- **`stat` omits `%U %G %y`** rather than inventing owner/group/date.
- **A duplicate sibling name is a read-first, write-never path.** A DataModel
  lets siblings share a name and a filesystem does not, so a path is not always
  a unique handle. Reading follows the first match; `rm`, `cp`, `mv`, `write`
  and `edit` refuse and point at `ls -i` / `find -inum`. Refusing on *every*
  lookup was tried and reverted: a stock place has ~2892 duplicate-name groups
  across ~11371 containers (`Keyframe`, `WeldConstraint`, `Model`), and it made
  a quarter of the tree unreachable to read for no safety gain.

  The remaining sharp edge: when an *intermediate* component is ambiguous, a
  path reaches whichever sibling comes first, so `dup/deep.luau` can report "no
  child named deep.luau" while the file sits under the other `dup`. The error
  names the container it actually reached. `find` and `tree` enumerate children
  directly and are unaffected; they are the way to reach into a duplicate.
- **`ln` is an ObjectValue**, and nothing resolves through one.
- **`export` marks shell variables**, not the host computer's environment.
  Nothing here spawns a process for one to be inherited by.
- **No state persists across Studio restarts.** Variables, functions and the cwd
  belong to the Terminal.
- **Non-`.luau`/`.lua` names skip the Luau parse check.** `notes.txt`,
  `config.json` and `README.md` are text; a name with no extension is assumed to
  be a script, which is what every instance name in a place actually is.

### Not implemented

- `tee`.
- `eval`.
- Base-N arithmetic literals: `$((2#101))`, `$((16#ff))`. Decimal, `0x` and
  leading-`0` octal all work.
- Arithmetic is exact to ±(2^53−1) and errors past it, while `printf %d` carries
  full 64-bit. The two disagree at the top of the range; the error is loud.

### Bounded rather than unbounded

Every limit refuses with a message naming the limit; none of them truncates
silently.

| Limit | Value |
|---|---|
| Shell input | 1 MB per line |
| Shell output | 4 MB per line |
| Loop/step budget | 10 000 steps, yielding |
| Words from one expansion | 10 000 |
| Bytes from one expansion | 1 MB |
| Syntax and arithmetic nesting | 64 |
| Call, function and expansion depth | 32 |
| `printf` output | 1 MB |

---

## 5. Output cutting — the full ladder

Four independent caps, and none of them is a bare cut. Every one names what it
dropped and how to see it.

> The shape and size of these limits are deliberate: coding-agent benchmarks show
> that tool output and interface design can materially affect agent performance.
> See [Methodology](./Methodology.md#tool-interface-benchmark-evidence).


| Cap | Value | Where | On overflow |
|---|---|---|---|
| `MAX_CAT_LINES` | 1000 lines | `Terminal.lua:114` | `… TRUNCATED: 1000 of 3182 lines shown. Page the rest with `sed -n '1001,2000p' /Path`` — the exact next command, pre-computed |
| `MAX_RESULTS` | 100 hits | `Terminal.lua:108` | `… N more matches (narrow the path or the pattern)` — **the walk continues past the cap** so N is a real number, not a shrug |
| `MAX_LIST` | 100 rows | `Shell.lua:68` | `… N more from "Workspace" on (narrow it: `ls /A*`, or `ls \| grep <name>`)` — names the *first casualty*, so "Workspace is missing" is visible rather than "the boring tail" |
| `MAX_SEQ` | 1000 values | `Shell.lua:1023` | refuses outright |
| `MAX_TREE` | 1000 rows | `Terminal.lua:116` | `… N more entries (narrow it with `tree -L <depth>` or a subdirectory)`. Depth is unlimited by default, as GNU has it; this replaced a silent depth-2 cut that rendered populated directories as empty |

Then two more on the wire, in `agent/Agent.lua`:

| Cap | Value | Behaviour |
|---|---|---|
| `MODEL_RESULT_CHARS` | 100 000 | per tool_result. Head, not tail (shell output front-loads). `safeCut` backs up to the last newline if that keeps >50% of the budget, else steps off UTF-8 continuation bytes — a cut landing mid-codepoint makes `JSONEncode` reject the whole request. Marker: `... [N characters truncated] ...` plus the narrower commands to re-run with. |
| `MODEL_TURN_CHARS` | 200 000 | per *turn*, across all parallel tool_results in the one user message. Smallest-first fair share: results already under their share release the remainder, so one huge `tree` beside three small listings gets nearly the whole budget instead of a quarter. Only binds from the third large result onward. |

**Answer to "is it just a pure cut?"** — no. Every cap is announced, four of the
six carry the exact narrowing command, and `MAX_RESULTS`/`MAX_LIST` carry a
count that is *true* rather than "≥100". The console still shows the user
everything; only the copy going on the wire is cut.

The flaw this section used to end on — trailers riding on stdout, so a cap
warning was itself data — is closed: they are stderr, and a pipe does not carry
them.

---

## 6. Performance — 10k nested instances

### grep

Per script, in `Terminal:grep` → `Fs.getSource` → `Fs.grepLines` →
`Fs.matchSpans` → `Regex.Program:find`. Takes several roots now, deduped by
instance, and records the paths it actually read so `-L` does not re-walk.

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
- `matchSpans` takes a `first` flag and returns after the first span whenever
  `-o` is off. The waste it removed was proportional to how *much* a file
  matched, so it was worst on the searches that find something.
- The prefilter has a case-folded path, so `grep -i` is no longer the one search
  that runs the full backtracker over every line in the place.
- `instancePath` appends and reverses once — O(depth), not O(depth²).

**Remaining cost at 10k:** one `FindScriptDocument` engine call per script, per
grep. Marked `ponytail:` in `Fs.lua:63`. Stateless by design — a cached open-set
can drift, and stale text is the exact failure the branch exists to remove. The
upgrade path is named in the comment: `TextDocumentDidOpen`/`DidClose`
maintaining a set.

Rough shape: 10k scripts × ~200 lines is 2M line-matches. With a prefilter hit
that is 2M `string.find` calls — Luau will do that, but not instantly, and the
`FindScriptDocument` calls are likely the larger half.

### find

`Terminal:find` is a recursive `GetChildren()` walk (not `GetDescendants()`) so
`-maxdepth` stops early rather than building the whole list and filtering.
Breathes. The cap counts past itself deliberately.

- `-path`/`-ipath`/`-regex` call `instancePath(inst)` **per node** — O(n·depth)
  string building for the whole subtree, now that `instancePath` itself is
  linear in depth. `-name` does not (it reads `.Name`), so `-name` is still the
  cheap one, and `-tag` is cheaper again: one `HasTag`, no string.
- Tests are a flat OR of AND-groups evaluated per node with closure calls, and
  the group that matched is recorded so an action can ask which branch claimed
  the node. Fine.
- `-delete` orders by real depth, measured once per instance into a table, so a
  child is never left behind its destroyed parent.

### ls

- `ls -S` computes its rank once per row before the sort. `Fs.size` on a
  container is `#inst:GetDescendants()`, so inside the comparator it was walking
  10k parts O(n log n) times to order one listing — making the flag that exists
  to find the big thing the slowest command in the shell. (`ls -t` was always
  fine — `Fs.mtime` is a table lookup.)
- `ls -R /` re-resolves a path string per container; breathes, so it is slow
  rather than fatal.

### diff

`diff -r` recurses, and it sorts each directory's children by name before
comparing. `GetChildren` has no defined order, so without the sort the same two
trees compare differently between runs. It breathes once per directory.

### Memory

Slowness is not what runs Studio out of memory. ALLOCATION between two frames
is, and a huge place has the process near its ceiling before this plugin
allocates anything at all — so the number that matters is how much garbage a
command makes without yielding, not how long it takes.

`Fs.size` is the shared primitive, and on a container it is
`#inst:GetDescendants()`: the engine builds a table holding a pointer to every
instance in the subtree, to return one integer. At `/Workspace` in a big place
that is a several-hundred-thousand-entry table per call.

- **`ls -S` called it inside `table.sort`'s comparator** — fixed above, and it
  was the worst allocation site in the codebase for a second reason:
  `table.sort` is the one loop here that *cannot breathe*, so the collector got
  no scheduled step for the entire sort.
- **`du` did not breathe at all** — fixed. Every other recursive walk yields a
  frame once it has held the thread for one; du held it for the whole walk, and
  it is the walk with the largest per-node allocation.
- **`find -size`** calls it per node, inside a walk that does breathe. Left as
  is: the yield is what makes it survivable, and there is no cheaper way to ask
  the engine how big a subtree is.

Reads are the other half. `.Source` hands back a full copy of the script, and
`splitLines` used to concatenate a newline onto it — copying the whole file a
**second** time — before allocating one string per line. It is a plain
`find(source, "\n", pos, true)` scan now: same lines out, one copy less per file
read. `grep -r /` over 10k scripts still allocates every source once; that is
the read itself, and it breathes.

The shell runtime adds one allocation shape of its own: output is a list of
`{fd, text}` chunks rather than two accumulating strings. That is strictly less
copying than the `..=` it replaced — chunks are appended, never re-concatenated,
until the one join at the end — and it is bounded by the 4 MB output budget.

Not profiled in Studio. These are allocation counts read off the code, and they
say which commands are capable of it, not which one did it.

### Regex engine

Backtracking with continuations, `MAX_STEPS = 200000` per line. Marked
`ponytail:` — a legitimate but expensive pattern is refused rather than served
slowly; the upgrade path (Thompson NFA) is linear but cannot do backreferences,
which is why every real grep still ships a backtracker. Correct call.

### Glob matcher

`Words.matches` is dynamic programming over pattern × text, bounded at 1M steps.
Not a backtracker: `*a*a*a*a*` against a failing subject is linear-ish rather
than exponential, which matters because a glob is expanded per path segment per
candidate name and the pattern comes from the model.

---

## 7. Studio APIs not being used

Researched against the engine reference. Only the ones that would actually pay.

### Confirmed available, would pay

**`StudioService.ActiveScript`** — **DONE.** `Instance`, read-only. Returns the
script currently being edited. `Fs.activeScript()` reads it,
`Fs.openDocuments()` puts that document first and flags it, and
`editorContext()` renders it `[ACTIVE]`. Still a list, because the other open
files are real context and `nil` is a real answer whenever the viewport is in
front — but the entry that survives the 6-entry/600-char cap is now always the
one that matters.

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
`Fs.hasTag` per node, and `stat` lists an instance's tags sorted.

What is *not* taken is the indexed half: `GetTagged` is the only lookup in the
whole shell that could beat a walk (**O(matches)**, not O(10k)). Seeding
`Terminal:find` from it means rebuilding the depth bounds and the deterministic
tree ordering off an unordered list, and it only holds while `-tag` is the
entire expression — so it is marked `ponytail:` on `Fs.hasTag` rather than done.

**`Instance:GetAttributes()`** — **DONE.** The xattr analogue, on `stat`, sorted
and rendered through the same `Fs.formatValue` that `cat` uses for properties.
Omitted entirely when empty, along with the tag line.

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

The shell is not pretending. What it does not do is refused **by name, with the
working substitute in the error message**, which is a higher standard than bash
itself holds.

The language is now a language: parsed whole before it runs, expanded after it
is parsed, with two ordered streams and per-Terminal state. That single change
closed most of this document.

Then a 20-area conformance pass driven **through the tool itself, inside
Studio**, found what a CLI harness could not: a path was not a unique handle, so
`find` could match one instance and `rm` destroy another with the same name. That
is fixed at `Fs.resolve` rather than at the `-exec` boundary where it was first
seen, because plain `rm x` had it too. Two more criticals from the same pass —
a substitution's stderr aborting the line, and `$((++i))` silently not
incrementing — are fixed and pinned against real bash.

**Two divergences remain open**, and they share one cause:

- **§3.1** a handler returns one string plus a boolean, so a command with
  several operands must choose between reporting its data and reporting its
  status. `cat a missing` keeps the data and exits 0 with the error on stdout;
  `head a missing` keeps the status and drops the data. The same limit is why
  one command's two streams concatenate instead of interleaving. The upgrade
  path is handlers writing chunks; the runtime already models it.
- **§3.2** `wc -l` counts a final line with no newline. Deliberate — the
  editor's reading, and the one a model asking "how long is this file" wants.

The security property worth stating separately, because it is not a fidelity
question: **expansion output never re-enters the lexer.** An instance named
`a; rm -rf /` expands to one word and stays one word. The previous design
spliced substitutions into raw text before tokenizing and had to refuse output
containing shell punctuation to stay safe; that refusal is gone because the
thing it defended against is now structurally impossible.

Performance: every cheap win is taken — first-span-only matching, a case-folded
prefilter for `grep -i`, precomputed sort keys for `ls -S` and `find -delete`,
a linear `instancePath`, a non-backtracking glob matcher. What remains is the
one already marked `ponytail:` in the source: `FindScriptDocument` runs once per
script per grep, by design.

Memory is tracked separately, in §6, because it is a different question: not how
long a command takes but how much it allocates without yielding, which is what
ends a session in a huge place. The two sites that could not yield are closed,
and reads cost one whole-file copy less apiece. `Fs.size` on a container is
still `#GetDescendants()`, which is the ceiling rather than a bug.

### Verification

None of this was checked by reading alone. `tests/run.mjs` loads the **real**
Luau modules under a small Roblox shim (`tests/RobloxShim.lua`) and runs them
against **actual bash** as the oracle:

```
node tests/run.mjs <path-to-luau> <path-to-bash>
```

| What | How | Count |
|---|---|---|
| `printf` | every vector passed as argv to a real Bash `printf` builtin, compared byte for byte including NUL, and on success/failure | 56 |
| Shell language | every case run through `bash --noprofile --norc`, comparing stdout **and** numeric exit status: quoting, expansion, arithmetic, `if`/`case`/loops, functions, `local`, forks, `read`/`IFS`, stream ordering under `2>&1` | 55 |
| Copy semantics | editor-buffer carry and rollback on a failed `cp` | `tests/CopyBuffers.lua` |
| DataModel behaviour | everything with no bash equivalent — `cp`/`mv`/`rm` on Instances, `cd`/`PWD`/`OLDPWD`, `find -delete` and `-o` scoping, `diff -r`, the `.luau` parse-check rule, stderr interleaving through real handlers | `fs/ShellTests.lua`, run inside `Shell.selfTest` |
| Everything else | `Shell.selfTest`, `Regex.selfTest`, `Props.selfTest` | in full |

The bash oracle is the part that matters: a vector is not "what we think bash
does", it is what bash on this machine actually did, captured at test time. A
divergence introduced by a future change fails the run rather than becoming the
new expected value.

Studio's startup self-tests are still the real gate; this is what catches things
before they get there.
