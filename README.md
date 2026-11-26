# Agent Usage Bar

A small macOS menu bar app that shows how much of your AI coding agent usage
limits you have used (session and weekly windows), so you are not surprised by a
rate limit.

![Menu bar](docs/menubar.png)

![screenshot](docs/screenshot.png)

> **Unofficial.** It uses undocumented endpoints (`api.anthropic.com/api/oauth/usage`,
> Google `cloudcode-pa` `v1internal`, and the `/quota` output of `agy`) that may
> break whenever those CLIs update. Not affiliated with Anthropic or Google.

## Requirements
- macOS 14 or later (Apple silicon)
- Xcode Command Line Tools / Swift 6 (`xcode-select --install`)
- Python 3 (the collectors use only the standard library)

## Build and install
    ./build.sh
    open ~/Applications/AgentUsageBar.app

The app is ad-hoc signed and built locally, so Gatekeeper does not quarantine it.
Set `INSTALL_DIR` to install somewhere other than `~/Applications`.

## Updating
The app checks github.com once a day (and when it starts) for a newer release, and
only tells you: the popover shows "Update available: vX.Y.Z", a "What's new" link and
an **Update** button. You can turn the daily check off with "Check for updates" in
the popover. Nothing is installed without your confirmation. The confirmation names
the version and the short commit of its tag. Pressing Update then downloads that
release's source into `~/Library/Application Support/AgentUsageBar/src`, **runs its
build script (`build.sh`) with your permissions on your Mac**, runs the new build's
`--version` and `--selftest`, and only then restarts into it. If any step fails, the
current app is left alone and the popover shows the error and the log
(`~/Library/Logs/AgentUsageBar/update.log`).

- **Requirements:** git and the Xcode Command Line Tools (`xcode-select --install`).
  Without them the popover only links to the release.
- **Trust:** the update runs code from the repository, exactly as running
  `./build.sh` yourself would. Only update if you trust the repo you built from
  (forks update from their own repo). The download uses https only and ignores your
  own git configuration (rewrites, hooks, credential helpers). Checking signed tags
  is a possible future hardening; it is not done today.
- **Roll back:** the version you replaced is kept at
  `~/Library/Application Support/AgentUsageBar/previous/AgentUsageBar.app` (not in
  your Applications folder). Quit the app, move that copy to where the app was
  (replacing the new one) and open it. The backup copy cannot update itself; it
  says so. If the new app does not start, the update puts the backup back by itself.
- **Turn checks off:** switch off "Check for updates" in the popover. The "Check now"
  button still works when you press it.
- **By hand:** `git pull && ./build.sh` still works, then quit and reopen the app.

See [CHANGELOG.md](CHANGELOG.md) for what changed. `AgentUsageBar --version` prints
the installed version.

## Supported agents
- **Claude Code**: reads its sign-in from the login Keychain item
  `Claude Code-credentials`, or `~/.claude/.credentials.json`. The token is used
  for one request and never printed or stored.
- **Antigravity CLI** (`agy`).

On first run macOS asks whether `security` may access the Keychain item. Choose
**Always Allow** so it does not ask on every refresh.

The menu bar label shows only the agents this Mac has set up (ready), side by side:
its logo and the percentage of its 5-hour session limit used (for example
`[claude] 7%  [agy] 18%`; a Claude-only Mac shows just `[claude] 7%`). If none is ready
it shows one neutral logo with `–`. The popover tabs follow the same rule, and with
nothing ready it shows the sign-in instructions. A number turns red at 90%. Click anywhere on the
label for the full popover with weekly windows and details. The app refreshes every 15 minutes
(3 minutes when any limit is at 90% or more) and turns red at 90%.
"Launch at login" is on by default; toggle it in the popover.

## Icons
Claude and Antigravity logos ship as defaults (see Trademarks below). Lookup order:

1. `~/.config/agent-usage-bar/icons/<id>-template.svg` (your override)
2. the bundled `<id>-template.svg`
3. an SF Symbol fallback

`<id>` is `claude` or `agy` (the file name of the usage JSON). All are loaded as
template images, so they follow the menu bar colours. Restart the app after adding an override.

## Trademarks
Claude and the Claude logo are trademarks of Anthropic, PBC. Antigravity and its logo are trademarks of Google LLC. They are used only to identify the services this app reads usage from. This project is not affiliated with or endorsed by either company, and the logo files are not covered by the MIT licence.

## Settings (environment variables)
- `AGENT_USAGE_DIR`: where usage JSON files are written and read. Default:
  `~/.local/state/agent-usage-bar/usage`. Set it to
  `~/.local/state/omarchy/agents/usage` for Omarchy-schema compatibility.
- `XDG_STATE_HOME`, `XDG_CACHE_HOME`: change the default state/cache locations.
- Extra collectors: executable files named `agent-usage-<id>` in
  `~/.config/agent-usage-bar/collectors/` are run too; they should write `<id>.json`.

## Demo mode
Try it with synthetic data and no sign-in:

    ~/Applications/AgentUsageBar.app/Contents/MacOS/AgentUsageBar --demo

or `AGENT_USAGE_DIR=$PWD/docs/demo` (any folder named `demo` never runs collectors).

## Checks
    swift build --package-path App && App/.build/debug/AgentUsageBar --selftest
    collectors/agent-usage-claude --print
    collectors/agent-usage-agy --print

## Uninstall
Turn off "Launch at login" in the popover first, then:

    osascript -e 'quit app "AgentUsageBar"'
    rm -rf ~/Applications/AgentUsageBar.app
    rm -rf ~/.cache/agent-usage-bar ~/.local/state/agent-usage-bar ~/.config/agent-usage-bar

## Versioning
The `VERSION` file is the single source of truth: line 1 is the version, line 2
the build number. `build.sh` writes both into the app's Info.plist and generates
`App/Sources/AgentUsageBar/Version.swift` (used by `--version`). Bump `VERSION`,
add a CHANGELOG entry, then build.

## License
MIT, see [LICENSE](LICENSE). See [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).
