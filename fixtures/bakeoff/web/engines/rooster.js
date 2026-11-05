// RoosterJS 9 (Outlook on the web, Teams): a content model written back into one contenteditable
// div, with native typing left to the browser. Mentions are read-only inline entities, the way
// Outlook marks them; emoji images are plain <img>.
Engines.roosterjs = {
  scripts: ['/vendor/rooster.min.js'],
  async mount(container, draft, options) {
    const R = roosterjs;
    const root = document.createElement('div');
    root.className = 'rooster';
    root.setAttribute('role', 'textbox');
    root.setAttribute('aria-multiline', 'true');
    root.setAttribute('aria-label', 'Message');
    if (options.rtl) root.dir = 'rtl';
    container.append(root);
    const html = draft.paragraphs.map((segments, p) => `<div>${segments.map((s, i) => s.mention
      ? `<span class="_Entity _EType_mention _EId_m${p}x${i} _EReadonly_1" contenteditable="false" data-mention="${Segments.escape(s.mention)}">@${Segments.escape(s.mention)}</span>`
      : s.emoji ? `<img class="emoji" alt="${s.emoji}" src="${Segments.emojiImage(s.emoji)}">` : Segments.escape(s.text)).join('') || '<br>'}</div>`).join('');
    const editor = R.createEditor(root, [], R.createModelFromHtml(html));
    const blocks = () => [...root.children].filter(child => child.tagName === 'DIV');
    return {
      root,
      text: () => Segments.domText(blocks()),
      counts: () => ({ chips: root.querySelectorAll('._Entity').length, images: root.querySelectorAll('img').length }),
      focus: () => editor.focus(),
      select: (start, end) => Segments.domSelect(blocks(), start, end),
      range: () => Segments.domOffsets(blocks()),
      insert: value => document.execCommand('insertText', false, value),
      // The content model rebuilt from the editor's HTML and written back: Rooster redraws each block.
      rerender() {
        const offsets = Segments.domOffsets(blocks());
        const model = R.createModelFromHtml(R.exportContent(editor, 'HTML'));
        editor.formatContentModel(current => { current.blocks = model.blocks; return true; });
        if (offsets) Segments.domSelect(blocks(), ...offsets);
      },
      onChange: listener => root.addEventListener('input', listener),
    };
  },
};
