// What every act shares: the stage, the glass, and the drop with its eyes.

const $ = (id) => document.getElementById(id);
const stage = $("stage"), draft = $("draft"), drop = $("drop"), label = $("dropLabel");
// Review aid: ?slow=8 plays every pause and CSS transition eight times slower.
const SLOW = Number(new URLSearchParams(location.search).get("slow")) || 1;
const sleep = (ms) => new Promise((done) => setTimeout(done, ms * SLOW));
if (SLOW !== 1) {
  const stretch = (value) => value.replace(/([\d.]+)(m?s)\b/g, (_, n, unit) => `${n * SLOW}${unit}`);
  const local = [...document.styleSheets].filter((sheet) => sheet.href?.startsWith(location.origin));
  for (const rule of local.flatMap((sheet) => [...sheet.cssRules])) {
    for (const key of ["transitionDuration", "transitionDelay", "animationDuration", "animationDelay"]) {
      if (rule.style?.[key]) rule.style[key] = stretch(rule.style[key]);
    }
  }
}

// Review aid: ?probe=1 reports in the tab title the slowest and average frame
// rate while glass is on screen, the glass mode, and the shortcuts received.
const PROBE = new URLSearchParams(location.search).has("probe") && { keys: "", frames: [], last: 0 };
function probe(key) {
  if (!PROBE) return;
  if (key) PROBE.keys += key;
  const f = PROBE.frames, mean = f.length ? f.reduce((a, b) => a + b) / f.length : 0;
  const slow = f.length ? Math.max(...f) : 0;
  document.title = `Oops ${glass ? "webgl" : "no-gl"} avg${mean ? Math.round(1000 / mean) : 0} min${slow ? Math.round(1000 / slow) : 0} n${f.length} keys[${PROBE.keys}]`;
}
if (PROBE) {
  addEventListener("keydown", (event) => probe(`${event.ctrlKey ? "^" : ""}${event.metaKey ? "@" : ""}${event.code.replace("Key", "")}=${event.key} `), true);
  requestAnimationFrame(function tick(now) {
    const busy = document.querySelector(".drop.is-in, .voice.is-in, .petal.is-in");
    if (busy && PROBE.last) PROBE.frames.push(now - PROBE.last);
    PROBE.last = busy ? now : 0;
    if (PROBE.frames.length % 30 === 1) probe();
    requestAnimationFrame(tick);
  });
}

// Real glass where WebGL is available; plain CSS capsules otherwise.
let glass = null;
try {
  glass = createGlass({ canvas: $("glass"), stage, draft, roots: [$("head"), draft, $("triggers")], frames: [$("outline")] });
} catch (error) {
  console.warn(error);
}
document.documentElement.classList.toggle("no-gl", !glass);
glass?.add(drop);

// The app's own cues. They play only for an act the visitor triggered: the
// hero is always silent when it plays by itself, so a forgotten tab never
// makes a sound. Browsers also need a click or key press before any audio.
const Sound = (() => {
  let allowed = false, take = 0;
  const arm = () => { allowed = true; };
  addEventListener("pointerdown", arm, { once: true, capture: true });
  addEventListener("keydown", arm, { once: true, capture: true });
  const play = (name, after) => {
    if (!allowed || !Sound.aloud) return;
    setTimeout(() => {
      const clip = new Audio(`sounds/${name}.m4a`);
      clip.volume = 0.55;
      clip.play().catch(() => {});
    }, after * SLOW);
  };
  return {
    aloud: false,
    start: () => play("start", 75),
    success: () => play(`success-${(take++ % 3) + 1}`, 130),
  };
})();

// One point of the app's 46pt drop, at the size the page draws it.
const unit = () => drop.offsetHeight / 46;

// Where the caret sits, in the stage's coordinates.
function caretSpot() {
  const caret = draft.querySelector(".caret").getBoundingClientRect();
  const box = stage.getBoundingClientRect();
  return { x: caret.left - box.left, bottom: caret.bottom - box.top, width: box.width };
}

// Every drop takes the same place by the caret: 12pt before it, 6pt under
// its line, as the app's does. `spot` may be where the caret will be.
function anchor(width, spot = caretSpot()) {
  const u = unit();
  return [Math.max(0, Math.min(spot.x - 12 * u, spot.width - width)), spot.bottom + 6 * u];
}

const Drop = {
  // The width the drop needs to show `text` beside the eyes.
  widthFor(text) {
    label.textContent = text;
    return Math.ceil(52 * unit() + label.offsetWidth + 18 * unit());
  },
  show(x, y, text = "") {
    label.textContent = text;
    drop.style.width = "";
    drop.classList.remove("is-wide", "is-working");
    Drop.move(x, y);
    void drop.offsetWidth; // take the new place before the entrance starts
    drop.classList.add("is-in");
    glass?.wake();
    Sound.start();
  },
  move(x, y) {
    drop.style.left = `${x}px`;
    drop.style.top = `${y}px`;
  },
  work(on) { drop.classList.toggle("is-working", on); },
  // Shows a symbol in place of the eyes, or the eyes again with null.
  glyph(paths) {
    if (paths) $("glyph").innerHTML = paths;
    drop.classList.toggle("is-glyph", Boolean(paths));
  },
  widen(text) {
    drop.classList.add("is-wide");
    drop.style.width = `${Drop.widthFor(text)}px`;
  },
  hide() {
    drop.classList.remove("is-wide", "is-working", "is-in");
    drop.style.width = "";
  },
};

// The eyes: two dashes on a 32-unit face that look, blink, read, and close
// into a check. Values ease toward a target pose every frame.
const eyes = (() => {
  const pair = $("eyePair"), left = $("eyeL"), right = $("eyeR"), lid = $("lidRect");
  const now = { gx: 0, gy: 0, lid: 0, check: 0 };
  let target = { ...now }, reading = 0, last = performance.now();
  const mix = (a, b, t) => a + (b - a) * t;
  const line = (el, eye, tick, t) => {
    el.setAttribute("x1", mix(eye[0], tick[0], t));
    el.setAttribute("y1", mix(eye[1], tick[1], t));
    el.setAttribute("x2", mix(eye[2], tick[2], t));
    el.setAttribute("y2", mix(eye[3], tick[3], t));
    el.setAttribute("stroke-width", mix(3.8, 2.2, t));
  };
  function frame(time) {
    const dt = Math.min(0.05, (time - last) / 1000);
    last = time;
    if (reading) {
      // 1.8s loop: sweep across for 80% of it, return for 20%, blink at 0.9s.
      const t = ((time - reading) / 1000) % 1.8;
      const sweep = t < 1.44 ? t / 1.44 : 1 - (t - 1.44) / 0.36;
      target = { gx: -0.5 + sweep, gy: 0.25, lid: t > 0.9 && t < 1.02 ? 1 : 0.4, check: 0 };
    }
    for (const key in now) now[key] += (target[key] - now[key]) * (1 - Math.exp(-dt * (key === "lid" ? 30 : 13)));
    const c = now.check;
    line(left, [12.7, 12.85, 12.7, 20.55], [11.5, 16.35, 14.25, 19.1], c);
    line(right, [19.3, 13.4, 19.3, 18.6], [20.5, 12.2, 14.25, 19.1], c);
    pair.setAttribute("transform", `translate(${now.gx * 4.5 * (1 - c)} ${now.gy * 3.5 * (1 - c)})`);
    lid.setAttribute("y", mix(10.95 + now.lid * 0.75 * 11.5, 0, c));
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  return {
    pose(next) { reading = 0; target = { gx: 0, gy: 0, lid: 0, check: 0, ...next }; },
    read() { reading = performance.now(); },
  };
})();
