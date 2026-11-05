// Review: one card at a time from the chosen queue, decided by button, swipe or key. The next card is always
// the first queue item without a label, so closing the page and coming back resumes where review stopped.
const Review = (() => {
  const S = Store.state;
  const $ = (id) => document.getElementById(id);
  const esc = Diff.esc;
  const SWIPE = 96;

  let queue = remember("queue") || "expected";
  let cur = null; // {item, kase, answer, sig}
  let pin = null; // an undone item stays on screen until it is decided again
  let editing = null; // the item the edit sheet was opened on keeps the screen while it is open
  let tab = "changes";
  let busy = false;
  let folds = [];
  const undo = [];
  const seen = new Set(); // queues whose explainer was dismissed, for when storage is unavailable
  const draft = { item: null, reasons: new Set(), note: "" }; // reasons and note for one card

  function remember(key, value) {
    try {
      if (value === undefined) return localStorage.getItem(`oops-eval.${key}`);
      localStorage.setItem(`oops-eval.${key}`, value);
    } catch {
      return null;
    }
  }

  function items(target) {
    const list = [];
    for (const [id, q] of S.queue) if (q.target === target && S.cases.has(q.case)) list.push({ id, ...q });
    return list.sort(
      (a, b) =>
        (b.flag ? 1 : 0) - (a.flag ? 1 : 0) || (a.order ?? 1e9) - (b.order ?? 1e9) || a.id.localeCompare(b.id),
    );
  }

  function render() {
    const all = { expected: items("expected"), output: items("output") };
    for (const t of ["expected", "output"]) {
      const left = all[t].filter((i) => !S.labels.has(i.id)).length;
      $(`count-${t}`).textContent = all[t].length ? String(left) : "";
      $(`q-${t}`).setAttribute("aria-selected", String(t === queue));
    }
    const list = all[queue];
    const pending = list.filter((i) => !S.labels.has(i.id));
    const done = list.length - pending.length;
    $("progress-text").textContent = `${done} of ${list.length} decided`;
    $("meter-fill").style.width = list.length ? `${(100 * done) / list.length}%` : "0";
    $("meter").setAttribute("aria-valuenow", String(done));
    $("meter").setAttribute("aria-valuemax", String(list.length));
    $("undo").disabled = !undo.length || busy;

    if (!seen.has(queue) && !remember(`intro.${queue}`)) return intro();
    const item = pending.find((i) => i.id === editing) || pending.find((i) => i.id === pin) || pending[0];
    if (!item) return empty(list.length > 0);
    const kase = S.cases.get(item.case);
    const answer = item.target === "expected" ? kase.expected : item.output;
    const sig = JSON.stringify([item, kase.input, kase.expected, kase.alternatives]);
    if (cur && cur.item.id === item.id && cur.sig === sig) return;
    if (!cur || cur.item.id !== item.id) tab = "changes";
    if (draft.item !== item.id) setDraft([], "", item.id);
    cur = { item, kase, answer, sig };
    card();
  }

  // Shown the first time each queue opens, and again from the help button.
  function intro() {
    cur = null;
    setDock(false, false);
    const { title, lead, rows } = Copy.queues[queue].intro;
    const list = rows
      .map(([k, how, what]) => `<div><dt>${k}${how ? `<span>${how}</span>` : ""}</dt><dd>${what}</dd></div>`)
      .join("");
    $("stage").innerHTML = `<section class="intro" aria-labelledby="intro-title"><h2 id="intro-title">${title}</h2>
      <p>${lead}</p><dl>${list}</dl>
      <p class="marks"><del>struck</del> removed from the draft, <ins>highlighted</ins> added to it</p>
      <button class="start" id="intro-start">Start</button></section>`;
    $("intro-start").focus({ preventScroll: true });
  }

  function empty(finished) {
    cur = null;
    setDock(false);
    const msg = {
      connecting: ["Loading the queue", "Cards appear as soon as the data arrives."],
      offline: ["Open this page in Claude", "Review needs the artifact's database. Open the artifact link while signed in."],
      error: ["The data didn't load", `The database answered “${S.error}”. Reload the page to try again.`],
    }[S.status] || (finished
      ? ["All decided", "Every card in this queue has a decision. New cards show up here as they are added."]
      : ["Nothing to review yet", Copy.queues[queue].empty]);
    $("stage").innerHTML = `<div class="empty"><h2>${msg[0]}</h2><p>${msg[1]}</p></div>`;
  }

  function setDock(on, shown = true) {
    $("dock").hidden = !shown;
    for (const b of document.querySelectorAll(".act, .chip")) b.disabled = !on;
  }

  function card() {
    const { item, kase, answer } = cur;
    const isOutput = item.target === "output";
    const known = answer === kase.expected || (kase.alternatives || []).includes(answer);
    const words = Copy.queues[item.target];
    for (const [id, [main, means]] of [
      ["act-agree", isOutput && !known ? words.agreeNew : words.agree],
      ["act-wrong", words.wrong],
      ["act-edit", words.edit],
    ]) {
      $(id).querySelector(".main").textContent = main;
      $(id).querySelector("small").textContent = means;
    }
    setDock(true);

    const errors = kase.tags?.errors || [];
    const changes = Diff.blocks(kase.input, answer).filter((b) => b.eq === undefined).length;
    const tags = [
      `<span class="tag lang">${Copy.langs[kase.lang] || esc(kase.lang)}</span>`,
      `<span class="tag">${Copy.lengths[kase.length] || esc(kase.length || "")}</span>`,
      errors.length
        ? `<span class="tag">Errors in draft: ${esc(errors.join(", ").replace(/_/g, " "))}</span>`
        : '<span class="tag clean">No errors in draft</span>',
      `<span class="tag diffs">${changes ? `${changes} edit${changes > 1 ? "s" : ""}` : "No edits"}</span>`,
      isOutput ? `<span class="tag diffs">${known ? "Same as key" : "Differs from key"}</span>` : "",
    ].join("");
    const tabs = words.tabs
      .map(([k, l]) => `<button role="tab" data-tab="${k}" aria-selected="${k === tab}">${l}</button>`)
      .join("");
    const el = document.createElement("article");
    el.className = "card enter";
    el.setAttribute("aria-label", `Case ${item.case}`);
    el.innerHTML = `
      <div class="stamp" aria-hidden="true"></div>
      <div class="card-head"><h2 class="question">${words.question}</h2>
        <button class="drop" id="act-drop" aria-keyshortcuts="d">Remove case</button></div>
      <div class="tags">${tags}</div>
      <div class="tabs" role="tablist" aria-label="View">${tabs}</div>
      <div class="card-body" id="card-body"></div>`;
    $("stage").replaceChildren(el);
    body();
    gestures(el);
  }

  function body() {
    const { item, kase, answer } = cur;
    const flag = item.flag ? `<p class="flag"><b>Drafter's question:</b> ${esc(item.flag)}</p>` : "";
    let html;
    if (tab === "draft") {
      html = `<p class="text plain">${esc(kase.input)}</p>`;
      folds = [];
    } else {
      const before = tab === "ref" ? kase.expected : kase.input;
      const r = Diff.render(before, answer, { fold: tab === "changes" });
      folds = r.folds;
      const same = tab === "ref" ? "Same as the answer key." : "No edits: the answer is the draft as written.";
      html = `<p class="text">${r.html}</p>${r.changes ? "" : `<p class="note-line">${same}</p>`}`;
    }
    $("card-body").innerHTML = flag + html;
  }

  // Decisions

  function label(decision, edited = null) {
    const { item } = cur;
    return {
      case: item.case,
      target: item.target,
      output_hash: item.output_hash ?? null,
      decision,
      edited,
      reasons: [...draft.reasons],
      note: draft.note.trim() || null,
      at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    };
  }

  async function decide(decision, dir, edited) {
    if (busy || !cur) return;
    if (!Store.writable) return toast("Decisions save only inside the Claude artifact viewer.");
    if (decision === "agree" && cur.item.target === "output") {
      const { kase, answer } = cur;
      if (answer !== kase.expected && !(kase.alternatives || []).includes(answer)) decision = "also_correct";
    }
    const id = cur.item.id;
    const rec = label(decision, edited ?? null);
    const step = { id, previous: S.labels.get(id) || null, label: rec, queue };
    busy = true;
    await flyOut(dir);
    undo.push(step);
    pin = null;
    setDraft([], "", null);
    busy = false;
    try {
      await Store.setLabel(id, rec);
    } catch (e) {
      undo.splice(undo.indexOf(step), 1);
      toast(`Not saved (${e?.code || "error"}). The card is back.`);
    }
    render();
  }

  async function undoLast() {
    if (busy || !undo.length) return;
    const step = undo.pop();
    if (step.queue !== queue) switchQueue(step.queue);
    pin = step.id;
    setDraft(step.label.reasons, step.label.note || "", step.id);
    try {
      await Store.clearLabel(step.id, step.previous);
      toast("Decision undone");
    } catch (e) {
      undo.push(step);
      toast(`Couldn't undo (${e?.code || "error"}).`);
    }
    render();
  }

  function setDraft(reasons, note, item) {
    draft.item = item;
    draft.reasons = new Set(reasons);
    draft.note = note;
    for (const c of document.querySelectorAll(".chip[data-reason]")) {
      c.setAttribute("aria-pressed", String(draft.reasons.has(c.dataset.reason)));
    }
    $("note").value = note;
    $("note").hidden = !note;
    $("note-toggle").setAttribute("aria-pressed", String(Boolean(note)));
  }

  function switchQueue(q) {
    queue = q;
    remember("queue", q);
    cur = null;
    render();
  }

  // Edit sheet

  function openEdit() {
    if (!cur || busy) return;
    editing = cur.item.id;
    $("editText").value = cur.answer;
    $("sheet").hidden = false;
    $("editText").focus();
  }

  function closeEdit() {
    $("sheet").hidden = true;
    editing = null;
    snapBack();
    render();
  }

  // Motion

  function flyOut(dir) {
    const el = $("stage").querySelector(".card");
    if (!el || matchMedia("(prefers-reduced-motion: reduce)").matches) return Promise.resolve();
    const to = { right: "translate(115%, 0) rotate(8deg)", left: "translate(-115%, 0) rotate(-8deg)",
      up: "translate(0, -70%)", down: "translate(0, 30%) scale(0.94)" }[dir] || "scale(0.96)";
    el.classList.add("leave");
    el.style.transform = to;
    return new Promise((r) => setTimeout(r, 180));
  }

  function snapBack() {
    const el = $("stage").querySelector(".card");
    if (!el) return;
    el.style.transition = "transform 0.2s cubic-bezier(0.2, 0.8, 0.2, 1)";
    el.style.transform = "";
    el.querySelector(".stamp").style.opacity = 0;
    setTimeout(() => (el.style.transition = ""), 220);
  }

  // Right agrees, left marks wrong, up edits. Up only starts once the card's text is scrolled to its end,
  // so reading a long draft never triggers it.
  function gestures(el) {
    const scroller = el.querySelector(".card-body");
    const stamp = el.querySelector(".stamp");
    let sx = 0, sy = 0, dx = 0, dy = 0, mode = null, atEnd = false, tracking = false;

    const begin = (x, y) => {
      sx = x;
      sy = y;
      dx = dy = 0;
      mode = null;
      tracking = true;
      atEnd = scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2;
    };
    const move = (x, y, e) => {
      if (!tracking) return;
      dx = x - sx;
      dy = y - sy;
      if (!mode) {
        if (Math.abs(dx) > 8 && Math.abs(dx) > Math.abs(dy)) mode = "h";
        else if (dy < -8 && atEnd && Math.abs(dy) > Math.abs(dx)) mode = "v";
        else if (Math.abs(dy) > 8) mode = "scroll";
      }
      if (mode === "h" || mode === "v" || (atEnd && dy < 0 && Math.abs(dy) >= Math.abs(dx))) e?.preventDefault();
      if (mode !== "h" && mode !== "v") return;
      const kind = mode === "v" ? "edit" : dx > 0 ? "agree" : "wrong";
      el.style.transform = mode === "h" ? `translate(${dx}px, 0) rotate(${dx / 28}deg)` : `translate(0, ${Math.min(0, dy)}px)`;
      stamp.className = `stamp ${kind}`;
      stamp.textContent = $(`act-${kind}`).querySelector(".main").textContent;
      stamp.style.opacity = Math.min(1, Math.abs(mode === "h" ? dx : dy) / SWIPE);
    };
    const end = () => {
      if (!tracking) return;
      tracking = false;
      if (mode === "h" && Math.abs(dx) >= SWIPE) decide(dx > 0 ? "agree" : "wrong", dx > 0 ? "right" : "left");
      else if (mode === "v" && -dy >= SWIPE) openEdit();
      else if (mode === "h" || mode === "v") snapBack();
      mode = null;
    };

    el.addEventListener("touchstart", (e) => e.touches.length === 1 && begin(e.touches[0].clientX, e.touches[0].clientY), { passive: true });
    el.addEventListener("touchmove", (e) => move(e.touches[0].clientX, e.touches[0].clientY, e), { passive: false });
    el.addEventListener("touchend", end);
    el.addEventListener("touchcancel", () => ((mode = mode && "cancel"), end(), snapBack()));
    el.addEventListener("pointerdown", (e) => {
      if (e.pointerType !== "mouse" || e.button !== 0 || e.target.closest("button")) return;
      begin(e.clientX, e.clientY);
      const mm = (ev) => move(ev.clientX, ev.clientY);
      const up = () => (removeEventListener("pointermove", mm), removeEventListener("pointerup", up), end());
      addEventListener("pointermove", mm);
      addEventListener("pointerup", up);
    });
  }

  let toastTimer;
  function toast(text) {
    const t = $("toast");
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (t.hidden = true), 2400);
  }

  // Wiring

  $("act-agree").onclick = () => decide("agree", "right");
  $("act-wrong").onclick = () => decide("wrong", "left");
  $("act-edit").onclick = openEdit;
  $("undo").onclick = undoLast;
  $("help").onclick = () => {
    seen.delete(queue);
    remember(`intro.${queue}`, "");
    cur = null;
    render();
  };
  $("stage").addEventListener("click", (e) => {
    const t = e.target.closest("button");
    if (!t) return;
    if (t.id === "act-drop") decide("drop", "down");
    else if (t.id === "intro-start") {
      seen.add(queue);
      remember(`intro.${queue}`, "seen");
      render();
    }
    else if (t.dataset.tab) {
      tab = t.dataset.tab;
      for (const b of t.parentNode.children) b.setAttribute("aria-selected", String(b === t));
      body();
    } else if (t.dataset.fold) {
      const span = document.createElement("span");
      span.className = "eq";
      span.textContent = folds[Number(t.dataset.fold)];
      t.replaceWith(span);
    }
  });
  for (const b of document.querySelectorAll("[data-queue]")) b.onclick = () => switchQueue(b.dataset.queue);
  for (const c of document.querySelectorAll(".chip[data-reason]")) {
    c.onclick = () => {
      const r = c.dataset.reason;
      draft.reasons.has(r) ? draft.reasons.delete(r) : draft.reasons.add(r);
      c.setAttribute("aria-pressed", String(draft.reasons.has(r)));
    };
  }
  $("note-toggle").onclick = () => {
    const show = $("note").hidden;
    $("note").hidden = !show;
    $("note-toggle").setAttribute("aria-pressed", String(show || Boolean(draft.note)));
    if (show) $("note").focus();
  };
  $("note").oninput = (e) => (draft.note = e.target.value);
  $("edit-cancel").onclick = closeEdit;
  $("sheet").addEventListener("click", (e) => {
    if (e.target === $("sheet")) closeEdit();
  });
  $("edit-form").onsubmit = (e) => {
    e.preventDefault();
    const text = $("editText").value;
    if (!cur || cur.item.id !== editing) return toast("This card was decided elsewhere. Cancel to go on.");
    if (text === cur.answer) return toast("The text is unchanged. Change it, or cancel.");
    $("sheet").hidden = true;
    editing = null;
    decide("edit", "up", text);
  };

  addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (!$("sheet").hidden) return e.key === "Escape" && closeEdit();
    if (e.target.closest?.("input, textarea, select") || $("review").hidden || $("intro-start")) return;
    const chip = document.querySelectorAll(".chip[data-reason]")[Number(e.key) - 1];
    const act = { ArrowRight: () => decide("agree", "right"), ArrowLeft: () => decide("wrong", "left"),
      ArrowUp: openEdit, e: openEdit, d: () => decide("drop", "down"), z: undoLast, u: undoLast,
      n: () => $("note-toggle").click() }[e.key] || (chip && (() => chip.click()));
    if (act) {
      e.preventDefault();
      act();
    }
  });

  Store.on((what) => {
    if (["cases", "queue", "labels", "status"].includes(what)) render();
  });
  render();
  return { render };
})();
