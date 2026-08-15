we are working with roblox... so language is luau

never make unnecessary changes.

for this harness.. THE AGENT SHOULD NOT NEED TO KNOW that its working on roblox.. for good quality or tool use... but it can...
this harness should be general/good like that yk? to not confuse the agent with unnecessary clobbering of its context window and rules...
anything that goes against this should be adressed.

REFER TO https://create.roblox.com/docs/llms.txt for complex roblox stuff

### for GUIs
- for roblox font text icons refer to https://github.com/VoxLenox/RobloxBuilderIconList/blob/main/index.html
- refer to roblox docs when dealing with complex UI classes

### references
- Claude Code's own source, leaked with the v2.1.88 sourcemap — read it before
  copying or claiming its behaviour: https://github.com/davccavalcante/claude-code-leaked
  (loop in `src/query.ts`, pacing in `src/query/tokenBudget.ts`). `curl` the raw
  files.
- Fine-grained tool streaming, incl. tool JSON truncated by `max_tokens`:
  https://docs.claude.com/en/docs/agents-and-tools/tool-use/fine-grained-tool-streaming
  NOT a beta any more — the `fine-grained-tool-streaming-2025-05-14` header does
  nothing and has been removed. The switch is `eager_input_streaming` on the
  tool definition and it IS set, on every tool, in `agent/Tools.lua`. On Roblox
  it is load-bearing, not a latency tweak: buffered parameters send nothing
  while a long `write` generates, and WebStreamClient closes a stream that goes
  quiet with `HttpError: InactivityTimeout`.
- Messages API: https://platform.claude.com/docs/en/api/messages