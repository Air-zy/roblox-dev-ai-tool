# Roblox Code Agent

A coding agent inside Roblox Studio, with a terminal over the live DataModel.

## Why

- VS Code agent workflow, directly on the live place.
- One plugin. No bridge, CLI wrapper, or second meter.
- Stop boiling the oceans for a script edit.

## How

`/Workspace` is Workspace. `grep`, `find`, `sed`, `awk`, pipes, and redirects
work over scripts and objects. Inspect live properties, tags, and attributes
from the same shell.

[SWE-agent's ablation](https://arxiv.org/abs/2405.15793) scored 18.0% with focused
100-line views versus 12.7% with whole files. Small, composable tools win.

## Comparison

| Workflow | Pros | Cons |
| --- | --- | --- |
| **This project** | One plugin, live DataModel, Claude/ChatGPT subscription login, GitHub script/text versioning. | Provider limits still apply. No viewport capture or automated playtests: looks right can still play badly. |
| [**VS Code agent + Rojo**](https://rojo.space/docs/v7/) | Full Git, LSPs, packages, tests, CI. | Studio-built models invite the [export/delete/resync dance](https://www.reddit.com/r/robloxgamedev/comments/1uvxlj0/rojo_with_roblox_studio/). [One dev's advice: start without it](https://www.reddit.com/r/robloxgamedev/comments/1ut6q8l/completely_new_to_roblox_game_dev/). |
| [**Studio MCP / bridges**](https://github.com/Roblox/creator-docs/blob/main/content/en-us/studio/mcp.md) | Screenshots, input, playtests, assets. | More moving parts; users report [black-box headaches](https://www.reddit.com/r/robloxgamedev/comments/1t4a7bf/im_building_an_ai_toolkit_to_make_it_easier_to/) and [quota burn](https://www.reddit.com/r/claude/comments/1ux4xi7/roblox_studio_with_claude_mcp/). |
| [**Forge**](https://forgeblox.app/) | Build, test, fix, screenshot loop. | Prepaid credits. [Bring your own key, still pay the cover charge](https://forgeblox.app/changelog). |
| [**ForgeGUI**](https://forgegui.com/) | UI/assets with a [Studio connector](https://create.roblox.com/store/asset/73739069039344/ForgeGUI-Connect). | Credits buy attempts. [One user's verdict: AI slop](https://www.reddit.com/r/robloxgamedev/comments/1uudx77/everyone_do_not_use_forgegui_its_a_scam/). |
| [**Ropilot**](https://ropilot.ai/use-claude-in-roblox) | Uses your Claude/ChatGPT plan. | Your subscription gets [a second meter: 500 free Studio actions/month, then paid plans](https://ropilot.ai/pricing). |

Checked October 2, 2026. Reddit links are user reports.

[BloxForge](https://github.com/princeofscale/bloxforge) and
[Roickbot](https://github.com/TonyD365/Roickbot) bridge to outside agents;
[BloxBot](https://github.com/paralov/app-bloxbot-ai) is a desktop app.

## Install

Download the plugin from [Releases](https://github.com/Air-zy/robloxStudioAIHarness/releases/latest),
or build with [Rojo 7.5+](https://rojo.space/docs/v7/getting-started/installation/):

```sh
rojo build default.project.json --output RobloxCodeAgent.rbxmx
```

Move the `.rbxmx` to **Plugins > Plugins Folder**, restart Studio, and enable
**Allow HTTP Requests**. `/provider` picks a provider, `/login` connects,
`/help` lists commands. Enable Luau probes in `/settings`.

## Documentation

See [ARCHITECTURE.md](ARCHITECTURE.md) for commands, tools, and internals.

## License

Copyright 2026 Airzy. Licensed under the [MIT License](LICENSE). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled components.
