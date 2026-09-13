// Sylvester live demo — a transcription of the app popover with example data.
// Layout, strings, formatting, and behaviors mirror the SwiftUI source
// (MenuView / ChartsViews / ActivityFeedView / Controls / Theme / AppState).
(() => {
  "use strict";
  const root = document.getElementById("sylvester-demo");
  if (!root) return;

  // ── example dataset ─────────────────────────────────────────────────────
  const CAD = 0.723;
  const ACCOUNTS = [
    { inst: "Fidelity", name: "Individual ••2241", cur: "USD", cash: 3002.84, total: 84512.34,
      holdings: [["VTI", 145, 296.40, 0.62, 18.4], ["AAPL", 120, 232.10, 1.84, 31.2], ["NVDA", 62, 172.25, 2.31, 64.7]] },
    { inst: "Fidelity", name: "Roth IRA ••8874", cur: "USD", cash: 649.59, total: 46220.19,
      holdings: [["VOO", 72, 558.30, 0.58, 12.1], ["SCHD", 180, 29.85, -0.21, 4.8]] },
    { inst: "Wealthsimple", name: "TFSA ••4832", cur: "CAD", cash: 1607.66, total: 41930.66,
      holdings: [["VFV.TO", 210, 151.20, 0.71, 22.6], ["SHOP.TO", 60, 142.85, 3.12, -8.3]] },
    { inst: "Robinhood", name: "Individual ••0925", cur: "USD", cash: 213.22, total: 12884.02,
      holdings: [["TSLA", 28, 342.60, -1.47, 41.9], ["VXUS", 45, 68.40, 0.33, 6.2]] },
  ];
  const NET = 173873.92, DELTA = 2121.85, DELTA_PCT = 1.24;
  const SERIES = ["#618CFA", "#4ACAAD", "#FAB852", "#F07087", "#A887F5", "#5CC4F7", "#ABD975", "#F28F5C"];
  const MUTED = "#8F9CB0";                          // Theme.muted — Other/Unclassified
  const GAIN = "#28CD41", LOSS = "#FF3B30";

  const ALLOC = {                                   // allocation(by:topN:8) — desc, "Other" last
    Asset: [["VTI", 42978], ["VOO", 40198], ["AAPL", 27852], ["VFV.TO", 22957], ["NVDA", 10680],
            ["TSLA", 9593], ["SHOP.TO", 6197], ["SCHD", 5373], ["Other", 8046]],
    Account: [["Individual ••2241", 84512], ["Roth IRA ••8874", 46220], ["TFSA ••4832", 30316], ["Individual ••0925", 12884]],
    Currency: [["USD", 143617], ["CAD", 30316]],
  };

  const day = 86400e3;
  const D = (n) => new Date(Date.now() - n * day);
  // type/style tables mirror ActivityFeedView.style(for:)
  const ACTS = [
    { d: 2,  type: "DIVIDEND", ttl: "Dividend · SCHD", acct: "Roth IRA ••8874", amt: 48.60, cur: "USD" },
    { d: 5,  type: "BUY", ttl: "Bought 5 AAPL", acct: "Individual ••2241", price: 231.40, amt: -1157.00, cur: "USD" },
    { d: 8,  type: "CONTRIBUTION", ttl: "Contribution", acct: "TFSA ••4832", amt: 500.00, cur: "CAD" },
    { d: 12, type: "DIVIDEND", ttl: "Dividend · VOO", acct: "Roth IRA ••8874", amt: 96.12, cur: "USD" },
    { d: 13, type: "DIVIDEND", ttl: "Dividend · VTI", acct: "Individual ••2241", amt: 151.75, cur: "USD" },
    { d: 19, type: "BUY", ttl: "Bought 12 VFV.TO", acct: "TFSA ••4832", price: 149.80, amt: -1797.60, cur: "CAD" },
    { d: 26, type: "INTEREST", ttl: "Interest", acct: "Individual ••0925", amt: 1.87, cur: "USD" },
  ];
  const STYLE = {
    BUY:          { g: "↓", tint: "#007AFF", amt: "primary" },
    SELL:         { g: "↑", tint: "#30B0C7", amt: "gain" },
    DIVIDEND:     { g: "$", tint: GAIN, amt: "gain" },
    INTEREST:     { g: "$", tint: GAIN, amt: "gain" },
    CONTRIBUTION: { g: "+", tint: GAIN, amt: "gain" },
    WITHDRAWAL:   { g: "−", tint: "#FF9500", amt: "orange" },
    default:      { g: "", tint: "#8E8E93", amt: "secondary" },
  };
  const CATEGORY = { BUY: 1, SELL: 1, DIVIDEND: 2, INTEREST: 2, REI: 2, DIVIDEND_REINVESTMENT: 2,
                     CONTRIBUTION: 3, WITHDRAWAL: 3, TRANSFER: 3, FEE: 3, TAX: 3 };

  // 1Y daily net-worth walk ending at NET, plus monthly $500 CAD contributions
  // (361.50 USD — matching the Activity feed cadence) as external flows
  const FLOWS = Array.from({ length: 12 }, (_, i) => ({ daysAgo: 338 - i * 30, amount: 361.5 }));
  const walk = (() => {
    let seed = 42;
    const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
    const pts = [];
    let v = 148600;
    for (let i = 365; i >= 0; i--) pts.push(v += v * (rnd() - 0.4305) * 0.006);
    const k = NET / pts[pts.length - 1];
    return pts.map((p) => p * k);
  })();
  const RANGES = { "1D": 1, "1W": 7, "1M": 30, "3M": 91,
                   YTD: Math.max(2, Math.floor((Date.now() - new Date(new Date().getFullYear(), 0, 1)) / day)),
                   "1Y": 365, All: 365 };

  // ── state ────────────────────────────────────────────────────────────────
  let privacy = false, tab = "Accounts", allocMode = "Asset", trendRange = "All", actFilter = "All";
  let unseen = true, refreshing = false, hoverSlice = null;
  const openAccts = new Set([0]);

  // ── formatters (transcribed from AppState) ──────────────────────────────
  const group = (v, dp = 2) => Math.abs(v).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
  // fullCurrency: system-locale currency (en-CA style: USD → "US$", CAD → "$")
  const money = (v, cur = "USD") => privacy ? "$•••••" :
    (v < 0 ? "-" : "") + (cur === "USD" ? "US$" : "$") + group(v);
  // baseCurrencyString: bare symbol, 2dp — used for net worth / deltas
  const baseMoney = (v) => privacy ? "$•••••" : (v < 0 ? "-" : "") + "$" + group(v);
  // compactCurrency: ≥1M "%.2fM" · ≥100k "%.0fk" · ≥1k "%.1fk" · else "%.0f"
  const compact = (v) => {
    if (privacy) return "$•••";
    const a = Math.abs(v);
    const body = a >= 1e6 ? (a / 1e6).toFixed(2) + "M" : a >= 1e5 ? (a / 1e3).toFixed(0) + "k"
               : a >= 1e3 ? (a / 1e3).toFixed(1) + "k" : a.toFixed(0);
    return (v < 0 ? "-" : "") + "$" + body;
  };
  const usd = (a) => a.cur === "CAD" ? a.total * CAD : a.total;
  const pct1 = (v) => (v * 100).toFixed(1).padStart(4) + "%";       // "%4.1f%%"
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  const dayLabel = (d) => {
    const sod = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
    const t = sod(new Date()), dd = sod(d);
    if (dd === t) return "Today";
    if (dd === t - day) return "Yesterday";
    return d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
  };
  const sinceLabel = (d) => d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })
    + " at " + d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });

  // ── computed tab heights (MenuView listHeight/allocationHeight/…) ───────
  function bodyHeight() {
    if (tab === "Accounts") {
      const groups = new Set(ACCOUNTS.map((a) => a.inst)).size;
      let h = groups * 26 + ACCOUNTS.length * 38 + 20;
      for (const i of openAccts) h += (ACCOUNTS[i].holdings.length + 1) * 30 + 8;
      return Math.min(Math.max(h, 60), 380);
    }
    if (tab === "Allocation") return 8 + 20 + 10 + 155 + 10 + ALLOC[allocMode].length * 21 + 10;
    if (tab === "Trend") return 268;
    const rows = ACTS.filter(actPass).length;
    return rows === 0 ? 170 : Math.min(rows * 36 + (Math.floor(rows / 4) + 1) * 24 + 8 + 20 + 16, 380);
  }
  const actPass = (a) => actFilter === "All" ||
    ({ Trades: 1, Income: 2, Cash: 3 })[actFilter] === CATEGORY[a.type];

  // ── render ───────────────────────────────────────────────────────────────
  const el = document.createElement("div");
  el.className = "demo";
  root.appendChild(el);

  function render() {
    const deltaTxt = privacy
      ? `▲ $••••• (${DELTA_PCT.toFixed(2)}%) today`
      : `▲ ${baseMoney(DELTA)} (${DELTA_PCT.toFixed(2)}%) today`;
    el.innerHTML = `
      <div class="d-head">
        <div class="d-label"><span>Net worth</span>
          <span class="d-updated">${refreshing ? '<span class="spin">↻</span>' : "updated just now"}</span>
          <button class="d-eye" data-act="privacy" title="${privacy ? "Show amounts" : "Hide amounts (for screenshots)"}">${eyeSvg(privacy)}</button>
        </div>
        <div class="d-value mono">${privacy ? "$•••••" : "$" + group(NET)}</div>
        <div class="d-delta">${deltaTxt}</div>
      </div>
      <div class="divider"></div>
      <div class="d-tabs" role="tablist">
        ${["Accounts", "Allocation", "Trend", "Activity"].map((t) =>
          `<button class="d-tab${t === tab ? " on" : ""}" role="tab" data-tab="${t}">${t}${t === "Activity" && unseen ? '<span class="dot"></span>' : ""}</button>`).join("")}
      </div>
      <div class="d-body" style="height:${bodyHeight()}px">
        ${{ Accounts: accounts, Allocation: allocation, Trend: trend, Activity: activity }[tab]()}
      </div>
      <div class="divider"></div>
      <div class="d-foot">
        <button class="d-btn" data-act="connect">${plusSvg()} Connect Account</button>
        <button class="d-btn" data-act="refresh" ${refreshing ? "disabled" : ""}>${arrowSvg()} Refresh</button>
        <button class="d-more" data-act="connect" aria-label="More">${ellipsisSvg()}</button>
        <div class="d-toast" id="d-toast"></div>
      </div>`;
    if (tab === "Trend") drawTrend();
  }

  // ── Accounts ──────────────────────────────────────────────────────────────
  function accounts() {
    let out = '<div class="d-list">';
    for (const inst of [...new Set(ACCOUNTS.map((a) => a.inst))]) {
      const list = ACCOUNTS.filter((a) => a.inst === inst);
      out += `<div class="d-grp">
        <div class="d-grp-head"><span>${inst}</span><span class="amt">${compact(list.reduce((s, a) => s + usd(a), 0))}</span></div>`;
      for (const a of list) {
        const i = ACCOUNTS.indexOf(a), open = openAccts.has(i);
        out += `
        <button class="d-acct${open ? " open" : ""}" data-acct="${i}">
          ${chevSvg()}
          <span class="col"><span class="nm">${esc(a.name)}</span>
          <span class="sync">live · feed synced 3 hr. ago</span></span>
          <span class="amt">${money(a.total, a.cur)}</span>
        </button>`;
        if (open) {
          out += `<div class="d-break">
            <div class="d-hold"><span class="col"><span class="t">Cash</span><span class="q">${a.cur}</span></span>
              <span class="right"><span class="v">${money(a.cash, a.cur)}</span></span></div>
            ${a.holdings.map(([t, q, p, td, pnl]) => `
            <div class="d-hold">
              <span class="col"><span class="t">${t}</span>
                <span class="q">${privacy ? money(p, a.cur) : `${q} × ${money(p, a.cur)}`}</span></span>
              <span class="right"><span class="v">${money(q * p, a.cur)}</span>
                <span class="m"><span class="${td >= 0 ? "up" : "down"}">${td >= 0 ? "▲" : "▼"}${Math.abs(td).toFixed(2)}% td</span><span class="${pnl >= 0 ? "up" : "down"}">${pnl >= 0 ? "+" : ""}${pnl.toFixed(1)}%</span></span></span>
            </div>`).join("")}
          </div>`;
        }
      }
      out += "</div>";
    }
    return out + "</div>";
  }

  // ── Allocation ────────────────────────────────────────────────────────────
  function allocation() {
    const data = ALLOC[allocMode];
    const total = data.reduce((s, [, v]) => s + v, 0);
    const OUTER = 74, INNER = OUTER * 0.64;                    // innerRadius .ratio(0.64)
    const R = (OUTER + INNER) / 2, W = OUTER - INNER;          // ring centerline + thickness
    const CIRC = 2 * Math.PI * R;
    let off = 0;
    const segs = data.map(([label, v], i) => {
      const frac = v / total;
      const color = label === "Other" ? MUTED : SERIES[i % SERIES.length];
      const dim = hoverSlice !== null && hoverSlice !== i;
      const s = `<circle r="${R}" cx="77.5" cy="77.5" fill="none" stroke="${color}" stroke-width="${W}"
        stroke-dasharray="${Math.max(frac * CIRC - 1.6, 0.6)} ${CIRC}" stroke-dashoffset="${(-off * CIRC).toFixed(2)}"
        transform="rotate(-90 77.5 77.5)" opacity="${dim ? 0.3 : 1}" data-slice="${i}" style="transition:opacity .12s"/>`;
      off += frac;
      return s;
    }).join("");
    const h = hoverSlice !== null ? data[hoverSlice] : null;
    const center = h
      ? `<span class="nm">${esc(h[0])}</span><span class="figS">${compact(h[1])}</span><span class="sub">${(h[1] / total * 100).toFixed(1)}%</span>`
      : `<span class="fig">${compact(total)}</span><span class="sub">${allocMode.toLowerCase()} mix</span>`;
    return `<div class="d-alloc">
      <div class="d-chips">${["Asset", "Account", "Currency"].map((m) =>
        `<button class="d-chip${m === allocMode ? " on" : ""}" data-alloc="${m}">${m}</button>`).join("")}</div>
      <div class="d-donut"><svg viewBox="0 0 155 155">${segs}</svg><div class="center">${center}</div></div>
      <div class="d-leg">${data.map(([label, v], i) => `
        <div class="d-leg-row${hoverSlice === i ? " hov" : ""}" data-slice="${i}"
             style="${hoverSlice === i ? `background:${(label === "Other" ? MUTED : SERIES[i % SERIES.length])}29` : ""}">
          <span class="sw" style="background:${label === "Other" ? MUTED : SERIES[i % SERIES.length]}"></span>
          <span class="lnm">${esc(label)}</span>
          <span class="lv">${compact(v)}</span>
          <span class="lp">${pct1(v / total)}</span>
        </div>`).join("")}</div>
    </div>`;
  }

  // ── Trend ────────────────────────────────────────────────────────────────
  function trendPoints() {
    const n = Math.min(RANGES[trendRange], walk.length - 1);
    const pts = walk.slice(walk.length - 1 - n);
    const flows = FLOWS.filter((f) => f.daysAgo <= n);
    const adj = pts.map((v, i) => {
      const dAgo = n - i;
      const flowSum = flows.filter((f) => f.daysAgo >= dAgo).reduce((s, f) => s + f.amount, 0);
      return v - flowSum;
    });
    return { n, pts, adj, netFlow: flows.reduce((s, f) => s + f.amount, 0) };
  }
  function trend() {
    const { n, pts, adj, netFlow } = trendPoints();
    const delta = pts[pts.length - 1] - pts[0], pctv = pts[0] ? delta / Math.abs(pts[0]) * 100 : 0;
    const growth = delta - netFlow;
    const up = delta >= 0, gUp = growth >= 0;
    const l2 = Math.abs(netFlow) > 0.01
      ? `<div class="l2" style="color:${gUp ? GAIN : LOSS}D9">${gUp ? "▲" : "▼"} ${money(Math.abs(growth))} excl. ${money(netFlow)} net deposits</div>` : "";
    return `<div class="d-trend">
      <div class="d-chips">${Object.keys(RANGES).map((r) =>
        `<button class="d-chip${r === trendRange ? " on" : ""}" data-range="${r}">${r}</button>`).join("")}</div>
      <div class="d-thead">
        <div class="l1"><span style="color:${up ? GAIN : LOSS}">${up ? "▲" : "▼"} ${money(Math.abs(delta))} (${Math.abs(pctv).toFixed(2)}%)</span>
          <span class="since">since ${sinceLabel(D(n))}</span></div>
        ${l2}
      </div>
      <div class="d-chart-wrap"><svg class="d-chart" id="d-trend-svg"></svg></div>
      <div class="d-foot-note">solid = net worth · dashed = excl. deposits/withdrawals</div>
    </div>`;
  }
  function drawTrend() {
    const svg = el.querySelector("#d-trend-svg");
    const { n, pts, adj, netFlow } = trendPoints();
    const box = svg.parentElement.getBoundingClientRect();
    const W = Math.max(box.width, 120), H = Math.max(box.height, 80);
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    const tint = pts[pts.length - 1] >= pts[0] ? GAIN : LOSS;
    const all = adj.concat(pts);
    const lo = Math.min(...all), hi = Math.max(...all);
    const pad = Math.max((hi - lo) * 0.18, Math.max(Math.abs(hi) * 0.002, 1));
    const AXIS_W = 30, y0 = lo - pad, y1 = hi + pad;
    const X = (i) => (i / (pts.length - 1)) * (W - AXIS_W);
    const Y = (v) => H - 12 - ((v - y0) / (y1 - y0)) * (H - 16);
    const path = (arr) => arr.map((v, i) => `${i ? "L" : "M"}${X(i).toFixed(1)},${Y(v).toFixed(1)}`).join("");
    const yTicks = [0.25, 0.5, 0.75, 1].map((f) => y0 + (y1 - y0) * f);
    const xTicks = [0.04, 0.36, 0.67, 0.97].map((f) => Math.round(f * (pts.length - 1)));
    const anchor = (k) => k === 0 ? "start" : k === 3 ? "end" : "middle";
    const xFmt = (i) => {
      const d = D(n - i * n / (pts.length - 1));
      return n <= 1 ? d.toLocaleTimeString("en-US", { hour: "numeric" })
                    : d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
    };
    svg.innerHTML = `
      <defs><linearGradient id="dg" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="${tint}" stop-opacity=".28"/><stop offset="1" stop-color="${tint}" stop-opacity=".02"/>
      </linearGradient></defs>
      ${yTicks.map((v) => `<line x1="0" x2="${W - AXIS_W}" y1="${Y(v)}" y2="${Y(v)}" stroke="rgba(0,0,0,.1)" stroke-width="1"/>
        <text x="${W - AXIS_W + 4}" y="${Y(v) + 3}" font-size="9" fill="rgba(0,0,0,.26)">${privacy ? "•••" : compact(v)}</text>`).join("")}
      ${xTicks.map((i, k) => `<text x="${X(i)}" y="${H - 1}" font-size="9" fill="rgba(0,0,0,.26)" text-anchor="${anchor(k)}">${xFmt(i)}</text>`).join("")}
      <path d="${path(pts)} L${X(pts.length - 1).toFixed(1)},${Y(y0)} L0,${Y(y0)} Z" fill="url(#dg)"/>
      ${Math.abs(netFlow) > 0.01 ? `<path d="${path(adj)}" fill="none" stroke="${MUTED}" stroke-opacity=".85" stroke-width="1.3" stroke-dasharray="4 3"/>` : ""}
      <path d="${path(pts)}" fill="none" stroke="${tint}" stroke-width="2" stroke-linejoin="round"/>
      <circle cx="${X(pts.length - 1)}" cy="${Y(pts[pts.length - 1])}" r="3.4" fill="${tint}"/>`;
  }

  // ── Activity ─────────────────────────────────────────────────────────────
  function activity() {
    const rows = ACTS.filter(actPass);
    let out = `<div class="d-chips" style="padding:8px 12px 0">${["All", "Trades", "Income", "Cash"].map((k) =>
      `<button class="d-chip${k === actFilter ? " on" : ""}" data-filter="${k}">${k}</button>`).join("")}</div>`;
    if (!rows.length) {
      return out + `<div class="d-empty" style="height:120px"><span class="glyph">🕓</span>
        No ${actFilter === "All" ? "" : actFilter.toLowerCase() + " "}activity in the last 30 days</div>`;
    }
    out += '<div class="d-acts">';
    let last = "";
    for (const a of rows) {
      const lbl = dayLabel(D(a.d));
      if (lbl !== last) { out += `<div class="d-day">${lbl}</div>`; last = lbl; }
      const st = STYLE[a.type] || STYLE.default;
      const amtCls = { gain: "up", orange: "", primary: "", secondary: "" }[st.amt];
      const amtStyle = st.amt === "secondary" ? "color:rgba(0,0,0,.5)" : st.amt === "orange" ? "color:#FF9500" : "";
      const sub = esc(a.acct) + (a.price ? ` · @ ${money(a.price, a.cur)}` : "");
      out += `<div class="d-act">
        <span class="ic"><span class="disc" style="background:${st.tint}">${st.g}</span></span>
        <span class="col"><span class="ttl">${esc(a.ttl)}<span class="new" title="New since last sync"></span></span>
        <span class="sub">${sub}</span></span>
        <span class="amt ${amtCls}" style="${amtStyle}">${money(a.amt, a.cur)}</span>
      </div>`;
    }
    return out + "</div>";
  }

  // ── icons ────────────────────────────────────────────────────────────────
  const eyeSvg = (slash) => `<svg viewBox="0 0 24 24"><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12z"/><circle cx="12" cy="12" r="2.6"/>${slash ? '<path d="M4 20L20 4"/>' : ""}</svg>`;
  const chevSvg = () => `<svg class="chev" viewBox="0 0 24 24"><path d="M9 5l7 7-7 7"/></svg>`;
  const plusSvg = () => `<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 8.5v7M8.5 12h7"/></svg>`;
  const arrowSvg = () => `<svg viewBox="0 0 24 24"><path d="M20 11a8 8 0 1 0-2.3 6"/><path d="M20 5v6h-6"/></svg>`;
  const ellipsisSvg = () => `<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><circle cx="7.5" cy="12" r=".8" fill="currentColor"/><circle cx="12" cy="12" r=".8" fill="currentColor"/><circle cx="16.5" cy="12" r=".8" fill="currentColor"/></svg>`;

  // ── events ───────────────────────────────────────────────────────────────
  el.addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.tab) {
      tab = b.dataset.tab;
      if (tab === "Activity") unseen = false;      // markActivitiesViewed()
      hoverSlice = null;
      render();
    }
    else if (b.dataset.acct !== undefined) {
      const i = +b.dataset.acct;
      openAccts.has(i) ? openAccts.delete(i) : openAccts.add(i);
      render();
    }
    else if (b.dataset.alloc) { allocMode = b.dataset.alloc; hoverSlice = null; render(); }
    else if (b.dataset.range) { trendRange = b.dataset.range; render(); }
    else if (b.dataset.filter) { actFilter = b.dataset.filter; render(); }
    else if (b.dataset.act === "privacy") { privacy = !privacy; render(); }
    else if (b.dataset.act === "refresh") {
      refreshing = true; render();
      setTimeout(() => { refreshing = false; render(); }, 900);
    }
    else if (b.dataset.act === "connect") toast("Just a demo — the real app opens SnapTrade here");
  });

  // donut + legend hover (bidirectional, mirrors the app's hover dim/highlight)
  el.addEventListener("mouseover", (e) => {
    const t = e.target.closest("[data-slice]");
    if (t && tab === "Allocation") { hoverSlice = +t.dataset.slice; render(); }
  });
  el.addEventListener("mouseout", (e) => {
    if (tab !== "Allocation" || hoverSlice === null) return;
    const to = e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest("[data-slice]");
    if (!to) { hoverSlice = null; render(); }
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
