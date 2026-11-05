// A canvas editor (Google Docs' canvas mode, Flutter web): the text is drawn, and keys, copy and paste
// go to a hidden contenteditable that holds only the current selection, so the browser's copy works.
// Accessibility sees that hidden field, never the document.
Engines.canvas = {
  async mount(container, draft, options) {
    let text = Segments.text(draft), selection = [text.length, text.length];
    const listeners = [];
    const canvas = document.createElement('canvas');
    canvas.width = 720; canvas.height = 360;
    canvas.style.width = '720px'; canvas.style.height = '360px';
    const target = document.createElement('div');
    target.contentEditable = 'true';
    target.setAttribute('role', 'textbox');
    target.setAttribute('aria-label', 'Document content');
    Object.assign(target.style, { position: 'absolute', opacity: '0', width: '1px', height: '1px', overflow: 'hidden', left: '0', top: '0' });
    container.style.position = 'relative';
    container.append(canvas, target);
    const draw = () => {
      const context = canvas.getContext('2d');
      context.clearRect(0, 0, canvas.width, canvas.height);
      context.font = '15px -apple-system, system-ui, sans-serif';
      context.direction = options.rtl ? 'rtl' : 'ltr';
      let y = 24;
      let at = 0;
      for (const line of text.split('\n')) {
        const [start, end] = [Math.max(selection[0] - at, 0), Math.min(selection[1] - at, line.length)];
        if (end > start) {
          context.fillStyle = '#b3d4fc';
          const x = context.measureText(line.slice(0, start)).width;
          context.fillRect(8 + x, y - 15, context.measureText(line.slice(start, end)).width, 20);
        }
        context.fillStyle = '#1d1d1f';
        context.fillText(line, 8, y);
        y += 22; at += line.length + 1;
      }
    };
    // The hidden field mirrors the selection, all of it selected, as Docs prepares a copy.
    const mirror = () => {
      target.textContent = text.slice(selection[0], selection[1]);
      const range = document.createRange();
      range.selectNodeContents(target);
      getSelection().removeAllRanges(); getSelection().addRange(range);
      draw();
    };
    // What the browser has selected in the hidden field, as document offsets: a client may narrow it
    // to part of the mirrored text (a single word to replace) before it types or pastes.
    const current = () => {
      const range = getSelection().rangeCount ? getSelection().getRangeAt(0) : null;
      if (!range || !target.contains(range.startContainer) || !target.contains(range.endContainer)) return selection;
      const offset = (node, at) => {
        const probe = document.createRange();
        probe.setStart(target, 0); probe.setEnd(node, at);
        return probe.toString().length;
      };
      return [selection[0] + offset(range.startContainer, range.startOffset), selection[0] + offset(range.endContainer, range.endOffset)];
    };
    const replace = value => {
      const [start, end] = current();
      text = text.slice(0, start) + value + text.slice(end);
      selection = [start + value.length, start + value.length];
      mirror();
      listeners.forEach(listener => listener());
    };
    target.addEventListener('beforeinput', event => {
      event.preventDefault();
      if (event.inputType === 'insertText' || event.inputType === 'insertReplacementText') replace(event.data ?? '');
      else if (event.inputType.startsWith('delete')) replace('');
    });
    target.addEventListener('copy', event => { event.preventDefault(); event.clipboardData.setData('text/plain', text.slice(...current())); });
    target.addEventListener('paste', event => { event.preventDefault(); replace(event.clipboardData.getData('text/plain')); });
    mirror();
    return {
      root: target,
      text: () => text,
      counts: () => ({ chips: 0, images: 0 }),
      focus: () => target.focus(),
      select: (start, end) => { selection = [start, end]; mirror(); },
      range: () => [...selection],
      insert: replace,
      rerender: draw,
      onChange: listener => listeners.push(listener),
    };
  },
};
