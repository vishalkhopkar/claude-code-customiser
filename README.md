# claude-code-customiser

A scheduled Windows job that refreshes the Claude Code spinner text. Every few hours it runs a headless Claude Code session with a prompt, takes the list of strings that comes back, and installs them as the global `spinnerVerbs` in `~/.claude/settings.json`.

The bundled prompt generates lesser-known historical facts about India, so the spinner shows a new fact while Claude works. Swap `prompt.txt` for any prompt that returns a list of strings.

## Requirements

- Windows with Windows PowerShell 5.1 or later
- [Claude Code](https://claude.com/claude-code) installed, on `PATH`, and logged in

## Setup

```powershell
git clone https://github.com/vishalkhopkar/claude-code-customiser.git
cd claude-code-customiser
.\register-task.ps1
```

`register-task.ps1` creates a Task Scheduler task (`ClaudeSpinnerVerbs` by default). The first run fires a minute after registration, then every `INTERVAL_HOURS`. The task runs as the current user while logged in; if the machine is off at the scheduled time, it runs at the next opportunity.

| Command | What it does |
|---|---|
| `.\register-task.ps1` | Register the task, or re-register it after changing `INTERVAL_HOURS` or `TASK_NAME` |
| `.\register-task.ps1 -StartAt '03:00'` | Register with a specific first-run time |
| `.\register-task.ps1 -Unregister` | Remove the task |
| `.\update-spinner-verbs.ps1` | Run the job once, right now |
| `.\update-spinner-verbs.ps1 -ReapplyLast` | Reinstall the latest batch from `strings.csv` without calling Claude |

## Configuration

All settings live in `config.json`.

| Key | Default | Meaning |
|---|---|---|
| `INTERVAL_HOURS` | `24` | Hours between scheduled runs |
| `NO_OF_STRINGS` | `20` | Number of strings each run must produce |
| `MAX_RETRIES` | `3` | Retries after a failed attempt |
| `RETRY_DELAY_SECONDS` | `60` | Wait between attempts |
| `HISTORY_MAX_STRINGS` | `500` | How many of the most recent past strings to show the model as a "do not repeat" list; `0` disables it |
| `CLAUDE_TIMEOUT_SECONDS` | `600` | Time limit for one headless Claude call |
| `MODEL` | `claude-opus-5-5` | Model for the headless run; empty uses your Claude Code default |
| `EFFORT` | `high` | Effort level for the headless run; empty uses your default |
| `PROMPT_FILE` | `prompt.txt` | Prompt to send |
| `SETTINGS_PATH` | `%USERPROFILE%\.claude\settings.json` | Settings file to update |
| `IDE_SETTINGS_PATHS` | VS Code's user `settings.json` | IDE settings files to update as well (see below); `[]` turns this off |
| `DATA_DIR` | `.` | Folder for `log.csv`, `strings.csv` and `run.log` |
| `TASK_NAME` | `ClaudeSpinnerVerbs` | Name of the scheduled task |

Relative paths are resolved against the folder containing `config.json`.

## The prompt

`prompt.txt` is sent as-is, with every `{NO_OF_STRINGS}` replaced by the configured count. The prompt must tell Claude to reply with only a JSON array of that many strings. A plain list with one string per line is also accepted as a fallback.

Each run is a fresh session with no memory, so the same prompt tends to produce the same strings day after day. To prevent that, put `{PREVIOUS_STRINGS}` in the prompt: it is replaced with a bulleted list of the most recent `HISTORY_MAX_STRINGS` strings from `strings.csv` (or `(none yet)` on the first run). Strings older than that window can come back. A prompt without the placeholder gets no history.

## VS Code and other IDEs

The Claude Code VS Code extension does not read `spinnerVerbs` from `~/.claude/settings.json`. It has its own VS Code setting, `claudeCode.spinnerVerbs`, with the same `mode` and `verbs` shape. The job therefore writes the strings to every file in `IDE_SETTINGS_PATHS` as well, and open chat panels pick up the change without a restart.

- The default covers VS Code. Add the user `settings.json` of other VS Code-based editors that run the extension (for example `%APPDATA%\\Cursor\\User\\settings.json`) to cover them too.
- A path whose folder does not exist is skipped.
- A settings file containing comments or trailing commas cannot be parsed by PowerShell 5.1. It is left untouched and a warning goes to `run.log`.
- A failed IDE update does not fail the run.
- The previous file is kept next to it as `settings.json.bak`.

Run `.\update-spinner-verbs.ps1 -ReapplyLast` after adding a path to apply the current strings straight away.

## How a run works

1. Run `claude -p` headlessly with the prompt, with all tools and MCP servers disabled.
2. Parse the reply into a list of strings.
3. Check that there are exactly `NO_OF_STRINGS` non-empty strings.
4. Write them to `settings.json` as `spinnerVerbs` in `replace` mode. Other settings are left untouched and the previous file is kept as `settings.json.bak`.
5. Write them to each IDE settings file as `claudeCode.spinnerVerbs`.
6. Append the strings to `strings.csv` and a `true` row to `log.csv`.

If any step fails, the attempt is logged as `false` and retried after `RETRY_DELAY_SECONDS`, up to `MAX_RETRIES` times. The script exits with code 1 if every attempt fails.

## Audit files

These are generated in `DATA_DIR` on every run and are not committed.

**`log.csv`** has one row per attempt, including failed ones.

| Column | Meaning |
|---|---|
| `Run_no` | Auto-incrementing attempt number |
| `Run_datetime` | When the attempt started (`yyyy-MM-dd HH:mm:ss`) |
| `Status` | `true` if the strings were pulled and installed, else `false` |

**`strings.csv`** has one row per string from each successful attempt; `Run_no` and `String_no` together are unique.

| Column | Meaning |
|---|---|
| `Run_no` | Matches `log.csv` |
| `String_no` | `1` to `NO_OF_STRINGS` |
| `String_text` | The string itself |

**`run.log`** is a plain-text log with the reason for each failure.

## Reverting

Remove the task with `.\register-task.ps1 -Unregister`, then delete the `spinnerVerbs` key from `~/.claude/settings.json` and the `claudeCode.spinnerVerbs` key from VS Code's settings (or restore the `settings.json.bak` files) to get the default spinner back.
