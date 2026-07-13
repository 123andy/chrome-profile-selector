# ChromeProfileSelector

A tiny macOS utility that asks **"which Chrome profile?"** every time a link is
opened — from the terminal, Slack, Mail, or any other app — and routes the URL
to the profile you pick.

If you work across several Chrome profiles (work, personal, clients, side
projects), you know the failure mode: something opens a link, Chrome picks
*its* idea of the current profile, and the tab lands in the wrong identity.
ChromeProfileSelector fixes this at the source by registering itself as your
default browser and putting a fast, keyboard-first picker in front of Chrome.

## What it does

When any app opens an `http`/`https` URL, a small dialog appears:

```
┌──────────────────────────────────────────────────────┐
│                        (◕‿◕)   ← photo of the        │
│  Open in which Chrome profile?   highlighted profile │
│  ⚙ Requested by Slack                                │
│  https://github.com/some/very/long/path/to/a/pu… ⧉   │
│  ┌──────────────────────────────────────────────┐    │
│  │ 1   Work        (you@company.com)            │    │
│  │ 2   Personal    (you@gmail.com)         ◀ ▌  │    │
│  │ 3   Client A    (you@client.com)             │    │
│  └──────────────────────────────────────────────┘    │
│   [ Open for 1 Hour ]        [ Cancel ]  [ Open ]    │
└──────────────────────────────────────────────────────┘
```

- **Shows the profile's photo**: the highlighted profile's Google account
  picture (circular, like Chrome's own profile switcher) appears at the top of
  the dialog and swaps live as you move the selection — a strong visual check
  that you're about to open the link as the right identity. Profiles without a
  photo get a Chrome-style colored monogram.
- **Remembers your last choice** — it's preselected, so a repeat is just ⏎.
- **"Open for 1 Hour"** — a third button that opens the highlighted profile
  *and* routes every link there silently for the next hour. Great for a focused
  work session. To end it early, launch the app directly
  (`open -a ChromeProfileSelector`) and click **Stop Auto-Open**; it expires on
  its own otherwise.
- **Return/Enter** opens the highlighted profile; **Esc** cancels (drops the URL).
- **↑/↓** move the highlight; pressing **1–9** opens that profile instantly;
  double-click works too.
- The URL is shown wide, in monospaced type (up to 3 lines, selectable, full
  URL in the tooltip), so you can actually read where you're about to go — with
  a **copy button** beside it to grab the URL to the clipboard instead of (or
  before) opening it.
- The profile list is read **live from Chrome's own profile data** on every
  invocation — add, remove, or rename profiles and the picker is always
  current. No configuration file to maintain.
- **Shows who's asking**: a "Requested by *App*" line (with the app's icon)
  identifies which application triggered the open — useful when a link opens
  and you're not sure why.

## Why not just `open -a "Google Chrome" --args --profile-directory=...`?

Because of a subtle and infuriating macOS/Chrome gotcha: that command **silently
ignores `--profile-directory` whenever Chrome is already running** (`open`'s
`--args` only apply on cold launch). Since Chrome is essentially always running,
the flag does nothing and the tab lands in the wrong profile anyway.

ChromeProfileSelector invokes the Chrome **binary** directly
(`…/Google Chrome.app/Contents/MacOS/Google Chrome --profile-directory=… <url>`),
which correctly hands the URL to the running Chrome instance and lands in the
right profile every time.

## Requirements

- macOS 12 (Monterey) or later
- Google Chrome installed at `/Applications/Google Chrome.app`
- Xcode Command Line Tools, for the one-time build (`xcode-select --install`)

## Install

```bash
git clone https://github.com/123andy/chrome-profile-selector.git
cd chrome-profile-selector
./install.sh
```

That's the whole setup: it builds the app, installs it to `/Applications`, and
asks macOS to make it the default browser — you just click **Use
"ChromeProfileSelector"** in the confirmation dialog macOS shows. (If you
dismiss the dialog, you can set it later in System Settings → Desktop & Dock →
Default web browser, or re-run `./install.sh`.)

Test it:

```bash
open https://example.com
```

## Uninstall

```bash
./uninstall.sh
```

Then pick a new default browser in System Settings.

## How it works

- **Default-browser interception.** macOS delivers every URL-open to the
  default browser. The app's `Info.plist` claims the `http`/`https` URL schemes
  and the `public.html` content type, which is what makes macOS treat it as a
  browser and offer it in the default-browser picker. The app itself is a
  single-file AppKit program (`src/main.swift`, no dependencies) that receives
  the URL, shows the picker, launches Chrome, and exits.
- **Profile discovery.** Profiles are parsed from
  `~/Library/Application Support/Google/Chrome/Local State`
  (`profile.info_cache`), which maps each profile directory (`Default`,
  `Profile 2`, …) to its display name and account email.
- **Avatars.** Each profile's photo is read from Chrome's on-disk copy
  (`<profile dir>/Google Profile Picture.png`, falling back to
  `Accounts/Avatar Images/<gaia_id>`), circular-cropped, and shown as the
  dialog's icon for the highlighted row. Profiles without a photo get a
  monogram circle tinted with Chrome's `default_avatar_fill_color`.
- **Memory.** The last-used profile directory is stored in the app's
  preferences (`defaults read org.chromeprofileselector`).
- **Sender identification.** The URL arrives as an Apple Event carrying the
  sender's process ID. GUI apps (Slack, Mail, …) are identified directly. A
  terminal `open https://…` attributes the event to the short-lived `open`
  process, so the app walks the process ancestry (open → shell → Terminal) to
  name the terminal; if that process has already exited, it falls back to the
  frontmost app, and shows nothing rather than guessing. No permissions or
  entitlements are needed for any of this.
- **Fail-safe.** If the profile list can't be read, the URL is handed to
  Chrome's Default profile rather than being swallowed. Cancel intentionally
  drops the URL.

## Troubleshooting

**I added / removed / renamed a Chrome profile — do I need to reinstall?**
No. The profile list, names, and photos are read fresh from Chrome's own data
every time a link opens, so changes appear in the very next picker. There is
nothing to rebuild, reconfigure, or reinstall. (If the profile you used last
was deleted, the picker simply preselects the first one; an active "Open for
1 Hour" pointing at a deleted profile is ignored and the picker returns.)

**How do I stop "Open for 1 Hour" early?** Launch the app with no URL —
`open -a ChromeProfileSelector` (or double-click it in /Applications). While an
hour is active, the dialog shows which profile links are going to, and until
when, with a **Stop Auto-Open** button. (Terminal alternative:
`defaults delete org.chromeprofileselector autoOpenUntil`.) It also simply
expires on its own.

**It doesn't appear in the default-browser list in System Settings.** macOS
only lists browsers that have been launched at least once, and System Settings
caches the list. Normally irrelevant — `install.sh` sets the default directly,
bypassing that list — but if you want it listed: launch the app once
(`open -a ChromeProfileSelector`), then quit and reopen System Settings. Or
just re-run `./install.sh`.

**Every app now shows the picker, not just the terminal.** Correct — default
browser interception is system-wide; that's the design. If you want specific
tools to bypass the picker, point them straight at a profile, e.g.
`BROWSER="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --profile-directory='Profile 2'"`
or an equivalent wrapper script.

**Chrome lives somewhere else / you use Chrome Beta or Chromium.** Adjust the
two paths at the top of `src/main.swift` (`loadProfiles()` and
`openInChrome()`), then re-run `./install.sh`.

**Firefox/Safari/other browsers?** Out of scope — this tool is Chrome-profile
specific. The picker pattern (a tiny app registered as the default browser)
generalizes; forks welcome.

## License

MIT — see [LICENSE](LICENSE).
