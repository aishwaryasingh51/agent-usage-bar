# Changelog

All notable changes to Agent Usage Bar are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

[0.2.0]: https://github.com/aishwaryasingh51/agent-usage-bar/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/aishwaryasingh51/agent-usage-bar/releases/tag/v0.1.0
