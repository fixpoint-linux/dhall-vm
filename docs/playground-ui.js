/* docs/playground-ui.js — wires the emscripten WASM modules (window.createDhall
 * from dhall.js, window.createDhallLsp from dhall-lsp.js) to the <dhall-playground>
 * custom element's DOM. A port of the former docs/app.js + docs/lsp-demo.js onto
 * the fixpoint-site custom-element contract:
 *
 *   #source (→ CodeMirror mode:'dhall'), #output, #status, #runBtn, #copyBtn,
 *   #modes (5 buttons data-mode=0..4), #examplesChips, #exCards, #lspDiagnostics,
 *   #lspStatus, #lspType, #lspTooltip, #editor-wrap.
 *
 * mode: 0=typecheck 1=normalize 2=to-json 3=to-toml 4=to-yaml
 * dhall_run returns the process exit code (0 ok / 1 type / 2 parse / 3 io);
 * the result or "Error: ..." is written to the module's output buffer.
 *
 * The LSP attaches diagnostics (lint addon) + hover to the SAME editor.
 *
 * Example fetches are ABSOLUTE ('/dhall-c/examples/<name>.dhall') so they work
 * at the /dhall-c/playground/ deep link, unlike the old relative 'examples/…'
 * which resolved under the docs site root.
 */
(function () {
  'use strict';

  var BASE = '/dhall-c';
  var Module = null;
  var currentMode = 2; // to-json by default

  var outputEl = document.getElementById('output');
  var statusEl = document.getElementById('status');
  var runBtn = document.getElementById('runBtn');
  var copyBtn = document.getElementById('copyBtn');
  var modeBtns = Array.prototype.slice.call(document.querySelectorAll('#modes .mode'));

  // Build the CodeMirror editor over the #source textarea; expose it so the
  // LSP glue can attach lint + hover to the SAME editor.
  var sourceEl = document.getElementById('source');
  var editor = CodeMirror.fromTextArea(sourceEl, {
    mode: 'dhall',
    theme: 'tokyonight',
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

  // Example sources served from examples/<name>.dhall (absolute path).
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
    fetch(BASE + '/examples/' + name + '.dhall')
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

  // Boot the interpreter module, then run the default snippet.
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

  /* ======================= LSP (ported from lsp-demo.js) ======================= */

  (function lsp() {
    var LModule = null;
    var URI = 'file:///demo.dhall';
    var version = 1;
    var msgId = 0;
    var currentType = null;
    var ed = window.__dhallEditor;

    var diagEl = document.getElementById('lspDiagnostics');
    var lspStatusEl = document.getElementById('lspStatus');
    var typeEl = document.getElementById('lspType');
    var tooltipEl = document.getElementById('lspTooltip');

    if (!ed) {
      if (lspStatusEl) lspStatusEl.textContent = 'LSP unavailable (no editor)';
      return;
    }

    function lspHandle(json) {
      var bytes = LModule.lengthBytesUTF8(json);
      var ptr = LModule._malloc(bytes + 1);
      LModule.stringToUTF8(json, ptr, bytes + 1);
      LModule._lsp_handle(ptr, bytes);
      LModule._free(ptr);
      var n = LModule._lsp_out_len();
      return n ? LModule.UTF8ToString(LModule._lsp_out(), n) : '';
    }

    function parseFrames(buf) {
      var msgs = [];
      var i = 0;
      while (i < buf.length) {
        var end = buf.indexOf('\r\n\r\n', i);
        if (end < 0) break;
        var m = /Content-Length: (\d+)/i.exec(buf.slice(i, end));
        if (!m) break;
        var len = parseInt(m[1], 10);
        msgs.push(buf.slice(end + 4, end + 4 + len));
        i = end + 4 + len;
      }
      return msgs;
    }

    function send(method, params, id) {
      var o = { jsonrpc: '2.0', method: method };
      if (params !== undefined) o.params = params;
      if (id !== undefined) o.id = id;
      return parseFrames(lspHandle(JSON.stringify(o))).map(JSON.parse);
    }

    function renderDiagnostics(diags) {
      diagEl.innerHTML = '';
      if (!diags.length) {
        var ok = document.createElement('div');
        ok.className = 'lsp-diag ok';
        ok.textContent = '\u2713 no errors';
        diagEl.appendChild(ok);
        return;
      }
      diags.forEach(function (d) {
        var row = document.createElement('div');
        row.className = 'lsp-diag err';
        var r = d.range;
        row.textContent = 'Ln ' + (r.start.line + 1) + ', Col ' + (r.start.character + 1) + ' \u2014 ' + d.message;
        diagEl.appendChild(row);
      });
    }

    function getAnnotations(text, updateLinting, options, cm) {
      if (!LModule) { updateLinting([]); return; }
      version++;
      var frames = send('textDocument/didChange', {
        textDocument: { uri: URI, version: version },
        contentChanges: [{ text: text }]
      });
      var all = [].concat.apply([], frames
        .filter(function (f) { return f.method === 'textDocument/publishDiagnostics'; })
        .map(function (f) { return f.params.diagnostics || []; }));
      renderDiagnostics(all);
      var annotations = all.map(function (d) {
        var r = d.range;
        var from = cm.Pos(r.start.line, r.start.character);
        var toLine = r.end.line;
        var toCh = r.end.character;
        var lineLen = cm.getLine(toLine) ? cm.getLine(toLine).length : 0;
        if (toCh >= lineLen) toCh = Math.max(lineLen, toCh + 1);
        else toCh++;
        return {
          from: from,
          to: cm.Pos(toLine, toCh),
          message: d.message,
          severity: 'error'
        };
      });
      updateLinting(annotations);
    }

    function updateType() {
      if (!LModule) return;
      var frames = send('textDocument/hover', {
        textDocument: { uri: URI },
        position: { line: 0, character: 0 }
      }, ++msgId);
      var r = frames.find(function (f) { return f.id === msgId; });
      if (r && r.result && r.result.contents) {
        currentType = r.result.contents.value;
        typeEl.textContent = 'type : ' + currentType;
      } else {
        currentType = null;
        typeEl.textContent = '';
      }
    }

    function showTooltip(ev, text) {
      if (!text) { tooltipEl.hidden = true; return; }
      tooltipEl.textContent = text;
      tooltipEl.hidden = false;
      var wrap = ed.getWrapperElement().getBoundingClientRect();
      tooltipEl.style.left = (ev.clientX - wrap.left + 12) + 'px';
      tooltipEl.style.top = (ev.clientY - wrap.top - 12) + 'px';
    }

    ed.setOption('lint', { async: true, getAnnotations: getAnnotations });

    ed.on('change', function () {
      updateType();
    });
    var hoverTimer = null;
    ed.on('mousemove', function (cm, ev) {
      showTooltip(ev, currentType);
      if (hoverTimer) return;
      hoverTimer = setTimeout(function () {
        hoverTimer = null;
        updateType();
      }, 250);
    });
    ed.on('mouseleave', function () { tooltipEl.hidden = true; });
    ed.on('mousedown', function () { tooltipEl.hidden = true; });

    lspStatusEl.textContent = 'loading LSP wasm…';
    createDhallLsp()
      .then(function (M) {
        LModule = M;
        var frames = send('initialize', {}, 1);
        var cap = frames.find(function (f) { return f.id === 1 && f.result; });
        if (!cap || !cap.result.capabilities || !cap.result.capabilities.hoverProvider) {
          lspStatusEl.textContent = 'LSP initialize failed';
          lspStatusEl.classList.add('error');
          return;
        }
        lspStatusEl.textContent = 'LSP ready';
        send('textDocument/didOpen', {
          textDocument: { uri: URI, languageId: 'dhall', version: version, text: ed.getValue() }
        });
        ed.performLint();
        updateType();
      })
      .catch(function (e) {
        lspStatusEl.textContent = 'LSP wasm failed to load: ' + e.message;
        lspStatusEl.classList.add('error');
      });
  })();
})();
