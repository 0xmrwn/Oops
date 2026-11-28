// Hero mock: one draft, three acts, three places. Oops fixes the draft in a
// chat composer, writes what is said after it in an email, and runs an action
// on it in a document: the words stay, the field around them changes. Timings
// follow the app (EyesDrop, Highlight, HelloDirector, DictationDrop, Wheel).

const T = { invoked: 150, working: 950, swap: 60, check: 900, result: 2000, note: 1100, first: 1500, next: 2400, rest: 6500 };

const field = $("field"), hero = field.parentElement, again = $("again");
// Each act plays in its own kind of text field.
const PLACE = { fix: "chat", dictate: "mail", actions: "doc" };
const triggers = Object.fromEntries([...document.querySelectorAll("#triggers [data-act]")].map((button) => [button.dataset.act, button]));

let did = { fixed: false, spoken: false, acted: false };
let busy = false;
let run = 0; // bumps on every reset so stale timers do nothing
let auto = 0, turn = 0;

// Self-play: runs `step` after a pause, and waits while the tab is in the
// background, so nothing plays to an empty room.
function later(step, ms) {
  const mine = ++turn;
  clearTimeout(auto);
  auto = setTimeout(function go() {
    if (mine !== turn) return;
    if (document.hidden) return document.addEventListener("visibilitychange", go, { once: true });
    step();
  }, ms * SLOW);
}
function stopSelfPlay() { turn++; clearTimeout(auto); }
let typing = false;

const escapeHTML = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

// The draft as it stands after the acts played so far.
function text(state = did) {
  if (state.acted) return RESULTS[state.acted][state.spoken ? 1 : 0][0];
  return (state.fixed ? SCENE.fixed : SCENE.typed) + (state.spoken ? ` ${SCENE.spoken}` : "");
}

// Indexes of the words in `after` that are not part of the longest common
// subsequence with `before`: the words the correction changed.
function changedWords(before, after) {
  const a = before.split(" "), b = after.split(" ");
  const lcs = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const changed = new Set();
  let i = 0, j = 0;
  while (j < b.length) {
    if (i < a.length && a[i] === b[j]) { i++; j++; }
    else if (i < a.length && lcs[i + 1][j] >= lcs[i][j + 1]) i++;
    else changed.add(j++);
  }
  return changed;
}

// `ghost` is what Dictate has heard so far: greyed out past the caret.
function markup(content, changed = new Set(), ghost = "") {
  let n = 0;
  const words = content.split(" ").map((word, index) => {
    const html = escapeHTML(word).replace(/`([^`]+)`/g, "<code>$1</code>");
    return changed.has(index) ? `<mark style="--i:${n++}">${html}</mark>` : html;
  });
  const heard = ghost ? `<span class="ghost"> ${escapeHTML(ghost)}</span>` : "";
  return `${words.join(" ")}<span class="caret"></span>${heard}`;
}

function render(content, changed, ghost) {
  draft.innerHTML = markup(content, changed, ghost);
  // The chat composer hugs the words, so the field needs their height.
  hero.style.setProperty("--text-h", `${draft.offsetHeight}px`);
}

// Where the caret will be once the draft reads `content`: drops appear there,
// so none is left stranded when its act reflows the words.
function caretAfter(content) {
  const now = draft.innerHTML;
  draft.innerHTML = markup(content);
  const spot = caretSpot();
  draft.innerHTML = now;
  return spot;
}

// Holds room for the tallest the draft gets, so nothing below it ever moves,
// and lays the glass over everything the drops and the wheel can reach.
function reserve() {
  stage.style.minHeight = "";
  const now = draft.innerHTML, around = stage.offsetHeight - draft.offsetHeight;
  let tallest = 0;
  const answers = Object.keys(RESULTS).flatMap((acted) => [{ acted }, { acted, spoken: true }]);
  for (const state of [{}, { fixed: true }, { spoken: true }, { fixed: true, spoken: true }, ...answers]) {
    draft.innerHTML = markup(text(state));
    tallest = Math.max(tallest, draft.offsetHeight);
  }
  draft.innerHTML = now;
  stage.style.minHeight = `${tallest + around}px`;
  hero.style.setProperty("--body-h", `${tallest + around}px`);
  hero.style.setProperty("--text-h", `${draft.offsetHeight}px`);
  glass?.fit(-stage.offsetLeft - 60, -stage.offsetTop - 20, field.offsetWidth + 120, field.offsetHeight + 60);
}

async function swapText(content, changed) {
  draft.classList.add("is-swapping");
  await sleep(T.swap);
  render(content, changed);
  draft.classList.remove("is-swapping");
}

function refresh() {
  const state = { fix: !did.acted, dictate: !did.acted && !did.spoken, actions: true };
  for (const [act, button] of Object.entries(triggers)) {
    button.setAttribute("aria-disabled", String(busy || !state[act]));
  }
  again.disabled = busy || typing || !(did.fixed || did.spoken || did.acted);
  again.classList.toggle("is-in", !again.disabled);
  triggers.fix.querySelector(".word").textContent = did.fixed && !did.acted ? "Undo" : "Fix";
  // The next act worth trying taps its own keys, so the eye lands on it.
  const next = !did.fixed ? "fix" : !did.spoken ? "dictate" : !did.acted ? "actions" : "";
  for (const [act, button] of Object.entries(triggers)) button.classList.toggle("is-next", !busy && act === next && !did.acted);
}

const acts = {
  async fix(mine) {
    const before = text(), undo = did.fixed;
    did.fixed = !undo;
    const words = undo ? "Reverted" : `${SCENE.fixes} fixes`;
    Drop.show(...anchor(Drop.widthFor(words), caretAfter(text())), words);
    if (undo) {
      eyes.pose({ gx: 0.1, gy: -0.95 });
      await swapText(text());
      Drop.widen(words);
      await sleep(T.note);
    } else {
      eyes.pose({ gx: -0.6, gy: -0.5, lid: 0.15 });
      await sleep(T.invoked);
      Drop.work(true);
      eyes.read();
      await sleep(T.working);
      if (mine !== run) return;
      await swapText(text(), changedWords(before, text()));
      Drop.work(false);
      Drop.widen(words);
      Sound.success();
      eyes.pose({ check: 1 });
      await sleep(T.check);
      eyes.pose({ gx: -0.9, gy: 0.35, lid: 0.55 });
      await sleep(T.result - T.check);
    }
    if (mine === run) Drop.hide();
  },

  async dictate(mine) {
    const base = text();
    Voice.listen(...anchor(168 * unit(), caretAfter(`${base} ${SCENE.spoken}`)));
    await sleep(500);
    let heard = "";
    for (const word of SCENE.spoken.split(" ")) {
      if (mine !== run) return;
      heard += (heard ? " " : "") + word;
      render(base, undefined, heard);
      await sleep(160 + 35 * word.length);
    }
    await sleep(350);
    Voice.transcribe();
    await sleep(450);
    if (mine !== run) return;
    did.spoken = true;
    await swapText(text());
    Voice.written();
    await sleep(T.note);
    if (mine === run) Voice.hide();
  },

  // Left alone the hero picks an action itself; a visitor gets the wheel to use.
  async actions(mine, byVisitor) {
    const d = drop.offsetHeight, u = unit();
    // The wheel opens on the drop's usual place, lowered so the top petal
    // clears the words, and kept inside the stage.
    const reach = Wheel.reach(), [ax, ay] = anchor(d);
    const room = stage.clientWidth;
    const x = room < reach.side * 2 ? room / 2 : Math.max(reach.side, Math.min(ax + d / 2, room - reach.side));
    Drop.show(x - d / 2, ay + 66 * u);
    eyes.pose({ gx: -0.6, gy: -0.5 });
    Wheel.open(x, ay + d / 2 + 66 * u, did.acted ? did.acted.split(":")[0] : "");
    const choice = byVisitor ? await Wheel.pick() : (await sleep(850), await Wheel.demo(SCENE.action));
    if (mine !== run) return;
    Wheel.close();
    if (!choice) return Drop.hide();
    await sleep(240);

    if (choice.restore) {
      did.acted = false;
      eyes.pose({ gx: 0.1, gy: -0.95 });
      await swapText(text());
      Drop.move(...anchor(Drop.widthFor("Restored")));
      Drop.widen("Restored");
      await sleep(T.note);
    } else {
      const asked = choice.choice ? `${choice.action}:${choice.choice}` : choice.action;
      // The wait is the time the answer really took.
      const took = RESULTS[asked][did.spoken ? 1 : 0][1];
      Drop.widen(`${choice.action}…`);
      Drop.work(true);
      eyes.read();
      await sleep(took);
      if (mine !== run) return;
      did.acted = asked;
      await swapText(text());
      Drop.work(false);
      // The draft has changed length: the drop glides back to the caret.
      const done = `${choice.action} · ${(took / 1000).toFixed(1)} s`;
      Drop.move(...anchor(Drop.widthFor(done)));
      Drop.widen(done);
      Sound.success();
      eyes.pose({ check: 1 });
      await sleep(T.check);
      eyes.pose({ gx: -0.9, gy: 0.35, lid: 0.55 });
      await sleep(T.result - T.check);
    }
    if (mine === run) Drop.hide();
  },
};

async function play(act, byVisitor) {
  // With the wheel open and waiting, its own trigger closes it.
  if (act === "actions" && Wheel.isOpen()) return Wheel.cancel();
  // A visitor who acts while the draft is still being typed gets it whole.
  if (typing && byVisitor) { run++; typing = false; render(text()); }
  if (busy || triggers[act].getAttribute("aria-disabled") === "true") return;
  if (byVisitor) stopSelfPlay();
  Sound.aloud = byVisitor;
  const mine = ++run;
  busy = true;
  refresh();
  if (field.dataset.kind !== PLACE[act]) {
    // The field redraws itself around the draft before the act begins.
    field.dataset.kind = PLACE[act];
    await sleep(650);
  }
  await acts[act](mine, byVisitor);
  if (mine !== run) return;
  busy = false;
  refresh();
  // Left alone, the hero goes on to the next act by itself.
  const next = { fix: "dictate", dictate: "actions" }[act];
  // Only what a visitor asked for is read out, and only once it is whole.
  if (byVisitor) return void ($("said").textContent = text());
  if (next) later(() => play(next, false), T.next);
  else later(start, T.rest);
}

// The hero opens on an empty field and types the draft in, typos and all,
// at the pace of the app's welcome scene. It is also how it starts over.
async function start() {
  const mine = ++run;
  stopSelfPlay();
  Drop.hide();
  Voice.hide();
  Wheel.close();
  did = { fixed: false, spoken: false, acted: false };
  busy = false;
  field.dataset.kind = "chat";
  const calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  typing = !calm;
  render(calm ? text() : "");
  reserve();
  refresh();
  for (let i = 1; typing && i <= SCENE.typed.length; i++) {
    await sleep(SCENE.typed[i - 1] === " " ? 70 + Math.random() * 90 : 48 + Math.random() * 46);
    if (mine !== run) return;
    render(SCENE.typed.slice(0, i));
  }
  typing = false;
  refresh();
  later(() => play("fix", false), T.first);
}

// The shortcuts only exist on a Mac keyboard; elsewhere the words are buttons.
document.documentElement.classList.toggle("no-keys", !/Mac/.test(navigator.platform) || navigator.maxTouchPoints > 0);

// Shortcuts are matched on the letter, wherever the keyboard layout puts it.
const KEYS = { w: "fix", x: "dictate", e: "actions" };
for (const [act, button] of Object.entries(triggers)) button.addEventListener("click", () => play(act, true));
again.addEventListener("click", start);
addEventListener("keydown", (event) => {
  const letter = event.key.length === 1 ? event.key : event.code.replace("Key", "");
  const act = KEYS[letter.toLowerCase()];
  if (!act || !event.ctrlKey || !event.metaKey) return;
  event.preventDefault();
  triggers[act].classList.add("is-pressed");
  setTimeout(() => triggers[act].classList.remove("is-pressed"), 160);
  play(act, true);
});

addEventListener("resize", reserve);
document.fonts?.ready.then(reserve);
start();

// The download button fetches the installer itself. The file's name carries
// the version, so the latest one is looked up; until then, and if the lookup
// fails, the button opens the release page.
fetch("https://api.github.com/repos/0xmrwn/Oops/releases/latest")
  .then((answer) => answer.json())
  .then((release) => {
    const installer = release.assets?.find((asset) => asset.name.endsWith(".dmg"));
    if (installer) document.querySelector(".get").href = installer.browser_download_url;
  })
  .catch(() => {});
