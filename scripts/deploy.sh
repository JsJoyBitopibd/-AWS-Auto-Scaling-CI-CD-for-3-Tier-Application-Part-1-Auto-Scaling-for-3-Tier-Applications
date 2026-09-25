#!/bin/bash
# =====================================================================
#  Bitopi pull-based deployer  -  /opt/deploy/deploy.sh
#  Runs at boot and every 60 s (systemd timer). Fetches the release for
#  its track from GitHub, and if the VERSION differs from what is running,
#  installs it and restarts the app.  No AWS credentials required.
#
#  DEPLOY_TRACK=latest   -> newest stable GitHub Release   (BLUE fleet)
#  DEPLOY_TRACK=v1.2.0   -> that exact tag, even a pre-release (GREEN fleet)
# =====================================================================
set -uo pipefail
REPO="Joyanta2934/AWS-Auto-Scaling-CI-CD-for-3-Tier-Application-Part-1-Auto-Scaling-for-3-Tier-Applications"
TRACK="${DEPLOY_TRACK:-latest}"
APP_DIR=/opt/app
LOG=/var/log/bitopi-deploy.log
exec >>"$LOG" 2>&1

if [ "$TRACK" = "latest" ]; then
  URL="https://github.com/$REPO/releases/latest/download/bitopi-app.zip"
else
  URL="https://github.com/$REPO/releases/download/$TRACK/bitopi-app.zip"
fi

TMP=$(mktemp -d)
if ! curl -fsSL --retry 3 -o "$TMP/app.zip" "$URL"; then
  echo "$(date -Is) [$TRACK] download failed: $URL"; rm -rf "$TMP"; exit 0
fi
unzip -q -o "$TMP/app.zip" -d "$TMP/app"
NEW=$(cat "$TMP/app/VERSION")
CUR=$(cat "$APP_DIR/VERSION" 2>/dev/null || echo "none")

if [ "$NEW" = "$CUR" ]; then rm -rf "$TMP"; exit 0; fi   # nothing to do

echo "$(date -Is) [$TRACK] deploying $CUR -> $NEW"
mkdir -p "$APP_DIR"
cp -r "$TMP/app/." "$APP_DIR/"            # .env is not in the zip, so it is preserved
cd "$APP_DIR" && npm install --omit=dev --no-audit --no-fund
systemctl restart bitopi-app
echo "$(date -Is) [$TRACK] deployed $NEW (commit $(cat "$APP_DIR/COMMIT" 2>/dev/null))"
rm -rf "$TMP"
