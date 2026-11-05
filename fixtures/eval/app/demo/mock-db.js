// In-memory stand-in for claude.use("db") over window.SEED, for local checks only (see preview.py).
(() => {
  const data = structuredClone(window.SEED || {});
  const subs = [];
  const snap = (id, body) => ({ id, exists: body !== undefined, data: () => body, metadata: { fromCache: false, hasPendingWrites: false } });
  const fire = () => subs.forEach((s) => s());
  const col = (name) => ({
    limit: () => col(name),
    onSnapshot(next) {
      const run = () => { const docs = Object.entries(data[name] || {}).sort(([a], [b]) => a.localeCompare(b)).map(([id, b]) => snap(id, b)); next({ docs, size: docs.length, empty: !docs.length }); };
      subs.push(run); setTimeout(run, 50); return () => {};
    },
    doc: (id) => ({
      set: async (b) => { (data[name] ||= {})[id] = b; window.__writes = (window.__writes || []).concat([[name, id, b]]); setTimeout(fire, 30); },
      delete: async () => { delete data[name]?.[id]; window.__writes = (window.__writes || []).concat([[name, id, null]]); setTimeout(fire, 30); },
    }),
  });
  const db = { collection: col, doc: (path) => { const [c, id] = path.split("/"); return { onSnapshot(next) { const run = () => next(snap(id, data[c]?.[id])); subs.push(run); setTimeout(run, 50); return () => {}; } }; } };
  window.__db = data;
  window.claude = { use: async (n) => (n === "db" ? db : null) };
})();
