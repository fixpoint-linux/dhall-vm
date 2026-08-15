/* lsp-demo.js — attaches the wasm LSP server (window.createDhallLsp from
 * dhall-lsp.js) to the CodeMirror editor created by app.js (window.__dhallEditor)
 * in the live demo section. Every change sends textDocument/didChange (full sync)
 * to the real src/lsp.c compiled to wasm; the resulting publishDiagnostics feed
 * CodeMirror's lint addon (squiggles + gutter markers + message tooltip). Hover
 * shows the inferred type from textDocument/hover. 100% client-side. */
(function () {
  'use strict';

  var Module = null;
  var URI = 'file:///demo.dhall';
  var version = 1;
  var msgId = 0;
  var currentType = null;
  var editor = window.__dhallEditor;

  var diagEl = document.getElementById('lspDiagnostics');
  var statusEl = document.getElementById('lspStatus');
  var typeEl = document.getElementById('lspType');
  var tooltipEl = document.getElementById('lspTooltip');

  if (!editor) {
    if (statusEl) statusEl.textContent = 'LSP unavailable (no editor)';
    return;
  }

  /* ---- LSP bridge (mirrors the interpreter demo's dhallRun) ---- */
  function lspHandle(json) {
    var bytes = Module.lengthBytesUTF8(json);
    var ptr = Module._malloc(bytes + 1);
    Module.stringToUTF8(json, ptr, bytes + 1);
    Module._lsp_handle(ptr, bytes);
    Module._free(ptr);
    var n = Module._lsp_out_len();
    return n ? Module.UTF8ToString(Module._lsp_out(), n) : '';
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

  /* ---- diagnostics list under the editor ---- */
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

  /* ---- CodeMirror lint: drive didChange, return LSP diagnostics ----
     CM's lint addon calls getAnnotations(text, updateLinting, options, cm):
     the first arg is the editor's current text string; the CodeMirror instance
     is the 4th arg. We send didChange (full sync), read publishDiagnostics,
     render the footer list, and feed CM's lint annotations. */
  function getAnnotations(text, updateLinting, options, cm) {
    if (!Module) { updateLinting([]); return; }
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
      // diagnostics are zero-width points; extend by one char so the squiggle
      // is visible, clamped to the line length.
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

  /* ---- hover: refresh the whole-doc type (server returns the doc type) ---- */
  function updateType() {
    if (!Module) return;
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

  /* ---- hover tooltip (type under the cursor) ---- */
  function showTooltip(ev, text) {
    if (!text) { tooltipEl.hidden = true; return; }
    tooltipEl.textContent = text;
    tooltipEl.hidden = false;
    var wrap = editor.getWrapperElement().getBoundingClientRect();
    tooltipEl.style.left = (ev.clientX - wrap.left + 12) + 'px';
    tooltipEl.style.top = (ev.clientY - wrap.top - 12) + 'px';
  }

  /* ---- wiring ---- */
  editor.setOption('lint', { async: true, getAnnotations: getAnnotations });

  editor.on('change', function () {
    updateType();
  });
  var hoverTimer = null;
  editor.on('mousemove', function (cm, ev) {
    showTooltip(ev, currentType);
    if (hoverTimer) return;
    hoverTimer = setTimeout(function () {
      hoverTimer = null;
      updateType();
    }, 250);
  });
  editor.on('mouseleave', function () { tooltipEl.hidden = true; });
  editor.on('mousedown', function () { tooltipEl.hidden = true; });

  /* ---- boot ---- */
  statusEl.textContent = 'loading LSP wasm…';
  createDhallLsp()
    .then(function (M) {
      Module = M;
      var frames = send('initialize', {}, 1);
      var cap = frames.find(function (f) { return f.id === 1 && f.result; });
      if (!cap || !cap.result.capabilities || !cap.result.capabilities.hoverProvider) {
        statusEl.textContent = 'LSP initialize failed';
        statusEl.classList.add('error');
        return;
      }
      statusEl.textContent = 'LSP ready';
      send('textDocument/didOpen', {
        textDocument: { uri: URI, languageId: 'dhall', version: version, text: editor.getValue() }
      });
      editor.performLint();
      updateType();
    })
    .catch(function (e) {
      statusEl.textContent = 'LSP wasm failed to load: ' + e.message;
      statusEl.classList.add('error');
    });
})();
