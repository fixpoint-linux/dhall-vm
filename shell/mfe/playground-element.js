// shell/mfe/playground-element.js — the <dhall-playground> custom element.
//
// Defines a custom element that encapsulates the WASM + CodeMirror playground
// editor. The element builds its editor DOM on connectedCallback and loads the
// required scripts (dhall.js, dhall-lsp.js, CodeMirror, dhall-mode.js,
// codemirror-lint.js, playground-ui.js).
//
// DOM contract (must be satisfied for playground-ui.js, ported from the old
// docs/app.js + docs/lsp-demo.js):
//   #source       — textarea (converted to CodeMirror, mode:'dhall')
//   #output       — textarea (readonly) for the result
//   #status       — status line
//   #runBtn       — the Run button
//   #copyBtn      — the Copy button
//   #modes        — container of 5 <button class=mode data-mode=0..4>
//                   (typecheck/normalize/to-json/to-toml/to-yaml)
//   #examplesChips — example chip container
//   #exCards      — example showcase cards
//   #lspDiagnostics — LSP diagnostics list
//   #lspStatus    — LSP status line
//   #lspType      — hover type line
//   #lspTooltip   — hover tooltip
//   #editor-wrap  — position:relative wrapper for the tooltip
//
// The element uses light DOM (NOT shadow DOM) because playground-ui.js uses
// document.getElementById to find these elements.

const BASE = '/dhall-c';

// Once-per-element boot guard.
const BOOTED = Symbol('booted');

// Reusable script loading (cached per URL).
const scriptCache = new Map();

function loadScript(src, opts) {
  const cache = !opts || opts.cache !== false;
  if (cache && scriptCache.has(src)) {
    return scriptCache.get(src);
  }
  const promise = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.async = false; // preserve ordering
    s.onload = () => { s.remove(); resolve(); };
    s.onerror = () => { s.remove(); reject(new Error(`playground-element: failed to load ${src}`)); };
    (document.head || document.documentElement).appendChild(s);
  });
  if (cache) scriptCache.set(src, promise);
  return promise;
}

function loadFactories() {
  return Promise.all([
    loadScript(`${BASE}/dhall.js`),
    loadScript(`${BASE}/dhall-lsp.js`),
    loadScript(`${BASE}/vendor/codemirror.min.js`),
    loadScript(`${BASE}/vendor/codemirror-simple.js`),
    loadScript(`${BASE}/vendor/codemirror-lint.js`),
    loadScript(`${BASE}/vendor/dhall-mode.js`),
  ]);
}

// Minimal DOM builder helper.
function el(tag, attrs, children) {
  const node = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') node.className = v;
      else if (k === 'html') node.innerHTML = v;
      else node.setAttribute(k, v);
    }
  }
  for (const c of children || []) {
    node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return node;
}

// Consolidated playground CSS: the fixpoint palette + the old docs demo's
// editor/controls/LSP rules (CodeMirror Tokyo-Night theme, squiggles, tooltip,
// editor-wrap, output, mode buttons, example chips/cards).
const PLAYGROUND_CSS = `
:root{--bg:#0b0e11;--bg2:#10141a;--fg:#d8dee6;--dim:#7d8794;--accent:#6ad6a1;--accent2:#8ab4f8;--line:#1e2730;--mono:"SFMono-Regular","Cascadia Code","JetBrains Mono","Fira Code",Menlo,Consolas,monospace;--sans:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.playground .modes{display:flex;gap:6px;flex-wrap:wrap;margin:0.4em 0 0.8em}
.playground .mode{font-family:var(--mono);font-size:13px;padding:5px 12px;border:1px solid var(--line);border-radius:16px;background:var(--bg2);color:var(--dim);cursor:pointer}
.playground .mode.active{background:var(--accent);color:var(--bg);border-color:var(--accent);font-weight:600}
.playground .demo-actions{display:flex;gap:8px;align-items:center;margin:0.6em 0}
.playground .btn{border:none;border-radius:6px;font-weight:600;font-size:14px;padding:8px 16px;cursor:pointer}
.playground .btn-primary{background:var(--accent);color:var(--bg)}
.playground .btn-primary:hover{background:var(--accent2)}
.playground .btn-ghost{background:transparent;color:var(--fg);border:1px solid var(--line)}
.playground .btn-ghost:hover{border-color:var(--dim)}
.playground .panes{display:grid;grid-template-columns:1fr 1fr;gap:16px}
@media (max-width:760px){.playground .panes{grid-template-columns:1fr}}
.playground .pane label{font-family:var(--mono);font-size:12px;color:var(--dim);display:block;margin-bottom:6px}
.playground textarea{width:100%;font-family:var(--mono);font-size:0.9em;line-height:1.5;background:var(--bg2);border:1px solid var(--line);border-radius:8px;padding:12px;color:var(--fg);resize:vertical;tab-size:2}
.playground #output{min-height:180px;white-space:pre-wrap;word-break:break-word}
.playground .status{font-family:var(--mono);font-size:12px;color:var(--dim)}
.playground .status.error{color:#ff7b72}
.playground .lsp-foot{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-top:6px;font-family:var(--mono);font-size:12px;color:var(--dim)}
.playground .lsp-type{color:var(--accent2)}
.playground .lsp-diagnostics{margin-top:8px;font-family:var(--mono);font-size:13px}
.playground .lsp-diagnostics .lsp-diag.ok{color:var(--accent)}
.playground .lsp-diagnostics .lsp-diag.err{color:#ff7b72}
.playground .demo-foot{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-top:12px;align-items:center}
.playground .examples{display:flex;gap:6px;flex-wrap:wrap}
.playground .examples button{font-family:var(--mono);font-size:12px;padding:3px 10px;border:1px solid var(--line);border-radius:12px;background:var(--bg2);color:var(--accent2);cursor:pointer}
.playground .examples button:hover{border-color:var(--accent2)}
.playground .ex-cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px}
.playground .ex-card{background:var(--bg2);border:1px solid var(--line);border-radius:10px;padding:16px}
.playground .ex-card h3{font-size:15px;font-weight:600;margin-bottom:6px}
.playground .ex-card p{font-size:13px;color:var(--dim);margin-bottom:10px}
.CodeMirror{border:1px solid #414868;height:360px;font-size:14px}
.CodeMirror,.CodeMirror-scroll{background:#1a1b26;color:#c0caf5}
.CodeMirror-gutters{background:#16161e;border-right:1px solid #292e42}
.CodeMirror-linenumber{color:#3b4261}
.CodeMirror-cursor{border-left:2px solid #c0caf5}
.CodeMirror-selected{background:#33467c}
.cm-s-tokyonight .cm-comment{color:#565f89;font-style:italic;}
.cm-s-tokyonight .cm-string{color:#9ece6a;}
.cm-s-tokyonight .cm-number{color:#ff9e64;}
.cm-s-tokyonight .cm-keyword{color:#bb9af7;font-weight:600;}
.cm-s-tokyonight .cm-atom{color:#e0af68;}
.cm-s-tokyonight .cm-operator{color:#89ddff;}
.cm-s-tokyonight .cm-bracket{color:#c0caf5;}
.cm-s-tokyonight .cm-def{color:#73daca;font-weight:600;}
.cm-dl-squiggle{text-decoration:underline wavy #f7768e;text-decoration-skip-ink:none;}
#lspTooltip{position:absolute;z-index:10;background:#1f2335;border:1px solid #7aa2f7;color:#c0caf5;padding:4px 8px;font-size:13px;font-family:monospace;max-width:420px;white-space:pre-wrap;pointer-events:none;border-radius:3px;box-shadow:0 2px 8px rgba(0,0,0,0.5)}
#editor-wrap{position:relative}
`;

/**
 * Wait until `element` is attached to the live document.
 */
function waitConnected(element) {
  if (element.isConnected) return Promise.resolve();
  return new Promise((resolve) => {
    const check = () => {
      if (element.isConnected) resolve();
      else requestAnimationFrame(check);
    };
    requestAnimationFrame(check);
  });
}

/**
 * Boot the playground: load factories then playground-ui.js against the element's DOM.
 */
async function bootPlayground(element) {
  await waitConnected(element);
  await loadFactories();
  // playground-ui.js is NOT cached: the @mfe shell unmounts/remounts the slot on
  // cross-page SPA nav, so a fresh <dhall-playground> must re-run the UI glue
  // against its own (only) DOM. The libs (dhall.js, dhall-lsp.js, CodeMirror,
  // dhall-mode.js) stay cached; only one playground exists at a time, so the
  // global getElementById lookups in playground-ui.js resolve to the new element.
  await loadScript(`${BASE}/playground-ui.js`, { cache: false });
}

/**
 * The <dhall-playground> custom element.
 */
class DhallPlayground extends HTMLElement {
  constructor() {
    super();
    this[BOOTED] = false;
    this._styleEl = null;
    this._linkEl = null;
  }

  connectedCallback() {
    if (this[BOOTED]) return;
    this[BOOTED] = true;

    const wrap = el('div', { class: 'playground' });
    const status = el('span', { id: 'status', class: 'status' });

    // Mode buttons (0..4).
    const modes = el('div', { id: 'modes', class: 'modes' });
    const modeNames = ['typecheck', 'normalize', 'to-json', 'to-toml', 'to-yaml'];
    modeNames.forEach((m, i) => {
      modes.appendChild(el('button', { class: 'mode' + (i === 2 ? ' active' : ''), 'data-mode': String(i), 'aria-selected': i === 2 ? 'true' : 'false' }, [m]));
    });

    const actions = el('div', { class: 'demo-actions' }, [
      el('button', { id: 'copyBtn', class: 'btn btn-ghost', type: 'button' }, ['Copy']),
      el('button', { id: 'runBtn', class: 'btn btn-primary', type: 'button' }, ['Run']),
    ]);

    const srcPane = el('div', { class: 'pane' }, [
      el('label', { for: 'source' }, ['Dhall source']),
      el('div', { id: 'editor-wrap' }, [
        el('textarea', { id: 'source', spellcheck: 'false', autocomplete: 'off', autocapitalize: 'off' }),
        el('div', { id: 'lspTooltip', role: 'tooltip', hidden: '' }),
      ]),
      el('div', { class: 'lsp-foot' }, [
        el('span', { id: 'lspStatus', class: 'status' }, ['loading LSP wasm…']),
        el('span', { id: 'lspType', class: 'lsp-type' }),
      ]),
      el('div', { id: 'lspDiagnostics', class: 'lsp-diagnostics' }),
    ]);

    const outPane = el('div', { class: 'pane' }, [
      el('label', { for: 'output' }, ['Result']),
      el('textarea', { id: 'output', readonly: '', spellcheck: 'false' }),
    ]);

    const panes = el('div', { class: 'panes' }, [srcPane, outPane]);

    const examplesChips = el('div', { id: 'examplesChips', class: 'examples', 'aria-label': 'Load an example' });
    const demoFoot = el('div', { class: 'demo-foot' }, [status, examplesChips]);

    const exCards = el('div', { id: 'exCards', class: 'ex-cards' });

    wrap.appendChild(modes);
    wrap.appendChild(actions);
    wrap.appendChild(panes);
    wrap.appendChild(demoFoot);
    wrap.appendChild(exCards);

    // Clear any existing content and append the editor DOM.
    this.textContent = '';
    this.appendChild(wrap);

    // Inject CSS: codemirror.css + codemirror-lint.css links + inline PLAYGROUND_CSS.
    this._linkEl = document.createElement('link');
    this._linkEl.rel = 'stylesheet';
    this._linkEl.href = `${BASE}/vendor/codemirror.css`;
    document.head.appendChild(this._linkEl);

    this._lintLinkEl = document.createElement('link');
    this._lintLinkEl.rel = 'stylesheet';
    this._lintLinkEl.href = `${BASE}/vendor/codemirror-lint.css`;
    document.head.appendChild(this._lintLinkEl);

    this._styleEl = document.createElement('style');
    this._styleEl.textContent = PLAYGROUND_CSS;
    document.head.appendChild(this._styleEl);

    // Boot the playground scripts non-blocking.
    void bootPlayground(this);
  }

  disconnectedCallback() {
    // Clean up injected styles if this element is removed.
    for (const ref of ['_styleEl', '_linkEl', '_lintLinkEl']) {
      if (this[ref]) {
        this[ref].remove();
        this[ref] = null;
      }
    }
  }
}

// Register the custom element.
customElements.define('dhall-playground', DhallPlayground);
