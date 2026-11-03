---
name: dabble
description: Read and manage the user's Dabble to-dos (a Things 3-style task manager for Mac, iPhone and iPad) - Today, Inbox, Upcoming, Anytime, Someday, Logbook, projects, areas, headings, tags, checklists, deadlines, reminders and repeating to-dos. Use whenever the user asks what's on their plate, wants to plan their day or week, or asks to add, schedule, complete, move, tag, reorganize or clean up tasks in Dabble. Uses the `dabble` MCP tools when they're available, otherwise the `dabble` command-line tool.
license: MIT
---

# Dabble

Dabble is the user's to-do app. It works like Things 3. Everything an agent can do goes through the same set of tools: the **`dabble` MCP server** (tools like `list_items` and `add_todo`) or the **`dabble` CLI** (`dabble list today --json`). Prefer the MCP tools when they're available. Otherwise run the CLI with `--json`.

The agent's copy of Dabble is a device in the user's sync group. Changes reach their Mac, iPhone and iPad within seconds when one of them is on the same network (or through their sync server).

## First: check the connection

Call `sync_status` (CLI: `dabble status`). If `joined` is false, the agent isn't connected to the user's to-dos yet. Stop and tell the user to do **one** of these:

- In Dabble on the Mac, open **Settings → Agents** and run the setup command shown there. It runs `dabble join <sync key>`.
- Or run `dabble pair` in a terminal and compare the code with the device showing **Settings → Sync → Pair New Device**.

Don't add to-dos while not joined. They'd only exist on this computer.

## How Dabble organizes things

| Concept | Meaning |
|---|---|
| **Inbox** | Unsorted capture. New to-dos land here unless you say otherwise. |
| **Today** | What the user plans to do today, including anything scheduled for an earlier day and anything due. It has a **This Evening** section. |
| **Upcoming** | Items scheduled for a future day, grouped by day. |
| **Anytime** | Everything actionable now that isn't scheduled for later, grouped by area and project. |
| **Someday** | Parked ideas and maybes. |
| **Logbook** | Completed and canceled items. **Trash** holds deleted items until it's emptied. |
| **Area** | An ongoing responsibility (Work, Home, Health) that holds projects and to-dos. |
| **Project** | A goal with several to-dos. It can have **headings** that split it into sections. |
| **Checklist** | Small steps inside one to-do. |
| **Tags** | Can be nested. To-dos inherit tags from their project and area. |

Getting dates right matters most:

- **`when`** is the day the user plans to *start* or do it: `today`, `this evening`, `tomorrow`, `fri`, `next week`, `in 3 days`, `2026-12-01`, `anytime` (no date), `someday` or `inbox`. A future date puts the item in Upcoming. On that day it moves to Today.
- **`deadline`** is when it's *due*. It shows a countdown and pulls the item into Today when the date arrives. Don't use a deadline as a scheduling date unless the user said "due" or "by".
- **`reminder`** is a notification time (`09:30`, `5pm`) on the item's `when` day.
- **`repeat`** takes `daily`, `weekly`, `every 2 weeks`, `every monday and thursday`, `monthly`, `yearly`, optionally with `after completion`. Completing a repeating to-do creates the next one automatically.

## Tools

| MCP tool | CLI | What it does |
|---|---|---|
| `overview` | `dabble overview` | Counts, areas, projects and tags, with ids. Start here. |
| `list_items` | `dabble list today` | A list (inbox, today, upcoming, anytime, someday, logbook, trash) or a project, area or tag by name or id. Add `tag` to filter. |
| `search` | `dabble search "milk"` | Find anything by words in its title, notes or checklist. |
| `get_item` | `dabble show <id>` | Full details: notes, checklist, a project's sections. |
| `add_todo` | `dabble add "Title" --list X --when tomorrow --deadline fri --tags a,b --checklist "x\ny"` | Add a to-do. |
| `add_project` / `add_area` / `add_heading` / `add_tag` | `dabble add-project "Trip" --area Personal --todos "a\nb"` | Create structure. |
| `update_item` | `dabble update <id> --title … --when … --deadline null --move-to Project` | Change any field. `null` clears deadline, reminder and repeat. |
| `set_status` | `dabble complete <id>` · `dabble cancel <id>` · `dabble reopen <id>` | Complete, cancel or reopen to-dos and projects. |
| `schedule` | `dabble schedule <id>,<id> --when today` | Set `when` for several items at once. |
| `move` | `dabble move <id> --to "Project" --heading "Section"` | Move into a project, area or the inbox, or out of one (`none`). |
| `edit_checklist` | `dabble edit-checklist <todo-id> --add "Step" --check <item-id>` | Add, check, uncheck, rename or remove checklist items. |
| `reorder`, `duplicate`, `convert_to_project` | same names | Ordering and restructuring. |
| `trash` / `restore` | `dabble trash <id>` | Recoverable delete. |
| `delete_permanently` / `empty_trash` | same names | **Irreversible, on every device.** Ask first. |
| `open_url` | `dabble open-url "dabble:///add?title=…"` | Run a `dabble:///` URL. |
| `sync_status` / `sync_now` | `dabble status` / `dabble sync` | Connection state, and reconnect. |

CLI notes:

- Every tool is also `dabble <tool_name>` with `--param value` flags. The first bare argument fills the main parameter, usually the title or id.
- `dabble call <tool> '<json>'` passes exact JSON arguments.
- Lists can be comma-separated (`--tags a,b`). Multi-line values like checklists use `\n`.
- Use `--json` for machine-readable output.
- Ids can be shortened to their first 8 characters when that's unambiguous. `dabble tools` lists every tool and parameter.

## Working well

- **Look before you change.** Get ids from `overview`, `list_items` or `search`. Never invent ids.
- **Do what was asked and no more.** Don't reschedule, retag or tidy things the user didn't mention.
- **Batch.** `schedule`, `move`, `set_status`, `trash` and `duplicate` all take several ids.
- **Destructive actions:** use `trash` (recoverable) rather than `delete_permanently`. Only call `delete_permanently` or `empty_trash` after the user confirms, because they delete from every device.
- **Report back briefly.** Say what changed, using titles rather than ids.

### Recipes

- **"What's on my plate today?"** Call `list_items` with `today`. Mention anything with a deadline today or overdue first, then the rest, then This Evening.
- **Plan my day.** Read `today`, then `anytime` (or a specific area). Suggest a short list, and after the user agrees, `schedule` the chosen ids with `when: today` (or `this evening`).
- **Inbox zero.** Read `inbox`. For each item, propose a project or area (`move`) and a `when`, then apply in batches after the user agrees.
- **Weekly review.** `upcoming` for the next 7 days, `anytime` for stale items, `someday` for things to revive, and the projects in `overview` with no open to-dos, which may be finished or stuck.
- **Capture from notes or email.** One `add_todo` per action item. Put details in `notes`, and only set `deadline` when a due date was stated. Group related items with `add_project` and its `todos`.
