/* The dashboard reads the scoring pipeline; it never computes an independent quality score. */
const $ = (id) => document.getElementById(id);
const esc = Diff.esc;
const pct = (v) => v == null ? "—" : `${(100 * v).toFixed(1)}%`;
const seconds = (v) => v == null ? "—" : `${(v / 1000).toFixed(2)}s`;
const money = (v) => v == null ? "—" : `$${v.toFixed(v < 0.01 ? 6 : 3)}`;
let state = null, detail = null, selectedCase = null, busy = false;
let selectedRun = new URLSearchParams(location.search).get("run") || "";
let detailRequest = 0, renderedReport = "", normalRunStatus = "";

async function request(url, options) {
  const response = await fetch(url, options);
  const value = await response.json();
  if (!response.ok) throw new Error(value.error || "The local server could not complete this request.");
  return value;
}

function runQuery() { return `run=${encodeURIComponent(selectedRun)}`; }
function route(lane) { return ({openai: "OpenAI API", chatgpt: "ChatGPT sign-in", claude: "Claude Code"})[lane.lane] || `${lane.provider} API`; }
function modelCell(lane) { return `${esc(lane.resolved)}<small>${esc(route(lane))}${lane.effort ? ` · ${esc(lane.effort)}` : ""}</small>`; }
function options(select, values, previous) {
  const identity = JSON.stringify(values);
  if (select.dataset.options !== identity) {
    select.innerHTML = values.map(([value, label]) => `<option value="${esc(value)}">${esc(label)}</option>`).join("");
    select.dataset.options = identity;
  }
  if (values.some(([v]) => v === previous)) select.value = previous;
}

async function refresh() {
  if (busy) return;
  busy = true;
  try {
    const requestedRun = selectedRun;
    const next = await request(`/api/state?${runQuery()}`);
    if (requestedRun !== selectedRun) return;
    state = next;
    selectedRun = next.run || "";
    options($("run"), next.runs.length ? next.runs.map((r) => [r, r]) : [["", "No runs yet"]], selectedRun);
    $("connection").textContent = `Updated ${new Date().toLocaleTimeString([], {hour: "2-digit", minute: "2-digit", second: "2-digit"})}`;
    $("connection").classList.remove("error");
    const identity = JSON.stringify(next);
    if (identity !== renderedReport) { renderedReport = identity; render(); normalRunStatus = $("runStatus").textContent; }
    else { $("runStatus").textContent = normalRunStatus; $("runStatus").classList.remove("error"); if (state.run) Live.render(state, esc, modelCell); }
    await refreshCaseEvidence();
  } catch (error) {
    $("connection").textContent = "Connection interrupted";
    $("connection").classList.add("error");
    $("runStatus").textContent = `${error.message} Last received results remain visible. Refresh to reconnect.`;
    $("runStatus").classList.add("error");
  } finally { busy = false; }
}

function render() {
  $("runStatus").classList.remove("error");
  if (!state.run) {
    $("title").innerHTML = "Ready for the first run.";
    $("intro").textContent = "The reviewed corpus is ready. The correction prompt is unchanged. No baseline has been launched.";
    $("runStatus").textContent = `${state.dataset.dev.cases + state.dataset.held.cases} reviewed synthetic cases · ${state.dataset.dev.cases} development / ${state.dataset.held.cases} held back`;
    $("banner").hidden = true;
    $("empty").hidden = false;
    $("empty").textContent = "Run progress will appear here after you explicitly launch generation from the command line. This website cannot start model calls.";
    $("liveOverview").hidden = true;
    $("chart").innerHTML = '<p class="empty">Quality and latency appear after a run has produced graded outputs.</p>';
    for (const id of ["liveRows", "resultRows", "breakdowns", "caseList"]) $(id).innerHTML = "";
    return;
  }
  $("policyText").textContent = state.rubric.policy;
  $("policyLabels").innerHTML = ["edit_labels","miss_labels"].map((field) => Object.entries(state.rubric[field]).map(([name,text]) => `<dt>${esc(name)}</dt><dd>${esc(text)}</dd>`).join("")).join("");
  $("title").innerHTML = "Corrections, measured.";
  $("intro").textContent = "Compare correction quality, preservation and response time.";
  const calibration = state.experiment?.kind === "calibration";
  $("results").hidden = calibration;
  document.querySelector('nav a[href="#results"]').hidden = calibration;
  if (calibration) { $("title").textContent = "Calibrating the judges."; $("intro").textContent = "Review existing answers against the correction policy before the first baseline."; }
  $("banner").hidden = !state.demo && Boolean(state.experiment) && !calibration;
  $("banner").textContent = calibration ? "Judge calibration panel — historical outputs and separately marked authored examples. This is not the baseline; quality and timing here are not a model comparison." : state.demo ? "Demonstration data — invented outputs for interface verification. These are not model measurements." : "Historical shakedown — no immutable experiment snapshot. These results are report-only, not the new baseline.";
  $("empty").hidden = state.lanes.some((l) => l.metrics.calls);
  $("empty").textContent = "No completed calls yet. Progress follows records as the runner writes them.";
  $("runStatus").textContent = `${state.run} · ${state.cases} cases × ${state.attempts} attempts · ${state.generating ? "Generation active" : "Generation idle"}`;
  Live.render(state, esc, modelCell);
  renderResults();
  const current = $("laneFocus").value;
  options($("laneFocus"), state.lanes.map((l) => [l.file, `${l.resolved} · ${l.provider}`]), current);
  renderBreakdowns(); renderCases();
  $("versions").textContent = JSON.stringify({experiment: state.experiment, rubric: state.rubric, metrics: state.metrics_version, models: state.lanes.map((l) => ({route: route(l), model: l.resolved, effort: l.effort, surface: l.surface})), comparison_calls: state.comparison_calls}, null, 2);
}

function renderResults() {
  if (!state?.run) return;
  $("comparisonNote").textContent = `${state.comparison_calls} matching, graded case-attempt pairs across every eligible lane. Chart uses this common sample. Table shows each lane's own coverage; partial rates can be biased by what is still ungraded.`;
  const ordered = [...state.lanes];
  const sort = $("sort").value;
  if (sort) ordered.sort((a,b) => {
    const x = a.metrics[sort], y = b.metrics[sort];
    if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
    return (x-y) * (sort === "fully_correct" ? -1 : 1);
  });
  $("resultRows").innerHTML = ordered.map((l) => {
    const m = l.metrics;
    return `<tr><td>${modelCell(l)}</td><td>${m.correct} / ${m.judged}<small>${pct(m.fully_correct)} · ${m.unresolved} unresolved</small></td><td>${pct(m.f05)}</td><td>${pct(m.precision)} / ${pct(m.recall)}</td><td>${pct(m.harm_rate)}<small>${m.protected_broken} raw preservation failures</small></td><td>${seconds(m.latency_p50_ms)} / ${seconds(m.latency_p95_ms)}<small>Full wait ${seconds(m.wait_p50_ms)} / ${seconds(m.wait_p95_ms)}</small></td><td>${money(m.cost_per_success_usd)}<small>${m.cost_usd == null ? "Cost unavailable / subscription" : `${money(m.cost_usd)} estimated list total`}</small></td></tr>`;
  }).join("");
  const metric = $("metric").value;
  const points = state.lanes.filter((l) => l.comparison[metric] != null && l.comparison.latency_p50_ms != null);
  if (!points.length) {
    $("chart").innerHTML = '<p class="empty">The comparison plot is waiting for matching, graded results across the lanes.</p>';
    return;
  }
  const maxX = Math.max(1000, ...points.map((l) => l.comparison.latency_p50_ms)) * 1.15;
  const x = (v) => 68 + 650 * v / maxX, y = (v) => 310 - 255 * v;
  let svg = '<svg viewBox="0 0 780 370" role="img" aria-label="Quality versus median completion latency; tabular values are below">';
  for (let i = 0; i <= 4; i++) {
    const rate = i / 4, xpos = x(maxX * rate), ypos = y(rate);
    svg += `<line class="grid" x1="68" x2="730" y1="${ypos}" y2="${ypos}"/><text class="tick" x="52" y="${ypos + 4}" text-anchor="end">${Math.round(rate * 100)}%</text><text class="tick" x="${xpos}" y="335" text-anchor="middle">${(maxX * rate / 1000).toFixed(1)}s</text>`;
  }
  svg += `<text class="plot-label" x="68" y="22">${esc($("metric").selectedOptions[0].textContent)}</text><text class="tick" x="400" y="365" text-anchor="middle">Median full-answer completion time</text>`;
  for (const lane of points) {
    const m = lane.comparison, cx = x(m.latency_p50_ms), cy = y(m[metric]);
    if (metric === "fully_correct" && m.fully_correct_ci) svg += `<line class="ci" x1="${cx}" x2="${cx}" y1="${y(m.fully_correct_ci[0])}" y2="${y(m.fully_correct_ci[1])}"/>`;
    svg += `<circle class="point" data-kind="${esc(lane.lane)}" cx="${cx}" cy="${cy}" r="6" tabindex="0"><title>${esc(lane.resolved)} (${esc(lane.provider)}): ${pct(m[metric])}, ${seconds(m.latency_p50_ms)}, n=${m.calls}</title></circle>`;
  }
  svg += '</svg><div class="legend"><span class="api">API</span><span>ChatGPT sign-in</span><span class="claude">Claude Code</span></div>';
  $("chart").innerHTML = svg;
}

function renderBreakdowns() {
  const lane = state?.lanes?.find((l) => l.file === $("laneFocus").value);
  if (!lane) return;
  $("breakdowns").innerHTML = Object.entries(lane.by).map(([dimension, entries]) => `<div class="breakdown"><h3>${esc({lang:"Language", length:"Length", origin:"Origin", split:"Split", errors:"Error type"}[dimension])}</h3><ul>${Object.entries(entries).map(([name, m]) => `<li>${esc(name)}<span>${m.correct}/${m.judged} · ${pct(m.fully_correct)}</span></li>`).join("") || '<li>No graded results</li>'}</ul></div>`).join("");
  const m = lane.metrics, raw = lane.raw_metrics;
  const diagnostics = [
    ["Clean drafts changed",pct(m.clean_changed)],
    ["Passed every repeated attempt",`${pct(m.pass_all)} · ${m.repeat_cases} complete cases`],
    ["Inconsistent repeat outcomes",pct(m.flip_rate)],
    ["Deadline failures",m.deadline_missed],
    ["Necessary / optional / harmful edits",`${m.needed} / ${m.optional} / ${m.harmful}`],
    ["Missed reference errors",m.missed],
    ["Edits dropped by reconciliation",m.dropped_edits],
    ["Raw model correct / graded",raw ? `${raw.correct} / ${raw.judged}` : "—"],
    ["Raw model unresolved",raw?.unresolved ?? "—"],
    ["First token / first content median",`${seconds(m.ttft_p50_ms)} / ${seconds(m.ttfc_p50_ms)}`]
  ];
  $("diagnostics").innerHTML = `<details><summary>All diagnostics for this model</summary><dl>${diagnostics.map(([label,value]) => `<div><dt>${esc(label)}</dt><dd>${esc(String(value))}</dd></div>`).join("")}</dl></details>`;

}

function renderCases() {
  if (!state?.run) return;
  const search = $("search").value.toLowerCase();
  const cases = state.case_index.filter((c) => c.id.toLowerCase().includes(search) && (!$("language").value || c.lang === $("language").value) && (!$("split").value || c.split === $("split").value));
  $("caseList").innerHTML = cases.map((c) => `<button class="case-button" type="button" data-case="${esc(c.id)}" aria-current="${c.id === selectedCase}">${esc(c.id)}<small>${esc(c.lang || "")} · ${esc(c.split || "")}</small></button>`).join("") || '<p class="muted">No cases match.</p>';
}

$("run").addEventListener("change", () => {
  selectedRun = $("run").value; renderedReport = ""; selectedCase = null; detail = null; detailRequest++;
  history.replaceState(null,"",`?${runQuery()}`);
  $("detail").innerHTML = '<p class="empty">Choose a case to inspect its corrections.</p>';
  refresh();
});
$("refresh").addEventListener("click", refresh);
$("metric").addEventListener("change", renderResults);
$("sort").addEventListener("change", renderResults);
$("laneFocus").addEventListener("change", renderBreakdowns);
for (const id of ["search","language","split"]) $(id).addEventListener("input", renderCases);
$("blind").addEventListener("change", renderDetailPreserving);
$("caseList").addEventListener("click", (event) => { const button = event.target.closest("[data-case]"); if (button) openCase(button.dataset.case); });
wireReview();

refresh();
setInterval(() => { if (!document.hidden) refresh(); }, 2500);
