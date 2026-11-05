// The page's loop: fetch the case meant for this shell, build its layout, mount its engine (in the
// page, a shadow root or an iframe), apply its behaviour, place the caret or selection, and post the
// engine's text to /state. A new case reloads the page, so no engine outlives its case.
(() => {
  const params = new URLSearchParams(location.search);
  const host = params.get('host');
  const framed = params.get('embed') === 'frame';
  // A cross-origin frame (embedding "xframe") runs the whole loop itself; its parent only lays out.
  const crossFramed = params.get('embed') === 'xframe';
  let delegated = false;
  let nonce = params.get('nonce'), handle = null, error = null, reported = null, ready = false, placed = null, selected = null;

  const load = (tag, attrs, parent) => new Promise((resolve, reject) => {
    const node = Object.assign(document.createElement(tag), attrs);
    node.onload = resolve; node.onerror = () => reject(new Error(`could not load ${attrs.src || attrs.href}`));
    (parent || document.head).append(node);
  });
  const loaded = new Set();
  async function assets(spec, root) {
    for (const href of spec.styles || []) {
      if (root) await load('link', { rel: 'stylesheet', href }, root);
      else if (!loaded.has(href)) { loaded.add(href); await load('link', { rel: 'stylesheet', href }); }
    }
    for (const src of spec.scripts || []) {
      if (!loaded.has(src)) { loaded.add(src); await load('script', { src }); }
    }
  }

  // Mounts the case's engine in `slot` and returns its handle, with the behaviour applied.
  async function mount(caseSpec, slot) {
    const spec = Engines[caseSpec.engine];
    if (!spec) throw new Error(`unknown engine ${caseSpec.engine}`);
    const options = { rtl: caseSpec.presentation === 'rtl', layout: caseSpec.layout, content: caseSpec.content, embedding: caseSpec.embedding };
    let container = slot, root = document;
    if (caseSpec.embedding === 'shadow' && !framed) {
      const shadowHost = document.createElement('div');
      slot.append(shadowHost);
      root = shadowHost.attachShadow({ mode: 'open' });
      await load('link', { rel: 'stylesheet', href: '/bakeoff.css' }, root);
      container = document.createElement('div');
      container.className = 'slot';
      root.append(container);
      options.shadowRoot = root;
      await assets(spec, root);
    } else {
      await assets(spec);
    }
    const editor = await spec.mount(container, caseSpec.draft, options);
    if (caseSpec.reaction === 'paste-intercept') Behaviours.pasteIntercept(editor);
    if (caseSpec.reaction === 'rerender') Behaviours.rerender(editor);
    if (caseSpec.reaction === 'combobox') Behaviours.combobox(editor);
    return editor;
  }

  // The iframe's inside: the parent hands over the case and reads window.bakeoff.
  async function mountFramed() {
    const caseSpec = window.parent.bakeoffCase;
    document.documentElement.dir = caseSpec.presentation === 'rtl' ? 'rtl' : 'ltr';
    document.body.className = 'frame';
    const slot = Object.assign(document.createElement('div'), { className: 'slot' });
    document.body.append(slot);
    window.bakeoff = { handle: await mount(caseSpec, slot) };
  }

  async function show(control) {
    const caseSpec = control.case;
    if (caseSpec.embedding === 'xframe' && !crossFramed) return showCrossFrame(caseSpec);
    if (crossFramed) {
      document.documentElement.dir = caseSpec.presentation === 'rtl' ? 'rtl' : 'ltr';
      const slot = Object.assign(document.createElement('div'), { className: 'slot' });
      document.body.replaceChildren(slot);
      handle = await mount(caseSpec, slot);
      return place(caseSpec, slot);
    }
    Layouts.present(caseSpec.presentation);
    document.title = `oops composer lab · bakeoff · ${caseSpec.id}`;
    const slot = Layouts.build(caseSpec.layout, { rtl: caseSpec.presentation === 'rtl' });
    if (caseSpec.embedding === 'iframe') {
      window.bakeoffCase = caseSpec;
      const frame = Object.assign(document.createElement('iframe'), { className: 'editor-frame', title: 'Editor' });
      const loadedFrame = new Promise(resolve => { frame.onload = resolve; });
      frame.src = `/page.html?embed=frame&host=${host}`;
      slot.append(frame);
      await loadedFrame;
      for (let i = 0; i < 100 && !frame.contentWindow.bakeoff; i++) await new Promise(r => setTimeout(r, 50));
      if (!frame.contentWindow.bakeoff) throw new Error('the framed editor did not mount');
      handle = frame.contentWindow.bakeoff.handle;
      frame.contentWindow.focus();
    } else {
      handle = await mount(caseSpec, slot);
    }
    return place(caseSpec, slot);
  }

  // The parent of a cross-origin editor: the same server under the other loopback name, a different
  // site, so Chromium runs the frame in its own process. The frame reports for itself.
  async function showCrossFrame(caseSpec) {
    delegated = true;
    Layouts.present(caseSpec.presentation);
    document.title = `oops composer lab · bakeoff · ${caseSpec.id}`;
    const slot = Layouts.build(caseSpec.layout, { rtl: caseSpec.presentation === 'rtl' });
    const other = location.hostname === 'localhost' ? '127.0.0.1' : 'localhost';
    const frame = Object.assign(document.createElement('iframe'), { className: 'editor-frame', title: 'Editor' });
    const loaded = new Promise(resolve => { frame.onload = resolve; });
    frame.src = `${location.protocol}//${other}:${location.port}/page.html?embed=xframe&host=${host}`;
    slot.append(frame);
    await loaded;
    Layouts.settle(caseSpec.layout, slot);
    frame.focus();
    frame.contentWindow.focus();
  }

  async function place(caseSpec, slot) {
    handle.caret = () => { const range = handle.range(); return range && range[0] === range[1] ? range[0] : null; };
    window.bakeoffHandle = handle; // For a person poking at a case in the console.
    if (!crossFramed) Layouts.settle(caseSpec.layout, slot); // a cross-origin frame has no layout of its own
    handle.focus();
    const [start, end] = caseSpec.selection ?? [caseSpec.caret, caseSpec.caret];
    handle.select(start, end);
    await new Promise(resolve => setTimeout(resolve, 150));
    placed = handle.range(); // Where the selection landed, before any behaviour: the runner checks it.
    selected = selectedText(handle.root);
    if (caseSpec.reaction === 'slash-menu') Behaviours.slashMenu(handle);
    if (caseSpec.reaction === 'ime' && !Behaviours.ime(handle)) throw new Error('no IME bridge in this shell');
    ready = true;
  }

  // What the browser itself has selected: the field's own selection, or the document's (or shadow root's).
  function selectedText(root) {
    if (root.setSelectionRange) return root.value.slice(root.selectionStart, root.selectionEnd);
    const scope = root.getRootNode();
    return String((scope.getSelection ? scope : root.ownerDocument).getSelection() ?? '');
  }

  async function report() {
    if (delegated) return;
    let text = null, counts = null;
    try { text = handle ? handle.text() : null; counts = handle ? handle.counts() : null; } catch (e) { error = error || `text: ${e.message}`; }
    const state = JSON.stringify({ host, nonce, ready, text, counts, placed, selected, error, pageErrors, composing: !!window.bakeoffComposing });
    if (state === reported) return;
    reported = state;
    try { await fetch('/state', { method: 'POST', body: state }); } catch { reported = null; }
  }

  async function poll() {
    try {
      const control = await (await fetch('/control', { cache: 'no-store' })).json();
      if (control.host === host && control.nonce !== nonce) {
        if (crossFramed && nonce !== null) return; // the parent reloads, and with it this frame
        if (nonce !== null) { location.replace(`/page.html?host=${host}&nonce=${encodeURIComponent(control.nonce)}`); return; }
        nonce = control.nonce;
        try { await show(control); } catch (e) { error = `${e.message}`; console.error(e); }
      } else if (control.host === host && control.nonce === nonce && !ready && !error && !handle && !delegated) {
        try { await show(control); } catch (e) { error = `${e.message}`; console.error(e); }
      }
    } catch {}
    await report();
    setTimeout(poll, 100);
  }

  // Errors before the case is ready are the fixture's; later ones are kept apart (engines log some).
  const pageErrors = [];
  window.addEventListener('error', event => {
    if (/ResizeObserver/.test(event.message)) return;
    if (ready) pageErrors.push(event.message); else error = error || `page: ${event.message}`;
  });
  if (framed) mountFramed().catch(e => { window.bakeoffError = e.message; console.error(e); });
  else poll();
})();
