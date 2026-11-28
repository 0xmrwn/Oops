// The hero's words. The corrections and action results below are what Oops
// itself produced for these drafts on 28 Nov 2026: its own prompts, decoding
// and validation (oops-eval), through the Claude Code connection. Fix ran on
// Haiku, the actions on Sonnet, both at low effort. Only `spoken` is written
// by hand: it stands for a sentence said aloud.

const SCENE = {
  typed: "Typos hapen. Oops fixs them rigth where you typed.",
  fixed: "Typos happen. Oops fixes them right where you typed.",
  fixes: 3,
  spoken: "Say it and it's written.",
  // The action the hero picks when it plays by itself.
  action: "Shorten",
};

// What each action answered, and how long the answer took in milliseconds.
// The first of a pair is for the draft as typed, the second for the draft
// once the dictated sentence has been added.
const RESULTS = {
  Shorten: [
    ["Oops fixes typos right where you type.", 2046],
    ["Oops fixes typos right where you type. Just say it and it's written.", 2221],
  ],
  "Translate:French": [
    ["Les fautes de frappe, ça arrive. Oops les corrige directement là où vous les avez tapées.", 2444],
    ["Les fautes de frappe, ça arrive. Oops les corrige directement là où vous avez tapé. Dites-le et c'est écrit.", 2548],
  ],
  "Translate:Spanish": [
    ["Los errores tipográficos pasan. Oops los corrige justo donde escribiste.", 2046],
    ["Los errores tipográficos pasan. Oops los corrige justo donde escribiste. Dilo y queda escrito.", 2480],
  ],
  "Translate:German": [
    ["Tippfehler passieren. Oops korrigiert sie direkt dort, wo du sie getippt hast.", 1900],
    ["Tippfehler passieren. Oops korrigiert sie direkt dort, wo du tippst. Sag es einfach, und es steht da.", 1527],
  ],
  "Translate:Italian": [
    ["Gli errori di battitura capitano. Oops li corregge direttamente dove hai scritto.", 2488],
    ["Gli errori di battitura capitano. Oops li corregge direttamente dove hai scritto. Dillo e sarà scritto.", 2469],
  ],
  "Tone:Formal": [
    ["Typographical errors are inevitable. Oops corrects them directly at the point where they were entered.", 2788],
    ["Typographical errors are inevitable. Oops corrects them at the point of entry. Simply speak, and your words are transcribed.", 2154],
  ],
  "Tone:Friendly": [
    ["Typos happen to everyone! Oops is here to help, quietly fixing them right where you typed.", 2446],
    ["Typos happen, and that's okay! Oops fixes them right where you typed, so just say it and watch it get written. 😊", 1808],
  ],
  "Tone:Direct": [
    ["Everyone makes typos. Oops fixes them right where you type.", 2743],
    ["You will make typos. Oops fixes them right where you type. Speak, and it writes.", 2411],
  ],
  "Tone:Concise": [
    ["Oops fixes typos right where you type.", 2427],
    ["Oops fixes typos right where you type. Just speak, and it writes.", 2098],
  ],
};
