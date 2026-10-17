# Codex Quota Widget

A compact, light Windows desktop widget for viewing Codex's five-hour and weekly usage limits.

## Features

- Shows remaining quota and reset times for the five-hour and weekly windows.
- Refreshes every five seconds; quota reads run in the background so the window stays responsive.
- Uses a compact, translucent light interface. Drag the header, cards, or blank areas to move it.
- Progress bars turn red below 10% remaining and amber at 50% or less.
- Right-click to refresh, view available reset credits, use a reset credit, toggle always-on-top, or exit. Using a reset credit requires confirmation.

## Requirements

- Windows 10 or 11.
- Windows PowerShell 5.1.
- Codex CLI installed and signed in for the current Windows user, with `codex` available on `PATH`.

## Run

Keep `CodexQuotaWidget.ps1` and `启动 Codex 额度小窗.bat` in the same folder, then double-click the `.bat` file. No administrator privileges or startup entry are required.

## Data and behavior

The widget talks to the local `codex app-server --stdio` process and reads its rate-limit data. It does not read or store login credentials and does not send telemetry to a separate service; the local Codex CLI handles its normal sign-in and network requests. The widget polls every five seconds because the app-server rate-limit API does not currently provide push updates.

The app-server API is experimental and may change with future Codex CLI releases. If the widget cannot sync, confirm that Codex CLI is signed in and try restarting the widget.

## 中文说明

双击“启动 Codex 额度小窗.bat”即可启动。小窗显示 5 小时额度和每周额度，右键可刷新、查看或使用重置卡、切换置顶和退出。使用重置卡前会再次确认。详细说明见 [使用说明.md](使用说明.md)。

This is an unofficial community project and is not affiliated with OpenAI.

