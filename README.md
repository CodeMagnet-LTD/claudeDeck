# ClaudeDeck

**English** · [Türkçe](README.tr.md)

**A native macOS app for running Claude Code sessions across many projects from one window.**

See at a glance which session is working, which one needs permission, which one is asking a question
and which one is done and waiting for you. Allow a permission prompt right from the notification,
put sessions side by side, and pick up exactly where you left off after a restart.

ClaudeDeck doesn't wrap, imitate or screen-scrape Claude. Every session runs **your own installed
`claude` CLI** through your login shell, in an embedded terminal (SwiftTerm, a real pty). Your settings,
`CLAUDE.md` files, remote control, MCP servers, skills and other hooks keep working exactly as before.

## Screenshots

<!-- Screenshots go in docs/screenshots/ (captured with tools/demo.sh, fake demo projects only). -->

## What it is, and what it isn't

| ClaudeDeck **is** | ClaudeDeck **is not** |
|---|---|
| A **session manager** that runs your installed `claude` CLI in real terminals | A chat client or API client that replaces Claude Code |
| A dashboard that learns session state from Claude Code's official **hooks** | A tool that reads the screen, parses terminal output or logs keystrokes |
| A local macOS app that gathers many projects and parallel sessions in one window | A cloud service, an account system or telemetry: nothing leaves your Mac |
| A shell around your own settings, `CLAUDE.md` files, MCP servers and skills | A plugin that changes Claude Code's behavior, permission rules or model |
| A shortcut that sends the key *you* would press to a permission prompt | An automation that approves permissions on its own |

Billing, usage limits and sign-in stay entirely with Claude Code. ClaudeDeck doesn't touch them.

## Highlights

- 🟢🔴🟡 **Live status:** running, needs permission, asking a question, or your turn, for every session.
  The state comes from Claude Code hooks, not from reading the screen.
- 🔔 **Notifications, Dock badge, menu bar item and a desktop widget**, so you never miss a session
  that needs you.
- ✅ **Allow or Deny from the app:** from the notification, the list or the pane header.
- 🗂 **Projects and groups:** pin projects, use colored groups, and sessions that need attention float to the top.
- 🪟 **Side-by-side panes:** drag and drop up to four sessions next to each other.
- ♻️ **Persistence:** open sessions come back with `claude --resume` after a restart. If the context
  has grown too large, `/compact` is sent automatically.
- 🌿 **Worktree sessions:** run parallel sessions in the same project, each in its own
  `claude --worktree`, so they never edit the same files.
- 📁 **Files panel:** a live file tree with git status marks, per-file history and diffs. Drag a file
  into a terminal to add it as `@path`. Opens files in VS Code.
- 💻 **Plain terminals:** a shell in the project folder, optionally with a startup command such as
  `yarn start` that runs when the app launches.
- ☁️ **iCloud sync (optional):** your project list and groups stay in sync across your Macs.
- 🎨 Light and dark themes, terminal zoom (⌘+ / ⌘- / ⌘0), and ⌘V to paste images into Claude.
- 🌐 **English and Turkish.** The app follows your system language. To choose one just for ClaudeDeck,
  go to System Settings › General › Language & Region › Applications.

## Install

1. Download the latest `ClaudeDeck-<version>.dmg` from [Releases](../../releases/latest).
2. Open the DMG and drag **ClaudeDeck** into **Applications**.
3. Launch it. On first launch the Claude Code hook is added to `~/.claude/settings.json`
   (a backup is made first; see below).

The app is signed with a Developer ID and notarized by Apple, so Gatekeeper won't warn you.

### Requirements

- macOS 15 (Sequoia) or later
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed, with `claude` available in your login shell
- `jq`, which ships with macOS 15 as `/usr/bin/jq`
- Optional:
  - Git status marks and file history need the Command Line Tools (`xcode-select --install`) or Homebrew git.
    Without either, these features stay off quietly.
  - Opening files in an editor needs VS Code, VS Code Insiders or VSCodium.

## How status works (no screen reading)

1. On first launch, the ClaudeDeck hook is **added** to `~/.claude/settings.json`:
   - A `settings.json.claudedeck-backup-<time>` backup is made first.
   - Your other hooks are left alone, and the hook is never added twice.
   - Symlinked settings files keep their link.
   - To undo it, go to Settings › Claude Code hooks › Uninstall.
2. The hook is `~/.claude/deck/bin/deck-hook.sh`: plain `sh` plus `/usr/bin/jq`, about 40 ms per event.
   - It only acts in terminals ClaudeDeck opened, which carry `CLAUDEDECK_TERMINAL_ID`, and does nothing
     for `claude` running anywhere else.
   - It writes `~/.claude/deck/sessions/<session_id>.json` atomically.
3. The app watches that folder with a DispatchSource (no polling) and cleans up stale files.
4. Esc interrupts and permission denials don't fire hooks, so they are picked up instantly from the
   session transcript's `[Request interrupted by user…]` entry instead.
5. Parallel tools: while a permission prompt is open, another tool finishing doesn't flip the state
   back to "running".

| Event | State |
|---|---|
| UserPromptSubmit, PreToolUse, PostToolUse(Failure), permission answered | 🟢 Running |
| PermissionRequest, Notification `permission_prompt` | 🔴 Needs permission |
| AskUserQuestion (PermissionRequest/PreToolUse), Notification `elicitation_dialog` | 🔴 Asking a question |
| Stop, StopFailure, Notification `idle_prompt`, interrupt/deny in transcript | 🟡 Your turn |
| SessionEnd / process exited | ⚪️ Stopped |

## Features

### Sessions
- **New Claude session:** use the **+** on a project header, the context menu, or ⌘T. You can run as
  many sessions per project as you like.
  - Names come from the project (`claude --name "<project>"`, then `"<project> · 2"`) and show up in
    remote control too.
  - Renaming is forwarded to the running session with `/rename`.
- **Resume a previous conversation:** project menu › Resume Previous Conversation…, which lists
  transcripts from `~/.claude/projects`.
- **Persistence:** sessions that were open when you quit come back on launch with
  `claude --resume <id>`.
  - Selecting a stopped session resumes it.
  - Sessions you closed with `/exit` or End Session come back when you choose Resume.
- **Auto /compact:** when a resumed session's context is above the threshold, `/compact` is sent.
  - The threshold is measured in real context tokens: `input + cache_read + cache_creation` of the last
    assistant message, not the transcript file size.
  - Configurable in Settings: 50K to 1M tokens, 200K by default.
- **Separate worktree:** project menu › New Claude Session (Separate Worktree)…, available in git repos only.
  - Runs `claude --worktree <name>` in its own git worktree.
  - The real folder is learned from the hooks' `cwd`, and resuming runs there.
- **Context menu:** Open Beside / Close Pane, Allow / Deny (when waiting), End Session, Resume,
  Start Fresh, Rename, and End and Remove. End and Remove asks first and never deletes Claude's history.

### Plain terminals
- Open one with the terminal icon on a project header, context menu › New Terminal, or ⌥⌘T. It starts
  a login shell in the project folder.
  - Terminals show a blue "Terminal" tag and the current terminal title.
  - They don't count toward status or notifications.
- **Startup command** (e.g. `yarn start`): typed and run every time the terminal opens.
  - It stays in history, and Ctrl+C doesn't close the terminal.
- **Start when the app launches:** on by default for terminals with a startup command.

### Permissions and notifications
- **Notifications** for permission prompts, questions and finished turns, with the tool and its
  command or file.
  - Skipped when that terminal is already visible, and for things you did yourself, like Esc or Deny.
  - Clicking one brings the app forward and selects that session.
- **Allow / Deny** appears in the notification, the Needs Attention row, the pane header and the context menu.
  - The app types the key you would press (Allow = `1`, Deny = Esc).
  - It only sends it if the session is still waiting on the same prompt.
  - Questions and plan approval (ExitPlanMode) are excluded.
- **Dock:** the badge shows how many sessions are waiting. The icon bounces until you return for a
  permission prompt or question, and once when a session finishes.
- **Menu bar:** waiting, running and your-turn counters. Click for the session list.
- **Widget:** right-click the desktop › Edit Widgets… › ClaudeDeck. The app must have been opened at
  least once.
  - Small size shows the counters; medium shows the first four sessions that need attention.
  - Clicking one opens that session (`claudedeck://session/<uuid>`).

### Sidebar
- **Needs Attention:** sessions asking for permission, asking a question, or finished but not yet seen
  sit at the top with project name and message. Permission prompts are highlighted in red.
- **Status tags:**
  - 🟢 Running (flowing dots)
  - 🔴 Needs permission / Asking a question (pulsing)
  - 🟡 Your turn
  - ⚪️ Stopped
  - 🔵 Terminal

  A row briefly glows when its state changes.
- **Projects:** "Pinned" and "Projects" sections.
  - Groups sit inside "Projects" like folders.
  - Projects and groups with waiting or active sessions move up, and ones with a waiting session expand
    automatically.
  - Clicking a project opens its latest session and points the Files panel at it.
- **Groups:** "Projects" header **+** › New Group….
  - Assign several projects at once with Choose Projects….
  - Change a group's color and name from its context menu.

### Side-by-side panes
- Open a session next to another one in any of these ways:
  - Drag it onto the left or right half of the terminal area.
  - Use context menu › Open Beside.
  - Open all of a project's sessions side by side from its menu.
- Up to four panes; drag the divider to resize.
- Each pane header shows the name, state, Allow/Deny, and ✕. ✕ only closes the pane; the process keeps running.
- The layout persists.

### Files panel (⌘⇧E)
- A live tree of the last clicked project, or the selected session's worktree.
  - `.git`, `node_modules`, `.build` and the like are hidden; use the eye icon to show hidden files.
- **Git:**
  - Modified files are shown as orange **M**, new ones as green **A/?**, deleted or conflicted ones in red.
    Folders containing changes are dotted.
  - Selecting a file shows its commit history. Click a commit for the file's diff; uncommitted changes
    are at the top.
- Click to select (⌘-click for several). Double-click opens the file in VS Code, or in the default app if
  VS Code isn't installed.
- **Context menu:** Open in VS Code, Open, Reveal in Finder, Add to Claude (`@path`), Copy Path,
  Copy Relative Path, New File / New Folder, Rename, Move to Trash.
- **Drag a file onto a terminal pane:**
  - In Claude it's added as `@relative/path`. Images use the full path, so Claude attaches them as images.
  - In a plain terminal the escaped path is typed.

### Terminal
- Full keyboard support, colors, shortcuts, resizing and copy/paste. Switching panes or sessions never
  kills processes.
- **Zoom:** ⌘+ / ⌘- / ⌘0 or pinch on the trackpad. The zoom level is remembered.
- **Theme:** System / Light / Dark in Settings; terminal colors follow.
- **⌘V with an image** on the clipboard attaches it to Claude as an image, as Terminal.app does.
  Files copied in Finder are pasted as paths.

### Settings (⚙︎ or ⌘,)
- Launch at login (the app must be in `/Applications`).
- Resume sessions on launch, auto /compact and its token threshold.
- Notifications and Dock bounce, theme, and keeping the app in the menu bar when the window is closed.
- iCloud sync (below).
- Claude Code hooks: status, reinstall, uninstall.

## iCloud sync (optional)

Turn it on in Settings › iCloud (off by default). No entitlement is needed; it is a plain file:
`~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeDeck/projects.json`.

- **Synced:** groups (id, name, color) and projects (path, name, group, pinned). Paths under your home
  folder are stored as `~/…`.
- **Not synced:** sessions, panes, selection, settings, expanded state, terminal and Claude ids.
- **Merge:** projects are matched by path and groups by id. Missing items are added, and on conflict
  the most recent change wins.
- **Deletions don't propagate:** an item deleted on one Mac stays on the others. Sync never deletes
  local projects or sessions.

## Data

| What | Where |
|---|---|
| Projects, groups, sessions, panes, settings | `~/Library/Application Support/ClaudeDeck/deck.json` |
| Live session states (written by the hook) | `~/.claude/deck/sessions/<session_id>.json` |
| Hook script | `~/.claude/deck/bin/deck-hook.sh` |
| settings.json backups | `~/.claude/settings.json.claudedeck-backup-<date>` |
| Widget snapshot | `~/Library/Group Containers/<team>.<bundle-prefix>.ClaudeDeck/widget-snapshot.json` |
| iCloud sync (if on) | `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeDeck/projects.json` |
| Conversation history | Claude's own location, `~/.claude/projects/<project>/<id>.jsonl` (read-only for ClaudeDeck) |

## Building from source

```sh
./build.sh           # release → build/ClaudeDeck.app (with widget and icon)
./build.sh debug     # debug build
./build.sh run       # build and (re)launch
./build.sh install   # build, copy to /Applications/ClaudeDeck.app and launch from there
swift build          # quick SwiftPM-only build (no widget)
swift test           # Core unit tests
xcodegen generate    # generate ClaudeDeck.xcodeproj from project.yml, then open it in Xcode
```

- `build.sh` builds with `xcodegen generate` + `xcodebuild`, because SwiftPM can't build app
  extensions such as the widget.
  - Without `xcodegen` (`brew install xcodegen`) it falls back to plain SwiftPM packaging, with no widget.
- The Xcode project is generated, so don't edit it by hand:
  - Change targets in `project.yml`.
  - Change the team, bundle id and version in `Config/Shared.xcconfig`.
  - On first open, Xcode asks you to "Trust & Enable" SwiftTerm's build plugin.
- UI strings live in string catalogs: `Support/Localizable.xcstrings` for the app and
  `Widget/Localizable.xcstrings` for the widget. Xcode adds new strings when you build in the IDE.
  To add a language, add translations there.
- The app icon is drawn in code: `swift tools/make-icon.swift Support` writes `Support/AppIcon.icns`
  and `Support/Assets.xcassets/AppIcon.appiconset`.

### Building with your own Apple account

The defaults use the official release team. To build on your own Mac:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # git-ignored
# DEVELOPMENT_TEAM = <your Team ID>      (a free Apple ID's personal team works)
# DECK_BUNDLE_PREFIX = com.yourname      (must differ from the official one)
./build.sh
```

The widget's App Group, the bundle ids and signing are all derived from these two values; nothing in
the code needs changing. Because the signature stays stable, macOS doesn't ask for folder or
notification permissions again after every build.

## Distribution

```sh
./make-dmg.sh    # test DMG from build/ClaudeDeck.app (unsigned)
./notarize.sh    # build → sign with Developer ID → notarize app and DMG → staple → verify
./release.sh     # notarize.sh + v<version> tag + GitHub Release (DMG and SHA-256 attached; asks before publishing)
```

- The version lives in one place: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `Config/Shared.xcconfig`.
- Notarization needs a **Developer ID Application** certificate and a `notarytool` profile.
  - Both live only in the local keychain; the repository contains no signing keys or passwords.
  - If anything is missing, `notarize.sh` stops with an explanation before building or uploading anything.

## Code layout

- `Sources/ClaudeDeckCore/`: the UI-free, tested layer.
  - Hook script and `settings.json` merging (`HookScript`, `HookInstaller`)
  - State model (`SessionState`, `StatusDirectory`) and transcript reading (`Transcript`)
  - Persistence (`DeckData`)
  - File listing and git (`FileListing`, `Git`)
  - iCloud (`DeckSync`) and the widget snapshot (`WidgetSnapshot`)
- `Sources/ClaudeDeck/`: the SwiftUI app.
  - `AppModel` and `TerminalRegistry` (SwiftTerm, processes)
  - Views: `SidebarView`, `ContentView` (panes), `FileBrowser`, `MenuBarViews`, `SettingsView`
  - `AttentionCenter` (notifications, Dock) and `PermissionActions`
  - `WidgetBridge` and `DeckSyncController`
- `Widget/`: the WidgetKit extension. `tools/make-icon.swift`: the icon generator.
- `Tests/ClaudeDeckCoreTests/`: unit tests, including the real hook script against a real git repository.

## Development notes

### Demo mode

`./build.sh && tools/demo.sh` launches the app with made-up projects, groups and sessions in every state.
Use it for screenshots.
- The data lives in `/tmp/ClaudeDeckDemo` and is recreated on every run.
- Sessions run `tools/demo-claude.sh`, a stand-in that prints a canned conversation and reports a fixed
  state, instead of the real `claude`.
- Demo mode never touches `~/.claude/settings.json`, your `deck.json` or iCloud.

### Snapshot mode


`CLAUDEDECK_SNAPSHOT_DIR=<dir> open build/ClaudeDeck.app` enables end-to-end testing without the Screen
Recording permission:
- It periodically renders the windows to PNG and writes table row counts to `rows.txt`.
- It processes command files in `<dir>`:
  - `<session>.in` types text into that terminal (`<CR>`, `<ESC>` are supported).
  - `<session>.select`, `<session>.beside`, `<session>.paste`, `<session>.approve` / `.deny`,
    and `<project>.shell` trigger the matching actions.
- The Liquid Glass sidebar renders blank in these snapshots; use `rows.txt` for it.

## License and legal

[MIT](LICENSE) © 2026 [CODE MAGNET YAZILIM LTD. ŞTİ.](https://codemagnet.co)
Third-party licenses: [Support/THIRD_PARTY_LICENSES.txt](Support/THIRD_PARTY_LICENSES.txt) (SwiftTerm, MIT).

ClaudeDeck is an independent open-source project. It is not affiliated with, endorsed by or sponsored
by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic PBC.
