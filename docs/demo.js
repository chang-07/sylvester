// Sylvester live demo — a click-through recreation of the app popover with example data.
// All figures are synthetic; layout, copy, and behavior mirror the real app.
(() => {
  "use strict";
  const root = document.getElementById("sylvester-demo");
  if (!root) return;

  // ── example dataset (matches the demo portfolio used in the screenshots) ──
  const CAD = 0.723; // demo FX rate
  const ACCOUNTS = [
    { inst: "Fidelity", name: "Individual", num: "2241", cur: "USD", cash: 3002.84, total: 84512.34,
      holdings: [["VTI", 145, 296.40, 0.62], ["AAPL", 120, 232.10, 1.84], ["NVDA", 62, 172.25, 2.31]] },
    { inst: "Fidelity", name: "Roth IRA", num: "8874", cur: "USD", cash: 649.59, total: 46220.19,
      holdings: [["VOO", 72, 558.30, 0.58], ["SCHD", 180, 29.85, -0.21]] },
    { inst: "Wealthsimple", name: "TFSA", num: "4832", cur: "CAD", cash: 1607.66, total: 41930.66,
      holdings: [["VFV.TO", 210, 151.20, 0.71], ["SHOP.TO", 60, 142.85, 3.12]] },
    { inst: "Robinhood", name: "Individual", num: "0925", cur: "USD", cash: 213.22, total: 12884.02,
      holdings: [["TSLA", 28, 342.60, -1.47], ["VXUS", 45, 68.40, 0.33]] },
  ];
  const NET = 173873.92, DELTA = 2121.85, DELTA_PCT = 1.24;

  const SERIES = ["#618CFA", "#4ACAAD", "#FAB852", "#F07087", "#A887F5", "#5CC4F7", "#ABD975", "#F28F5C"];
  const SLATE = "#98A2B0";

  const ALLOC = {
    Asset: [["VTI", 42978], ["VOO", 40198], ["AAPL", 27852], ["VFV.TO", 22957], ["NVDA", 10680],
            ["TSLA", 9593], ["SHOP.TO", 6197], ["SCHD", 5373], ["Other", 8046]],
    Account: [["Individual ••2241", 84512], ["Roth IRA ••8874", 46220], ["TFSA ••4832", 30316], ["Individual ••0925", 12884]],
    Currency: [["USD", 143617], ["CAD", 30316]],
  };

  const day = 86400e3;
  const D = (n) => new Date(Date.now() - n * day);
  const ACTS = [
    { d: 2,  t: "income", ic: "$", c: "#219947", ttl: "Dividend · SCHD", sub: "Roth IRA ••8874", amt: 48.60, cur: "USD" },
    { d: 5,  t: "trade",  ic: "↓", c: "#007AFF", ttl: "Bought 5 AAPL", sub: "Individual ••2241", amt: -1157.00, cur: "USD" },
    { d: 8,  t: "cash",   ic: "+", c: "#219947", ttl: "Contribution", sub: "TFSA ••4832", amt: 500.00, cur: "CAD" },
    { d: 12, t: "income", ic: "$", c: "#219947", ttl: "Dividend · VOO", sub: "Roth IRA ••8874", amt: 96.12, cur: "USD" },
    { d: 13, t: "income", ic: "$", c: "#219947", ttl: "Dividend · VTI", sub: "Individual ••2241", amt: 151.75, cur: "USD" },
    { d: 19, t: "trade",  ic: "↓", c: "#007AFF", ttl: "Bought 12 VFV.TO", sub: "TFSA ••4832", amt: -1797.60, cur: "CAD" },
    { d: 26, t: "cash",   ic: "●", c: "#98A2B0", ttl: "Cash interest", sub: "Individual ••0925", amt: 1.87, cur: "USD" },
  ];

  // deterministic 1Y daily net-worth series ending at NET
  const walk = (() => {
    let seed = 42;
    const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
    const pts = [];
    let v = 151400;
    for (let i = 365; i >= 0; i--) {
      v += v * (rnd() - 0.472) * 0.006;
      pts.push(v);
    }
    const scale = NET / pts[pts.length - 1];
    return pts.map((p) => p * scale);
  })();
  const RANGES = { "1D": 2, "1W": 7, "1M": 30, "3M": 91, "YTD": Math.floor((Date.now() - new Date(new Date().getFullYear(), 0, 1)) / day), "1Y": 365, "All": 365 };

  // ── state ──
  let privacy = false;
  let tab = "Accounts";
  let allocMode = "Asset", trendRange = "1M", actFilter = "All";
  const openAccts = new Set([0]);

  // ── formatting ──
  const money = (v, cur = "USD", compact = false) => {
    if (privacy) return "••••••";
    const prefix = (cur === "USD" ? "US$" : "$");
    if (compact) {
      const a = Math.abs(v), k = a / 1000;
      const s = a < 1000 ? a.toFixed(0) : k.toFixed(k >= 100 ? 0 : 1) + "k";
      return (v < 0 ? "-" : "") + "$" + s;
    }
    const s = Math.abs(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    return (v < 0 ? "-" : "") + prefix + s;
  };
  const usd = (a) => a.cur === "CAD" ? a.total * CAD : a.total;
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  const dayLabel = (d) => d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });

  // ── render ──
  const el = document.createElement("div");
  el.className = "demo";
  root.appendChild(el);

  function render() {
    el.innerHTML = `
      <div class="d-head">
        <div class="d-label"><span>Net worth</span>
          <span style="display:flex;align-items:center;gap:6px">updated just now
            <button class="d-eye" aria-label="Toggle privacy mode" data-act="privacy">${eyeSvg()}</button>
          </span>
        </div>
        <div class="d-value">${privacy ? "$••••••" : "$" + NET.toLocaleString("en-US", { minimumFractionDigits: 2 })}</div>
        <div class="d-delta">▲ ${privacy ? "$••• (•.••%)" : `$${DELTA.toLocaleString("en-US", { minimumFractionDigits: 2 })} (${DELTA_PCT}%)`} today</div>
      </div>
      <div class="d-tabs" role="tablist">
        ${["Accounts", "Allocation", "Trend", "Activity"].map((t) =>
          `<button class="d-tab${t === tab ? " on" : ""}" role="tab" data-tab="${t}">${t}${t === "Activity" ? '<span class="dot"></span>' : ""}</button>`).join("")}
      </div>
      <div class="d-body">${{ Accounts: accounts, Allocation: allocation, Trend: trend, Activity: activity }[tab]()}</div>
      <div class="d-foot">
        <button class="d-btn" data-act="connect">${plusSvg()} Connect Account</button>
        <button class="d-btn" data-act="refresh">${refreshSvg()} Refresh</button>
        <button class="d-more" data-act="connect" aria-label="More">⊙ ⌄</button>
        <div class="d-toast" id="d-toast"></div>
      </div>`;
  }

  function accounts() {
    const groups = [];
    for (const inst of [...new Set(ACCOUNTS.map((a) => a.inst))]) {
      const list = ACCOUNTS.filter((a) => a.inst === inst);
      const sum = list.reduce((s, a) => s + usd(a), 0);
      groups.push(`<div class="d-grp"><span>${inst}</span><span>${money(sum, "USD", true)}</span></div>` +
        list.map((a) => {
          const i = ACCOUNTS.indexOf(a);
          const open = openAccts.has(i);
          return `
          <button class="d-acct${open ? " open" : ""}" data-acct="${i}">
            ${chevSvg()}<span class="nm">${a.name} ••${a.num}</span>
            <span class="amt">${money(a.total, a.cur)}</span>
          </button>
          <div class="d-sub">live · feed synced 3 hrs ago</div>
          <div class="d-holdings">
            <div class="d-hold"><div><div class="t">Cash</div><div class="q">${a.cur}</div></div>
              <div class="right"><div class="v">${money(a.cash, a.cur)}</div></div></div>
            ${a.holdings.map(([t, q, p, chg]) => `
              <div class="d-hold">
                <div><div class="t">${t}</div><div class="q">${q} × ${money(p, a.cur)}</div></div>
                <div class="right"><div class="v">${money(q * p, a.cur)}</div>
                  <div class="chg ${chg >= 0 ? "up" : "down"}">${chg >= 0 ? "▲" : "▼"}${Math.abs(chg).toFixed(2)}% td</div></div>
              </div>`).join("")}
          </div>`;
        }).join(""));
    }
    return groups.join("");
  }

  function allocation() {
    const data = ALLOC[allocMode];
    const total = data.reduce((s, [, v]) => s + v, 0);
    const R = 60, CIRC = 2 * Math.PI * R;
    let off = 0;
    const segs = data.map(([label, v], i) => {
      const frac = v / total;
      const color = label === "Other" ? SLATE : SERIES[i % SERIES.length];
      const seg = `<circle r="${R}" cx="84" cy="84" fill="none" stroke="${color}" stroke-width="22"
        stroke-dasharray="${Math.max(frac * CIRC - 2.5, 0.8)} ${CIRC}" stroke-dashoffset="${-off * CIRC}"
        transform="rotate(-90 84 84)" stroke-linecap="butt"/>`;
      off += frac;
      return seg;
    }).join("");
    return `
      <div class="d-chips">${["Asset", "Account", "Currency"].map((m) =>
        `<button class="d-chip${m === allocMode ? " on" : ""}" data-alloc="${m}">${m}</button>`).join("")}</div>
      <div class="d-donut"><svg viewBox="0 0 168 168">${segs}</svg>
        <div class="c"><b>${money(total, "USD", true)}</b><span>${allocMode.toLowerCase()} mix</span></div></div>
      <div class="d-leg">${data.map(([label, v], i) => `
        <div class="d-leg-row">
          <span class="sw" style="background:${label === "Other" ? SLATE : SERIES[i % SERIES.length]}"></span>
          <span>${esc(label)}</span>
          <span class="lv">${money(v, "USD", true)}</span>
          <span class="lp">${(v / total * 100).toFixed(1)}%</span>
        </div>`).join("")}</div>`;
  }

  function trend() {
    const n = Math.min(RANGES[trendRange], walk.length - 1);
    const pts = walk.slice(walk.length - 1 - n);
    const first = pts[0], last = pts[pts.length - 1];
    const delta = last - first, pct = (delta / first) * 100;
    const lo = Math.min(...pts), hi = Math.max(...pts), pad = (hi - lo) * 0.15 || 1;
    const W = 328, H = 168;
    const x = (i) => (i / (pts.length - 1)) * (W - 40);
    const y = (v) => 8 + (1 - (v - lo + pad) / (hi - lo + 2 * pad)) * (H - 30);
    const line = pts.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("");
    const dashPts = pts.map((v, i) => v - (i / (pts.length - 1)) * Math.min(delta * 0.35, 4200));
    const dash = dashPts.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("");
    const up = delta >= 0;
    const col = up ? "#219947" : "#D12E24";
    const ticks = [hi, (hi + lo) / 2, lo].map((v) =>
      `<text x="${W - 36}" y="${y(v) + 3}" font-size="9" fill="#8a8a8e">${privacy ? "$•••" : "$" + (v / 1000).toFixed(0) + "k"}</text>`).join("");
    const since = D(n).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
    return `
      <div class="d-chips">${Object.keys(RANGES).map((r) =>
        `<button class="d-chip${r === trendRange ? " on" : ""}" data-range="${r}">${r}</button>`).join("")}</div>
      <div class="d-trend-head">
        <span class="rng" style="color:${col}">${up ? "▲" : "▼"} ${money(Math.abs(delta))} (${Math.abs(pct).toFixed(2)}%)</span>
        <span class="since">since ${since}</span>
      </div>
      <svg class="d-chart" viewBox="0 0 ${W} ${H}">
        <path d="${line} L${x(pts.length - 1)},${H - 6} L0,${H - 6} Z" fill="${col}" opacity="0.09"/>
        <path d="${dash}" fill="none" stroke="#8a8a8e" stroke-width="1.3" stroke-dasharray="4 3" opacity="0.7"/>
        <path d="${line}" fill="none" stroke="${col}" stroke-width="2"/>
        <circle cx="${x(pts.length - 1)}" cy="${y(last)}" r="3" fill="${col}"/>
        ${ticks}
      </svg>
      <div class="d-chart-note">solid = net worth · dashed = excl. deposits/withdrawals</div>`;
  }

  function activity() {
    const kinds = { All: () => true, Trades: (a) => a.t === "trade", Income: (a) => a.t === "income", Cash: (a) => a.t === "cash" };
    const rows = ACTS.filter(kinds[actFilter]);
    let out = `<div class="d-chips">${Object.keys(kinds).map((k) =>
      `<button class="d-chip${k === actFilter ? " on" : ""}" data-filter="${k}">${k}</button>`).join("")}</div>`;
    let lastDay = "";
    for (const a of rows) {
      const lbl = dayLabel(D(a.d));
      if (lbl !== lastDay) { out += `<div class="d-day">${lbl}</div>`; lastDay = lbl; }
      out += `
        <div class="d-act">
          <span class="ic" style="background:${a.c}">${a.ic}</span>
          <div><div class="ttl">${esc(a.ttl)}<span class="dot"></span></div><div class="sub">${esc(a.sub)}</div></div>
          <span class="amt${a.amt > 0 && a.t !== "trade" ? " up" : ""}">${money(a.amt, a.cur)}</span>
        </div>`;
    }
    return out;
  }

  // ── icons ──
  function eyeSvg() { return `<svg viewBox="0 0 24 24"><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12z"/><circle cx="12" cy="12" r="2.6"/></svg>`; }
  function chevSvg() { return `<svg class="chev" viewBox="0 0 24 24"><path d="M9 5l7 7-7 7"/></svg>`; }
  function plusSvg() { return `<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/></svg>`; }
  function refreshSvg() { return `<svg viewBox="0 0 24 24"><path d="M20 11a8 8 0 1 0-2.3 6"/><path d="M20 5v6h-6"/></svg>`; }

  // ── events ──
  el.addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.tab) { tab = b.dataset.tab; render(); }
    else if (b.dataset.acct !== undefined) {
      const i = +b.dataset.acct;
      openAccts.has(i) ? openAccts.delete(i) : openAccts.add(i);
      b.classList.toggle("open");
    }
    else if (b.dataset.alloc) { allocMode = b.dataset.alloc; render(); }
    else if (b.dataset.range) { trendRange = b.dataset.range; render(); }
    else if (b.dataset.filter) { actFilter = b.dataset.filter; render(); }
    else if (b.dataset.act === "privacy") { privacy = !privacy; render(); }
    else if (b.dataset.act === "refresh") {
      const svg = b.querySelector("svg"); svg.classList.add("spin");
      setTimeout(() => svg.classList.remove("spin"), 650);
    }
    else if (b.dataset.act === "connect") { toast("Just a demo — the real app opens SnapTrade here"); }
  });

  let toastTimer;
  function toast(msg) {
    const t = el.querySelector("#d-toast");
    t.textContent = msg; t.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove("show"), 2200);
  }

  render();
})();
