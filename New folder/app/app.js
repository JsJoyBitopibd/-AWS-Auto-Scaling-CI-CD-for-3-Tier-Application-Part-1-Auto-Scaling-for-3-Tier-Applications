// =====================================================================
//  Bitopi 3-Tier Application  -  Backend (Application Tier)
//  A small Express app that:
//    - answers  GET /health   (shallow liveness check for the ALB)
//    - answers  GET /          (shows which server replied + live DB data)
//  It connects to the MySQL database (Data Tier) over the network on 3306.
// =====================================================================
const express = require('express');
const os = require('os');
const mysql = require('mysql2/promise');

const app = express();
const PORT = process.env.PORT || 3000;
const INSTANCE_ID = process.env.INSTANCE_ID || os.hostname();
const AZ = process.env.AZ || 'unknown';

const dbConfig = {
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  port: Number(process.env.DB_PORT) || 3306,
  connectTimeout: 5000,
};

// ---- /health : used by the ALB Target Group. Stays shallow on purpose ----
// (app-alive only, NOT a DB check) so a brief DB blip never makes the whole
// fleet unhealthy. DB health is shown separately on the home page.
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy', instance: INSTANCE_ID, az: AZ });
});

// ---- / : home page, proves the full 3-tier round trip ----
app.get('/', async (req, res) => {
  let dbStatus = 'DOWN', dbInfo = '', visitCount = null, dbError = '';
  try {
    const conn = await mysql.createConnection(dbConfig);
    await conn.execute('INSERT INTO visits (hostname) VALUES (?)', [os.hostname()]);
    const [infoRows] = await conn.query('SELECT info FROM app_info WHERE id=1');
    const [cntRows]  = await conn.query('SELECT COUNT(*) AS c FROM visits');
    dbInfo = infoRows.length ? infoRows[0].info : '(no info row)';
    visitCount = cntRows[0].c;
    dbStatus = 'CONNECTED';
    await conn.end();
  } catch (e) {
    dbError = e.message;
  }

  res.status(200).send(`<!doctype html>
<html><head><meta charset="utf-8"><title>Bitopi 3-Tier App</title>
<style>
body{font-family:'Segoe UI',Arial,sans-serif;margin:0;background:#0f172a;color:#e2e8f0}
.card{max-width:680px;margin:40px auto;background:#1e293b;border-radius:14px;padding:28px 32px;box-shadow:0 10px 30px rgba(0,0,0,.4)}
h1{margin:0 0 6px;color:#38bdf8}
.k{color:#94a3b8}.v{color:#f8fafc;font-weight:600}
.row{display:flex;justify-content:space-between;padding:10px 0;border-bottom:1px solid #334155}
.ok{color:#34d399;font-weight:700}.bad{color:#f87171;font-weight:700}
.badge{display:inline-block;background:#0ea5e9;color:#08131f;padding:2px 10px;border-radius:20px;font-size:12px;font-weight:700;margin-bottom:14px}
</style></head><body><div class="card">
<h1>Bitopi 3-Tier Application</h1>
<span class="badge">BACKEND TIER &middot; AUTO SCALING</span>
<div class="row"><span class="k">Served by instance</span><span class="v">${INSTANCE_ID}</span></div>
<div class="row"><span class="k">Availability Zone</span><span class="v">${AZ}</span></div>
<div class="row"><span class="k">Hostname</span><span class="v">${os.hostname()}</span></div>
<div class="row"><span class="k">Database (Tier 3)</span><span class="${dbStatus==='CONNECTED'?'ok':'bad'}">${dbStatus}</span></div>
${dbStatus==='CONNECTED'
  ? `<div class="row"><span class="k">DB message</span><span class="v">${dbInfo}</span></div>
     <div class="row"><span class="k">Total visits recorded</span><span class="v">${visitCount}</span></div>`
  : `<div class="row"><span class="k">DB error</span><span class="bad">${dbError}</span></div>`}
<p style="color:#64748b;margin-top:18px;font-size:13px">Refresh the page &mdash; the load balancer may route you to a different instance (notice the instance ID change). Every visit is written to the MySQL database, proving the Backend &rarr; Database link.</p>
</div></body></html>`);
});

app.listen(PORT, () => console.log(`Bitopi app listening on port ${PORT}`));
