// CodeMirror 6 (Obsidian, Replit, GitHub's file editor, many markdown fields): a contenteditable
// that draws only the lines in view from a plain-text document. Mentions are marked text; emoji
// images replace their character with a non-editable widget, as Obsidian's live preview does.
Engines.codemirror = {
  scripts: ['/vendor/codemirror.min.js'],
  async mount(container, draft, options) {
    const C = BakeCodeMirror;
    class EmojiWidget extends C.WidgetType {
      constructor(emoji) { super(); this.emoji = emoji; }
      eq(other) { return other.emoji === this.emoji; }
      toDOM() {
        const image = document.createElement('img');
        image.className = 'emoji'; image.alt = this.emoji; image.src = Segments.emojiImage(this.emoji);
        return image;
      }
    }
    const emoji = new Set(draft.paragraphs.flat().filter(s => s.emoji).map(s => s.emoji));
    const plugin = (regexp, decorate) => {
      const matcher = new C.MatchDecorator({ regexp, decoration: decorate });
      return C.ViewPlugin.fromClass(class {
        constructor(view) { this.decorations = matcher.createDeco(view); }
        update(update) { this.decorations = matcher.updateDeco(update, this.decorations); }
      }, { decorations: v => v.decorations, provide: p => C.EditorView.atomicRanges.of(view => view.plugin(p)?.decorations ?? C.Decoration.none) });
    };
    const extensions = [
      C.history(),
      C.keymap.of([...C.defaultKeymap, ...C.historyKeymap]),
      C.EditorView.lineWrapping,
      C.EditorView.contentAttributes.of({ 'aria-label': 'Message', ...(options.rtl ? { dir: 'rtl' } : {}) }),
      plugin(/@[A-Z][a-z]+ [A-Z][a-z]+/g, () => C.Decoration.mark({ class: 'mention' })),
      C.EditorView.updateListener.of(update => { if (update.docChanged) listeners.forEach(listener => listener()); }),
    ];
    if (emoji.size) extensions.push(plugin(new RegExp([...emoji].join('|'), 'gu'), match => C.Decoration.replace({ widget: new EmojiWidget(match[0]) })));
    const listeners = [];
    const view = new C.EditorView({
      parent: container,
      root: options.shadowRoot,
      state: C.EditorState.create({ doc: Segments.text(draft), extensions }),
    });
    const text = () => view.state.doc.toString();
    return {
      root: view.contentDOM,
      text,
      counts: () => ({ chips: 0, images: [...text()].filter(c => emoji.has(c)).length }),
      focus: () => view.focus(),
      select: (start, end) => view.dispatch({ selection: C.EditorSelection.single(start, end) }),
      range: () => [view.state.selection.main.from, view.state.selection.main.to],
      insert: value => view.dispatch(view.state.replaceSelection(value)),
      // The whole document replaced by itself: every line redrawn, the selection mapped back.
      rerender() {
        const { anchor, head } = view.state.selection.main;
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text() }, selection: C.EditorSelection.single(anchor, head) });
      },
      onChange: listener => listeners.push(listener),
    };
  },
};
