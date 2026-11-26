# Changelog

All notable changes to Agent Usage Bar are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.0] - 2026-11-26

### Added
- The app can now update itself. It checks GitHub for a newer release when it
  starts and then once a day (turn this off with the "Check for updates" switch
  in the popover). When a newer version exists, the popover shows "Update
  available", a "What's new" link and an Update button. Nothing is installed
  silently: pressing Update asks you to confirm, then the app downloads the
  source for that release, builds it on your Mac, checks the new build, and
  restarts into it. Your previous version is kept as `AgentUsageBar.previous.app`
  next to the app. If anything fails, the current version stays untouched and the
  popover shows what went wrong and where the log is. In-app updating needs git
  and the Xcode Command Line Tools (`xcode-select --install`); without them the
  app only tells you a new version exists and links to it.

## [0.2.2] - 2026-11-26

### Changed
- The menu bar and the popover tabs now show only the subscriptions this Mac
  actually has. A Claude-only Mac shows just the Claude logo and percentage, with
  no tabs. If none is signed in yet, the bar shows one neutral logo with a dash
  and the popover lists the sign-in instructions.

## [0.2.1] - 2026-11-26

### Fixed
- Antigravity now shows both the 5-hour session and the weekly limit. When
  `agy /quota` could not be read inside the app, only a single limit was shown,
  mislabelled as weekly. The `agy` call now runs with a clean `PATH` that
  includes Homebrew, waits longer, and retries once.
- The per-model fallback sorts limits into session or weekly by when they
  reset, instead of always calling them weekly.

## [0.2.0] - 2026-11-26

### Added
- The menu bar now shows every provider side by side: its logo and the share of
  its 5-hour session limit used. The number turns red at 90% or more, and a
  dash appears when a provider is not ready.
- When a provider is not ready, the popover explains why and how to sign in.
- A `--version` option, and a single `VERSION` file that sets the app version.

### Changed
- The popover opens on the busiest provider that is ready.
- The popover now fits its content, with no empty transparent band.
- Antigravity looks for `agy` in more install locations, and always says why it
  is not ready. Its tab is removed when `agy` is not installed.
- The plan label is hidden when empty.

### Fixed
- The Antigravity check no longer touches the Keychain when `agy` is missing.
- Clicking outside the popover (or pressing Esc) closes it again.

## [0.1.0] - 2026-11-25

First public release.

### Added
- Menu bar app showing Claude Code and Antigravity usage.
- Popover with a provider switcher, limit meters with a live reset countdown,
  a 7-day token chart and top models.
- Launch at login.
- Bundled Claude and Antigravity logos, which you can override with your own.
- A `--check-icons` diagnostic and hardened icon lookup.
- Demo mode with synthetic data.
- MIT licence, Omarchy credit and a trademarks note.

[0.3.0]: https://github.com/aishwaryasingh51/agent-usage-bar/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/aishwaryasingh51/agent-usage-bar/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/aishwaryasingh51/agent-usage-bar/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/aishwaryasingh51/agent-usage-bar/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/aishwaryasingh51/agent-usage-bar/releases/tag/v0.1.0
