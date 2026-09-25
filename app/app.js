// =====================================================================
//  Bitopi 3-Tier Application  -  Backend (Application Tier)
//  v1.1.0  -  now deployed by the CI/CD pipeline (GitHub Actions ->
//  GitHub Release -> pull-based deployer on every Auto Scaling instance)
//
//    GET /health   shallow liveness check used by the ALB target group
//    GET /version  which build is running (used to verify deployments)
//    GET /         shows which server replied, its environment colour,
//                  and live data from the MySQL database (Tier 3)
// =====================================================================
const express = require('express');
const os = require('os');
const mysql = require('mysql2/promise');

const app = express();
const PORT        = process.env.PORT || 3000;
const INSTANCE_ID = process.env.INSTANCE_ID || os.hostname();
const AZ          = process.env.AZ || 'unknown';
const ENV_COLOR   = (process.env.ENV_COLOR || 'blue').toLowerCase();   // blue | green
const APP_VERSION = require('./package.json').version;

const dbConfig = {
  host: process.env.DB_HOST, user: process.env.DB_USER,
  password: process.env.DB_PASS, database: process.env.DB_NAME,
  port: Number(process.env.DB_PORT) || 3306, connectTimeout: 5000,
};

// ---- /health : shallow on purpose (app alive, NOT a DB check) so a brief
//      DB blip never makes the whole fleet unhealthy at once ----
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy', version: APP_VERSION, env: ENV_COLOR,
                         instance: INSTANCE_ID, az: AZ });
});

// ---- /version : the one-line answer to "what is deployed right now?" ----
app.get('/version', (req, res) => {
  res.status(200).json({ version: APP_VERSION, env: ENV_COLOR, instance: INSTANCE_ID });
});

// ---- / : proves the full 3-tier round trip ----
app.get('/', async (req, res) => {
  let dbStatus = 'DOWN', dbInfo = '', visitCount = null, dbError = '';
  try {
    const conn = await mysql.createConnection(dbConfig);
    await conn.execute('INSERT INTO visits (hostname) VALUES (?)', [os.hostname()]);
    const [infoRows] = await conn.query('SELECT info FROM app_info WHERE id=1');
    const [cntRows]  = await conn.query('SELECT COUNT(*) AS c FROM visits');
    dbInfo = infoRows.length ? infoRows[0].info : '(no info row)';
    visitCount = cntRows[0].c; dbStatus = 'CONNECTED'; await conn.end();
  } catch (e) { dbError = e.message; }

  const accent = ENV_COLOR === 'green' ? '#34d399' : '#38bdf8';
  res.status(200).send(`<!doctype html>
<html><head><meta charset="utf-8"><title>Bitopi 3-Tier App ${APP_VERSION}</title>
<style>
body{font-family:'Segoe UI',Arial,sans-serif;margin:0;background:#0f172a;color:#e2e8f0}
.card{max-width:680px;margin:40px auto;background:#1e293b;border-radius:14px;padding:28px 32px;box-shadow:0 10px 30px rgba(0,0,0,.4);border-top:6px solid ${accent}}
h1{margin:0 0 6px;color:${accent}}.k{color:#94a3b8}.v{color:#f8fafc;font-weight:600}
.row{display:flex;justify-content:space-between;padding:10px 0;border-bottom:1px solid #334155}
.ok{color:#34d399;font-weight:700}.bad{color:#f87171;font-weight:700}
.badge{display:inline-block;background:${accent};color:#08131f;padding:2px 10px;border-radius:20px;font-size:12px;font-weight:700;margin:0 6px 14px 0}
.ver{font-size:26px;font-weight:800;color:${accent}}
</style></head><body><div class="card">
<h1>Bitopi 3-Tier Application</h1>
<span class="badge">BACKEND TIER &middot; AUTO SCALING</span><span class="badge">${ENV_COLOR.toUpperCase()} ENVIRONMENT</span>
<div class="row"><span class="k">Application version</span><span class="ver">v${APP_VERSION}</span></div>
<div class="row"><span class="k">Environment</span><span class="v">${ENV_COLOR}</span></div>
<div class="row"><span class="k">Served by instance</span><span class="v">${INSTANCE_ID}</span></div>
<div class="row"><span class="k">Availability Zone</span><span class="v">${AZ}</span></div>
<div class="row"><span class="k">Hostname</span><span class="v">${os.hostname()}</span></div>
<div class="row"><span class="k">Database (Tier 3)</span><span class="${dbStatus==='CONNECTED'?'ok':'bad'}">${dbStatus}</span></div>
${dbStatus==='CONNECTED'
  ? `<div class="row"><span class="k">DB message</span><span class="v">${dbInfo}</span></div>
     <div class="row"><span class="k">Total visits recorded</span><span class="v">${visitCount}</span></div>`
  : `<div class="row"><span class="k">DB error</span><span class="bad">${dbError}</span></div>`}
<p style="color:#64748b;margin-top:18px;font-size:13px">Deployed by GitHub Actions &rarr; GitHub Release &rarr; pull-based deployer on this server. Refresh to be routed to another instance.</p>
</div></body></html>`);
});

// Only start listening when run directly (tests import the app instead)
if (require.main === module) {
  app.listen(PORT, () => console.log(`Bitopi app v${APP_VERSION} (${ENV_COLOR}) listening on port ${PORT}`));
}
module.exports = app;
