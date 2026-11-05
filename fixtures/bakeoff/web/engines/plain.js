// Plain fields, no engine: a textarea, a single-line input, and a contenteditable div composer.
// A textarea's mentions are plain "@Name" text under a highlight mirror, the way textarea composers
// (GitHub, early Discord) draw them; the contenteditable's are non-editable chips.
(() => {
  // A textarea or input, kept in a holder so a re-render can swap the element itself.
  function field(tag, container, draft, options) {
    const holder = document.createElement('div');
    container.append(holder);
    const listeners = [];
    let element;
    const mirror = options.content === 'mentions' && tag === 'textarea' ? document.createElement('div') : null;
    const paint = () => {
      if (!mirror) return;
      const escape = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
      mirror.innerHTML = escape(element.value).replace(/@[A-Z][a-z]+ [A-Z][a-z]+/g, m => `<mark>${m}</mark>`) + '\n';
    };
    const make = (value, start, end) => {
      const next = document.createElement(tag);
      if (tag === 'input') next.type = 'text';
      next.value = value;
      next.setAttribute('aria-label', 'Message');
      next.spellcheck = false;
      if (options.rtl) next.dir = 'rtl';
      for (const listener of listeners) next.addEventListener('input', listener);
      next.addEventListener('input', paint);
      if (element) element.replaceWith(next); else holder.append(next);
      element = next;
      paint();
      if (start !== undefined) { element.focus(); element.setSelectionRange(start, end); }
    };
    if (mirror) { holder.className = 'mirrored'; mirror.className = 'mirror'; holder.append(mirror); }
    make(Segments.text(draft));
    return {
      get root() { return element; },
      text: () => element.value,
      counts: () => ({ chips: 0, images: 0 }),
      focus: () => element.focus(),
      select: (start, end) => element.setSelectionRange(start, end),
      range: () => [element.selectionStart, element.selectionEnd],
      insert(text) {
        element.setRangeText(text, element.selectionStart, element.selectionEnd, 'end');
        element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertFromPaste', data: text }));
      },
      rerender: () => make(element.value, element.selectionStart, element.selectionEnd),
      onChange(listener) { listeners.push(listener); element.addEventListener('input', listener); },
    };
  }

  Engines.textarea = { mount: async (container, draft, options) => field('textarea', container, draft, options) };
  // A sign-in form's password, and a read-only textarea (a closed thread's last draft): both must refuse.
  Engines.password = {
    async mount(container, draft, options) {
      const handle = field('input', container, draft, options);
      handle.root.type = 'password';
      handle.root.setAttribute('aria-label', 'Password');
      handle.root.autocomplete = 'current-password';
      return handle;
    },
  };
  Engines.readonly = {
    async mount(container, draft, options) {
      const handle = field('textarea', container, draft, options);
      handle.root.readOnly = true;
      return handle;
    },
  };
  Engines.input = { mount: async (container, draft, options) => field('input', container, draft, options) };

  // A contenteditable composer the app reads from the DOM: one div per line, chips and images inline.
  Engines.contenteditable = {
    async mount(container, draft, options) {
      const root = document.createElement('div');
      root.className = 'plain-editor';
      root.contentEditable = 'true';
      root.setAttribute('role', 'textbox');
      root.setAttribute('aria-multiline', 'true');
      root.setAttribute('aria-label', 'Message');
      if (options.rtl) root.dir = 'rtl';
      const fill = paragraphs => { root.innerHTML = paragraphs.map(p => `<div>${p}</div>`).join(''); };
      fill(draft.paragraphs.map(p => Segments.html(p)));
      container.append(root);
      const blocks = () => [...root.children].filter(child => child.tagName === 'DIV');
      const text = () => Segments.domText(blocks());
      const handle = {
        root,
        text,
        counts: () => ({ chips: root.querySelectorAll('.mention').length, images: root.querySelectorAll('img').length }),
        focus: () => root.focus(),
        select: (start, end) => Segments.domSelect(blocks(), start, end),
        insert: value => document.execCommand('insertText', false, value),
        // The app's own render: every line rebuilt from its state, the selection put back by offset.
        rerender() {
          const offsets = Segments.domOffsets(blocks());
          fill(blocks().map(block => block.innerHTML));
          if (offsets) handle.select(...offsets);
        },
        range: () => Segments.domOffsets(blocks()),
        onChange: listener => root.addEventListener('input', listener),
      };
      return handle;
    },
  };
})();
