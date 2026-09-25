#!/bin/bash
# =====================================================================
#  Bitopi 3-Tier Assignment  -  APPLICATION (BACKEND) SERVER user-data
#  Runs on first boot of every Auto Scaling instance. It:
#    1) installs Node.js
#    2) reads this instance's ID + AZ from the metadata service
#    3) writes the app + its config
#    4) installs dependencies and starts the app as a systemd service
#  Result: an identical, self-configuring backend server every time.
# =====================================================================
exec > >(tee /var/log/user-data.log) 2>&1
set -x

# 1) Install Node.js (npm comes bundled)
dnf install -y nodejs

# 2) Read instance metadata (IMDSv2 - token first, then query)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/placement/availability-zone)

# 3) Create the app
mkdir -p /opt/app

cat >/opt/app/package.json <<'PKG'
{
  "name": "bitopi-3tier-app",
  "version": "1.0.0",
  "main": "app.js",
  "dependencies": { "express": "^4.18.2", "mysql2": "^3.6.5" }
}
PKG

cat >/opt/app/app.js <<'APP'
const express = require('express');
const os = require('os');
const mysql = require('mysql2/promise');
const app = express();
const PORT = process.env.PORT || 3000;
const INSTANCE_ID = process.env.INSTANCE_ID || os.hostname();
const AZ = process.env.AZ || 'unknown';
const dbConfig = {
  host: process.env.DB_HOST, user: process.env.DB_USER,
  password: process.env.DB_PASS, database: process.env.DB_NAME,
  port: Number(process.env.DB_PORT) || 3306, connectTimeout: 5000,
};
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy', instance: INSTANCE_ID, az: AZ });
});
app.get('/', async (req, res) => {
  let dbStatus='DOWN', dbInfo='', visitCount=null, dbError='';
  try {
    const conn = await mysql.createConnection(dbConfig);
    await conn.execute('INSERT INTO visits (hostname) VALUES (?)', [os.hostname()]);
    const [infoRows] = await conn.query('SELECT info FROM app_info WHERE id=1');
    const [cntRows]  = await conn.query('SELECT COUNT(*) AS c FROM visits');
    dbInfo = infoRows.length ? infoRows[0].info : '(no info row)';
    visitCount = cntRows[0].c; dbStatus='CONNECTED'; await conn.end();
  } catch (e) { dbError = e.message; }
  res.status(200).send(`<!doctype html>
<html><head><meta charset="utf-8"><title>Bitopi 3-Tier App</title>
<style>body{font-family:'Segoe UI',Arial,sans-serif;margin:0;background:#0f172a;color:#e2e8f0}
.card{max-width:680px;margin:40px auto;background:#1e293b;border-radius:14px;padding:28px 32px;box-shadow:0 10px 30px rgba(0,0,0,.4)}
h1{margin:0 0 6px;color:#38bdf8}.k{color:#94a3b8}.v{color:#f8fafc;font-weight:600}
.row{display:flex;justify-content:space-between;padding:10px 0;border-bottom:1px solid #334155}
.ok{color:#34d399;font-weight:700}.bad{color:#f87171;font-weight:700}
.badge{display:inline-block;background:#0ea5e9;color:#08131f;padding:2px 10px;border-radius:20px;font-size:12px;font-weight:700;margin-bottom:14px}</style>
</head><body><div class="card"><h1>Bitopi 3-Tier Application</h1>
<span class="badge">BACKEND TIER &middot; AUTO SCALING</span>
<div class="row"><span class="k">Served by instance</span><span class="v">${INSTANCE_ID}</span></div>
<div class="row"><span class="k">Availability Zone</span><span class="v">${AZ}</span></div>
<div class="row"><span class="k">Hostname</span><span class="v">${os.hostname()}</span></div>
<div class="row"><span class="k">Database (Tier 3)</span><span class="${dbStatus==='CONNECTED'?'ok':'bad'}">${dbStatus}</span></div>
${dbStatus==='CONNECTED'
  ? `<div class="row"><span class="k">DB message</span><span class="v">${dbInfo}</span></div>
     <div class="row"><span class="k">Total visits recorded</span><span class="v">${visitCount}</span></div>`
  : `<div class="row"><span class="k">DB error</span><span class="bad">${dbError}</span></div>`}
<p style="color:#64748b;margin-top:18px;font-size:13px">Refresh &mdash; the load balancer may route you to a different instance. Every visit is written to MySQL, proving the Backend &rarr; Database link.</p>
</div></body></html>`);
});
app.listen(PORT, () => console.log(`Bitopi app listening on port ${PORT}`));
APP

# 4) Config (environment variables the app reads)
cat >/opt/app/.env <<ENV
PORT=3000
INSTANCE_ID=$IID
AZ=$AZ
DB_HOST=10.0.13.216
DB_USER=appuser
DB_PASS=Bitopi#Db2026
DB_NAME=appdb
DB_PORT=3306
ENV

# 5) Install dependencies + run as a service
cd /opt/app && npm install --omit=dev

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

systemctl daemon-reload
systemctl enable --now bitopi-app
echo "===== Bitopi app started on port 3000 ====="
