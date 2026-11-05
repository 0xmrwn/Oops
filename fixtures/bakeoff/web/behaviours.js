// What apps do around an editor, applied the same way to every engine through its handle:
// a paste handler of the app's own, a re-render after each edit, a slash-command menu, and an IME
// composition (WebKit app shells only: the host app starts it through NSTextInputClient).
window.Engines = {};

window.Behaviours = (() => {
  // The app takes the paste over: it stops the browser's and the engine's own handling and inserts
  // the plain text itself a moment later, through the engine, as apps that convert pastes do.
  function pasteIntercept(handle) {
    const root = handle.root.getRootNode();
    const target = root.nodeType === Node.DOCUMENT_NODE ? root.defaultView : root;
    target.addEventListener('paste', event => {
      if (!handle.root.contains(event.composedPath()[0])) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const text = event.clipboardData.getData('text/plain');
      setTimeout(() => handle.insert(text), 80);
    }, true);
  }

  // The app re-renders the editor from its own state after each edit, replacing its DOM, as
  // controlled React components and collaborative sync do. The selection is put back by offsets.
  function rerender(handle) {
    let timer = null, busy = false;
    handle.onChange(() => {
      if (busy) return;
      clearTimeout(timer);
      timer = setTimeout(() => {
        busy = true;
        try { handle.rerender(); } finally { setTimeout(() => { busy = false; }, 0); }
      }, 60);
    });
  }

  // A "/" just typed opened a command menu at the caret. Focus stays in the editor, which points at
  // the menu's active option; the menu takes Enter, Tab, arrows and Escape, and closes when the
  // selection leaves the "/" or the "/" goes.
  function slashMenu(handle) {
    // TinyMCE's body is its own iframe's: the menu goes in the page around it.
    const doc = handle.root.ownerDocument, page = handle.menuDocument || doc;
    const menu = page.createElement('div');
    menu.className = 'slash-menu'; menu.id = 'slash-menu'; menu.setAttribute('role', 'listbox');
    ['Summarize', 'Insert table', 'Mention someone', 'Add emoji'].forEach((label, i) => {
      const option = page.createElement('div');
      option.id = `slash-option-${i}`; option.setAttribute('role', 'option');
      option.setAttribute('aria-selected', String(i === 0)); option.textContent = label;
      menu.append(option);
    });
    const field = handle.ariaTarget ? handle.ariaTarget() : handle.root;
    const open = () => {
      const rect = caretRect(doc) ?? field.getBoundingClientRect();
      menu.style.left = `${rect.left}px`;
      menu.style.top = `${Math.max(8, rect.top - 150)}px`;
      page.body.append(menu);
      field.setAttribute('aria-haspopup', 'listbox'); field.setAttribute('aria-expanded', 'true');
      field.setAttribute('aria-controls', menu.id); field.setAttribute('aria-activedescendant', 'slash-option-0');
    };
    const close = () => {
      menu.remove();
      field.setAttribute('aria-expanded', 'false'); field.removeAttribute('aria-activedescendant');
    };
    const anchor = handle.text().lastIndexOf('/');
    doc.addEventListener('keydown', event => {
      if (!menu.isConnected || !['Enter', 'Tab', 'ArrowUp', 'ArrowDown', 'Escape'].includes(event.key)) return;
      event.preventDefault(); event.stopImmediatePropagation();
      close();
    }, true);
    const check = () => {
      if (!menu.isConnected) return;
      const caret = handle.caret ? handle.caret() : null;
      if (handle.text().lastIndexOf('/') !== anchor || (caret !== null && caret !== anchor + 1)) close();
    };
    handle.onChange(check);
    doc.addEventListener('selectionchange', check);
    setTimeout(open, 50);
  }

  // The editor announces itself as a combobox, as composers with autocomplete do (Grok's ProseMirror,
  // HuggingChat's textarea): Accessibility reports an AXComboBox, not a text area. Engines that
  // rewrite their own role are put back.
  function combobox(handle) {
    const field = handle.ariaTarget ? handle.ariaTarget() : handle.root;
    const set = () => {
      field.setAttribute('role', 'combobox');
      field.setAttribute('aria-autocomplete', 'list');
      field.setAttribute('aria-haspopup', 'listbox');
      field.setAttribute('aria-expanded', 'false');
    };
    set();
    new MutationObserver(() => { if (field.getAttribute('role') !== 'combobox') set(); }).observe(field, { attributes: true, attributeFilter: ['role'] });
  }

  // Asks the WebKit host app to start a composition at the caret, as a Japanese input method does.
  function ime(handle) {
    let bridge = window.webkit?.messageHandlers?.bakeoff;
    try { bridge ??= window.top.webkit?.messageHandlers?.bakeoff; } catch { /* a cross-origin parent */ }
    if (!bridge) return false;
    handle.root.addEventListener('compositionstart', () => { window.bakeoffComposing = true; }, true);
    handle.root.addEventListener('compositionend', () => { window.bakeoffComposing = false; }, true);
    setTimeout(() => bridge.postMessage({ ime: 'にほんご' }), 200);
    return true;
  }

  function caretRect(doc) {
    const selection = doc.getSelection?.();
    if (!selection || !selection.rangeCount) return null;
    const rect = selection.getRangeAt(0).getBoundingClientRect();
    return rect.width || rect.height ? rect : null;
  }

  return { pasteIntercept, rerender, slashMenu, combobox, ime };
})();
