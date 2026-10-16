#!/bin/sh
# Builds a clean copy of server/ as its own git repo with one commit, ready to push as proviyaaretailtech/pos-server. Pushes nothing.
# Usage: scripts/make-vercel-snapshot.sh <target folder, must not exist or be empty>
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?usage: make-vercel-snapshot.sh <target folder>}"
[ -d "$DEST" ] && [ -n "$(ls -A "$DEST")" ] && { echo "refusing: $DEST is not empty"; exit 1; }
mkdir -p "$DEST"
# Only what the deployed server and its docs need. Test scripts that touch the local Docker database (scripts/) stay out.
for f in package.json package-lock.json tsconfig.json vercel.json vercel-README.md README.md ENDPOINTS.md .env.example .gitignore; do cp "$SRC/$f" "$DEST/$f"; done
cp -R "$SRC/src" "$SRC/public" "$DEST/"
mkdir -p "$DEST/tests" && cp -R "$SRC/tests/unit" "$DEST/tests/"
# nothing secret may travel
if find "$DEST" -name '.env' -o -name '.env.local' -o -name node_modules | grep -q .; then echo "refusing: secret or dependency folder found"; exit 1; fi
if grep -rEl 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|sb_secret_[A-Za-z0-9]|sbp_[A-Za-z0-9]{20,}' "$DEST" >/dev/null 2>&1; then echo "refusing: something that looks like a key is in the snapshot"; exit 1; fi
cd "$DEST"
git init -q -b main
git add -A
GIT_AUTHOR_NAME=proviyaaretailtech GIT_AUTHOR_EMAIL=339435687+proviyaaretailtech@users.noreply.github.com \
GIT_COMMITTER_NAME=proviyaaretailtech GIT_COMMITTER_EMAIL=339435687+proviyaaretailtech@users.noreply.github.com \
git commit -q -m "VINII POS server: one generic /rpc endpoint, Vercel entry"
echo "snapshot ready in $DEST (1 commit, author proviyaaretailtech). Create proviyaaretailtech/pos-server on GitHub and push it yourself."
