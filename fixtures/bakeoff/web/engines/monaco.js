// Monaco (VS Code, Azure DevOps, GitHub Codespaces, Cursor): canvas-like rendered lines over a hidden
// textarea that takes input. Its accessibility is left on "auto", as web apps ship it. Mentions are
// decorated text; there are no images.
Engines.monaco = {
  scripts: ['/vendor/monaco.min.js'],
  styles: ['/vendor/monaco.min.css'],
  async mount(container, draft, options) {
    const { editor: M, Range } = BakeMonaco;
    self.MonacoEnvironment ??= { getWorker: () => new Worker(URL.createObjectURL(new Blob([''], { type: 'text/javascript' }))) };
    const host = document.createElement('div');
    host.className = 'monaco-host';
    if (options.rtl) host.dir = 'rtl';
    container.append(host);
    const editor = M.create(host, {
      value: Segments.text(draft),
      language: 'plaintext',
      minimap: { enabled: false },
      lineNumbers: 'off',
      glyphMargin: false,
      folding: false,
      wordWrap: 'on',
      fontSize: 15,
      scrollBeyondLastLine: false,
      quickSuggestions: false,
      wordBasedSuggestions: 'off',
      occurrencesHighlight: 'off',
      links: false,
      renderLineHighlight: 'none',
      ariaLabel: 'Message',
      automaticLayout: true,
    });
    const model = editor.getModel();
    model.setEOL(M.EndOfLineSequence.LF);
    let mentions = [];
    const decorate = () => {
      const ranges = model.findMatches('@[A-Z][a-z]+ [A-Z][a-z]+', false, true, true, null, false).map(match => ({ range: match.range, options: { inlineClassName: 'mention' } }));
      mentions = editor.deltaDecorations(mentions, ranges);
    };
    decorate();
    editor.onDidChangeModelContent(decorate);
    const range = (start, end) => {
      const a = model.getPositionAt(start), b = model.getPositionAt(end);
      return new Range(a.lineNumber, a.column, b.lineNumber, b.column);
    };
    return {
      get root() { return host.querySelector('textarea'); },
      text: () => model.getValue(),
      counts: () => ({ chips: 0, images: 0 }),
      focus: () => editor.focus(),
      select: (start, end) => editor.setSelection(range(start, end)),
      range() {
        const selection = editor.getSelection();
        return [model.getOffsetAt(selection.getStartPosition()), model.getOffsetAt(selection.getEndPosition())];
      },
      insert: value => editor.executeEdits('paste', [{ range: editor.getSelection(), text: value, forceMoveMarkers: true }]),
      // The model's value set again, as apps that sync a controlled value do: the view redraws.
      rerender() {
        const selection = editor.getSelection();
        const start = model.getOffsetAt(selection.getStartPosition()), end = model.getOffsetAt(selection.getEndPosition());
        model.setValue(model.getValue());
        editor.setSelection(range(start, end));
      },
      onChange: listener => editor.onDidChangeModelContent(listener),
    };
  },
};
