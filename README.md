# OmniBar

A tiny macOS menu bar widget that lists the most recent calls going through
[OmniRoute](https://github.com/diegosouzapw/OmniRoute), read from its `GET /api/usage/call-logs` API. It is one
Swift file with no Xcode project and no dependencies. It uses about 15 MB of memory and no CPU while idle.

- **Icon:** a branch glyph. The number next to it counts calls that are still running. The icon turns red when a
  request failed in the last 5 minutes, and becomes an orange ⚠︎ when the fetch itself fails (the reason is in the
  tooltip and the menu).
- **Menu:** the newest 15 requests, one line each:
  `time  status  duration  tokens in→out  model  provider · combo · API key`.
  Hover over a row for details, including any failed or extra provider attempts. Click a row to copy its JSON.
- **Polling:** every 30 s and whenever the menu opens. Each poll is about 50 KB.

OmniRoute logs a combo request as a client row (combo, API key) plus one row per provider attempt, all with the same
`correlationId`. OmniBar folds them into a single line.

Requires macOS 14 or later on Apple silicon, and the Xcode Command Line Tools (`xcode-select --install`).

## Setup

1. **Token.** The call-log route needs a management credential. Use a `read`-scoped access token (`oma_live_…`) from
   the OmniRoute dashboard (Settings → Access Tokens), then run:

       ./set-token.sh                 # paste it; it goes to the login keychain, service omniroute-bar

   If OmniRoute runs on a server you can SSH into, `./set-token.sh --mint HOST [ENV_FILE]` mints the token there with
   the manage-scoped `OMNIROUTE_API_KEY` from `ENV_FILE` on that host. OmniBar reads the token through
   `/usr/bin/security`, so rebuilding the app never triggers a keychain prompt.

2. **URL.** The default is OmniRoute's local address, `http://localhost:20128/api/usage/call-logs`. For a remote
   instance:

       defaults write local.omnibar url https://omniroute.example.com/api/usage/call-logs

3. **Build and install:**

       ./build.sh             # build, copy to /Applications, start now and at every login
       ./build.sh build       # only build build/OmniBar.app
       ./build.sh uninstall   # stop it and remove the app and the LaunchAgent

   Autostart is a LaunchAgent (`~/Library/LaunchAgents/local.omnibar.plist`) that also restarts the app if it
   crashes. Quitting from the menu stops it until the next login.

## Settings

    defaults write local.omnibar interval -float 30   # seconds between polls
    defaults write local.omnibar rows -int 15         # rows in the menu
    launchctl kickstart -k gui/$(id -u)/local.omnibar  # restart to apply

`/Applications/OmniBar.app/Contents/MacOS/OmniBar --once` prints the rows and exits, which is handy for checking the
token and URL.
