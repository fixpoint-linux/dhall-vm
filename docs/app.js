/* app.js — wires the emscripten WASM module (window.createDhall from dhall.js)
 * to the live demo. The source pane is a CodeMirror 5 editor (Dhall mode,
 * syntax highlighting). createDhall() returns a Promise resolving to the Module;
 * we expose run(mode, src) and wire up mode buttons, Run, Ctrl/⌘+Enter, and the
 * example loaders. lsp-demo.js attaches the wasm LSP (diagnostics + hover) to
 * the same editor via window.__dhallEditor.
 *
 * mode: 0=typecheck 1=normalize 2=to-json 3=to-toml 4=to-yaml
 * dhall_run returns the process exit code (0 ok / 1 type / 2 parse / 3 io);
 * the result or "Error: ..." is written to the module's output buffer.
 */

(function () {
  'use strict';

  var Module = null;
  var currentMode = 2; // to-json by default

  var outputEl = document.getElementById('output');
  var statusEl = document.getElementById('status');
  var runBtn = document.getElementById('runBtn');
  var copyBtn = document.getElementById('copyBtn');
  var modeBtns = Array.prototype.slice.call(document.querySelectorAll('#modes .mode'));

  // Build the CodeMirror editor over the #source textarea; expose it so
  // lsp-demo.js can attach the LSP lint + hover to the SAME editor.
  var sourceEl = document.getElementById('source');
  var editor = CodeMirror.fromTextArea(sourceEl, {
    mode: 'dhall',
    theme: 'dhall',
    lineNumbers: true,
    indentUnit: 2,
    tabSize: 2,
    lineWrapping: true
  });
  window.__dhallEditor = editor;

  var DEFAULT_SRC =
    'let port = 8080\n' +
    'in  {\n' +
    '      name = "demo",\n' +
    '      port = port,\n' +
    '      tls  = True,\n' +
    '      tags = [ "web", "api" ],\n' +
    '      log  = < INFO = "info" | DEBUG : Text | ERROR : Text >\n' +
    '    }\n';

  // Example sources served from examples/<name>.dhall.
  var EXAMPLES = [
    { name: 'server', mode: 2, title: 'server.dhall',
      desc: 'Nested record, a Text union with a payload, a List Text, and scalars.' },
    { name: 'ci', mode: 2, title: 'ci.dhall',
      desc: 'A CI pipeline: let-bound shared step lists, a merge over a union, and lists of records.' },
    { name: 'types', mode: 2, title: 'types.dhall',
      desc: 'A tour of value types: record type annotations, Some/None, arithmetic, comparisons, and List/map.' }
  ];

  function setStatus(text, isError) {
    statusEl.textContent = text;
    statusEl.classList.toggle('error', !!isError);
  }

  function setMode(mode) {
    currentMode = mode;
    modeBtns.forEach(function (b) {
      var on = Number(b.getAttribute('data-mode')) === mode;
      b.classList.toggle('active', on);
      b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
  }

  // Synchronous bridge into the compiled interpreter.
  function dhallRun(mode, src) {
    // Allocate by UTF-8 byte length, NOT src.length (UTF-16 units): multi-byte
    // chars (em-dash, Unicode lambda/arrow, non-ASCII Text) are several bytes,
    // and stringToUTF8's budget is bytes. Using src.length here truncates the
    // tail of any non-ASCII source (e.g. a `-- …` comment), dropping its closing `}`.
    var bytes = Module.lengthBytesUTF8(src);
    var srcPtr = Module._malloc(bytes + 1);
    Module.stringToUTF8(src, srcPtr, bytes + 1);
    var rc = Module._dhall_run(mode, srcPtr, bytes);
    Module._free(srcPtr);
    var outLen = Module._dhall_out_len();
    var out = outLen ? Module.UTF8ToString(Module._dhall_out(), outLen) : '';
    return { rc: rc, out: out };
  }

  function doRun() {
    if (!Module) { setStatus('WASM still loading…', true); return; }
    var src = editor.getValue();
    var t0 = performance.now();
    var res;
    try {
      res = dhallRun(currentMode, src);
    } catch (e) {
      setStatus('internal error: ' + e.message, true);
      outputEl.value = 'Internal error: ' + e.message;
      outputEl.classList.add('error');
      return;
    }
    var dt = performance.now() - t0;
    outputEl.value = res.out;
    outputEl.classList.toggle('error', res.rc !== 0);
    setStatus('exit ' + res.rc + ' · ' + dt.toFixed(1) + ' ms');
  }

  function loadExample(name, mode) {
    setStatus('loading ' + name + '.dhall…');
    fetch('examples/' + name + '.dhall')
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.text();
      })
      .then(function (txt) {
        editor.setValue(txt);
        setMode(mode);
        doRun();
      })
      .catch(function (e) {
        setStatus('could not load example: ' + e.message, true);
      });
  }

  // Demo footer chips.
  var chips = document.getElementById('examplesChips');
  EXAMPLES.forEach(function (ex) {
    var b = document.createElement('button');
    b.textContent = ex.name;
    b.title = ex.title;
    b.addEventListener('click', function () { loadExample(ex.name, ex.mode); });
    chips.appendChild(b);
  });

  // Example showcase cards (own section).
  var cards = document.getElementById('exCards');
  EXAMPLES.forEach(function (ex) {
    var card = document.createElement('div');
    card.className = 'ex-card';
    var h = document.createElement('h3'); h.textContent = ex.title;
    var p = document.createElement('p'); p.textContent = ex.desc;
    var a = document.createElement('button');
    a.className = 'btn'; a.textContent = 'Load in demo';
    a.addEventListener('click', function () {
      document.getElementById('demo').scrollIntoView({ behavior: 'smooth' });
      loadExample(ex.name, ex.mode);
    });
    card.appendChild(h); card.appendChild(p); card.appendChild(a);
    cards.appendChild(card);
  });

  // Wire controls.
  modeBtns.forEach(function (b) {
    b.addEventListener('click', function () { setMode(Number(b.getAttribute('data-mode'))); });
  });
  runBtn.addEventListener('click', doRun);
  document.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); doRun(); }
  });

  // Copy the current result to the clipboard (with a legacy fallback).
  if (copyBtn) {
    function fallbackCopy(text) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); } catch (e) { /* ignore */ }
      document.body.removeChild(ta);
    }
    copyBtn.addEventListener('click', function () {
      var text = outputEl.value;
      function done() {
        copyBtn.textContent = 'Copied ✓';
        setTimeout(function () { copyBtn.textContent = 'Copy'; }, 1200);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
      } else {
        fallbackCopy(text);
        done();
      }
    });
  }

  // Boot the module, then run the default snippet.
  editor.setValue(DEFAULT_SRC);
  setStatus('loading WASM…');
  createDhall()
    .then(function (M) {
      Module = M;
      setStatus('WASM ready');
      doRun();
    })
    .catch(function (e) {
      setStatus('WASM failed to load: ' + e.message, true);
    });
})();
