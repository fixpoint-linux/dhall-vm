/* lsp-demo.js — wires the wasm LSP server (window.createDhallLsp from dhall-lsp.js)
 * to the interactive 'LSP demo' section. We send initialize / didOpen / didChange
 * (full sync) / textDocument/hover and parse the Content-Length-framed
 * publishDiagnostics + hover responses. The server is the REAL src/lsp.c
 * compiled to wasm (lsp_handle / lsp_out / lsp_out_len). */
(function () {
  'use strict';

  var Module = null;
  var URI = 'file:///demo.dhall';
  var version = 1;
  var msgId = 0;
  var currentType = null;

  var sourceEl = document.getElementById('lspSource');
  var highlightEl = document.getElementById('lspHighlight');
  var diagEl = document.getElementById('lspDiagnostics');
  var statusEl = document.getElementById('lspStatus');
  var typeEl = document.getElementById('lspType');
  var tooltipEl = document.getElementById('lspTooltip');

  var DEFAULT_SRC =
    'let port = 8080\n' +
    'in  { name = "demo", port = port, tls = True, tags = [ "web", "api" ] }';

  function esc(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  /* Attribute-safe variant: also neutralises quotes so diagnostic messages
     (which can echo pasted source) can't break out of a title="..." attribute. */
  function escAttr(s) {
    return esc(s).replace(/"/g, '&quot;').replace(/'/g, '&#39;');
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

  /* ---- rendering ---- */
  function renderDiagnostics(diags) {
    diagEl.innerHTML = '';
    typeEl.textContent = currentType ? ('type : ' + currentType) : '';
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

  function renderHighlight(text, diags) {
    var lines = text.split('\n');
    var marks = {}; // line -> { col -> message }
    diags.forEach(function (d) {
      var l = d.range.start.line, c = d.range.start.character;
      if (l < 0 || l >= lines.length) return;
      (marks[l] = marks[l] || {})[c] = d.message;
    });
    var html = lines.map(function (line, li) {
      var m = marks[li];
      if (!m) return esc(line) + (li < lines.length - 1 ? '\n' : '');
      var cols = Object.keys(m).map(Number).sort(function (a, b) { return a - b; });
      var out = '', i = 0;
      cols.forEach(function (c) {
        if (c < 0) c = 0;
        if (c > line.length) c = line.length;
        if (c > i) out += esc(line.slice(i, c));
        out += '<span class="err" title="' + escAttr(m[c]) + '">' + esc(line.charAt(c) || ' ') + '</span>';
        i = c + 1;
      });
      out += esc(line.slice(i));
      return out + (li < lines.length - 1 ? '\n' : '');
    }).join('');
    highlightEl.innerHTML = html;
  }

  function refresh() {
    var frames = send('textDocument/didChange', {
      textDocument: { uri: URI, version: version },
      contentChanges: [{ text: sourceEl.value }]
    });
    var all = [].concat.apply([], frames
      .filter(function (f) { return f.method === 'textDocument/publishDiagnostics'; })
      .map(function (f) { return f.params.diagnostics || []; }));
    renderHighlight(sourceEl.value, all);
    renderDiagnostics(all);
  }

  function hover() {
    var frames = send('textDocument/hover', {
      textDocument: { uri: URI },
      position: { line: 0, character: 0 } // server returns the whole-doc type
    }, ++msgId);
    var r = frames.find(function (f) { return f.id === msgId; });
    if (r && r.result && r.result.contents) {
      currentType = r.result.contents.value;
      typeEl.textContent = 'type : ' + currentType;
    } else {
      currentType = null;
      typeEl.textContent = '';
    }
    return currentType;
  }

  function showTooltip(ev, text) {
    if (!text) { tooltipEl.hidden = true; return; }
    tooltipEl.textContent = text;
    tooltipEl.hidden = false;
    var wrap = sourceEl.parentNode.getBoundingClientRect();
    tooltipEl.style.left = (ev.clientX - wrap.left + 12) + 'px';
    tooltipEl.style.top = (ev.clientY - wrap.top - 12) + 'px';
  }

  /* ---- wiring ---- */
  sourceEl.addEventListener('input', function () {
    version++;
    refresh();
    hover();
  });

  var hoverTimer = null;
  sourceEl.addEventListener('mousemove', function (ev) {
    showTooltip(ev, currentType);
    if (hoverTimer) return;
    hoverTimer = setTimeout(function () {
      hoverTimer = null;
      hover();
    }, 200);
  });
  sourceEl.addEventListener('mouseleave', function () { tooltipEl.hidden = true; });

  sourceEl.addEventListener('scroll', function () {
    highlightEl.scrollTop = sourceEl.scrollTop;
    highlightEl.scrollLeft = sourceEl.scrollLeft;
  });

  /* ---- boot ---- */
  sourceEl.value = DEFAULT_SRC;
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
        textDocument: { uri: URI, languageId: 'dhall', version: version, text: sourceEl.value }
      });
      refresh();
      hover();
    })
    .catch(function (e) {
      statusEl.textContent = 'LSP wasm failed to load: ' + e.message;
      statusEl.classList.add('error');
    });
})();
