// The Actions wheel: the drop in the middle, and glass petals that bud out of
// it along the compass lines. It is driven as in the app: hover or an arrow
// key points at a petal, a click or letting the arrow go chooses it, Escape
// closes. An action with a choice opens a second ring of words.
// The petals here do not merge into each other as the app's liquid glass does,
// and the centre cannot be typed into.

const Wheel = (() => {
  const ICONS = {
    Translate: '<circle cx="12" cy="12" r="7.5"/><path d="M4.5 12h15M12 4.5c2.3 2 3.4 4.5 3.4 7.5s-1.1 5.5-3.4 7.5c-2.3-2-3.4-4.5-3.4-7.5s1.1-5.5 3.4-7.5z"/>',
    Shorten: '<path d="M19.5 4.5L14 10M14 5.8V10h4.2M4.5 19.5L10 14M10 18.2V14H5.8"/>',
    Tone: '<path d="M6 5.5h12a1.5 1.5 0 011.5 1.5v8a1.5 1.5 0 01-1.5 1.5h-6.5L8 19.5v-3H6A1.5 1.5 0 014.5 15V7A1.5 1.5 0 016 5.5z"/><path d="M8.5 9.8h7M8.5 12.7H13"/>',
    Restore: '<path d="M9 6.5L5 10.5l4 4M5 10.5h9.5a4.25 4.25 0 010 8.5H11"/>',
  };
  // Three of the app's starters on their compass lines; choices run up, right,
  // down, left. Sharpen prompt is left out: this draft is not a prompt.
  const ACTIONS = [
    { name: "Translate", at: [1, 0], ask: "Language", choices: ["French", "Spanish", "German", "Italian"] },
    { name: "Shorten", at: [0, 1] },
    { name: "Tone", at: [-1, 0], ask: "Tone", choices: ["Formal", "Friendly", "Direct", "Concise"] },
  ];
  const ARROW_ORDER = ["0,-1", "1,0", "0,1", "-1,0"];
  const ARROWS = { ArrowUp: [0, -1], ArrowRight: [1, 0], ArrowDown: [0, 1], ArrowLeft: [-1, 0] };

  let hub = { x: 0, y: 0 };
  let ring = [];    // the petals or pills now open
  let live = null;  // how a waiting wheel hears the pointer

  const make = (item, kind) => {
    const el = document.createElement("div");
    el.className = kind;
    el.setAttribute("role", "button");
    el.tabIndex = -1;
    el.addEventListener("focus", () => live?.point(item));
    el.addEventListener("blur", () => live?.point(null));
    el.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      live?.choose(item);
    });
    el.addEventListener("pointerenter", () => live?.point(item));
    el.addEventListener("pointerleave", () => live?.point(null));
    el.addEventListener("click", () => live?.choose(item));
    stage.append(el);
    glass?.add(el);
    return Object.assign(item, { el });
  };
  const petals = ACTIONS.map((action) => make({ ...action }, "petal"));
  const pills = Object.values(ARROWS).map((at) => make({ at }, "petal pill"));
  const hint = document.createElement("span");
  hint.className = "ask";
  const neck = document.createElement("div");
  neck.className = "neck";
  stage.append(hint, neck);
  glass?.add(neck);

  // Each piece hangs from the hub: `edge` and `reach` are how far out it sits.
  function place(item, edge, reach) {
    const u = unit(), style = item.el.style;
    style.left = `${hub.x}px`;
    style.top = `${hub.y}px`;
    item.gap = (item.at[0] ? edge : reach - 19) + 8; // from the hub to just inside the piece
    style.setProperty("--n", ARROW_ORDER.indexOf(item.at.join()));
    style.setProperty("--ax", item.at[0]);
    style.setProperty("--dx", `${item.at[0] * edge * u}px`);
    style.setProperty("--dy", `${item.at[1] * reach * u}px`);
  }

  function show(items) {
    for (const item of [...petals, ...pills]) item.el.classList.remove("is-in", "is-pointed", "is-quiet");
    neck.classList.remove("is-in");
    ring = items;
    for (const item of [...petals, ...pills]) {
      item.el.tabIndex = ring.includes(item) ? 0 : -1;
      item.el.setAttribute("aria-label", item.label || "");
    }
    // Let the pieces take their closed place before they bud out.
    requestAnimationFrame(() => ring.forEach((item) => item.el.classList.add("is-in")));
    glass?.wake();
  }

  function point(item) {
    for (const other of ring) {
      other.el.classList.toggle("is-pointed", other === item);
      other.el.classList.toggle("is-quiet", Boolean(item) && other !== item);
    }
    if (item) stage.classList.add("is-named");
    if (item) $("said").textContent = item.label;
    // A neck of glass reaches from the drop to what is pointed at.
    neck.classList.toggle("is-in", Boolean(item));
    if (item) {
      const u = unit(), thick = 13 * u, long = item.gap * u, [ax, ay] = item.at;
      Object.assign(neck.style, {
        left: `${hub.x + (ax ? Math.min(0, ax * long) : -thick / 2)}px`,
        top: `${hub.y + (ay ? Math.min(0, ay * long) : -thick / 2)}px`,
        width: `${ax ? long : thick}px`,
        height: `${ay ? long : thick}px`,
      });
    }
    eyes.pose(item ? { gx: item.at[0] * 0.85, gy: item.at[1] * 0.8 } : { gx: -0.6, gy: -0.5 });
  }

  function secondRing(action) {
    pills.forEach((pill, index) => {
      pill.label = action.choices[index] || "";
      pill.el.textContent = pill.label;
      place(pill, 36, 58);
    });
    Drop.glyph(ICONS[action.name]);
    hint.textContent = action.ask;
    hint.style.left = `${hub.x}px`;
    hint.style.top = `${hub.y + 82 * unit()}px`;
    hint.classList.add("is-in");
    show(pills.filter((pill) => pill.label));
  }

  function close() {
    live?.stop();
    for (const item of [...petals, ...pills]) item.el.classList.remove("is-in", "is-pointed", "is-quiet");
    stage.classList.remove("is-named");
    neck.classList.remove("is-in");
    hint.classList.remove("is-in");
    Drop.glyph(null);
    for (const item of ring) item.el.tabIndex = -1;
    ring = [];
  }

  return {
    // The room the open wheel needs around its hub.
    reach: () => ({ side: 93 * unit() + 96, up: 98 * unit() }),
    isOpen: () => ring.length > 0,
    cancel: () => live?.done(null),
    close,

    // `restore` names the action just run: its petal offers to undo it, and it
    // is the only one offered, since the answers here were all written for the
    // draft as it was before any action.
    open(x, y, restore) {
      hub = { x, y };
      for (const petal of petals) {
        petal.label = petal.name === restore ? "Restore" : petal.name;
        petal.el.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[petal.label]}</svg><span>${petal.label}</span>`;
        place(petal, 55, 74);
      }
      show(restore ? petals.filter((petal) => petal.label === "Restore") : petals);
    },

    // The hero playing by itself: looks at a petal, then takes it.
    async demo(name) {
      point(petals.find((petal) => petal.name === name));
      await sleep(900);
      return { action: name };
    },

    // Waits for the visitor. Resolves with what they chose, or null if they left.
    pick() {
      return new Promise((resolve) => {
        let action = null, pointed = null, commit = 0;
        const held = new Set();
        const names = setTimeout(() => stage.classList.add("is-named"), 700 * SLOW);
        const done = (result) => { live.stop(); resolve(result); };
        const choose = (item) => {
          clearTimeout(commit);
          if (action) return done({ action: action.name, choice: item.label });
          if (item.label === "Restore") return done({ restore: true });
          if (!item.choices) return done({ action: item.name });
          action = item;
          pointed = null;
          secondRing(item);
        };
        const keydown = (event) => {
          if (event.key === "Escape") return done(null);
          const at = ARROWS[event.key];
          if (!at || event.metaKey || event.ctrlKey) return;
          event.preventDefault();
          clearTimeout(commit);
          held.add(event.key);
          pointed = ring.find((item) => item.at[0] === at[0] && item.at[1] === at[1]) || null;
          point(pointed);
        };
        // Letting go of the arrow takes what it points at, after a short grace.
        const keyup = (event) => {
          if (!held.delete(event.key) || held.size || !pointed) return;
          const item = pointed;
          commit = setTimeout(() => choose(item), 50);
        };
        const outside = (event) => {
          if (!event.target.closest(".petal, .triggers")) done(null);
        };
        live = {
          point: (item) => { pointed = item; point(item); },
          choose,
          done,
          stop() {
            clearTimeout(names);
            clearTimeout(commit);
            removeEventListener("keydown", keydown);
            removeEventListener("keyup", keyup);
            removeEventListener("pointerdown", outside);
            live = null;
          },
        };
        addEventListener("keydown", keydown);
        addEventListener("keyup", keyup);
        setTimeout(() => live && addEventListener("pointerdown", outside), 0);
      });
    },
  };
})();
