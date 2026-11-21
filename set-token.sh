#!/bin/sh
# Store an OmniRoute access token in the login keychain (generic password, service
# omniroute-bar), where OmniBar reads it. The token is never printed or passed as an argument.
#
#   ./set-token.sh
#       Paste a token (input hidden). Create one in the OmniRoute dashboard under
#       Settings → Access Tokens with scope "read".
#   ./set-token.sh --mint HOST [ENV_FILE] [NAME]
#       Mint a read-scoped token over `ssh HOST` against OmniRoute on that host
#       (http://127.0.0.1:20128). It uses the manage-scoped OMNIROUTE_API_KEY from ENV_FILE,
#       a path on HOST relative to its home (default .env). NAME defaults to omnibar.
set -eu

# A heredoc inside $(...) trips bash 3.2 (/bin/sh) on the quotes below, so wrap it in a function.
mint() {
ssh "$1" "python3 - '$3' '$2'" <<'PY'
import json, os, re, sys, urllib.request
name, env_file = sys.argv[1], os.path.expanduser(sys.argv[2])
key = re.search(r"""^(?:export\s+)?OMNIROUTE_API_KEY=["']?([^"'\n]+)""", open(env_file).read(), re.M).group(1)
req = urllib.request.Request(
    "http://127.0.0.1:20128/api/cli/tokens", method="POST",
    data=json.dumps({"name": name, "scope": "read"}).encode(),
    headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
body = json.load(urllib.request.urlopen(req, timeout=15))

def walk(v):
    if isinstance(v, dict):
        yield v
        for x in v.values(): yield from walk(x)
    elif isinstance(v, list):
        for x in v: yield from walk(x)

secret = next((s for d in walk(body) for s in d.values()
               if isinstance(s, str) and s.startswith("oma_live_")), None)
safe = ("id", "name", "scope", "prefix", "displayPrefix", "createdAt", "expiresAt")
meta = {k: v for d in walk(body) for k, v in d.items() if k in safe and not str(v).startswith("oma_live_")}
print("created " + json.dumps(meta), file=sys.stderr)
if secret: print(secret)
PY
}

NAME=omnibar
if [ "${1:-}" = --mint ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 --mint HOST [ENV_FILE] [NAME]" >&2; exit 2; }
  NAME=${4:-omnibar}
  TOKEN=$(mint "$2" "${3:-.env}" "$NAME") || TOKEN=
else
  printf 'OmniRoute access token (input hidden): ' >&2
  stty -echo 2>/dev/null || true
  read -r TOKEN || true
  stty echo 2>/dev/null || true
  echo >&2
fi
[ -n "${TOKEN:-}" ] || { echo "no token; nothing stored" >&2; exit 1; }

# Keep exactly one item, so OmniBar never picks up a stale token.
while security delete-generic-password -s omniroute-bar >/dev/null 2>&1; do :; done
# security -i reads the command from stdin, so the token never shows up in ps.
printf 'add-generic-password -s omniroute-bar -a %s -l OmniBar -w %s\n' "$NAME" "$TOKEN" | security -i >/dev/null
unset TOKEN
security find-generic-password -s omniroute-bar >/dev/null && echo "stored in the keychain (service omniroute-bar, account $NAME)"
