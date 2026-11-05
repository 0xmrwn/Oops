// Word-level diff for the review card: Myers over word, space and punctuation tokens, rendered as quiet
// unchanged text with marked deletions and insertions.
const Diff = (() => {
  const TOKEN = /\s+|[\p{L}\p{M}\p{N}_]+|[^\s\p{L}\p{M}\p{N}_]/gu;
  const MAX_EDITS = 1500; // beyond this the answer is a rewrite; show it as one replacement
  const tokens = (s) => s.match(TOKEN) || [];

  // Myers' O((N+M)D) diff; each trace row keeps only the diagonals that backtracking reads.
  function myers(a, b) {
    const n = a.length;
    const m = b.length;
    const off = n + m + 2;
    const v = new Int32Array(2 * off + 2);
    const trace = [];
    for (let d = 0; d <= n + m; d++) {
      if (d > MAX_EDITS) return null;
      trace.push(v.slice(off - d - 1, off + d + 2));
      for (let k = -d; k <= d; k += 2) {
        let x = k === -d || (k !== d && v[off + k - 1] < v[off + k + 1]) ? v[off + k + 1] : v[off + k - 1] + 1;
        let y = x - k;
        while (x < n && y < m && a[x] === b[y]) {
          x++;
          y++;
        }
        v[off + k] = x;
        if (x >= n && y >= m) return backtrack(trace, a, b);
      }
    }
    return null;
  }

  function backtrack(trace, a, b) {
    let x = a.length;
    let y = b.length;
    const ops = [];
    for (let d = trace.length - 1; d >= 0; d--) {
      const row = trace[d];
      const at = (k) => row[k + d + 1];
      const k = x - y;
      const pk = k === -d || (k !== d && at(k - 1) < at(k + 1)) ? k + 1 : k - 1;
      const px = at(pk);
      const py = px - pk;
      while (x > px && y > py) {
        x--;
        y--;
        ops.push(["=", a[x]]);
      }
      if (d > 0) ops.push(x === px ? ["+", b[--y]] : ["-", a[--x]]);
      x = px;
      y = py;
    }
    return ops.reverse();
  }

  // Blocks of {eq} or {del, ins}. A lone space between two changes joins them, so a rewritten phrase reads
  // as one replacement instead of alternating fragments.
  function blocks(before, after) {
    const a = tokens(before);
    const b = tokens(after);
    const ops = myers(a, b) || [...a.map((t) => ["-", t]), ...b.map((t) => ["+", t])];
    const out = [];
    for (let i = 0; i < ops.length; i++) {
      const [op, t] = ops[i];
      const bridge = op === "=" && /^[ \t]+$/.test(t) && ops[i - 1]?.[0] !== "=" && ops[i + 1] && ops[i + 1][0] !== "=";
      const last = out[out.length - 1];
      if (op === "=" && !bridge) {
        if (last?.eq !== undefined) last.eq += t;
        else out.push({ eq: t });
        continue;
      }
      const block = last && last.eq === undefined ? last : (out.push({ del: "", ins: "" }), out[out.length - 1]);
      if (op !== "+") block.del += t;
      if (op !== "-") block.ins += t;
    }
    return out;
  }

  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

  // Changed whitespace has to be visible: a lost line break or a doubled space is the whole change.
  function marked(s) {
    if (/^[ \t]+$/.test(s)) return `<span class="ws" aria-label="space">${"·".repeat(s.length)}</span>`;
    return esc(s).replace(/\n/g, '<span class="ws" aria-label="line break">↵</span>\n');
  }

  // Long unchanged runs fold to their edges when `fold` is set; the folded middle sits in `folds`.
  function render(before, after, { fold = false } = {}) {
    const list = blocks(before, after);
    const folds = [];
    let changes = 0;
    const html = list
      .map((blk, i) => {
        if (blk.eq === undefined) {
          changes++;
          return (blk.del ? `<del>${marked(blk.del)}</del>` : "") + (blk.ins ? `<ins>${marked(blk.ins)}</ins>` : "");
        }
        const words = blk.eq.match(/\S+\s*|\s+/g) || [];
        const keepHead = i === 0 ? 0 : 14;
        const keepTail = i === list.length - 1 ? 0 : 14;
        if (!fold || list.length === 1 || words.length <= keepHead + keepTail + 24) {
          return `<span class="eq">${esc(blk.eq)}</span>`;
        }
        const middle = words.slice(keepHead, words.length - keepTail).join("");
        folds.push(middle);
        const count = middle.split(/\s+/).filter(Boolean).length;
        return (
          `<span class="eq">${esc(words.slice(0, keepHead).join(""))}</span>` +
          `<button type="button" class="fold" data-fold="${folds.length - 1}">${count} unchanged words</button>` +
          `<span class="eq">${esc(words.slice(words.length - keepTail).join(""))}</span>`
        );
      })
      .join("");
    return { html, changes, folds };
  }

  return { render, blocks, esc };
})();
