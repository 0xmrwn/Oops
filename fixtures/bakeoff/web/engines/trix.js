// Trix (Basecamp, HEY, Rails' Action Text): a <trix-editor> element redrawn from Trix's document.
// Lines break with <br> inside one block. Mentions and emoji images are content attachments, the way
// Basecamp attaches @mentions: non-editable figures inline.
Engines.trix = {
  scripts: ['/vendor/trix.min.js'],
  styles: ['/vendor/trix.css'],
  async mount(container, draft, options) {
    const attachment = (content, type) => `<figure data-trix-attachment="${Segments.escape(JSON.stringify({ content, contentType: type }))}" data-trix-content-type="${type}" class="attachment attachment--content"></figure>`;
    const html = `<div>${draft.paragraphs.map(segments => segments.map(s => s.mention
      ? attachment(`<span class="mention">@${Segments.escape(s.mention)}</span>`, 'application/vnd.bakeoff.mention')
      : s.emoji ? attachment(`<img class="emoji" alt="${s.emoji}" src="${Segments.emojiImage(s.emoji)}">`, 'application/vnd.bakeoff.emoji')
      : Segments.escape(s.text)).join('')).join('<br>')}</div>`;
    const element = document.createElement('trix-editor');
    element.setAttribute('aria-label', 'Message');
    if (options.rtl) element.dir = 'rtl';
    const ready = new Promise(resolve => element.addEventListener('trix-initialize', resolve, { once: true }));
    container.append(element);
    await ready;
    const editor = element.editor;
    editor.loadHTML(html);
    // Trix's document is the model: an attachment is one character there (U+FFFC), and its label lives
    // in its content. Trix's renderer drops an image's alt text, so the DOM can't tell.
    const attachments = () => editor.getDocument().getAttachments();
    const label = attachment => {
      const holder = document.createElement('div');
      holder.innerHTML = attachment.getAttribute('content') || '';
      return holder.querySelector('img')?.alt ?? holder.textContent;
    };
    const labels = () => attachments().map(label);
    const text = () => {
      const names = labels();
      let index = 0;
      return editor.getDocument().toString().replace(/\n$/, '').replace(/\uFFFC/g, () => names[index++] ?? '');
    };
    // Trix positions (an attachment is 1) to draft offsets (an attachment is its label), and back.
    const toDraft = position => {
      const raw = editor.getDocument().toString(), names = labels();
      let offset = 0, index = 0;
      for (let i = 0; i < position && i < raw.length; i++) offset += raw[i] === '\uFFFC' ? names[index++].length : 1;
      return offset;
    };
    const toTrix = offset => {
      const raw = editor.getDocument().toString(), names = labels();
      let position = 0, index = 0;
      while (offset > 0 && position < raw.length) { offset -= raw[position] === '\uFFFC' ? names[index++].length : 1; position++; }
      return position;
    };
    return {
      root: element,
      text,
      counts() {
        const types = attachments().map(a => a.getContentType());
        return { chips: types.filter(t => t.endsWith('mention')).length, images: types.filter(t => t.endsWith('emoji')).length };
      },
      focus: () => element.focus(),
      select: (start, end) => editor.setSelectedRange([toTrix(start), toTrix(end)]),
      range: () => editor.getSelectedRange().map(toDraft),
      insert: value => editor.insertString(value),
      // Trix's document reloaded from its own JSON: the element is redrawn from scratch.
      rerender() {
        const range = editor.getSelectedRange();
        editor.loadJSON(JSON.parse(JSON.stringify(editor)));
        editor.setSelectedRange(range);
      },
      onChange: listener => element.addEventListener('trix-change', listener),
    };
  },
};
