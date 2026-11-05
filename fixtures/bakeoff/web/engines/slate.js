// Slate with slate-react (Discord, Canva, Grafana): React renders every node and Slate maps the DOM
// selection back. Mentions and emoji images are inline void elements, with Slate's zero-width text.
Engines.slate = {
  scripts: ['/vendor/slate.min.js'],
  async mount(container, draft, options) {
    const { React, createRoot, Slate: S, SlateReact: SR, withHistory } = BakeSlate;
    const h = React.createElement;
    const editor = withHistory(SR.withReact(S.createEditor()));
    const { isInline, isVoid } = editor;
    editor.isInline = element => ['mention', 'emoji'].includes(element.type) || isInline(element);
    editor.isVoid = element => ['mention', 'emoji'].includes(element.type) || isVoid(element);
    const value = draft.paragraphs.map(segments => {
      const children = [{ text: '' }];
      for (const s of segments) {
        if (s.mention) children.push({ type: 'mention', name: s.mention, children: [{ text: '' }] }, { text: '' });
        else if (s.emoji) children.push({ type: 'emoji', emoji: s.emoji, children: [{ text: '' }] }, { text: '' });
        else children[children.length - 1].text += s.text;
      }
      return { type: 'paragraph', children };
    });
    const renderElement = ({ attributes, children, element }) => {
      if (element.type === 'mention') {
        return h('span', { ...attributes, contentEditable: false, className: 'mention', 'data-mention': element.name }, '@' + element.name, children);
      }
      if (element.type === 'emoji') {
        return h('span', { ...attributes, contentEditable: false }, h('img', { className: 'emoji', alt: element.emoji, src: Segments.emojiImage(element.emoji) }), children);
      }
      return h('p', { ...attributes, dir: options.rtl ? 'rtl' : undefined }, children);
    };
    const listeners = [];
    const onChange = () => {
      if (editor.operations.some(op => op.type !== 'set_selection')) listeners.forEach(listener => listener());
    };
    const host = document.createElement('div');
    container.append(host);
    const app = createRoot(host);
    let generation = 0;
    const render = initialValue => new Promise(resolve => {
      generation++;
      app.render(h(SR.Slate, { key: generation, editor, initialValue, onChange },
        h(SR.Editable, { renderElement, 'aria-label': 'Message', className: 'slate-editor' })));
      setTimeout(resolve, 60);
    });
    await render(value);
    const root = () => host.querySelector('[data-slate-editor]');
    const label = node => node.type === 'mention' ? '@' + node.name : node.type === 'emoji' ? node.emoji : node.text;
    // Slate keeps its own selection and redraws the DOM's from it: select through Slate, by path.
    const point = offset => {
      for (let p = 0; p < editor.children.length; p++) {
        const children = editor.children[p].children;
        const size = children.reduce((sum, node) => sum + label(node).length, 0);
        if (offset <= size || p === editor.children.length - 1) {
          for (let i = 0; i < children.length; i++) {
            const length = label(children[i]).length;
            if (children[i].type === undefined && offset <= length) return { path: [p, i], offset };
            offset -= length;
          }
          return S.Editor.end(editor, [p]);
        }
        offset -= size + 1;
      }
    };
    const offsetOf = ({ path: [p, i], offset }) => editor.children.slice(0, p).reduce((sum, node) => sum + node.children.reduce((n, c) => n + label(c).length, 0) + 1, 0)
      + editor.children[p].children.slice(0, i).reduce((sum, node) => sum + label(node).length, 0) + offset;
    const handle = {
      get root() { return root(); },
      text: () => editor.children.map(p => p.children.map(label).join('')).join('\n'),
      counts() {
        const inlines = editor.children.flatMap(p => p.children);
        return { chips: inlines.filter(n => n.type === 'mention').length, images: inlines.filter(n => n.type === 'emoji').length };
      },
      focus: () => SR.ReactEditor.focus(editor),
      select: (start, end) => S.Transforms.select(editor, { anchor: point(start), focus: point(end) }),
      range: () => editor.selection && [offsetOf(S.Range.start(editor.selection)), offsetOf(S.Range.end(editor.selection))],
      insert: text => editor.insertText(text),
      // A remount from the current value (a new React key): every DOM node is new.
      rerender() {
        const selection = editor.selection;
        const offsets = selection && [offsetOf(S.Range.start(selection)), offsetOf(S.Range.end(selection))];
        const current = JSON.parse(JSON.stringify(editor.children));
        editor.selection = null;
        render(current).then(() => {
          SR.ReactEditor.focus(editor);
          if (offsets) handle.select(...offsets);
        });
      },
      onChange: listener => listeners.push(listener),
    };
    return handle;
  },
};
