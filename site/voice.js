// The dictation drop: a capsule of regular glass whose shape tells the state.
// It carries the voice while Oops listens, a sweep of dots while it turns
// speech into text, and shrinks to a round check once the words are written.
// The voice drawn here is the app's "Wave" animation, acted, not recorded.

const Voice = (() => {
  const el = $("voice"), canvas = $("bars"), ink = canvas.getContext("2d");
  const history = [];
  let phase = "", began = 0, sampled = 0, running = false;
  glass?.add(el, true);

  // Loudness of the acted voice, as the app's own hello scene plays it.
  const level = (t) =>
    Math.min(1, 0.12 + 0.6 * (0.5 + 0.5 * Math.sin(15.5 * t)) * (0.55 + 0.45 * Math.sin(5.3 * t + 1.1)) + 0.12 * Math.sin(31 * t));

  function bar(x, half, width, alpha) {
    ink.globalAlpha = Math.max(0, Math.min(1, alpha));
    ink.beginPath();
    ink.roundRect(x - width / 2, canvas.height / 2 - half, width, half * 2, width / 2);
    ink.fill();
  }

  function frame(time) {
    if (!el.classList.contains("is-in")) { running = false; return; }
    const dpr = Math.min(devicePixelRatio || 1, 2);
    const w = el.clientWidth * dpr, h = el.clientHeight * dpr;
    if (canvas.width !== Math.round(w) || canvas.height !== Math.round(h)) {
      canvas.width = Math.round(w);
      canvas.height = Math.round(h);
    }
    const u = h / 46, t = (time - began) / 1000;
    ink.clearRect(0, 0, w, h);
    ink.fillStyle = getComputedStyle(el).color;

    if (phase === "recording") {
      // A new bar every 45ms, scrolling from the trailing end to the leading cap.
      if (time - sampled > 45) { sampled = time; history.unshift(level(t)); history.length = Math.min(history.length, 36); }
      history.forEach((loud, i) => {
        const x = w - 24 * u - i * 5 * u;
        const fade = Math.min(1, x / (0.18 * w));
        bar(x, (1.25 + 12.5 * loud ** 1.15) * u, (i ? 2.5 : 3.5) * u, (0.55 + 0.45 * Math.sqrt(loud)) * fade);
      });
      bar(w - 17 * u, 1.25 * u, 2.5 * u, 0.55);
      bar(w - 11 * u, 1.25 * u, 2.5 * u, 0.25);
    } else if (phase === "transcribing") {
      // A crest sweeps along a centred row of dots.
      for (let x = 14 * u; x <= w - 14 * u; x += 5 * u) {
        const crest = Math.sin(2 * Math.PI * (1.1 * x / w - 1.3 * t)) ** 2;
        bar(x, (1.25 + 6.5 * crest) * u, 2.5 * u, 0.5 + 0.5 * crest);
      }
    }
    requestAnimationFrame(frame);
  }

  function set(next, width) {
    phase = next;
    began = performance.now();
    history.length = 0;
    el.dataset.phase = next;
    el.style.width = `${width * unit()}px`;
  }

  return {
    listen(x, y) {
      el.style.left = `${x}px`;
      el.style.top = `${y}px`;
      set("recording", 168);
      el.classList.add("is-in");
      glass?.wake();
      Sound.start();
      if (!running) { running = true; requestAnimationFrame(frame); }
    },
    transcribe() { set("transcribing", 96); },
    written() { set("written", 46); Sound.success(); },
    hide() { el.classList.remove("is-in"); },
  };
})();
