// Application tests run by the CI pipeline (npm test).
// Uses Node's built-in test runner - no extra dependencies.
const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const app = require('../app');
const pkg = require('../package.json');

const server = app.listen(0);                       // random free port, no DB needed
const base = () => `http://127.0.0.1:${server.address().port}`;
after(() => server.close());

test('GET /health returns 200 and status "healthy"', async () => {
  const res = await fetch(`${base()}/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.status, 'healthy');
  assert.ok(body.instance, 'instance id present');
});

test('GET /version reports the package.json version', async () => {
  const res = await fetch(`${base()}/version`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.version, pkg.version);
});

test('GET / renders the page even when the database is unreachable', async () => {
  const res = await fetch(`${base()}/`);
  assert.equal(res.status, 200);
  const html = await res.text();
  assert.match(html, /Bitopi 3-Tier Application/);
  assert.match(html, new RegExp(`v${pkg.version.replace(/\./g, '\\.')}`));
});
