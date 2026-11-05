// Where the editor sits on the page, the way apps place composers: a chat's bottom composer, a reply
// in a thread pane, an assistant's side panel, a modal dialog, a box inside nested scrolling, or a
// whole-page document. Each builder fills the body and returns the element the editor mounts in.
window.Layouts = (() => {
  const el = (tag, className, children = [], text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    node.append(...children);
    return node;
  };
  const messages = (lines, rtl) => (rtl ? RTL_LINES : lines).map(([who, text]) =>
    el('div', 'message', [el('b', '', [], who), el('span', '', [], text)]));
  const LINES = [
    ['Sam', 'Morning! Did the deploy go out last night?'],
    ['Priya', 'It did, but the login page looked off on Safari.'],
    ['Sam', 'Can you send the release notes before the stand-up?'],
  ];
  const RTL_LINES = [
    ['سارة', 'صباح الخير! هل تم النشر الليلة الماضية؟'],
    ['كريم', 'نعم، لكن صفحة الدخول بدت غريبة.'],
  ];
  const composer = slot => el('div', 'composer', [slot, el('button', 'send', [], '➤')]);

  const builders = {
    composer(slot, rtl) {
      return el('div', 'chat', [el('header', '', [], '# release'), el('div', 'messages', messages(LINES, rtl)), composer(slot)]);
    },
    thread(slot, rtl) {
      const channel = el('div', 'channel', [el('header', '', [], '# release'), el('div', 'messages', messages(LINES, rtl))]);
      const thread = el('aside', 'thread', [
        el('header', '', [], 'Thread'),
        el('div', 'messages', messages(LINES.slice(1), rtl)),
        el('div', 'replies', [], '2 replies'),
        composer(slot),
      ]);
      return el('div', 'split', [channel, thread]);
    },
    'side-panel'(slot, rtl) {
      const article = el('main', 'article', [el('h1', '', [], 'Quarterly planning'),
        ...Array.from({ length: 6 }, () => el('p', '', [], 'The roadmap for the next two sprints is final. Priorities are clear and owners are assigned for each track.'))]);
      const panel = el('aside', 'panel', [el('header', '', [], 'Assistant'), el('div', 'messages', messages(LINES.slice(2), rtl)), composer(slot)]);
      return el('div', 'split', [article, panel]);
    },
    modal(slot) {
      const page = el('main', 'article dimmed', [el('h1', '', [], 'Feed'), el('p', '', [], 'Recent posts from your team.')]);
      const dialog = el('div', 'dialog', [el('header', '', [], 'New post'), el('div', 'dialog-body', [slot]),
        el('footer', '', [el('button', '', [], 'Cancel'), el('button', 'primary', [], 'Post')])]);
      dialog.setAttribute('role', 'dialog'); dialog.setAttribute('aria-modal', 'true'); dialog.setAttribute('aria-label', 'New post');
      return el('div', 'modal-root', [page, el('div', 'scrim'), dialog]);
    },
    'nested-scroll'(slot) {
      const filler = n => Array.from({ length: n }, (_, i) => el('p', '', [], `Earlier note ${i + 1}: the build moved to the new runners and the cache is warm again.`));
      const inner = el('div', 'inner-scroll', [...filler(8), el('div', 'card', [el('header', '', [], 'Reply'), el('div', 'box-scroll', [slot])]), ...filler(4)]);
      return el('div', 'outer-scroll', [el('header', '', [], 'Activity'), ...filler(10), inner, ...filler(10)]);
    },
    document(slot) {
      return el('div', 'document', [el('div', 'doc-title', [], 'Weekly update'), slot]);
    },
  };

  return {
    build(layout, { rtl }) {
      const slot = el('div', 'slot');
      document.body.replaceChildren(builders[layout](slot, rtl));
      document.body.dataset.layout = layout;
      return slot;
    },

    // After the editor mounted: scroll nested containers so the editor sits mid-way, as a person would.
    settle(layout, slot) {
      if (layout !== 'nested-scroll') return;
      const outer = document.querySelector('.outer-scroll'), inner = document.querySelector('.inner-scroll');
      const card = slot.closest('.card');
      // Positions only: if the editor isn't in its card, the runner's caret checks report the case.
      if (!outer || !inner || !card) return;
      inner.scrollTop = card.offsetTop - inner.offsetTop - 60;
      outer.scrollTop = inner.offsetTop - 120;
    },

    present(presentation) {
      const root = document.documentElement;
      root.dir = presentation === 'rtl' ? 'rtl' : 'ltr';
      root.lang = presentation === 'rtl' ? 'ar' : 'en';
      root.style.zoom = presentation === 'zoom' ? '1.5' : '';
    },
  };
})();
