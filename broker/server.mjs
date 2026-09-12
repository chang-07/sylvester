// Sylvester token broker.
//
// SnapTrade's dashboard-issued OAuth apps are CONFIDENTIAL clients: the token endpoint
// requires the client secret via HTTP Basic auth, and a distributed native app cannot
// hold a secret. This service is the missing half of that client — it forwards /token
// and /revoke to SnapTrade with the client credentials attached, exactly as the docs
// prescribe ("send the authorization result to a backend that performs the token
// exchange"). PKCE still binds each exchange to the app instance that started it.
//
// Stateless by construction: no storage, and nothing secret is ever logged — tokens,
// codes, and verifiers pass straight through. The only secret at rest is the client
// secret in the environment.
//
//   SNAPTRADE_CLIENT_ID / SNAPTRADE_CLIENT_SECRET   required
//   TOKEN_URL / REVOKE_URL                          default to SnapTrade prod
//   PORT                                            default 8080

import { createServer } from "node:http";

const {
  SNAPTRADE_CLIENT_ID: CLIENT_ID,
  SNAPTRADE_CLIENT_SECRET: CLIENT_SECRET,
  TOKEN_URL = "https://api.snaptrade.com/oauth/token/",
  REVOKE_URL = "https://api.snaptrade.com/oauth/revoke_token/",
  PORT = 8080,
} = process.env;

if (!CLIENT_ID || !CLIENT_SECRET) {
  console.error("SNAPTRADE_CLIENT_ID and SNAPTRADE_CLIENT_SECRET are required");
  process.exit(1);
}

const UPSTREAMS = { "/token": TOKEN_URL, "/revoke": REVOKE_URL };
const ALLOWED_GRANTS = new Set(["authorization_code", "refresh_token"]);
const MAX_BODY = 64 * 1024;
const basicAuth = "Basic " + Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString("base64");

function respond(res, status, body, type = "application/json") {
  res.writeHead(status, { "Content-Type": type });
  res.end(body);
}

// Per-IP token bucket. The broker signs whatever it forwards with the shared client
// credential, so unthrottled garbage sprays would arrive at SnapTrade as OUR traffic —
// risking the one client id getting flagged, which would break refresh for every
// install at once. Sign-in + refresh needs single-digit requests per user per day;
// 20 burst / 20-per-minute refill is generous for real use and useless for abuse.
const BUCKET = { capacity: 20, refillPerSec: 20 / 60 };
const buckets = new Map();
function allowed(ip) {
  const now = Date.now() / 1000;
  const b = buckets.get(ip) ?? { tokens: BUCKET.capacity, ts: now };
  b.tokens = Math.min(BUCKET.capacity, b.tokens + (now - b.ts) * BUCKET.refillPerSec);
  b.ts = now;
  const ok = b.tokens >= 1;
  if (ok) b.tokens -= 1;
  buckets.set(ip, b);
  return ok;
}
setInterval(() => {
  const stale = Date.now() / 1000 - 300;
  for (const [ip, b] of buckets) if (b.ts < stale) buckets.delete(ip);
}, 60_000).unref();

// A client hanging up mid-body makes the request stream's async iterator reject;
// without this catch-all that rejection is unhandled and kills the whole process
// (one truncated POST from an internet scanner = broker down).
const server = createServer((req, res) => {
  handle(req, res).catch(() => {
    req.destroy();
    res.destroy();
  });
});

async function handle(req, res) {
  const path = new URL(req.url, "http://x").pathname.replace(/\/$/, "");
  if (req.method === "GET" && path === "/healthz") return respond(res, 200, "ok", "text/plain");
  const upstream = UPSTREAMS[path];
  if (!upstream) return respond(res, 404, '{"error":"not_found"}');
  if (req.method !== "POST") return respond(res, 405, '{"error":"method_not_allowed"}');
  const ip = req.headers["fly-client-ip"] ?? req.socket.remoteAddress ?? "?";
  if (!allowed(ip)) return respond(res, 429, '{"error":"rate_limited"}');

  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) return respond(res, 413, '{"error":"body_too_large"}');
    chunks.push(chunk);
  }

  const form = new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
  if (path === "/token" && !ALLOWED_GRANTS.has(form.get("grant_type"))) {
    return respond(res, 400, '{"error":"unsupported_grant_type"}');
  }
  // The credentials are ours regardless of what the app sent; keep body and Basic
  // auth consistent so oauthlib never sees a client-id mismatch.
  form.set("client_id", CLIENT_ID);
  form.delete("client_secret");

  try {
    const out = await fetch(upstream, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Authorization: basicAuth,
      },
      body: form.toString(),
      signal: AbortSignal.timeout(15_000),
    });
    respond(res, out.status, await out.text(), out.headers.get("content-type") ?? "application/json");
  } catch {
    respond(res, 502, '{"error":"upstream_unreachable"}');
  }
}

server.listen(PORT, () => console.log(`sylvester broker listening on :${server.address().port}`));
