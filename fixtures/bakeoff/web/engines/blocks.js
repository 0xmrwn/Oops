// A block editor (WordPress's Gutenberg, Notion): every paragraph is its own contenteditable, the way
// Gutenberg's RichText renders `p.block-editor-rich-text__editable[role=document]`. Focus and the
// caret live in one block; the app joins the blocks into its document. Mentions are non-editable
// chips, emoji images <img>.
Engines.blocks = {
  async mount(container, draft, options) {
    const root = document.createElement('div');
    root.className = 'blocks-editor';
    if (options.rtl) root.dir = 'rtl';
    container.append(root);
    const block = html => {
      const p = document.createElement('p');
      p.className = 'block-editor-rich-text__editable';
      p.contentEditable = 'true';
      p.setAttribute('role', 'document');
      p.setAttribute('aria-multiline', 'true');
      p.setAttribute('aria-label', 'Block: Paragraph');
      p.innerHTML = html;
      return p;
    };
    const fill = htmls => root.replaceChildren(...htmls.map(block));
    fill(draft.paragraphs.map(p => Segments.html(p).replace(/^<br>$/, '')));
    const blocks = () => [...root.children];
    const lengths = () => blocks().map(b => Segments.measure(b));
    // A draft offset as (block, offset inside it); offsets never span two blocks here.
    const locate = offset => {
      const all = lengths();
      for (let i = 0; i < all.length; i++) {
        if (offset <= all[i] || i === all.length - 1) return [i, Math.min(offset, all[i])];
        offset -= all[i] + 1;
      }
    };
    const current = () => {
      const scope = root.getRootNode();
      const selection = (scope.getSelection ? scope : document).getSelection();
      const node = selection.rangeCount ? selection.getRangeAt(0).startContainer : null;
      return blocks().findIndex(b => b === node || b.contains(node));
    };
    const handle = {
      get root() { const i = current(); return blocks()[i < 0 ? 0 : i]; },
      text: () => Segments.domText(blocks()),
      counts: () => ({ chips: root.querySelectorAll('.mention').length, images: root.querySelectorAll('img').length }),
      focus: () => handle.root.focus(),
      select(start, end) {
        const [i, from] = locate(start), [, to] = locate(end);
        const target = blocks()[i];
        target.focus();
        Segments.domSelect([target], from, to);
      },
      range() {
        const i = current();
        if (i < 0) return null;
        const offsets = Segments.domOffsets([blocks()[i]]);
        const before = lengths().slice(0, i).reduce((sum, length) => sum + length + 1, 0);
        return offsets && [before + offsets[0], before + offsets[1]];
      },
      insert: value => document.execCommand('insertText', false, value),
      // The app re-renders the blocks from its state, as Gutenberg's React tree does after an edit.
      rerender() {
        const range = handle.range();
        fill(blocks().map(b => b.innerHTML));
        if (range) handle.select(...range);
      },
      onChange: listener => root.addEventListener('input', listener),
    };
    return handle;
  },
};
