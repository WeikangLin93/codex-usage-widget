# Changelog

## 0.2.3

- Clarify that browser-only ChatGPT login is not enough; the widget needs local Codex auth files.

## 0.2.2

- Fix GitHub publishing of PNG preview images by uploading binary files as base64 blobs.

## 0.2.1

- Refresh README to highlight the v0.2.0 stability, packaging, and engineering improvements.
- Add day and night mode preview images for a clearer first impression.
- Include documentation images in release packages.

## 0.2.0

- Move generated config and cache to `%LOCALAPPDATA%\CodexUsageWidget`.
- Refresh usage in a background PowerShell job so the widget stays responsive.
- Back up and atomically update auth files when refreshing tokens.
- Add readable light/dark adaptive widget colors.
- Add packaging scripts, tests, and GitHub Actions CI/release workflow.

## 0.1.0

- Initial Windows floating widget for Codex usage.
