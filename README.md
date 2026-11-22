# OmniBar

A tiny macOS menu bar widget that lists the most recent calls going through
[OmniRoute](https://github.com/diegosouzapw/OmniRoute), read from its `GET /api/usage/call-logs` API. It is one
Swift file with no Xcode project and no dependencies. It uses about 15 MB of memory and no CPU while idle.

- **Icon:** a branch glyph in the menu bar's own colour. The number next to it counts calls that are still running.
  It becomes a ⚠︎ when the fetch itself fails (the reason is in the tooltip and the menu). Its tooltip also counts the
  requests that failed in the last 5 minutes and names the providers that are not ok.
- **Recent calls:** the newest 15 requests as a table:
  `time  status  duration  tokens in → out  position  model  provider · combo · API key`.
  - **Status:** shown only for a failure (`429`, with a ⚠ symbol), or `…` while the call runs (⌛).
  - **Position:** for a combo call, where the model that served it sits in the combo's fallback chain. `1/3` is the
    combo's first choice and `3/3` its last fallback.
  - **Provider:** the name from the `providers` setting, or a custom node's own name, so `ppq` rather than
    `openai-compatible-chat-…`.

  Hover over a row for details, including any failed or extra provider attempts and their positions. Click a row to
  copy its JSON.
- **Providers:** one line per provider connection, with a symbol for its state:
  - ✓ ok: its last hourly check passed.
  - ◷ waiting: cooling down after a rate limit, or a quota window used up. OmniRoute skips the connection until then.
  - ⚠ failing: every call through it failed in the last hour, even if its check passes.
  - ! errors: some calls failed in the last hour.
  - ✕ a failed check, such as `login expired`, or no connection that matches the `providers` entry.
  - – switched off in OmniRoute.

  After the name comes the quota OmniRoute tracks for the connection: the share used of each window, as in
  `5h 73% · week 72% used`. It comes from the cache that OmniRoute's provider-limits sync refreshes every
  10 minutes. Pay-as-you-go connections such as custom OpenAI-compatible nodes have none. Below the line, each
  window in use gets a countdown line:

      5h     ████░░░░░░   1h 47m  resets Sun 22 Nov 15:30
      week   █░░░░░░░░░  11h 17m  available Mon 23 Nov 01:00

  The bar is the time left of the window, and it drains to empty at the reset. A used-up window says when it is
  `available` again. A cooldown that no used-up window explains gets a countdown line of its own.

  OmniRoute's hourly check calls a model of its own (`connection-test`), so it can pass while every real call fails.
  `failing` catches that. Hover over a line for the full error, the time of the last check, the quota with amounts
  and reset times, and the calls per model. Click it to copy the connection's JSON.
- **Polling:** every 30 s and whenever the menu opens. Each poll is about 50 KB. The chains come from
  `GET /api/combos` on the same server, re-read every 5 minutes. The provider health comes from `GET /api/providers`,
  the last hour of `GET /api/providers/health-matrix` (healthy providers left out) and the quota cache
  `GET /api/usage/provider-limits`, about 45 KB once a minute.

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
    defaults write local.omnibar providers -array glm kimi "openai=codex"   # the Providers block
    launchctl kickstart -k gui/$(id -u)/local.omnibar  # restart to apply

Each `providers` entry is a label. The label also picks the connections: a connection whose provider id, name or
node name equals it (ignoring case), or else contains it. Write `label=match` when the label should differ, as in
`openai=codex`. If one entry picks several connections, the line shows the worst of them. Without the setting, the
block lists every active connection under its own name.

`/Applications/OmniBar.app/Contents/MacOS/OmniBar --once` prints the rows and exits, which is handy for checking the
token and URL.
