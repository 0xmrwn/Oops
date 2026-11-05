// CKEditor 5, classic build (Teams' and many CMS and helpdesk editors): a model, a virtual view and
// the DOM, re-rendered from the view. Mentions are text with a mention attribute (its Mention
// plugin); emoji images are inline widgets, non-editable.
Engines.ckeditor = {
  scripts: ['/vendor/ckeditor.min.js'],
  styles: ['/vendor/ckeditor.css'],
  async mount(container, draft, options) {
    const K = BakeCKEditor;
    class EmojiImage extends K.Plugin {
      static get requires() { return [K.Widget]; }
      init() {
        const editor = this.editor;
        editor.model.schema.register('emojiImage', { inheritAllFrom: '$inlineObject', allowAttributes: ['alt'] });
        editor.conversion.for('upcast').elementToElement({
          view: { name: 'img', classes: 'emoji' },
          model: (view, { writer }) => writer.createElement('emojiImage', { alt: view.getAttribute('alt') }),
        });
        editor.conversion.for('dataDowncast').elementToElement({
          model: 'emojiImage',
          view: (model, { writer }) => writer.createEmptyElement('img', { class: 'emoji', alt: model.getAttribute('alt'), src: Segments.emojiImage(model.getAttribute('alt')) }),
        });
        editor.conversion.for('editingDowncast').elementToElement({
          model: 'emojiImage',
          view: (model, { writer }) => {
            const span = writer.createContainerElement('span', { class: 'emoji-widget' }, [
              writer.createEmptyElement('img', { class: 'emoji', alt: model.getAttribute('alt'), src: Segments.emojiImage(model.getAttribute('alt')) }),
            ]);
            return K.toWidget(span, writer);
          },
        });
        editor.editing.mapper.on('viewToModelPosition', K.viewToModelPositionOutsideModelElement(editor.model, view => view.hasClass('emoji-widget')));
      }
    }
    const element = document.createElement('div');
    container.append(element);
    const html = draft.paragraphs.map(segments => `<p>${segments.map(s => s.mention
      ? `<span class="mention" data-mention="@${Segments.escape(s.mention)}">@${Segments.escape(s.mention)}</span>`
      : s.emoji ? `<img class="emoji" alt="${s.emoji}">` : Segments.escape(s.text)).join('')}</p>`).join('');
    const editor = await K.ClassicEditor.create(element, {
      licenseKey: 'GPL',
      plugins: [K.Essentials, K.Paragraph, K.Bold, K.Italic, K.Link, K.Mention, EmojiImage],
      toolbar: [],
      language: { content: options.rtl ? 'ar' : 'en' },
      mention: { feeds: [{ marker: '@', feed: ['@Alice Martin', '@Sam Lee', '@Priya Patel'] }] },
      initialData: html,
    });
    const domRoot = () => editor.editing.view.getDomRoot();
    domRoot().setAttribute('aria-label', 'Message');
    const paragraphs = () => [...editor.model.document.getRoot().getChildren()];
    const text = () => paragraphs().map(paragraph => {
      let line = '';
      for (const item of editor.model.createRangeIn(paragraph).getItems()) {
        if (item.is('$textProxy')) line += item.data;
        else if (item.is('element', 'emojiImage')) line += item.getAttribute('alt');
      }
      return line;
    }).join('\n');
    // Draft offsets to model positions: text counts as itself, an emoji widget as one model offset.
    const position = (writer, offset) => {
      const all = paragraphs();
      for (let p = 0; p < all.length; p++) {
        let size = 0;
        for (const child of all[p].getChildren()) size += child.is('$text') ? child.data.length : child.getAttribute('alt').length;
        if (offset <= size || p === all.length - 1) {
          let model = 0;
          for (const child of all[p].getChildren()) {
            const length = child.is('$text') ? child.data.length : child.getAttribute('alt').length;
            if (child.is('$text') && offset <= length) return writer.createPositionAt(all[p], model + offset);
            offset -= length; model += child.offsetSize;
          }
          return writer.createPositionAt(all[p], 'end');
        }
        offset -= size + 1;
      }
    };
    const offsetOf = modelPosition => {
      const all = paragraphs(), index = all.indexOf(modelPosition.parent);
      let at = all.slice(0, index).reduce((sum, paragraph) => sum + [...paragraph.getChildren()].reduce((n, c) => n + (c.is('$text') ? c.data.length : c.getAttribute('alt').length), 0) + 1, 0);
      let model = 0;
      for (const child of modelPosition.parent.getChildren()) {
        if (model >= modelPosition.offset) break;
        const take = Math.min(child.offsetSize, modelPosition.offset - model);
        at += child.is('$text') ? take : child.getAttribute('alt').length;
        model += child.offsetSize;
      }
      return at;
    };
    return {
      get root() { return domRoot(); },
      text,
      counts() {
        const mentions = new Set();
        let images = 0;
        for (const paragraph of paragraphs()) {
          for (const item of editor.model.createRangeIn(paragraph).getItems()) {
            if (item.is('$textProxy') && item.getAttribute('mention')) mentions.add(item.getAttribute('mention').uid);
            if (item.is('element', 'emojiImage')) images++;
          }
        }
        return { chips: mentions.size, images };
      },
      focus: () => editor.editing.view.focus(),
      select: (start, end) => editor.model.change(writer => writer.setSelection(writer.createRange(position(writer, start), position(writer, end)))),
      range() {
        const range = editor.model.document.selection.getFirstRange();
        return [offsetOf(range.start), offsetOf(range.end)];
      },
      insert: value => editor.model.change(writer => editor.model.insertContent(writer.createText(value))),
      // The editor's data set again: the model, view and DOM are rebuilt.
      rerender() {
        const range = editor.model.document.selection.getFirstRange();
        const offsets = [offsetOf(range.start), offsetOf(range.end)];
        editor.setData(editor.getData());
        editor.model.change(writer => writer.setSelection(writer.createRange(position(writer, offsets[0]), position(writer, offsets[1]))));
      },
      onChange: listener => editor.model.document.on('change:data', listener),
    };
  },
};
