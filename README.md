# AI Agent Ampel

Live status HUD for AI coding agents (OpenAI Codex, Google Antigravity, Claude Code, plus your own):
a 4-colour traffic light per agent and depleting rings for the usage limits.

## Download

Latest builds are on the [Releases page](../../releases/latest):

| Platform | File |
| --- | --- |
| Windows | `AgentAmpel-windows-setup.exe` (installer) or `AgentAmpel-windows-x64.zip` |
| Linux | `AgentAmpel-linux-x64.tar.gz` |
| macOS | `AgentAmpel-macos.zip` — unsigned: right-click the app, then *Open* the first time |
| Android | `AgentAmpel-android.apk` (allow installs from your browser once) |
| Web | `AgentAmpel-web.zip` (demo mode only, see below) |

The desktop app checks the Releases page and updates itself.

## Use

- **Alt + Space** shows or hides the compact HUD, **Esc** hides it. The expand button in the top bar opens the large window.
- Notifications fire when an agent hits a limit (red) and when it is available again.
- Hooks for Claude Code, Codex and Antigravity are installed automatically (with `.bak` backups).
- **Own agents** (Kimi, Grok, ...): add them in Settings, then report status with
  `POST http://127.0.0.1:47832/api/hook` and `{"agent":"kimi","event":"working","usage":{"5h":40}}`.
  Events: `working`, `permission`, `stop`, `error`.
- **Android / web** show the desktop's live status through *Settings → Sync host* (the desktop must allow LAN access).
  A page served over `https://` cannot open the desktop's `ws://` socket, so the hosted web app only runs in demo mode.

## Build from source

```bash
flutter pub get && flutter analyze && flutter test
flutter build windows --release   # or linux / macos / web / apk
```

Releases are built by GitHub Actions from `.github/workflows/release.yml`. Secrets (Android keystore, Play, Firebase)
live only in GitHub Actions secrets; see `PLAY_STORE_SETUP.md`.
