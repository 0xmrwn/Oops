// ProseMirror through Tiptap (Linear, GitLab, Substack, ChatGPT's and Claude's composers): one
// contenteditable root that ProseMirror redraws from its document. Mentions are atom nodes (a
// non-editable chip), emoji images inline atom nodes.
Engines.prosemirror = {
  scripts: ['/vendor/tiptap.min.js'],
  async mount(container, draft, options) {
    const { Editor, Node, mergeAttributes, StarterKit, Mention } = BakeTiptap;
    const EmojiImage = Node.create({
      name: 'emojiImage', group: 'inline', inline: true, atom: true,
      addAttributes: () => ({ alt: { default: '' }, src: { default: '' } }),
      parseHTML: () => [{ tag: 'img.emoji' }],
      renderHTML: ({ HTMLAttributes }) => ['img', mergeAttributes({ class: 'emoji' }, HTMLAttributes)],
      renderText: ({ node }) => node.attrs.alt,
    });
    const leaf = node => node.type.name === 'mention' ? '@' + node.attrs.label : node.type.name === 'emojiImage' ? node.attrs.alt : node.type.name === 'hardBreak' ? '\n' : '';
    const paragraph = segments => ({
      type: 'paragraph',
      content: segments.filter(s => !('text' in s) || s.text).map(s => s.mention ? { type: 'mention', attrs: { id: s.mention, label: s.mention } }
        : s.emoji ? { type: 'emojiImage', attrs: { alt: s.emoji, src: Segments.emojiImage(s.emoji) } } : { type: 'text', text: s.text }),
    });
    const element = document.createElement('div');
    container.append(element);
    const editor = new Editor({
      element,
      extensions: [
        StarterKit,
        Mention.configure({
          HTMLAttributes: { class: 'mention' },
          renderText: ({ node }) => '@' + node.attrs.label,
          renderHTML: ({ node }) => ['span', { class: 'mention', 'data-mention': node.attrs.label }, '@' + node.attrs.label],
        }),
        EmojiImage,
      ],
      content: { type: 'doc', content: draft.paragraphs.map(paragraph) },
      editorProps: { attributes: { 'aria-label': 'Message', role: 'textbox', 'aria-multiline': 'true', ...(options.rtl ? { dir: 'rtl' } : {}) } },
    });
    const view = editor.view;
    const blocks = () => [...view.dom.children];
    const text = () => view.state.doc.textBetween(0, view.state.doc.content.size, '\n', leaf);
    return {
      root: view.dom,
      text,
      counts() {
        const counts = { chips: 0, images: 0 };
        view.state.doc.descendants(node => {
          if (node.type.name === 'mention') counts.chips++;
          if (node.type.name === 'emojiImage') counts.images++;
        });
        return counts;
      },
      focus: () => view.focus(),
      select: (start, end) => Segments.domSelect(blocks(), start, end),
      range() {
        const { from, to } = view.state.selection;
        return [view.state.doc.textBetween(0, from, '\n', leaf).length, view.state.doc.textBetween(0, to, '\n', leaf).length];
      },
      insert: value => view.pasteText(value),
      // A full reload of the same document: every node redrawn, the selection kept by position.
      rerender() {
        const { from, to } = view.state.selection;
        editor.commands.setContent(editor.getJSON(), { emitUpdate: false });
        editor.commands.setTextSelection({ from, to });
      },
      onChange: listener => editor.on('update', listener),
    };
  },
};
