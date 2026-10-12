<coding_guidelines>
# AGENTS.md — OpenCode Bar

Guidance for coding agents working in this repository.

## What this app is

OpenCode Bar is a **Windows tray app** that shows your [OpenCode](https://opencode.ai) **Go**
plan usage limits (rolling 5-hour, weekly and monthly windows) and notifies you when you
approach a limit. It polls `GET https://opencode.ai/zen/go/v1/usage` with a DPAPI-protected
API key, shows a color-coded OpenCode logo tray icon (dark below 75%, orange from 75%,
red from 90%), renders a dark popup with one bar per window, and fires threshold
notifications (75% / 90% / 100%) once per threshold. No telemetry; the only host it talks
to is `opencode.ai`.

The endpoint is not publicly documented. The response contract implemented here mirrors
what the [opencode-quota](https://github.com/slkiser/opencode-quota) project reads from
`/zen/go/v1/usage`: `{ "usage": { "rolling" | "weekly" | "monthly": { "status":
"ok" | "rate-limited", "percent": 0-100, "resetsAt": "<ISO timestamp>" } } }`. It may
change without notice; the parser is defensive on purpose.

## Windows-only caveats (do not "fix" these)

- The app targets **Windows PowerShell 5.1 + .NET Framework 4** only (`#Requires -Version 5.1`).
- `OpenCodeBar.exe` is a tiny C# host (`src/OpenCodeBarHost.cs`) that runs `opencode-bar.ps1`
  **in-process** via `build.ps1` (compiled with the .NET Framework 4 `csc.exe`; no SDK needed).
- The GUI depends on **WinForms / GDI+ / P-Invoke / DPAPI / the registry** — none of which
  run on Linux or macOS. You cannot run or dot-source the full script on a non-Windows host;
  GUI behavior must be smoke-tested via GitHub Actions (`windows-latest`) or `-Preview` renders there.
- DPAPI protects the API key so only the Windows user can decrypt it; this is intentional.

## Build / run

```powershell
# Build OpenCodeBar.exe (Windows only)
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1

# Run (script directly, no build needed)
powershell -NoProfile -ExecutionPolicy Bypass -File opencode-bar.ps1

# Run (compiled host)
OpenCodeBar.exe
```

Install = extract the release zip anywhere and run `OpenCodeBar.exe`. Nothing to install;
the app ships as the zip only.

## Validation protocol (developer flags)

Use these flags to validate without the live GUI:

| Flag | What it does |
| --- | --- |
| `-Mock samples\mock.json` | Use a local JSON file instead of the API. |
| `-Preview out.png` | Render the popup (and tray icon) to a PNG and exit. |
| `-Dump` | Print the raw API response and exit. |

Protocol for changes that touch rendering or data logic:

1. Unit-test pure helpers with Pester (see below).
2. `opencode-bar.ps1 -Mock samples\mock.json -Preview out.png` and inspect the PNG.
3. `-Dump` to verify raw API/parse behavior.
4. CI on `windows-latest` runs the same smoke checks and uploads the PNGs as artifacts.

## Tests and lint

Every gate lives in **`tools/RepoChecks.ps1`** and is invoked from both CI and the
local pre-commit hook, so the two can never drift. Run them all with:

```powershell
pwsh -File tools\RepoChecks.ps1 -Check all
```

Individual gates: `-Check parse`, `lint`, `format`, `largefiles`, `secrets`,
`tests`, `coverage` (each exits non-zero on failure).

- **Parse** (`parse`): `[System.Management.Automation.Language.Parser]::ParseFile`
  must report zero errors for `opencode-bar.ps1`, `src/opencode-bar-lib.psm1`,
  `build.ps1` and `tools/RepoChecks.ps1`. CI enforces this on PowerShell 5.1,
  which is what guards against PS 7-only syntax.
- **Lint** (`lint`): PSScriptAnalyzer 1.25.0 with `PSScriptAnalyzerSettings.psd1`.
  Zero Error-severity findings required. Every rule excluded in the settings file
  carries a justification comment (DPAPI key path, intentional silent catches,
  `Draw-*` GUI helpers, `Write-Log`, fixed event-handler signatures, positional
  internal calls). Analyze **one path per call** — `-Path` takes a single string.
- **Format** (`format`): `Invoke-Formatter` must be a no-op on every analyzed
  file. PSSA's formatter is the canonical PowerShell formatter; if it would
  change a file, the file is not committed in formatted shape.
- **Hygiene** (`largefiles`, `secrets`): no tracked file over 1 MB, no code or doc
  over 1500 lines, and no key-shaped credential material (`sk-` prefix plus 16 or
  more key characters) in the worktree **or in git history**.
- **Tests** (`tests`): Pester pinned to 5.7.1, suite in `tests/`.
- **Coverage** (`coverage`): Pester code coverage on `src/opencode-bar-lib.psm1`
  must stay at or above **85%**. The GUI script is excluded on purpose: its
  WinForms paths are only reachable on Windows.

### Local pre-commit hook

Hooks cannot be committed into `.git/hooks`, so install them once per clone:

```powershell
pwsh -File tools\Install-Hooks.ps1
```

This sets `core.hooksPath = .githooks`, after which `.githooks/pre-commit` runs
the `parse`, `lint`, `largefiles` and `secrets` gates before each commit. The
`format` and `coverage` gates are CI-only (they need the PSScriptAnalyzer engine
and a full Pester run). All gates also run in CI
(`.github/workflows/ci.yml`) on every PR and push to `main`.

## Config / state / log paths (Windows)

All under `%APPDATA%\opencode-bar\`:

| File | Purpose |
| --- | --- |
| `config.json` | Settings: `pollMinutes`, `thresholds`, `notifyPools`, `trayPool`, `apiBase`, `apiKeyProtected` (DPAPI). |
| `state.json` | Per-window alert state (which thresholds already fired). |
| `opencode-bar.log` | Rotated log (~512 KB). Never logs the API key. |

`OPENCODE_GO_API_KEY` env var overrides the stored key. See README "Configuration" for the full table.

## Coding conventions

- **PowerShell 5.1-compatible syntax only**: no `?.`/`??`, no ternary `? :`, no `&&`/`||`
  between statements, no PS 7-only cmdlets. `[ordered]@{}` and `Join-Path` are fine.
- **No external runtime modules** — the app must run on a stock Windows 10/11 install.
  `System.Windows.Forms` / `System.Drawing` live only in `opencode-bar.ps1`, never in `src/opencode-bar-lib.psm1`
  (the lib module must import cleanly on pwsh/Linux for unit testing).
- **Verb-Noun** function names (existing examples: `Get-WinInfo`, `Format-Pct`, `Draw-Popup`, `Test-Alerts`).
- `Set-StrictMode -Version Latest` at the top of script and module — guard `$null` before property access.
  Strict mode makes references to non-existent properties terminating errors, so dynamic
  API/mock JSON members must be read via `Get-MemberValue` (returns `$null` when missing).
- Pure/testable logic goes in `src/opencode-bar-lib.psm1`; GUI, polling and P/Invoke stay in `opencode-bar.ps1`.
- English comments; comment intent where it is non-obvious.
- **`TODO(#NN)` convention**: tracked tech debt uses `TODO(#123)` referencing a GitHub issue
  (never a bare `TODO`).
- Privacy invariants: the only network host is `opencode.ai` (`apiBase`); the API key is
  never logged, committed, or echoed.

## Contribution workflow

- Branch from `main` → commit → PR → CI must pass → merge. Do not push directly to `main`.
- Commit messages: short imperative subject (e.g. `Extract pure helpers into src/opencode-bar-lib.psm1`).
- Use the repo issue/PR templates.
- The API key is a secret: never commit, echo, or log it.

## Release steps

1. Merge all feature work into `main` with green CI.
2. Push a tag: `git tag v0.1.0 && git push origin v0.1.0` (semver `vMAJOR.MINOR.PATCH`).
3. The tag triggers `.github/workflows/release.yml` (on `windows-latest`): runs `build.ps1`,
   zips `OpenCodeBar.exe` + `opencode-bar.ps1` + `src/opencode-bar-lib.psm1` + README + LICENSE, and
   creates a GitHub Release with auto-generated notes and the zip attached.
4. Verify at [Releases](https://github.com/soaresfellipe/opencode-bar-windows/releases) that the
   zip asset contains the expected files.
</coding_guidelines>
