i took some time to find some parsers....
I MIGHT BE WRONG ABOUT THESE CHOICES

**LuauParser (vantoanvh)** — the only one that parses modern Luau syntax, but single-maintainer, AI-assisted port, no tests, low adoption
**luaup (jackdotink)** — real code, but stale and undocumented
**Write your own** — a recursive descent parser for the subset of Luau syntax you actually care about checking

**I was wrong about luaup.** It's effectively abandoned (25 of 27 commits are from one day in March 2025; zero commits in 17 months), and there's an **OPEN unresolved bug** (issue #7 by user `wally2471`) showing the lossless parser produces *wrong output on `...` varargs* — a basic Luau feature. The same author moved on to `poke` (last commit Feb 2026, but no README, no Wally package, CLI-style `require("./X")` that needs manual porting for Studio).

**Honest verdict: there is exactly one library that genuinely fits your constraints** (lightweight, pure Luau, drop-in for a Roblox plugin, works with current Luau, actively maintained):

### ⭐ `boatbomber/Highlighter`
- Wally: `Highlighter = "boatbomber/highlighter@0.11.1"`
- Uses Studio-style `require(script.types)` (verified in source) — zero porting
- Last commit 2026-07-29; 35 commits; 9 contributors; 97 stars
- 11 real bug reports from real users (proves it's used)
- 1,080-line pure-Luau lexer, handles interpolated strings + type operators + buffer

**BUT it's a *lexer*, not a parser.** Catches unfinished strings, bad numbers, bad comments. **Cannot** catch missing `end` — that needs structural tracking. My recommendation: use Highlighter for live tokenization, then roll a ~100-line token-stack validator on top of its token stream (track `function/if/for/while/do/repeat/(`/`[`/`{` openings, pop on closers, report unclosed at EOF). Covers ~80% of "forgot an `end`" errors.

**For full type checking inside a plugin: no pure-Luau solution exists.** Either shell out to `luau-analyze` (not lightweight) or skip it.