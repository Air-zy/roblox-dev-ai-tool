# Roblox Code Agent

A coding agent inside Roblox Studio. It gives supported models a terminal over
the live DataModel.

## Why I made this

- power of a VS Code agent + Rojo without the Rojo setup.
- whole thing to live in a Studio plugin, without an external editor or bridge.
- don't want to boil the oceans for nothing, so the toolset has to use as few tokens as possible.

## Methodology

Unlike bridge-heavy workflows, this plugin treats the live DataModel as the
coding environment: `/Workspace` is Workspace, and writes support Studio undo.

One plugin holds the agent and seven tools. [SWE-agent](https://arxiv.org/abs/2405.15793)
scored 18.0% with focused 100-line views versus 12.7% with whole files, supporting
a small, composable interface.

### Why Bash

One Bash tool replaces a custom tool for every operation. Models already know
Linux shell commands, keeping the schema small and complex workflows composable.

## The blunt comparison

| Workflow | Pros | Cons |
| --- | --- | --- |
| **This project** | One plugin, the live DataModel, and direct Claude/ChatGPT subscription login: plan limits, no API-token or wrapper bill. | It cannot see the viewport or simulate a player. Correct code can still produce a bad experience. |
| [**VS Code agent + Rojo**](https://rojo.space/docs/v7/) | Real Git, LSPs, packages, tests, and CI. | Studio caught up. Some developers now say [start without Rojo](https://www.reddit.com/r/robloxgamedev/comments/1ut6q8l/completely_new_to_roblox_game_dev/); existing places and Studio-built models reveal the painful [file-first bargain](https://www.reddit.com/r/robloxgamedev/comments/1uvxlj0/rojo_with_roblox_studio/). |
| [**Roblox Studio MCP**](https://github.com/Roblox/creator-docs/blob/main/content/en-us/studio/mcp.md) | The most power: screenshots, input, playtests, and assets. | When "done" is wrong, you debug the model, MCP, and Studio at once. Users cannot tell [what ran or changed](https://www.reddit.com/r/robloxgamedev/comments/1t4a7bf/im_building_an_ai_toolkit_to_make_it_easier_to/), and tool-heavy sessions [torch model quota](https://www.reddit.com/r/claude/comments/1ux4xi7/roblox_studio_with_claude_mcp/). |
| [**Forge**](https://forgeblox.app/) | A polished build, test, fix, and screenshot loop. | It sells prepaid credits; even BYOK pays a flat per-message fee. |
| [**ForgeGUI**](https://forgegui.com/) | One beginner-friendly suite for code, UI, and assets, with a [Studio connector](https://create.roblox.com/store/asset/73739069039344/ForgeGUI-Connect). | The "free" pitch becomes a credit treadmill: [users report](https://www.reddit.com/r/robloxgamedev/comments/1uudx77/everyone_do_not_use_forgegui_its_a_scam/) generic output burning the balance before they can iterate. |

[BloxForge](https://github.com/princeofscale/bloxforge) and
[Roickbot](https://github.com/TonyD365/Roickbot) bridge Studio to an outside
agent; [BloxBot](https://github.com/paralov/app-bloxbot-ai) bundles that agent
into a desktop app. Their billing follows the external client or provider. This
project puts the Claude/ChatGPT subscription-backed agent inside Studio itself.

## Install

Get the ready-to-install plugin from [Releases](https://github.com/Air-zy/robloxStudioAIHarness/releases/latest),
or build it from source with [Rojo 7.5 or newer](https://rojo.space/docs/v7/getting-started/installation/):

```sh
rojo build default.project.json --output ClaudeCodeForRoblox.rbxmx
```

Move the `.rbxmx` to **Plugins > Plugins Folder**, restart Studio, and enable
**Allow HTTP Requests**. Open it and run `/login`; `/provider` switches providers
and `/help` lists commands.

## Documentation

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed behavior and internals.

## License

Copyright 2026 Airzy. Licensed under the [MIT License](LICENSE). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled components.
