// Broker smoke test: spins a mock SnapTrade token endpoint, points the broker at it,
// and asserts Basic-auth injection, grant filtering, passthrough, and /healthz.
// Run: node broker/smoke-test.mjs
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { connect } from "node:net";
import { setTimeout as sleep } from "node:timers/promises";
import assert from "node:assert/strict";

const seen = [];
const mock = createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  seen.push({
    path: req.url,
    auth: req.headers.authorization,
    body: new URLSearchParams(Buffer.concat(chunks).toString()),
  });
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end('{"access_token":"AT","refresh_token":"RT","expires_in":3600}');
});
mock.listen(0);
await once(mock, "listening");
const mockPort = mock.address().port;

const broker = spawn(process.execPath, [new URL("./server.mjs", import.meta.url).pathname], {
  env: {
    ...process.env,
    SNAPTRADE_CLIENT_ID: "cid",
    SNAPTRADE_CLIENT_SECRET: "sec",
    TOKEN_URL: `http://127.0.0.1:${mockPort}/oauth/token/`,
    REVOKE_URL: `http://127.0.0.1:${mockPort}/oauth/revoke_token/`,
    PORT: "0",
  },
  stdio: ["ignore", "pipe", "inherit"],
});
const line = await new Promise(resolve => broker.stdout.once("data", d => resolve(d.toString())));
const port = Number(line.match(/:(\d+)/)[1]);
const base = `http://127.0.0.1:${port}`;
const form = (o) => new URLSearchParams(o).toString();
const post = (path, body) => fetch(`${base}${path}`, {
  method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
});

try {
  // healthz
  assert.equal((await fetch(`${base}/healthz`)).status, 200);

  // authorization_code exchange: forwarded with Basic auth, client_id forced, secret stripped
  const r1 = await post("/token", form({
    grant_type: "authorization_code", code: "C", code_verifier: "V",
    redirect_uri: "http://127.0.0.1:8765/callback", client_id: "spoofed", client_secret: "leak",
  }));
  assert.equal(r1.status, 200);
  assert.deepEqual(await r1.json(), { access_token: "AT", refresh_token: "RT", expires_in: 3600 });
  const f1 = seen.at(-1);
  assert.equal(f1.path, "/oauth/token/");
  assert.equal(f1.auth, "Basic " + Buffer.from("cid:sec").toString("base64"));
  assert.equal(f1.body.get("client_id"), "cid");
  assert.equal(f1.body.get("client_secret"), null);
  assert.equal(f1.body.get("code_verifier"), "V");

  // refresh passthrough
  assert.equal((await post("/token", form({ grant_type: "refresh_token", refresh_token: "RT" }))).status, 200);

  // disallowed grant + unknown path + wrong method
  assert.equal((await post("/token", form({ grant_type: "client_credentials" }))).status, 400);
  assert.equal((await post("/nope", "")).status, 404);
  assert.equal((await fetch(`${base}/token`)).status, 405);

  // revoke forwarded to the revoke upstream
  assert.equal((await post("/revoke", form({ token: "RT" }))).status, 200);
  assert.equal(seen.at(-1).path, "/oauth/revoke_token/");

  // oversized body → 413, connection handled cleanly
  const big = form({ grant_type: "refresh_token", refresh_token: "x".repeat(70 * 1024) });
  assert.equal((await post("/token", big)).status, 413);

  // client hangs up mid-body: must NOT kill the process (async iterator rejection)
  for (const graceful of [false, true]) {
    const sock = connect(port, "127.0.0.1");
    await once(sock, "connect");
    sock.write("POST /token HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\n\r\ngrant_type=");
    await sleep(100);
    graceful ? sock.end() : sock.destroy();
  }
  await sleep(300);
  assert.equal(broker.exitCode, null, "broker died on client abort");
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  assert.equal((await post("/token", form({ grant_type: "refresh_token", refresh_token: "RT" }))).status, 200);

  assert.equal(broker.exitCode, null, "broker exited during the test run");
  console.log("smoke test: all assertions passed");
} finally {
  broker.kill();
  mock.close();
}
