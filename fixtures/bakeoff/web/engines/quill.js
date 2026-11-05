// Quill 2 (Slack's composer began as Quill, Signal, Gemini's prompt box): a Delta document, redrawn
// into one contenteditable root. Mentions and emoji images are embed blots: a non-editable inner
// span between two zero-width guards.
Engines.quill = {
  scripts: ['/vendor/quill.min.js'],
  styles: ['/vendor/quill.snow.css'],
  async mount(container, draft, options) {
    const Embed = Quill.import('blots/embed');
    if (!Quill.imports['formats/mention']) {
      class MentionBlot extends Embed {
        static blotName = 'mention';
        static tagName = 'span';
        static className = 'mention';
        static create(name) { const node = super.create(); node.dataset.name = name; node.textContent = '@' + name; return node; }
        static value(node) { return node.dataset.name; }
      }
      class EmojiBlot extends Embed {
        static blotName = 'emoji';
        static tagName = 'span';
        static className = 'emoji-blot';
        static create(emoji) {
          const node = super.create();
          node.dataset.emoji = emoji;
          node.innerHTML = `<img class="emoji" alt="${emoji}" src="${Segments.emojiImage(emoji)}">`;
          return node;
        }
        static value(node) { return node.dataset.emoji; }
      }
      Quill.register(MentionBlot);
      Quill.register(EmojiBlot);
    }
    const element = document.createElement('div');
    container.append(element);
    const quill = new Quill(element, { theme: 'snow', modules: { toolbar: false } });
    const ops = [];
    for (const segments of draft.paragraphs) {
      for (const s of segments) ops.push(s.mention ? { insert: { mention: s.mention } } : s.emoji ? { insert: { emoji: s.emoji } } : { insert: s.text });
      ops.push({ insert: '\n' });
    }
    quill.setContents(ops.filter(op => op.insert !== ''), 'silent');
    quill.root.setAttribute('aria-label', 'Message');
    if (options.rtl) quill.root.dir = 'rtl';
    const blocks = () => [...quill.root.children];
    const text = () => quill.getContents().ops.map(op => typeof op.insert === 'string' ? op.insert
      : op.insert.mention ? '@' + op.insert.mention : op.insert.emoji ?? '').join('').replace(/\n$/, '');
    return {
      root: quill.root,
      text,
      counts() {
        const embeds = quill.getContents().ops.filter(op => typeof op.insert === 'object');
        return { chips: embeds.filter(op => op.insert.mention).length, images: embeds.filter(op => op.insert.emoji).length };
      },
      focus: () => quill.focus(),
      select: (start, end) => Segments.domSelect(blocks(), start, end),
      range: () => Segments.domOffsets(blocks()),
      insert(value) {
        const range = quill.getSelection(true);
        quill.deleteText(range.index, range.length, 'user');
        quill.insertText(range.index, value, 'user');
        quill.setSelection(range.index + value.length, 0, 'user');
      },
      // The same Delta set again: Quill empties and redraws every line.
      rerender() {
        const range = quill.getSelection();
        quill.setContents(quill.getContents(), 'silent');
        if (range) quill.setSelection(range, 'silent');
      },
      onChange: listener => quill.on('text-change', listener),
    };
  },
};
