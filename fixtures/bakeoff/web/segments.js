// Drafts as engines see them: paragraphs of segments, each plain text, a mention or an emoji image.
// Every engine's text() follows the same rules, so the runner compares one string per case:
// paragraphs joined by "\n", a mention as "@Name", an emoji image as its alt text.
window.Segments = {
  segmentText(segment) {
    if (segment.mention) return '@' + segment.mention;
    if (segment.emoji) return segment.emoji;
    return segment.text;
  },

  paragraphText(paragraph) { return paragraph.map(Segments.segmentText).join(''); },

  text(draft) { return draft.paragraphs.map(Segments.paragraphText).join('\n'); },

  // Where a text offset falls: paragraph, segment and offset inside it. Selections and carets only
  // land in plain text or at a paragraph's end, never inside an atom.
  locate(draft, offset) {
    let rest = offset;
    for (let p = 0; p < draft.paragraphs.length; p++) {
      const paragraph = draft.paragraphs[p];
      const length = Segments.paragraphText(paragraph).length;
      if (rest <= length) {
        for (let s = 0; s < paragraph.length; s++) {
          const size = Segments.segmentText(paragraph[s]).length;
          if (rest <= size && !paragraph[s].mention && !paragraph[s].emoji) return { paragraph: p, segment: s, offset: rest, inParagraph: offset - Segments.start(draft, p) };
          rest -= size;
        }
        return { paragraph: p, segment: paragraph.length, offset: 0, inParagraph: length };
      }
      rest -= length + 1;
    }
    const last = draft.paragraphs.length - 1;
    return { paragraph: last, segment: draft.paragraphs[last].length, offset: 0, inParagraph: Segments.paragraphText(draft.paragraphs[last]).length };
  },

  start(draft, paragraph) {
    let at = 0;
    for (let p = 0; p < paragraph; p++) at += Segments.paragraphText(draft.paragraphs[p]).length + 1;
    return at;
  },

  // Model positions for engines that count an atom as one position (ProseMirror, Slate offsets, Quill,
  // CodeMirror widgets do not: they keep the label). `atom` is the size an atom takes in the engine.
  // Returns the offset inside the paragraph, in engine units.
  engineOffset(draft, located, atom) {
    const paragraph = draft.paragraphs[located.paragraph];
    let at = 0;
    for (let s = 0; s < located.segment && s < paragraph.length; s++) {
      const segment = paragraph[s];
      at += segment.mention || segment.emoji ? atom(segment) : segment.text.length;
    }
    return at + located.offset;
  },

  // A paragraph as HTML: mentions as non-editable chips, emoji as images, the way chat apps render them.
  html(paragraph, { chip = 'span', imageClass = 'emoji' } = {}) {
    const escape = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    return paragraph.map(segment => {
      if (segment.mention) return `<${chip} class="mention" data-mention="${escape(segment.mention)}" contenteditable="false">@${escape(segment.mention)}</${chip}>`;
      if (segment.emoji) return `<img class="${imageClass}" alt="${segment.emoji}" src="${Segments.emojiImage(segment.emoji)}">`;
      return escape(segment.text);
    }).join('') || '<br>';
  },

  // An emoji drawn as an image, like Slack, Discord and X render them: an SVG with the glyph inside.
  emojiImage(emoji) {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><text x="0" y="16" font-size="16">${emoji}</text></svg>`;
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  },

  // DOM selection by draft offsets, for engines that follow the browser's selection (most do: they
  // listen to selectionchange). `blocks` are the paragraph elements in order. An atom (a
  // non-editable chip, an image) counts as its label; zero-width guards count as nothing; a <br>
  // counts as a line break only where the engine keeps several lines in one block (`br: 1`).
  measure(node, br = 0) {
    if (node.nodeType === Node.TEXT_NODE) return node.data.replace(/\uFEFF|\u200B/g, '').length;
    if (node.nodeType !== Node.ELEMENT_NODE) return 0;
    if (node.tagName === 'IMG') return (node.alt || '').length;
    if (node.tagName === 'BR') return node.dataset.lexicalLinebreak !== undefined || br ? br : 0;
    if (node.getAttribute('contenteditable') === 'false') return Segments.atomLabel(node).length;
    let total = 0;
    for (const child of node.childNodes) total += Segments.measure(child, br);
    return total;
  },

  atomLabel(node) {
    if (node.dataset.mention) return '@' + node.dataset.mention;
    const image = node.querySelector('img');
    if (image) return image.alt || '';
    return node.textContent.replace(/\uFEFF|\u200B/g, '');
  },

  // A (node, offset) point `offset` characters into `element`.
  point(element, offset, br = 0) {
    for (const child of element.childNodes) {
      const size = Segments.measure(child, br);
      if (offset <= size) {
        if (child.nodeType === Node.TEXT_NODE) {
          let seen = 0, i = 0;
          for (; i < child.data.length && seen < offset; i++) if (!/\uFEFF|\u200B/.test(child.data[i])) seen++;
          return [child, i];
        }
        const atom = child.nodeType === Node.ELEMENT_NODE && (child.tagName === 'IMG' || child.tagName === 'BR' || child.getAttribute('contenteditable') === 'false');
        if (!atom) return Segments.point(child, offset, br);
        const index = Array.prototype.indexOf.call(element.childNodes, child);
        return [element, offset === 0 ? index : index + 1];
      }
      offset -= size;
    }
    return [element, element.childNodes.length];
  },

  domSelect(blocks, start, end, br = 0) {
    const locate = offset => {
      for (let i = 0; i < blocks.length; i++) {
        const size = Segments.measure(blocks[i], br);
        if (offset <= size || i === blocks.length - 1) return Segments.point(blocks[i], Math.min(offset, size), br);
        offset -= size + 1;
      }
    };
    const doc = blocks[0].ownerDocument, root = blocks[0].getRootNode();
    const selection = (root.getSelection ? root : doc).getSelection();
    // setBaseAndExtent, unlike addRange, also places a selection inside a shadow root in WebKit.
    selection.setBaseAndExtent(...locate(start), ...locate(end));
  },

  // The draft offset of a DOM point, and the current selection as draft offsets.
  offsetOf(blocks, node, offset, br = 0) {
    let total = 0;
    for (const block of blocks) {
      if (block === node || block.contains(node)) {
        const range = block.ownerDocument.createRange();
        range.setStart(block, 0);
        range.setEnd(node, offset);
        const probe = block.ownerDocument.createElement('div');
        probe.append(range.cloneContents());
        return total + Segments.measure(probe, br);
      }
      total += Segments.measure(block, br) + 1;
    }
    return null;
  },

  domOffsets(blocks, br = 0) {
    if (!blocks.length) return null;
    const root = blocks[0].getRootNode();
    const selection = (root.getSelection ? root : blocks[0].ownerDocument).getSelection();
    if (!selection || !selection.rangeCount) return null;
    const range = selection.getRangeAt(0);
    const start = Segments.offsetOf(blocks, range.startContainer, range.startOffset, br);
    const end = Segments.offsetOf(blocks, range.endContainer, range.endOffset, br);
    return start === null || end === null ? null : [start, end];
  },

  // A DOM editor's text by the same rules: what engines with no model of their own (or whose model
  // is the DOM) hold. One string per block, joined by "\n".
  domText(blocks, br = 0) {
    return blocks.map(block => {
      let line = '';
      const walk = node => {
        if (node.nodeType === Node.TEXT_NODE) line += node.data.replace(/\uFEFF|\u200B/g, '');
        else if (node.nodeType !== Node.ELEMENT_NODE) return;
        else if (node.tagName === 'IMG') line += node.alt;
        else if (node.tagName === 'BR') line += br ? '\n' : '';
        else if (node.getAttribute('contenteditable') === 'false') line += Segments.atomLabel(node);
        else node.childNodes.forEach(walk);
      };
      block.childNodes.forEach(walk);
      return line;
    }).join('\n');
  },

  escape: s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
};
