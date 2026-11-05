// The page's view of the Artifact database. The orchestrator writes cases, queue, lanes, kpis and meta/run;
// the page writes only labels, one document per queue item (same id), in the contract's Label shape.
const Store = (() => {
  const COLLECTIONS = ["cases", "queue", "labels", "lanes", "kpis"];
  const state = {
    status: "connecting", // connecting | live | offline | error
    error: null,
    cases: new Map(),
    queue: new Map(),
    labels: new Map(),
    lanes: [],
    kpis: [],
    meta: null,
    loaded: new Set(),
  };
  const listeners = new Set();
  let db = null;
  let pending = 0;
  let chain = Promise.resolve(); // label writes run one at a time, in the order decided

  const notify = (what) => listeners.forEach((fn) => fn(what));

  function apply(name, docs) {
    if (name === "lanes" || name === "kpis") {
      state[name] = docs.map((d) => ({ id: d.id, ...d.data() }));
    } else {
      state[name] = new Map(docs.map((d) => [d.id, d.data()]));
    }
  }

  async function start() {
    try {
      db = await window.claude?.use?.("db");
    } catch {
      db = null;
    }
    if (!db) {
      state.status = "offline";
      notify("status");
      return;
    }
    for (const name of COLLECTIONS) {
      db.collection(name)
        .limit(1000)
        .onSnapshot(
          (snap) => {
            apply(name, snap.docs);
            state.loaded.add(name);
            if (state.loaded.size >= COLLECTIONS.length) state.status = "live";
            notify(name);
          },
          (e) => fail(e),
        );
    }
    db.doc("meta/run").onSnapshot(
      (snap) => {
        state.meta = snap.exists ? snap.data() : null;
        notify("meta");
      },
      (e) => fail(e),
    );
  }

  function fail(e) {
    state.status = "error";
    state.error = e?.code || "unavailable";
    notify("status");
  }

  // The label shows at once; a failed write puts the previous state back and rejects.
  async function setLabel(id, label) {
    const before = state.labels.get(id);
    state.labels = new Map(state.labels).set(id, label);
    notify("labels");
    pending++;
    try {
      await serial(() => db.collection("labels").doc(id).set(label));
    } catch (e) {
      restore(id, before);
      throw e;
    } finally {
      pending--;
    }
  }

  async function clearLabel(id, previous) {
    const before = state.labels.get(id);
    restore(id, previous);
    pending++;
    try {
      const ref = db.collection("labels").doc(id);
      await serial(() => (previous ? ref.set(previous) : ref.delete()));
    } catch (e) {
      restore(id, before);
      throw e;
    } finally {
      pending--;
    }
  }

  function restore(id, label) {
    const next = new Map(state.labels);
    if (label) next.set(id, label);
    else next.delete(id);
    state.labels = next;
    notify("labels");
  }

  function serial(write) {
    const run = chain.catch(() => {}).then(() => retry(write));
    chain = run;
    return run;
  }

  async function retry(write) {
    try {
      return await write();
    } catch (e) {
      if (e?.code !== "unavailable") throw e;
      await new Promise((r) => setTimeout(r, 400 + Math.random() * 600));
      return write();
    }
  }

  return {
    state,
    start,
    setLabel,
    clearLabel,
    get writable() {
      return Boolean(db);
    },
    get pending() {
      return pending;
    },
    on: (fn) => listeners.add(fn),
  };
})();
