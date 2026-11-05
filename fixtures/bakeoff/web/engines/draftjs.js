// Draft.js 0.11 on React 17 (X's composer, older Facebook surfaces, many CMS fields): React renders
// blocks from an immutable EditorState. Mentions are text under an immutable entity, as in
// draft-js-plugins; emoji are text drawn as an image behind transparent glyphs, as X does.
Engines.draftjs = {
  scripts: ['/vendor/draft.min.js'],
  styles: ['/vendor/draft.css'],
  async mount(container, draft, options) {
    const { React, ReactDOM, Draft: D } = BakeDraft;
    const h = React.createElement;
    const strategy = type => (block, callback, content) => block.findEntityRanges(c => {
      const key = c.getEntity();
      return key !== null && content.getEntity(key).getType() === type;
    }, callback);
    const decorator = new D.CompositeDecorator([
      { strategy: strategy('MENTION'), component: props => h('span', { className: 'mention', spellCheck: false }, props.children) },
      {
        strategy: strategy('EMOJI'),
        component: props => h('span', { className: 'draft-emoji', style: { backgroundImage: `url("${Segments.emojiImage(props.decoratedText)}")`, color: 'transparent', backgroundSize: 'contain' } }, props.children),
      },
    ]);
    const entityMap = {};
    const blocks = draft.paragraphs.map((segments, index) => {
      let text = '';
      const entityRanges = [];
      for (const s of segments) {
        const piece = Segments.segmentText(s);
        if (s.mention || s.emoji) {
          const key = Object.keys(entityMap).length;
          entityMap[key] = { type: s.mention ? 'MENTION' : 'EMOJI', mutability: 'IMMUTABLE', data: { value: piece } };
          entityRanges.push({ offset: text.length, length: piece.length, key });
        }
        text += piece;
      }
      return { key: `b${index}`, text, type: 'unstyled', depth: 0, inlineStyleRanges: [], entityRanges, data: {} };
    });
    let state = D.EditorState.createWithContent(D.convertFromRaw({ blocks, entityMap }), decorator);
    const listeners = [];
    let editorRef = null;
    const element = document.createElement('div');
    container.append(element);
    const render = () => ReactDOM.render(h(D.Editor, {
      editorState: state,
      ref: ref => { editorRef = ref; },
      ariaLabel: 'Message',
      ariaMultiline: true,
      textDirectionality: options.rtl ? 'RTL' : 'LTR',
      onChange: next => {
        const changed = next.getCurrentContent() !== state.getCurrentContent();
        state = next;
        render();
        if (changed) listeners.forEach(listener => listener());
      },
    }), element);
    render();
    const keys = () => state.getCurrentContent().getBlocksAsArray().map(block => block.getKey());
    const lengths = () => state.getCurrentContent().getBlocksAsArray().map(block => block.getLength());
    const point = offset => {
      const all = lengths();
      for (let i = 0; i < all.length; i++) {
        if (offset <= all[i] || i === all.length - 1) return [keys()[i], Math.min(offset, all[i])];
        offset -= all[i] + 1;
      }
    };
    const offsetOf = (key, offset) => {
      const all = lengths(), index = keys().indexOf(key);
      return all.slice(0, index).reduce((sum, length) => sum + length + 1, 0) + offset;
    };
    const setSelection = (start, end) => {
      const [anchorKey, anchorOffset] = point(start), [focusKey, focusOffset] = point(end);
      const selection = D.SelectionState.createEmpty(anchorKey).merge({ anchorKey, anchorOffset, focusKey, focusOffset, hasFocus: true });
      state = D.EditorState.forceSelection(state, selection);
      render();
    };
    const content = () => state.getCurrentContent();
    return {
      get root() { return element.querySelector('[contenteditable=true]'); },
      text: () => content().getBlocksAsArray().map(block => block.getText()).join('\n'),
      counts() {
        const counts = { chips: 0, images: 0 };
        content().getBlocksAsArray().forEach(block => block.findEntityRanges(c => c.getEntity() !== null, start => {
          const type = content().getEntity(block.getEntityAt(start)).getType();
          if (type === 'MENTION') counts.chips++; else counts.images++;
        }));
        return counts;
      },
      focus: () => editorRef?.focus(),
      select: setSelection,
      range() {
        const selection = state.getSelection();
        return [offsetOf(selection.getStartKey(), selection.getStartOffset()), offsetOf(selection.getEndKey(), selection.getEndOffset())];
      },
      insert(value) {
        const next = D.Modifier.replaceText(content(), state.getSelection(), value);
        state = D.EditorState.push(state, next, 'insert-characters');
        render();
        listeners.forEach(listener => listener());
      },
      // The same content under new block keys: React replaces every block's DOM.
      rerender() {
        const selection = state.getSelection();
        const start = offsetOf(selection.getStartKey(), selection.getStartOffset()), end = offsetOf(selection.getEndKey(), selection.getEndOffset());
        const raw = D.convertToRaw(content());
        raw.blocks.forEach(block => { block.key = D.genKey(); });
        state = D.EditorState.createWithContent(D.convertFromRaw(raw), decorator);
        render();
        setSelection(start, end);
      },
      onChange: listener => listeners.push(listener),
    };
  },
};
