# Roblox Code Agent

A coding agent inside Roblox Studio, with a terminal over the live DataModel.

## Why

- power of a VS Code agent + Rojo without the Rojo setup.
- whole thing to live in a Studio plugin, without an external editor or bridge.
- don't want to boil the oceans for nothing, so the toolset has to use as few tokens as possible.

## How

The agent reads and edits the live DataModel through a Bash-style shell:
`/Workspace` is Workspace. Search, pipes, and redirects work over scripts and
objects. Writes support Studio undo.

Edits report syntax errors. Reads and runs include unsaved editor changes.

One plugin holds the agent and a small toolset. [SWE-agent](https://arxiv.org/abs/2405.15793)
scored 18.0% with focused 100-line views versus 12.7% with whole files. Small,
composable tools win.

## Comparison

| Workflow | Pros | Cons |
| --- | --- | --- |
| **This project** | One plugin, the live DataModel, and direct Claude/ChatGPT subscription login: plan limits, no API-token or wrapper bill. | It cannot capture the viewport or simulate a player, so correct code that plays badly gets past it. |
| [**VS Code agent + Rojo**](https://rojo.space/docs/v7/) | Real Git, LSPs, packages, tests, and CI. | Studio caught up: r/robloxgamedev now tells beginners to [start without Rojo](https://www.reddit.com/r/robloxgamedev/comments/1ut6q8l/completely_new_to_roblox_game_dev/), and [file-first sync chokes](https://www.reddit.com/r/robloxgamedev/comments/1uvxlj0/rojo_with_roblox_studio/) on existing places and Studio-built models. |
| [**Roblox Studio MCP**](https://github.com/Roblox/creator-docs/blob/main/content/en-us/studio/mcp.md) | The most power: screenshots, input, playtests, and assets. | When "done" is wrong, you debug the model, MCP, and Studio at once. Users cannot tell [what ran or changed](https://www.reddit.com/r/robloxgamedev/comments/1t4a7bf/im_building_an_ai_toolkit_to_make_it_easier_to/), and tool-heavy sessions [torch model quota](https://www.reddit.com/r/claude/comments/1ux4xi7/roblox_studio_with_claude_mcp/). |
| [**Forge**](https://forgeblox.app/) | A polished build, test, fix, and screenshot loop. | It sells prepaid credits; [even BYOK pays a flat per-message fee](https://forgeblox.app/changelog). |
| [**ForgeGUI**](https://forgegui.com/) | One beginner-friendly suite for code, UI, and assets, with a [Studio connector](https://create.roblox.com/store/asset/73739069039344/ForgeGUI-Connect). | The "free" pitch becomes a credit treadmill: [users report](https://www.reddit.com/r/robloxgamedev/comments/1uudx77/everyone_do_not_use_forgegui_its_a_scam/) generic output burning the balance before they can iterate. |

### Capabilities

| Capability | This project | VS Code + Rojo | Studio MCP | Forge | ForgeGUI |
| --- | --- | --- | --- | --- | --- |
| In Game Live Building/Modeling | Yes | With MCP | Yes | Yes | With MCP |
| Run Luau | Yes | With MCP | Yes | Yes | With MCP |
| Automated playtests and viewport capture | No built-in tools | With MCP | Yes | Yes | [External MCP client](https://forgegui.com/forge-mcp) |

Checked September 30, 2026.

[BloxForge](https://github.com/princeofscale/bloxforge) and
[Roickbot](https://github.com/TonyD365/Roickbot) bridge Studio to an outside
agent; [BloxBot](https://github.com/paralov/app-bloxbot-ai) is a desktop app.

## Install

Download the plugin from [Releases](https://github.com/Air-zy/robloxStudioAIHarness/releases/latest),
or build with [Rojo 7.5+](https://rojo.space/docs/v7/getting-started/installation/):

```sh
rojo build default.project.json --output RobloxCodeAgent.rbxmx
```

Move the `.rbxmx` to **Plugins > Plugins Folder**, restart Studio, and enable
**Allow HTTP Requests**. Open it and run `/login`; `/provider` switches providers
and `/help` lists commands.

Use **+** or `/attach` to add images and text files to your next message.

## Documentation

See [ARCHITECTURE.md](ARCHITECTURE.md) for commands, tools, and internals.

## License

Copyright 2026 Airzy. Licensed under the [MIT License](LICENSE). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled components.
