// Lexical, without React (Facebook, Messenger, WhatsApp Web, Ghost): a reconciler that owns the
// contenteditable DOM. Mentions are token text nodes (editable text, deleted whole), as in Lexical's
// playground; emoji images are inline decorator nodes.
Engines.lexical = {
  scripts: ['/vendor/lexical.min.js'],
  async mount(container, draft, options) {
    const L = BakeLexical;
    class MentionNode extends L.TextNode {
      static getType() { return 'mention'; }
      static clone(node) { return new MentionNode(node.__mention, node.__text, node.__key); }
      static importJSON(json) { return $mention(json.mention); }
      constructor(mention, text, key) { super(text ?? '@' + mention, key); this.__mention = mention; }
      exportJSON() { return { ...super.exportJSON(), type: 'mention', mention: this.__mention, version: 1 }; }
      createDOM(config) { const dom = super.createDOM(config); dom.className = 'mention'; return dom; }
      isTextEntity() { return true; }
      canInsertTextBefore() { return false; }
      canInsertTextAfter() { return false; }
    }
    class EmojiImageNode extends L.DecoratorNode {
      static getType() { return 'emoji-image'; }
      static clone(node) { return new EmojiImageNode(node.__emoji, node.__key); }
      static importJSON(json) { return new EmojiImageNode(json.emoji); }
      constructor(emoji, key) { super(key); this.__emoji = emoji; }
      exportJSON() { return { type: 'emoji-image', emoji: this.__emoji, version: 1 }; }
      createDOM() {
        const span = document.createElement('span');
        span.contentEditable = 'false';
        span.innerHTML = `<img class="emoji" alt="${this.__emoji}" src="${Segments.emojiImage(this.__emoji)}">`;
        return span;
      }
      updateDOM() { return false; }
      decorate() { return null; }
      isInline() { return true; }
      getTextContent() { return this.__emoji; }
    }
    const $mention = name => new MentionNode(name).setMode('token');
    const root = document.createElement('div');
    root.contentEditable = 'true';
    root.setAttribute('role', 'textbox');
    root.setAttribute('aria-multiline', 'true');
    root.setAttribute('aria-label', 'Message');
    if (options.rtl) root.dir = 'rtl';
    container.append(root);
    const editor = L.createEditor({ namespace: 'bakeoff', nodes: [MentionNode, EmojiImageNode], onError: error => { throw error; } });
    editor.setRootElement(root);
    L.mergeRegister(L.registerRichText(editor), L.registerHistory(editor, L.createEmptyHistoryState(), 300));
    editor.update(() => {
      const top = L.$getRoot();
      top.clear();
      for (const segments of draft.paragraphs) {
        const paragraph = L.$createParagraphNode();
        for (const s of segments) {
          if (s.mention) paragraph.append($mention(s.mention));
          else if (s.emoji) paragraph.append(new EmojiImageNode(s.emoji));
          else if (s.text) paragraph.append(L.$createTextNode(s.text));
        }
        top.append(paragraph);
      }
    }, { discrete: true });
    const blocks = () => [...root.children];
    const read = fn => editor.getEditorState().read(fn);
    const handle = {
      root,
      text: () => read(() => L.$getRoot().getChildren().map(node => node.getTextContent()).join('\n')),
      counts: () => read(() => {
        const counts = { chips: 0, images: 0 };
        const walk = node => {
          if (node instanceof MentionNode) counts.chips++;
          if (node instanceof EmojiImageNode) counts.images++;
          if (L.$isElementNode(node)) node.getChildren().forEach(walk);
        };
        walk(L.$getRoot());
        return counts;
      }),
      focus: () => root.focus(),
      select: (start, end) => Segments.domSelect(blocks(), start, end),
      range: () => Segments.domOffsets(blocks()),
      insert: value => editor.update(() => {
        const selection = L.$getSelection();
        if (L.$isRangeSelection(selection)) selection.insertRawText(value);
      }),
      // The same state parsed again: new node keys, so the reconciler rebuilds every element.
      rerender() {
        const offsets = Segments.domOffsets(blocks());
        const json = JSON.stringify(editor.getEditorState().toJSON());
        editor.setEditorState(editor.parseEditorState(json));
        if (offsets) setTimeout(() => handle.select(...offsets), 0);
      },
      onChange: listener => editor.registerUpdateListener(({ dirtyElements, dirtyLeaves }) => {
        if (dirtyElements.size || dirtyLeaves.size) listener();
      }),
    };
    return handle;
  },
};
