/* Completion forecasts use observed wall-clock throughput, including pacing and failures. */
const Live = (() => {
  const number = (n) => n.toLocaleString();
  const fraction = (n, total) => total > 0 ? Math.min(n / total, 1) : 0;
  const duration = (seconds) => {
    const minutes = Math.max(1, Math.ceil(seconds / 60));
    return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
  };
  const clock = (timestamp) => new Date(timestamp).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"});
  function estimate(remaining, completed, elapsed) {
    return remaining <= 0 ? 0 : completed >= 10 && elapsed >= 30 ? remaining * elapsed / completed : null;
  }
  function forecast(state, now = Date.now()) {
    const session = state.manifest.sessions?.at(-1);
    const elapsed = session ? Math.max(0, (now - Date.parse(session.started)) / 1000) : 0;
    const providers = new Map();
    const lanes = state.lanes.filter((l) => l.state !== "skipped");
    for (const lane of lanes) {
      const p = providers.get(lane.provider) || {remaining: 0, completed: 0};
      p.remaining += Math.max(0, lane.expected - lane.metrics.calls);
      p.completed += lane.session_calls || 0;
      providers.set(lane.provider, p);
    }
    const remaining = [...providers.values()].filter((p) => p.remaining > 0);
    const estimates = remaining.map((p) => estimate(p.remaining, p.completed, elapsed));
    const deferred = lanes.some((l) => l.metrics.calls < l.expected && l.state === "deferred");
    return {
      elapsed, deferred,
      complete: lanes.length > 0 && remaining.length === 0,
      seconds: !lanes.length || !state.generating || deferred || estimates.some((s) => s == null) ? null : Math.max(0, ...estimates),
      laneSeconds: (lane) => estimate(lane.expected - lane.metrics.calls, lane.session_calls || 0, elapsed),
    };
  }
  function judgeForecast(progress, now = Date.now()) {
    if (progress?.status !== "running") return null;
    const elapsed = (now - Date.parse(progress.started)) / 1000;
    if (!progress.by_judge) return estimate(progress.total - progress.done, progress.done, elapsed);
    const remaining = Object.values(progress.by_judge).filter((j) => j.total > j.done);
    const estimates = remaining.map((j) => estimate(j.total - j.done, j.done, elapsed));
    return estimates.some((s) => s == null) ? null : Math.max(0, ...estimates);
  }
  function render(state, esc, modelCell) {
    const $ = (id) => document.getElementById(id);
    const calibration = state.experiment?.kind === "calibration";
    const lanes = state.lanes.filter((l) => l.state !== "skipped");
    const total = lanes.reduce((n, l) => n + l.expected, 0);
    const done = lanes.reduce((n, l) => n + l.metrics.calls, 0);
    const scored = lanes.reduce((n, l) => n + l.metrics.judged, 0);
    const finished = lanes.filter((l) => l.metrics.calls >= l.expected).length;
    const now = Date.now(), eta = forecast(state, now);
    $("liveOverview").hidden = false;
    $("generationLabel").textContent = calibration ? "Frozen answers" : "Generation";
    $("generationPercent").textContent = `${(100 * fraction(done, total)).toFixed(1)}%`;
    $("generationBar").max = total || 1; $("generationBar").value = done;
    $("progressSummary").textContent = `${number(done)} / ${number(total)} ${calibration ? "frozen answer records" : "calls recorded"}`;
    $("generationDetail").textContent = calibration ? "Historical and authored answers. No correction generation." : `${finished} / ${lanes.length} lanes finished · Includes failed calls; completion does not mean success.`;
    $("etaLabel").textContent = calibration ? "Generation" : "Estimated generation remaining";
    $("generationEta").textContent = calibration ? "Not running" : eta.complete ? "Complete" : eta.deferred ? "Quota hold" : !state.generating ? "Paused" : eta.seconds == null ? "Estimating…" : `~${duration(eta.seconds)}`;
    $("generationFinish").textContent = calibration ? "Calibration panel" : eta.complete ? "All planned calls recorded" : eta.deferred ? "Waiting for a provider reset" : !state.generating ? "Resume required for remaining calls" : eta.seconds == null ? "Waiting for enough completed calls" : `Around ${clock(now + eta.seconds * 1000)} · at current throughput`;
    $("scoringCount").textContent = `${number(scored)} / ${number(total)} scored`;
    $("scoringBar").max = total || 1; $("scoringBar").value = scored;
    const j = state.judging, jp = state.judge_progress;
    $("judgeProgress").textContent = `Decisions ${number(j.decisions_done)} · Codex ${number(j.codex_done)} · ${number(j.sources.pending || 0)} pending · ${number(j.sources.disagreement || 0)} disputed. Provisional.${jp ? ` Judge requests ${jp.done}/${jp.total}: ${jp.status}.` : " Judges have not started; automatic scores appear first."}`;
    const judgeSeconds = judgeForecast(jp, now);
    const workerStatus = jp?.status === "running" && jp.workers ? `Sol ${jp.by_judge?.codex?.active || 0}/${jp.workers.codex} workers active · Decisions ${jp.by_judge?.decisions?.active || 0}/${jp.workers.decisions} workers active.` : "";
    $("judgeEta").hidden = !workerStatus && judgeSeconds == null;
    $("judgeEta").textContent = `${workerStatus}${judgeSeconds == null ? workerStatus ? " ETA estimating…" : "" : ` Judging: ~${duration(judgeSeconds)} remaining at current throughput. Adjudication follows.`}`;
    $("liveRows").innerHTML = state.lanes.map((l) => {
      const m = l.metrics, complete = m.calls >= l.expected && l.state !== "skipped";
      const active = state.generating && !complete && !["done", "skipped", "deferred"].includes(l.state);
      const status = complete ? "Done" : active ? "Running" : l.state === "pending" ? "Paused" : l.state;
      const remaining = eta.laneSeconds(l);
      const when = calibration ? "Frozen" : complete ? "Complete" : l.state === "deferred" ? "Quota hold" : l.state === "skipped" ? "—" : !active ? "Paused" : remaining == null ? "Estimating…" : `~${duration(remaining)}`;
      const activity = l.deferred_until ? `Reset ${new Date(l.deferred_until).toLocaleString()}` : l.live ? `${l.live.requests} sends · ${l.live.rate_limited} rate limits` : "";
      return `<tr><td>${modelCell(l)}</td><td class="lane-generation"><div class="progress-heading"><span>${number(m.calls)} / ${number(l.expected)}</span><span>${(100 * fraction(m.calls, l.expected)).toFixed(0)}%</span></div><progress max="${l.expected || 1}" value="${m.calls}" aria-label="${esc(l.resolved)} generation"></progress></td><td class="lane-scoring">${number(m.judged)} / ${number(m.calls)}<progress max="${l.expected || 1}" value="${m.judged}" aria-label="${esc(l.resolved)} scoring coverage"></progress></td><td><span class="lane-state" data-state="${active ? "active" : complete ? "done" : "idle"}">${esc(status)}</span>${l.deferred ? `<small>${l.deferred} deferred</small>` : ""}</td><td${m.errors + m.invalid ? ' class="has-failures"' : ""}>${m.errors} / ${m.invalid}</td><td class="lane-eta">${esc(when)}<small>${esc(activity)}</small></td></tr>`;
    }).join("");
  }
  return {render, forecast, judgeForecast};
})();
