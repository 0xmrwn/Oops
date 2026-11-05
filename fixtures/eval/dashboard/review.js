/* Blind case review and local drafts. Model and owner judgments stay separate. */
let reviewDrafts = {};
try { reviewDrafts = JSON.parse(localStorage.getItem("oops-review-drafts") || "{}"); } catch { /* Storage may be unavailable. */ }

function readReview(form, task) {
  const data = new FormData(form);
  const judgment = {fully_correct:data.get("fully_correct"),faithful:data.get("faithful"),explanation:data.get("explanation") || "Owner review.",edits:[],misses:[]};
  for (const type of ["edits","misses"]) {
    const items = type === "edits" ? task.evidence.edits : task.evidence.reference_edits;
    judgment[type] = items.map((item) => ({id:item.id,verdict:data.get(`${type}:${item.id}`),explanation:"Owner review."}));
  }
  return judgment;
}

function persistDrafts() {
  try { localStorage.setItem("oops-review-drafts", JSON.stringify(reviewDrafts)); return true; } catch { return false; }
}

async function refreshCaseEvidence() {
  if (!detail || detail.case.id !== selectedCase) return;
  const serial = detailRequest, run = selectedRun, id = selectedCase;
  try {
    const next = await request(`/api/case?${runQuery()}&id=${encodeURIComponent(id)}`);
    if (serial !== detailRequest || run !== selectedRun || id !== selectedCase) return;
    if (JSON.stringify(next) !== JSON.stringify(detail)) { detail = next; renderDetailPreserving(); }
    if ($("caseStatus")) $("caseStatus").hidden = true;
  } catch {
    if (serial === detailRequest && $("caseStatus")) {
      $("caseStatus").hidden = false;
      $("caseStatus").textContent = "Case evidence could not refresh. Your review draft is kept; retry with Refresh.";
    }
  }
}

function renderDetailPreserving() {
  const root = $("detail"), active = document.activeElement, form = active?.closest(".review-form");
  const focus = form && root.contains(active) ? {key:form.dataset.key,name:active.name || "submit",start:active.selectionStart,end:active.selectionEnd} : null;
  const openness = new Map(), counts = new Map(), statuses = new Map();
  for (const element of root.querySelectorAll("details")) {
    const key = element.closest("article")?.dataset.answerKey || "root", index = counts.get(key) || 0;
    openness.set(`${key}:${index}`, element.open); counts.set(key,index+1);
  }
  for (const item of root.querySelectorAll(".review-form")) statuses.set(item.dataset.key,item.querySelector(".save-state").textContent);
  const reading = [...root.querySelectorAll("article")].find((item) => { const r=item.getBoundingClientRect(); return r.bottom>100 && r.top<innerHeight; });
  const readingKey = reading?.dataset.answerKey, readingTop = reading?.getBoundingClientRect().top;
  renderDetail(); counts.clear();
  for (const element of root.querySelectorAll("details")) {
    const key = element.closest("article")?.dataset.answerKey || "root", index=counts.get(key)||0, identity=`${key}:${index}`;
    if (openness.has(identity)) element.open=openness.get(identity);
    counts.set(key,index+1);
  }
  for (const item of root.querySelectorAll(".review-form")) if (statuses.has(item.dataset.key)) item.querySelector(".save-state").textContent=statuses.get(item.dataset.key);
  if (focus) {
    const nextForm=root.querySelector(`form[data-key="${CSS.escape(focus.key)}"]`);
    const next=focus.name==="submit" ? nextForm?.querySelector('button[type="submit"]') : nextForm?.querySelector(`[name="${CSS.escape(focus.name)}"]`);
    next?.focus({preventScroll:true});
    if (typeof focus.start==="number" && next?.setSelectionRange) next.setSelectionRange(focus.start,focus.end);
  }
  if (readingKey) {
    const anchor=root.querySelector(`article[data-answer-key="${CSS.escape(readingKey)}"]`);
    if (anchor) scrollBy(0,anchor.getBoundingClientRect().top-readingTop);
  }
}
async function openCase(id) {
  selectedCase = id; renderCases();
  const serial = ++detailRequest;
  $("detail").innerHTML = '<p class="empty">Loading correction evidence…</p>';
  try {
    const next = await request(`/api/case?${runQuery()}&id=${encodeURIComponent(id)}`);
    if (serial !== detailRequest) return;
    detail = next; renderDetail();
  } catch (error) { if (serial === detailRequest) $("detail").innerHTML = `<p class="error">${esc(error.message)}</p>`; }
}

function choice(label, name, choices, value = "uncertain") {
  return `<label>${esc(label)}<select name="${esc(name)}">${choices.map(([v, text]) => `<option value="${v}"${v === value ? " selected" : ""}>${esc(text)}</option>`).join("")}</select></label>`;
}

function humanForm(task, human, title = "Grade this answer") {
  const committed = Boolean(human), draft = reviewDrafts[task.key];
  human = draft || human;
  const e = task.evidence;
  const field = (items, type, choices) => items.map((item) => {
    const saved = human?.[type].find((x) => x.id === item.id);
    return `<div class="edit-label"><code>${esc(item.before || "(insertion)")} → ${esc(item.after || "(deletion)")}</code>${choice(type === "edits" ? "This change is…" : "This reference correction is…", `${type}:${item.id}`, choices, saved?.verdict)}</div>`;
  }).join("");
  return `<details${committed && !draft ? "" : " open"}><summary>${draft ? "Continue your draft" : committed ? "Your saved judgment — edit" : title}</summary><form class="review-form" aria-label="${esc(title)}" data-key="${task.key}">
    ${choice("Is this a fully correct answer?", "fully_correct", [["uncertain","Not sure"],["yes","Yes, fully acceptable"],["no","No, a problem remains"]], human?.fully_correct)}
    ${choice("Does it preserve meaning, register and language?", "faithful", [["uncertain","Not sure"],["yes","Yes"],["no","No"]], human?.faithful)}
    ${field(e.edits, "edits", [["uncertain","Not sure"],["needed","Needed and correct"],["optional","Acceptable, unnecessary"],["harmful","Wrong or violates policy"]])}
    ${field(e.reference_edits, "misses", [["uncertain","Not sure"],["satisfied","Fixed, including valid alternatives"],["missed","Real error still missed"],["optional","Reference change was optional"]])}
    <label>Your note<textarea name="explanation" placeholder="Optional context for this judgment">${esc(human?.explanation || "")}</textarea></label><button type="submit">Save judgment</button><span class="save-state" role="status"></span></form></details>`;
}

function renderDetail() {
  if (!detail) return;
  const c = detail.case, blind = $("blind").checked;
  const grouped = new Map();
  for (const answer of detail.answers) {
    const key = answer.task || answer.raw_task ? `${answer.task?.key || "failure"}:${answer.raw_task?.key || "same"}` : `${answer.record.file}:${answer.record.attempt}`;
    if (!grouped.has(key)) grouped.set(key, {answer, calls: []});
    grouped.get(key).calls.push(answer.record);
  }
  const groups = [...grouped.values()].sort((a,b) => (a.answer.task?.key || a.answer.record.file).localeCompare(b.answer.task?.key || b.answer.record.file));
  $("detail").innerHTML = `<h3>${esc(c.id)}</h3><p class="muted"><a href="#review-policy">Read the correction policy and grading labels</a></p><p id="caseStatus" class="muted" role="status" hidden></p><p class="muted">${esc(c.lang || "")} · ${esc(c.length || "")} · ${esc(c.origin || "")} · ${esc(c.split || "")}</p><details><summary>Original draft</summary><p class="draft">${esc(c.input)}</p></details>${c.expected != null ? `<details><summary>Approved reference and alternatives</summary><div class="diff">${Diff.render(c.input,c.expected).html}</div>${(c.alternatives || []).map((a) => `<div class="diff">${Diff.render(c.input,a).html}</div>`).join("")}</details>` : '<p class="muted">No reviewed reference for this historical draft. Evaluate the answer against the correction policy.</p>'}` +
    (groups.length ? groups.map(({answer:a,calls}, index) => {
      const r = a.record;
      const name = blind ? `Answer ${index + 1}` : [...new Set(calls.map((x) => `${x.model} / ${x.provider}`))].join(", ");
      const judges = judgeEvidence(a.judges);
      const rawReview = a.raw_task ? `<details><summary>Raw model answer — before reconciliation</summary><div class="diff">${Diff.render(c.input,a.raw_task.evidence.corrected).html}</div>${state.experiment ? humanForm(a.raw_task,a.raw_judges.human?.judgment,"Grade raw model answer") : ""}<details><summary>Raw answer judge evidence</summary>${judgeEvidence(a.raw_judges)}</details></details>` : "";
      return `<article class="answer" data-answer-key="${esc((a.task?.key || r.file + r.attempt) + ":" + (a.raw_task?.key || "same"))}"><div class="answer-head"><h3>${esc(name)}</h3><small>${calls.length} call${calls.length === 1 ? "" : "s"}${blind ? "" : ` · ${esc(a.source)}`}</small></div>${r.output != null ? `<div class="diff">${Diff.render(c.input,r.output).html}</div>` : `<p class="error">${esc(r.error || r.verdict)}</p>`}
        ${a.task && state.experiment ? humanForm(a.task,a.judges.human?.judgment) : ""}${rawReview}<details><summary>Judge evidence</summary>${judges || '<p class="muted">No model judgments saved. Code-scored answers use the approved answer key.</p>'}</details><details><summary>Raw response and timing</summary><pre>${esc(JSON.stringify({raw:r.raw, dropped_edits:r.dropped_edits, raw_judgment:a.raw_judgment, checks:r.checks, completion_ms:r.total_ms, full_wait_ms:r.elapsed_ms, first_token_ms:r.ttft_ms, first_content_ms:r.ttfc_ms, retries:r.retries},null,2))}</pre></details></article>`;
    }).join("") : '<p class="empty">This case has no generated answers yet.</p>');
}


function judgeEvidence(rows) {
  return Object.entries(rows).filter(([name]) => name !== "human").map(([name,j]) => `<div class="judge-evidence"><h3>${esc(name)} · ${esc(j.judgment.fully_correct)}</h3><p>${esc(j.judgment.explanation)}</p>${[...j.judgment.edits,...j.judgment.misses].map((x) => `<p>${esc(x.id)}: ${esc(x.verdict)} — ${esc(x.explanation)}</p>`).join("")}</div>`).join("") || '<p class="muted">No model judgments saved. Code-scored answers use the approved answer key.</p>';
}

function reviewTarget(key) {
  for (const answer of detail.answers) {
    if (answer.task?.key === key) return {task:answer.task,judges:answer.judges};
    if (answer.raw_task?.key === key) return {task:answer.raw_task,judges:answer.raw_judges};
  }
  throw new Error("Review evidence changed. Reload this case.");
}

function wireReview() {
$("detail").addEventListener("input", (event) => {
  const form = event.target.closest(".review-form");
  if (!form) return;
  const {task} = reviewTarget(form.dataset.key);
  reviewDrafts[task.key] = readReview(form, task);
  form.querySelector(".save-state").textContent = persistDrafts() ? "Draft kept in this browser. Save judgment to finish." : "Draft not saved locally. Keep this tab open until you save.";
});
$("detail").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target, key = form.dataset.key;
  const {task,judges} = reviewTarget(key);
  const judgment = readReview(form, task);
  const button = form.querySelector("button"), status = form.querySelector(".save-state");
  button.disabled = true; status.textContent = "Saving…";
  try {
    await request(`/api/labels?${runQuery()}`, {method:"POST",headers:{"Content-Type":"application/json","X-Oops-Token":state.token},body:JSON.stringify({key,judgment})});
    judges.human = {judgment}; delete reviewDrafts[key]; persistDrafts(); status.textContent = "Saved on this Mac"; refresh();
  } catch(error) { status.textContent = `Not saved: ${error.message}`; }
  finally { button.disabled = false; }
});
}
