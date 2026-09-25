#!/bin/bash
# =====================================================================
#  Bitopi 3-Tier  -  APP SERVER user-data  v2  (BLUE environment)
#  Part 2: the app is no longer embedded here. Every server installs a
#  pull-based deployer that fetches the app from GitHub Releases:
#    - at boot   -> a brand-new Auto Scaling instance gets the current
#                   release before its first health check
#    - every 60s -> a new release rolls out with no AWS action at all
#  DEPLOY_TRACK: latest = newest stable release  |  vX.Y.Z = pinned tag
# =====================================================================
exec > >(tee /var/log/user-data.log) 2>&1
set -x

# 1) Runtime + tools
dnf install -y nodejs unzip

# 2) Who am I? (IMDSv2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

mkdir -p /opt/app /opt/deploy

# 3) App configuration (never inside the release zip, so deploys keep it)
cat >/opt/app/.env <<ENV
PORT=3000
INSTANCE_ID=$IID
AZ=$AZ
ENV_COLOR=blue
DB_HOST=10.0.13.216
DB_USER=appuser
DB_PASS=Bitopi#Db2026
DB_NAME=appdb
DB_PORT=3306
ENV

# 4) Which release track this environment follows
cat >/opt/deploy/deploy.env <<ENV
DEPLOY_TRACK=latest
ENV

# 5) The deployer (identical to scripts/deploy.sh in the repo)
cat >/opt/deploy/deploy.sh <<'DEPLOY'
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
DEPLOY
chmod +x /opt/deploy/deploy.sh

# 6) systemd: the app service, and the deploy timer that checks every minute
cat >/etc/systemd/system/bitopi-app.service <<'SVC'
[Unit]
Description=Bitopi 3-Tier App
After=network-online.target
[Service]
EnvironmentFile=/opt/app/.env
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=root
[Install]
WantedBy=multi-user.target
SVC

cat >/etc/systemd/system/bitopi-deploy.service <<'SVC'
[Unit]
Description=Bitopi pull-based deployer (fetch release, install if new)
[Service]
Type=oneshot
EnvironmentFile=/opt/deploy/deploy.env
ExecStart=/opt/deploy/deploy.sh
SVC

cat >/etc/systemd/system/bitopi-deploy.timer <<'TMR'
[Unit]
Description=Check GitHub Releases for a new app version every 60 seconds
[Timer]
OnBootSec=45
OnUnitActiveSec=60
AccuracySec=5
[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload

# 7) First deploy NOW, so the app is running before the ALB health checks start
set -a; . /opt/deploy/deploy.env; set +a
/opt/deploy/deploy.sh

systemctl enable --now bitopi-app
systemctl enable --now bitopi-deploy.timer
echo "===== Bitopi app server (blue, track=latest) ready ====="
