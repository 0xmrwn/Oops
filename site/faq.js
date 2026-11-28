// The questions sheet. The "?" key in the footer, or the same key on the
// keyboard, opens it; Escape, the key again or a click outside closes it.
// Pointing at a question, or the up and down arrows, brings its answer.
// While it is up the hero's own shortcuts rest, and so does its self-play.

const Faq = (() => {
  const sheet = $("faq"), key = $("ask"), guide = sheet.querySelector(".guide");
  const questions = [...sheet.querySelectorAll(".q")];
  const answers = questions.map((question) => $(question.getAttribute("aria-controls")));
  let at = -1;

  function show(index) {
    if (index === at) return;
    at = index;
    questions.forEach((question, i) => {
      question.setAttribute("aria-selected", String(i === at));
      question.tabIndex = i === at ? 0 : -1;
      answers[i].classList.toggle("is-on", i === at);
    });
    guide.style.setProperty("--at", at);
    guide.classList.remove("is-off");
    void guide.offsetWidth; // so the little hop plays again
    guide.classList.add("is-off");
  }

  function toggle() {
    if (sheet.open) return sheet.close();
    Wheel.cancel();
    sheet.showModal();
    // The sheet grows out of its key.
    const box = sheet.getBoundingClientRect(), from = key.getBoundingClientRect();
    sheet.style.transformOrigin = `${from.x + from.width / 2 - box.x}px ${from.y + from.height / 2 - box.y}px`;
    sheet.focus(); // the sheet itself, so no question lights up unasked
    at = -1;
    show(0);
  }

  questions.forEach((question, index) => {
    question.addEventListener("click", () => show(index));
    question.addEventListener("focus", () => show(index));
    question.addEventListener("pointerenter", (event) => { if (event.pointerType === "mouse") show(index); });
  });
  key.addEventListener("click", toggle);
  sheet.querySelector(".shut").addEventListener("click", () => sheet.close());
  // A click on the dimmed page lands on the dialog itself, not its content.
  sheet.addEventListener("click", (event) => { if (event.target === sheet) sheet.close(); });
  sheet.addEventListener("keydown", (event) => {
    const step = { ArrowDown: 1, ArrowUp: -1 }[event.key];
    if (!step) return;
    event.preventDefault();
    show((at + step + questions.length) % questions.length);
    // Focus follows the selection, so Enter and the focus ring agree with it.
    if (questions.includes(document.activeElement)) questions[at].focus();
  });
  addEventListener("keydown", (event) => {
    if (event.key !== "?" || event.metaKey || event.ctrlKey || event.altKey) return;
    event.preventDefault();
    key.classList.add("is-pressed");
    setTimeout(() => key.classList.remove("is-pressed"), 160);
    toggle();
  });

  return { isOpen: () => sheet.open, whenClosed: (then) => sheet.addEventListener("close", then, { once: true }) };
})();
