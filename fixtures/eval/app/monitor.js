// Monitor: run progress per lane and model, then the KPIs from the kpis collection. Rates come with their
// 95% interval ({v, lo, hi, n}); a value without lo/hi is shown bare.
const Monitor = (() => {
  const S = Store.state;
  const $ = (id) => document.getElementById(id);
  const esc = Diff.esc;
  const LANES = { api: "API", claude: "Claude", chatgpt: "ChatGPT" };
  const { metrics: METRICS, groups: GROUPS, categories: CATEGORIES } = Copy.monitor;
  const CATEGORY_ORDER = ["en", "fr", "mixed", "xs", "s", "m", "l", "xl"];

  let metric = remember("metric") || "fully_correct";
  let group = "lang";
  let open = null; // expanded model in the leaderboard
  let picked = null; // model highlighted in the chart
  let cell = null; // "<model id>|<category>" picked in the heatmap

  function remember(key, value) {
    try {
      if (value === undefined) return localStorage.getItem(`oops-eval.${key}`);
      localStorage.setItem(`oops-eval.${key}`, value);
    } catch {
      return null;
    }
  }

  const n0 = new Intl.NumberFormat("en-US");
  const pct = (v) => (v == null ? "–" : v < 0.1 && v > 0 ? `${(v * 100).toFixed(1)}%` : `${Math.round(v * 100)}%`);
  const pctBare = (v) => pct(v).replace("%", "");
  const ms = (v) => (v == null ? "–" : v < 1000 ? `${Math.round(v)} ms` : `${(v / 1000).toFixed(v < 10000 ? 1 : 0)} s`);
  const dur = (v) => (v >= 3600000 ? `${Math.floor(v / 3600000)} h ${Math.round((v % 3600000) / 60000)} min` : `${Math.round(v / 60000)} min`);
  function fmt(kind, m) {
    if (!m) return "–";
    if (kind === "rate") return pct(m.v);
    if (kind === "ms") return ms(m.v);
    return m.v == null ? "None, subscription" : `$${(m.v * 1000).toFixed(3)} per 1k`;
  }
  function interval(kind, m) {
    if (!m || m.lo == null || m.hi == null) return "";
    return kind === "rate" ? `${pctBare(m.lo)}–${pct(m.hi)}` : kind === "ms" ? `${ms(m.lo)}–${ms(m.hi)}` : "";
  }
  const name = (k) => `${k.model.split("/").pop()}${k.effort && k.effort !== "none" ? ` · ${k.effort}` : ""}`;
  const laneColor = (lane) => `var(--lane-${LANES[lane] ? lane : "api"})`;

  const day = (iso) => new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month: "short" });
  const ciText = (kind, m, unit) =>
    [interval(kind, m) && `95% CI ${interval(kind, m)}`, m?.n && unit && `${n0.format(m.n)} ${unit}`].filter(Boolean).join(" · ");

  function cellNote() {
    const [id, c] = (cell || "").split("|");
    const k = S.kpis.find((x) => x.id === id);
    const m = k?.by?.[group]?.[c];
    if (!m) return "";
    const [label] = CATEGORIES[c] || [c.replace(/_/g, " ")];
    return `<b>${esc(name(k))}</b> (${esc(k.provider)}), ${esc(label)}: ${pct(m.v)} fully correct, ${ciText("rate", m, "attempts")}.`;
  }

  function render() {
    if ($("monitor").hidden) return;
    const m = S.meta;
    const head = m
      ? `<h1>Run ${esc(m.run || "")}</h1><p class="m-sub">Eval set ${esc(m.dataset || "?")} · prompt ${esc(m.prompt || "?")} · ` +
        `${m.updated ? `updated ${new Date(m.updated).toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })}` : "not updated yet"}` +
        `${m.demo ? ' · <span class="demo">demo data</span>' : ""}</p>`
      : "<h1>No run yet</h1><p class=\"m-sub\">Progress and KPIs appear when the orchestrator writes a run.</p>";
    $("monitor").innerHTML = `<header class="m-head">${head}</header>${progress()}${chart()}${board()}${heat()}`;
  }

  function progress() {
    if (!S.lanes.length) return "";
    const sum = (k) => S.lanes.reduce((a, l) => a + (l[k] || 0), 0);
    const stats = [
      ["Calls finished", `${n0.format(sum("done"))}<small> of ${n0.format(sum("total"))}</small>`],
      ["Deferred to a later day", n0.format(sum("deferred"))],
      ["Failed calls", n0.format(sum("errors"))],
      ["Rate-limit waits", `${n0.format(sum("rate_limit_waits"))}<small> · ${dur(sum("wait_ms"))} waiting</small>`],
    ].map(([l, v]) => `<div><dt>${l}</dt><dd>${v}</dd></div>`).join("");
    const lanes = Object.keys(LANES).filter((lane) => S.lanes.some((l) => l.lane === lane));
    const rows = lanes.map((lane) => {
      const list = S.lanes.filter((l) => l.lane === lane).sort((a, b) => a.provider.localeCompare(b.provider) || a.model.localeCompare(b.model));
      const finished = (l) => l.done + l.errors >= l.total && !l.deferred;
      const row = (l) => {
          const w = (k) => `${(100 * (l[k] || 0)) / (l.total || 1)}%`;
          const left = l.total - l.done - l.errors - l.deferred;
          const bits = [
            `${n0.format(l.done)} of ${n0.format(l.total)} calls`,
            l.deferred ? `<span class="warn">${l.deferred} deferred${l.next_retry ? ` to ${day(l.next_retry)}` : ""}</span>` : "",
            l.errors ? `<span class="bad">${l.errors} failed</span>` : "",
            l.rate_limit_waits ? `${l.rate_limit_waits} rate-limit wait${l.rate_limit_waits > 1 ? "s" : ""}` : "",
          ].filter(Boolean).join(" · ");
          return `<div class="lane-row"><div class="lane-name"><b>${esc(name(l))}</b><span>${esc(l.provider)}</span></div>` +
            `<div class="lane-nums">${bits}</div><div class="lane-bar" role="img" aria-label="${l.done} done, ${l.errors} errors, ${l.deferred} deferred, ${left} left">` +
            `<i class="done" style="width:${w("done")}"></i><i class="err" style="width:${w("errors")}"></i><i class="def" style="width:${w("deferred")}"></i></div></div>`;
      };
      const done = list.filter(finished);
      const open = list.filter((l) => !finished(l));
      return `<h3 class="lane-h"><i style="background:${laneColor(lane)}"></i>${LANES[lane]}<span>${done.length} of ${list.length} models finished</span></h3>` +
        open.map(row).join("") +
        (done.length ? `<details class="finished"><summary>${done.length} finished model${done.length > 1 ? "s" : ""}</summary>${done.map(row).join("")}</details>` : "");
    }).join("");
    const key = [["done", "finished"], ["err", "failed"], ["def", "deferred"], ["left", "not run yet"]]
      .map(([c, t]) => `<span><i class="sw ${c}"></i>${t}</span>`).join("");
    return `<section><h2>Run progress</h2><dl class="stats">${stats}</dl><div class="legend bars">${key}</div>${rows}</section>`;
  }

  function chart() {
    const pts = S.kpis.filter((k) => k.m?.fully_correct && k.m?.latency_p50_ms?.v > 0);
    if (!pts.length) return "";
    const W = Math.max(300, Math.min(688, ($("monitor").clientWidth || 360) - 32));
    const H = 280, L = 38, R = 12, T = 16, B = 36;
    const lat = pts.map((k) => k.m.latency_p50_ms.v);
    const x0 = Math.log10(Math.min(...lat) / 1.4), x1 = Math.log10(Math.max(45000, Math.max(...lat) * 1.3));
    const y0 = Math.max(0, Math.floor(Math.min(...pts.map((k) => k.m.fully_correct.lo ?? k.m.fully_correct.v)) * 10) / 10);
    let y1 = Math.min(1, Math.ceil(Math.max(...pts.map((k) => k.m.fully_correct.hi ?? k.m.fully_correct.v)) * 10) / 10);
    if (y1 - y0 < 0.1) y1 = Math.min(1, y0 + 0.1); // one rate on a tick, or all equal
    const yLo = Math.min(y0, y1 - 0.1);
    const X = (v) => L + ((Math.log10(v) - x0) / (x1 - x0)) * (W - L - R);
    const Y = (v) => T + (1 - (v - yLo) / (y1 - yLo)) * (H - T - B);
    let g = "";
    for (let v = yLo; v <= y1 + 1e-9; v += 0.1) {
      g += `<line class="grid" x1="${L}" x2="${W - R}" y1="${Y(v)}" y2="${Y(v)}"/><text class="tick" x="${L - 6}" y="${Y(v) + 4}" text-anchor="end">${Math.round(v * 100)}%</text>`;
    }
    for (const t of [100, 200, 500, 1000, 2000, 5000, 10000, 20000, 40000]) {
      if (Math.log10(t) < x0 || Math.log10(t) > x1) continue;
      g += `<line class="grid" x1="${X(t)}" x2="${X(t)}" y1="${T}" y2="${H - B}"/><text class="tick" x="${X(t)}" y="${H - B + 16}" text-anchor="middle">${t / 1000}</text>`;
    }
    g += `<text class="tick" x="${(L + W - R) / 2}" y="${H - 4}" text-anchor="middle">Median latency, seconds, log scale</text>`;
    g += `<line class="deadline" x1="${X(40000)}" x2="${X(40000)}" y1="${T}" y2="${H - B}"/><text class="tick" x="${X(40000) - 4}" y="${T + 10}" text-anchor="end">40 s deadline</text>`;
    const sorted = [...pts].sort((a, b) => a.m.latency_p50_ms.v - b.m.latency_p50_ms.v);
    let best = -1;
    const front = sorted.filter((k) => k.m.fully_correct.v > best && (best = k.m.fully_correct.v) >= 0);
    g += `<polyline class="front" points="${front.map((k) => `${X(k.m.latency_p50_ms.v)},${Y(k.m.fully_correct.v)}`).join(" ")}"/>`;
    for (const k of pts) {
      const x = X(k.m.latency_p50_ms.v), y = Y(k.m.fully_correct.v), f = k.m.fully_correct;
      const on = k.id === picked;
      g += `<g class="pt${on ? " on" : ""}" data-pick="${esc(k.id)}" style="color:${laneColor(k.lane)}">` +
        (f.lo != null ? `<line x1="${x}" x2="${x}" y1="${Y(f.lo)}" y2="${Y(f.hi)}" stroke="currentColor" stroke-opacity="0.45" stroke-width="1.5"/>` : "") +
        `<circle cx="${x}" cy="${y}" r="${on ? 7 : 5}" fill="currentColor" stroke="var(--surface)" stroke-width="1.5"/><circle cx="${x}" cy="${y}" r="16" fill="transparent"/></g>`;
    }
    // Name the picked point, then the frontier from the top; a label that would collide is left out.
    const placed = [];
    const free = (x, y, w) => x >= 2 && x + w <= W - 2 && y - 11 >= 0 && y <= H - B &&
      placed.every((p) => x + w < p.x || x > p.x + p.w || y < p.y - 13 || y - 13 > p.y);
    const named = [...pts.filter((k) => k.id === picked), ...[...front].reverse().filter((k) => k.id !== picked)];
    for (const k of named) {
      const x = X(k.m.latency_p50_ms.v), y = Y(k.m.fully_correct.v), text = name(k), w = text.length * 6.2;
      for (const [dx, dy, end] of [[9, -7, 0], [9, 15, 0], [-9, -7, 1], [-9, 15, 1]]) {
        const lx = end ? x + dx - w : x + dx;
        if (!free(lx, y + dy, w)) continue;
        placed.push({ x: lx, y: y + dy, w });
        g += `<text class="pt-label" x="${lx}" y="${y + dy}">${esc(text)}</text>`;
        break;
      }
    }
    const sel = pts.find((k) => k.id === picked);
    const cap = sel
      ? `<b>${esc(name(sel))}</b> (${esc(sel.provider)}): ${pct(sel.m.fully_correct.v)} fully correct (95% CI ${interval("rate", sel.m.fully_correct)}), median latency ${ms(sel.m.latency_p50_ms.v)}`
      : "One dot per model, with its 95% interval as a vertical line. The dotted line joins the best rate at each latency. Tap a dot to name it.";
    const legend = Object.entries(LANES).filter(([l]) => pts.some((k) => k.lane === l))
      .map(([l, t]) => `<span><i style="background:${laneColor(l)}"></i>${t}</span>`).join("");
    return `<section><h2>Fully correct answers against latency</h2><div class="legend">${legend}</div>` +
      `<svg class="scatter" viewBox="0 0 ${W} ${H}" role="img" aria-label="Fully correct rate against median latency, one point per model">${g}</svg>` +
      `<p class="caption">${cap}</p></section>`;
  }

  function board() {
    if (!S.kpis.length) return "";
    const [key, , kind, dir] = METRICS.find((m) => m[0] === metric) || METRICS[0];
    const rows = S.kpis.filter((k) => k.m?.[key]?.v != null);
    rows.sort((a, b) => dir * (b.m[key].v - a.m[key].v));
    const his = rows.map((k) => k.m[key].hi ?? k.m[key].v);
    const los = rows.map((k) => k.m[key].lo ?? k.m[key].v);
    const lo = kind === "rate" ? Math.floor(Math.min(...los) * 10) / 10 : 0;
    const hi = kind === "rate" ? Math.ceil(Math.max(...his) * 10) / 10 : Math.max(...his) * 1.05;
    const sx = (v) => `${Math.max(0, Math.min(100, (100 * (v - lo)) / (hi - lo || 1)))}%`;
    const scale = kind === "rate" ? `${pct(lo)} to ${pct(hi)}` : `0 to ${kind === "ms" ? ms(hi) : `$${(hi * 1000).toFixed(3)} per 1k`}`;
    const options = METRICS.map(([k, l]) => `<option value="${k}"${k === key ? " selected" : ""}>${l}</option>`).join("");
    const list = rows.map((k, i) => {
      const m = k.m[key];
      const ci = m.lo != null ? `<i class="ci" style="left:${sx(m.lo)};width:calc(${sx(m.hi)} - ${sx(m.lo)})"></i>` : "";
      const detail = k.id === open ? `<dl class="detail">${METRICS.map(([mk, ml, mkind, , unit]) => `<div><dt>${ml}</dt><dd>${fmt(mkind, k.m[mk])}<small>${ciText(mkind, k.m[mk], unit)}</small></dd></div>`).join("")}</dl>` : "";
      return `<li class="${k.id === open ? "open" : ""}"><button class="row" data-open="${esc(k.id)}" aria-expanded="${k.id === open}">` +
        `<span class="rank">${i + 1}</span><span class="who"><b>${esc(name(k))}</b><span><i style="background:${laneColor(k.lane)}"></i>${esc(k.provider)}</span></span>` +
        `<span class="val">${fmt(kind, m)}<small>${interval(kind, m) && `95% CI ${interval(kind, m)}`}</small></span>` +
        `<span class="track">${ci}<i class="dot" style="left:${sx(m.v)}"></i></span></button>${detail}</li>`;
    }).join("");
    const none = S.kpis.length - rows.length;
    return `<section><div class="board-h"><h2>Models</h2><label class="pick"><span>Rank by</span><select id="metric">${options}</select></label></div>` +
      `<p class="caption scale">Dot: the value, on a ${scale} scale. Band: its 95% interval. Tap a model for all its metrics.</p><ol class="board">${list}</ol>${none ? `<p class="caption">${none} without this metric (subscription lanes have no per-call cost).</p>` : ""}</section>`;
  }

  function heat() {
    const rows = S.kpis.filter((k) => k.by?.[group]);
    if (!rows.length) return "";
    rows.sort((a, b) => (b.m?.fully_correct?.v ?? 0) - (a.m?.fully_correct?.v ?? 0));
    const keys = [...new Set(rows.flatMap((k) => Object.keys(k.by[group])))];
    keys.sort((a, b) => (CATEGORY_ORDER.indexOf(a) + 1 || 99) - (CATEGORY_ORDER.indexOf(b) + 1 || 99));
    const vals = rows.flatMap((k) => keys.map((c) => k.by[group][c]?.v).filter((v) => v != null));
    const lo = Math.min(...vals), hi = Math.max(...vals);
    const tabs = Object.entries(GROUPS).map(([g, l]) => `<button role="tab" data-group="${g}" aria-selected="${g === group}">${l}</button>`).join("");
    const head = keys.map((c) => {
      const [label, sub] = CATEGORIES[c] || [c.replace(/_/g, " ")];
      return `<th scope="col">${esc(label)}${sub ? `<small>${sub}</small>` : ""}</th>`;
    }).join("");
    const body = rows.map((k) => `<tr><th scope="row">${esc(name(k))} <small>${esc(k.provider)}</small></th>${keys.map((c) => {
      const m = k.by[group][c];
      if (!m) return "<td>–</td>";
      const s = hi > lo ? (m.v - lo) / (hi - lo) : 0.5;
      const on = cell === `${k.id}|${c}` ? " on" : "";
      return `<td class="${s > 0.55 ? "strong" : ""}${m.n && m.n < 30 ? " few" : ""}${on}" style="--s:${Math.round(8 + s * 80)}%" data-cell="${esc(k.id)}|${esc(c)}">${pctBare(m.v)}</td>`;
    }).join("")}</tr>`).join("");
    return `<section><h2>Fully correct by category</h2><div class="seg" role="tablist" aria-label="Category">${tabs}</div>` +
      `<div class="heat-wrap"><table class="heat"><thead><tr><th></th>${head}</tr></thead><tbody>${body}</tbody></table></div>` +
      `<p class="caption">${cellNote() || "Percent of attempts fully correct in each category. Underlined values rest on fewer than 30 attempts. Tap a value for its 95% interval."}</p></section>`;
  }

  $("monitor").addEventListener("click", (e) => {
    const t = e.target.closest("[data-open], [data-pick], [data-group], [data-cell]");
    if (!t) return;
    if (t.dataset.open) open = open === t.dataset.open ? null : t.dataset.open;
    if (t.dataset.pick) picked = picked === t.dataset.pick ? null : t.dataset.pick;
    if (t.dataset.group) group = t.dataset.group;
    if (t.dataset.cell) cell = cell === t.dataset.cell ? null : t.dataset.cell;
    const y = $("monitor").scrollTop;
    render();
    $("monitor").scrollTop = y;
  });
  $("monitor").addEventListener("change", (e) => {
    if (e.target.id !== "metric") return;
    metric = e.target.value;
    remember("metric", metric);
    const y = $("monitor").scrollTop;
    render();
    $("monitor").scrollTop = y;
  });

  function show(view) {
    for (const b of document.querySelectorAll("[data-view]")) b.setAttribute("aria-selected", String(b.dataset.view === view));
    $("review").hidden = view !== "review";
    $("monitor").hidden = view !== "monitor";
    remember("view", view);
    if (view === "monitor") render();
  }
  for (const b of document.querySelectorAll("[data-view]")) b.onclick = () => show(b.dataset.view);

  function status() {
    const text = { connecting: "Loading", offline: "Read-only", error: "Not syncing" }[S.status] || (S.meta?.demo ? "Demo data" : "");
    $("status").textContent = text;
  }

  let resizeTimer;
  addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(render, 150);
  });
  Store.on((what) => {
    status();
    if (["lanes", "kpis", "meta", "status"].includes(what)) render();
  });
  show(remember("view") === "monitor" ? "monitor" : "review");
  status();
  Store.start();
  return { render };
})();
