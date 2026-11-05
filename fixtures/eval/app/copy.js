// The words of each review queue in one place: the job it names, the question every card asks, what each
// decision means there, and the explainer shown the first time the queue opens.
const Copy = {
  queues: {
    expected: {
      name: "Set answer key",
      question: "Is this the correction you'd want?",
      agree: ["Keep", "use as key"],
      wrong: ["Wrong", "not what I'd want"],
      edit: ["Rewrite", "write yours"],
      tabs: [
        ["changes", "Edits to draft"],
        ["draft", "Original"],
      ],
      intro: {
        title: "Set the answer key",
        lead: "Each card is a draft with errors and the correction proposed for it. Kept corrections become the answers models are graded against.",
        rows: [
          ["Keep", "swipe right", "The correction is what you'd want."],
          ["Wrong", "swipe left", "It isn't. Tap a reason first if one fits."],
          ["Rewrite", "swipe up", "Type the correction you'd want instead."],
          ["Remove case", "", "The draft itself is unusable, for example unrealistic."],
        ],
      },
      empty: "Proposed corrections appear here once the drafted cases are loaded.",
    },
    output: {
      name: "Grade models",
      question: "Is this model's correction acceptable?",
      agree: ["Accept", "matches the key"],
      agreeNew: ["Accept", "adds to the key"],
      wrong: ["Wrong", "not acceptable"],
      edit: ["Rewrite", "write yours"],
      tabs: [
        ["changes", "Edits to draft"],
        ["ref", "Vs answer key"],
        ["draft", "Original"],
      ],
      intro: {
        title: "Grade model answers",
        lead: "Each card is one model's correction of a draft. The model isn't named. Your grades calibrate the automatic judges.",
        rows: [
          ["Accept", "swipe right", "Acceptable. If it differs from the key, it's added as another right answer."],
          ["Wrong", "swipe left", "Not acceptable. Tap a reason first if one fits."],
          ["Rewrite", "swipe up", "Type the correction that would be right."],
          ["Vs answer key", "", "Shows where the model's answer differs from the key."],
        ],
      },
      empty: "Model answers appear here once a run picks some for grading.",
    },
  },
  // Monitor: [key, label, kind, better direction, what n counts]
  monitor: {
    metrics: [
      ["fully_correct", "Fully correct answers", "rate", 1, "attempts"],
      ["f05", "Edit F0.5 (precision weighted)", "rate", 1, ""],
      ["precision", "Edit precision: edits that were needed", "rate", 1, "edits"],
      ["recall", "Edit recall: errors fixed", "rate", 1, "errors"],
      ["clean_changed", "Clean drafts changed", "rate", -1, "clean drafts"],
      ["protected_broken", "Protected text broken", "rate", -1, "drafts with protected text"],
      ["harm_rate", "Answers with a harmful edit", "rate", -1, "attempts"],
      ["valid_rate", "Valid responses", "rate", 1, "attempts"],
      ["deadline_missed", "Over the 40 s deadline", "rate", -1, "attempts"],
      ["pass2", "Both attempts correct (pass^2)", "rate", 1, "cases"],
      ["flip_rate", "Attempts disagree (flip rate)", "rate", -1, "cases"],
      ["latency_p50_ms", "Median latency", "ms", -1, ""],
      ["latency_p95_ms", "Latency, 95th percentile", "ms", -1, ""],
      ["ttft_p50_ms", "Median time to first token", "ms", -1, ""],
      ["ttft_p95_ms", "Time to first token, 95th percentile", "ms", -1, ""],
      ["cost_per_success_usd", "Cost per correct answer", "usd", -1, ""],
    ],
    groups: { lang: "Language", length: "Length", errors: "Error type" },
    // Column headings, with the draft length in characters under each length bucket
    categories: {
      en: ["English"], fr: ["French"], mixed: ["Mixed"],
      xs: ["XS", "< 80 chars"], s: ["S", "80–300"], m: ["M", "300–1.2k"], l: ["L", "1.2k–4k"], xl: ["XL", "4k–16k"],
      clean: ["No errors"],
    },
  },
  lengths: { xs: "Very short", s: "Short", m: "Medium", l: "Long", xl: "Very long" },
  langs: { en: "English", fr: "French", mixed: "English and French" },
};
