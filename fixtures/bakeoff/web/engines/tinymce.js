// TinyMCE, classic mode (WordPress's classic editor, Atlassian and many CMS and LMS forms): the
// editable body lives in TinyMCE's own iframe. Mentions are non-editable spans, emoji images <img>.
Engines.tinymce = {
  scripts: ['/vendor/tinymce.min.js'],
  async mount(container, draft, options) {
    const tinymce = BakeTinyMCE.default;
    const target = document.createElement('textarea');
    container.append(target);
    target.value = draft.paragraphs.map(segments => `<p>${segments.map(s => s.mention
      ? `<span class="mention mceNonEditable" contenteditable="false" data-mention="${Segments.escape(s.mention)}">@${Segments.escape(s.mention)}</span>`
      : s.emoji ? `<img class="emoji" alt="${s.emoji}" src="${Segments.emojiImage(s.emoji)}">` : Segments.escape(s.text)).join('') || '<br>'}</p>`).join('');
    const [editor] = await tinymce.init({
      target,
      license_key: 'gpl',
      menubar: false,
      toolbar: false,
      statusbar: false,
      promotion: false,
      branding: false,
      height: options.layout === 'document' ? 440 : 150,
      directionality: options.rtl ? 'rtl' : 'ltr',
      allow_svg_data_urls: true,
      content_style: '.mention { background: #e8f0fe; color: #1a56c4; border-radius: 4px; padding: 0 3px; } img.emoji { width: 1.2em; height: 1.2em; vertical-align: -0.2em; } body { font: 15px/1.45 -apple-system, system-ui, sans-serif; }',
      iframe_aria_text: 'Message',
    });
    const body = () => editor.getBody();
    const blocks = () => [...body().children];
    return {
      get root() { return body(); },
      menuDocument: document,
      text: () => Segments.domText(blocks()),
      counts: () => ({ chips: body().querySelectorAll('.mention').length, images: body().querySelectorAll('img').length }),
      focus: () => editor.focus(),
      select: (start, end) => Segments.domSelect(blocks(), start, end),
      range: () => Segments.domOffsets(blocks()),
      insert: value => editor.insertContent(Segments.escape(value)),
      // The content set again: TinyMCE parses and redraws the whole body.
      rerender() {
        const offsets = Segments.domOffsets(blocks());
        editor.setContent(editor.getContent());
        if (offsets) Segments.domSelect(blocks(), ...offsets);
      },
      onChange: listener => editor.on('input ExecCommand', listener),
    };
  },
};
