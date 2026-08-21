#!/usr/bin/env node
/**
 * scripts/ssg.mjs — static-site-generator build step for the dhall-c docs site.
 *
 * Multi-route SSG: pre-renders EACH of the 5 content pages to its own
 * dist/<dir>/index.html so deep-links + no-JS/SEO work under Caddy static hosting.
 *
 * Pipeline:
 *
 *   1.  Expects the Elm app already compiled to `dist/elm.js`:
 *         elm make src/Main.elm --output=dist/elm.js --optimize
 *   2.  Boots a happy-dom `Window`, installs its browser globals onto
 *       globalThis, then loads the compiled Elm bundle ONCE with an indirect
 *       eval `(0, eval)(code)`. The bundle is a classic IIFE whose `this` binds
 *       to globalThis, so `Elm` lands on `globalThis.Elm`. The bundle is loaded
 *       exactly once and reused across all pages — loading it again would hit
 *       Elm's `_Debug_crash(6)` ("name clash") on `_Platform_mergeExportsProd`.
 *   3.  For each content page (from PAGES):
 *         - Creates a detached root `<div>`
 *         - Calls `Elm.Main.init({ node, flags: { pathname: page.path } })`
 *         - Waits for the initial render to flush
 *         - Reads back `node.innerHTML` — the pre-rendered page markup
 *   4.  Wraps the rendered markup in a full HTML document (import map + the
 *       page's template slot) and writes dist/<dir>/index.html.
 *   5.  The playground page is pre-rendered like other content pages (Elm
 *       renders the hero/sections; the <dhall-playground> custom element is
 *       empty in static HTML and boots client-side).
 *   6.  Copies shell/ to dist/ and vendor/@mfe to dist/vendor/@mfe.
 *   7.  Copies the playground static assets from docs/ to dist/ (emscripten
 *       resolves *.wasm relative to the script's own directory, so they must be
 *       colocated: dist/dhall.js + dist/dhall.wasm, etc.), plus CodeMirror and
 *       the examples.
 *
 * The output pages ship with content already present (no-JS / SEO) and all
 * styling inline (the rendered markup carries the `<style>` emitted by
 * `Fixpoint.Style.stylesheet`). Client-side, the shell's `ssr` rehydration
 * lets the MFE take over the pre-rendered DOM — see `shell/mfe/dhallc-page.js`.
 *
 * Run from the repo root:
 *   node scripts/ssg.mjs
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, cpSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { Window } from 'happy-dom';
import { PAGES, CONTENT_PAGES } from '../shell/pages.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const DIST = join(ROOT, 'dist');
const ELM_BUNDLE = join(DIST, 'elm.js');
const DOCS_DIR = join(ROOT, 'docs');

// The import map is shared by every generated page. All paths are ABSOLUTE
// (/dhall-c/...) because the 5 pages live at different URL depths.
const IMPORT_MAP = `{
  "imports": {
    "@mfe/core": "/vendor/@mfe/core/index.js",
    "@mfe/framework": "/vendor/@mfe/framework/index.js",
    "dhallc-landing": "/dhall-c/shell/mfe/dhallc-page.js",
    "dhallc-language": "/dhall-c/shell/mfe/dhallc-page.js",
    "dhallc-cli": "/dhall-c/shell/mfe/dhallc-page.js",
    "dhallc-api": "/dhall-c/shell/mfe/dhallc-page.js",
    "dhallc-playground": "/dhall-c/shell/mfe/dhallc-page.js",
    "fixpoint-landing": "/shell/mfe/fixpoint-landing.js"
  }
}`;

function log(msg) {
  console.log(`[ssg] ${msg}`);
}

/** Wrap a slot body in a full HTML document with the shared import map. */
function wrapDocument(title, description, slotHtml) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<meta name="description" content="${description}">
<script type="importmap">
${IMPORT_MAP}
</script>
</head>
<body>
<div id="app" ssr>
  <div class="fixpoint-root">
${slotHtml}
  </div>
</div>
<script type="module" src="/dhall-c/shell/shell.js"></script>
</body>
</html>
`;
}

/** The slot element for a page (indented 4 spaces to fit wrapDocument). */
function slotHtml(slotName, inner) {
  const rendered = inner === undefined ? '' : `\n${inner}\n    `;
  return `    <div data-mfe="${slotName}">${rendered}</div>`;
}

/**
 * Install happy-dom's window-backed values onto globalThis so the compiled Elm
 * bundle and its runtime see a browser-shaped global object.
 *
 * `navigator` and `location` already exist on Node's globalThis as getter-only
 * properties, so they cannot be plain-assigned — `defineProperty` with
 * `configurable: true` replaces them.
 */
function installGlobals(window) {
  const globals = [
    'window',
    'document',
    'navigator',
    'location',
    'history',
    'customElements',
    'performance',
    'requestAnimationFrame',
    'cancelAnimationFrame',
    'HTMLElement',
    'HTMLDivElement',
    'HTMLSpanElement',
    'HTMLAnchorElement',
    'HTMLButtonElement',
    'HTMLTableElement',
    'Element',
    'Node',
    'Document',
    'DocumentFragment',
    'Text',
    'Comment',
    'NodeList',
    'HTMLCollection',
    'Event',
    'CustomEvent',
    'MouseEvent',
    'KeyboardEvent',
    'UIEvent',
    'EventTarget',
    'MutationObserver',
    'getComputedStyle',
    'matchMedia',
  ];
  for (const name of globals) {
    const value = window[name];
    if (value === undefined) continue;
    Object.defineProperty(globalThis, name, {
      value,
      configurable: true,
      writable: true,
    });
  }
}

/**
 * Load the compiled Elm bundle ONCE into globalThis.Elm. Must not be called
 * twice — a second indirect eval re-runs the IIFE and Elm's prod export
 * merge crashes with "name clash".
 */
function loadElmOnce() {
  if (globalThis.__dhallcElmLoaded) return;
  const code = readFileSync(ELM_BUNDLE, 'utf8');
  // eslint-disable-next-line no-eval -- indirect eval runs in global scope.
  (0, eval)(code);
  globalThis.__dhallcElmLoaded = true;
}

/** Mount the Elm app with the given pathname flag and return the rendered HTML. */
async function renderPage(window, pathname) {
  const Elm = globalThis.Elm;
  if (!Elm || !Elm.Main || typeof Elm.Main.init !== 'function') {
    throw new Error('dist/elm.js did not expose Elm.Main.init on globalThis');
  }

  const root = window.document.createElement('div');
  root.setAttribute('id', 'docs-root');
  window.document.body.appendChild(root);

  Elm.Main.init({ node: root, flags: { pathname } });

  // Let Elm's initial render flush. Browser.element schedules its first paint
  // through the virtual DOM, which Elm drives with requestAnimationFrame /
  // macrotasks. Flushing happy-dom's async task manager covers both; fall back
  // to a couple of macrotask ticks for robustness.
  const flush = window.happyDOM && typeof window.happyDOM.whenAsyncComplete === 'function'
    ? () => window.happyDOM.whenAsyncComplete()
    : () => new Promise((resolve) => setTimeout(resolve, 0));
  await flush();
  await flush();

  return root.innerHTML;
}

/** Copy a file or directory tree from src to dest. */
function copyRecursive(src, dest) {
  const stats = statSync(src);
  if (stats.isDirectory()) {
    mkdirSync(dest, { recursive: true });
    for (const entry of readdirSync(src)) {
      copyRecursive(join(src, entry), join(dest, entry));
    }
  } else {
    mkdirSync(dirname(dest), { recursive: true });
    cpSync(src, dest);
  }
}

async function main() {
  if (!existsSync(ELM_BUNDLE)) {
    console.error(
      `[ssg] missing ${ELM_BUNDLE}. Build it first:\n` +
        '  elm make src/Main.elm --output=dist/elm.js --optimize',
    );
    process.exit(1);
  }

  const window = new Window();
  installGlobals(window);
  loadElmOnce();

  // Render each content page to dist/<dir>/index.html.
  for (const page of CONTENT_PAGES) {
    log(`rendering ${page.slot} (path=${page.path}) ...`);
    const rendered = await renderPage(window, page.path);
    log(`  rendered ${rendered.length} bytes`);

    // The playground's <dhall-playground> custom element is client-booted only:
    // if we pre-render it into the static HTML, the client MFE re-creates a
    // SECOND element and both boot (double editor). Strip the element from the
    // pre-rendered markup so exactly one (the client's) ever exists.
    let pageHtml = rendered;
    if (page.slug === 'playground') {
      pageHtml = rendered.replace(/<dhall-playground\b[^>]*>\s*<\/dhall-playground>/g, '');
      if (pageHtml !== rendered) log('  stripped <dhall-playground> (client-booted)');
    }

    const outputDir = page.dir === '' ? DIST : join(DIST, page.dir);
    const outputPath = join(outputDir, 'index.html');
    const finalHtml = wrapDocument(page.title, page.title, slotHtml(page.slot, pageHtml));
    mkdirSync(outputDir, { recursive: true });
    writeFileSync(outputPath, finalHtml);
    log(`  wrote ${outputPath} (${finalHtml.length} bytes)`);
  }

  // Copy shell/ to dist/ (templates + mfe modules + pages.js + shell.js).
  log('copying shell/ to dist/ ...');
  copyRecursive(join(ROOT, 'shell'), join(DIST, 'shell'));

  // Copy vendor/@mfe to dist/vendor/@mfe (built by the mfe-framework target).
  const vendorMfeSrc = join(ROOT, 'vendor', '@mfe');
  if (existsSync(vendorMfeSrc)) {
    log('copying vendor/@mfe to dist/vendor/@mfe ...');
    copyRecursive(vendorMfeSrc, join(DIST, 'vendor', '@mfe'));
  }

  // Copy the playground static assets. The .wasm files MUST be colocated with
  // their .js (emscripten currentScript -> scriptDirectory -> locateFile).
  const playgroundAssets = ['dhall.js', 'dhall.wasm', 'dhall-lsp.js', 'dhall-lsp.wasm', 'playground-ui.js'];
  for (const asset of playgroundAssets) {
    const src = join(DOCS_DIR, asset);
    if (existsSync(src)) {
      cpSync(src, join(DIST, asset));
      log(`  copied ${asset}`);
    }
  }

  // Copy the CodeMirror assets from docs/vendor/ to dist/vendor/.
  const cmAssets = ['codemirror.min.js', 'codemirror.css', 'codemirror-simple.js', 'codemirror-lint.js', 'codemirror-lint.css', 'dhall-mode.js'];
  for (const asset of cmAssets) {
    const src = join(DOCS_DIR, 'vendor', asset);
    if (existsSync(src)) {
      mkdirSync(join(DIST, 'vendor'), { recursive: true });
      cpSync(src, join(DIST, 'vendor', asset));
      log(`  copied vendor/${asset}`);
    }
  }

  // Copy the example .dhall files for the playground example loader.
  const examplesSrc = join(DOCS_DIR, 'examples');
  if (existsSync(examplesSrc)) {
    log('copying examples/ to dist/examples/ ...');
    copyRecursive(examplesSrc, join(DIST, 'examples'));
  }

  log('SSG complete.');
}

main().catch((err) => {
  console.error('[ssg] failed:', err);
  process.exit(1);
});
