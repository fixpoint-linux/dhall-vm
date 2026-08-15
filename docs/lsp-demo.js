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
      var cls = tokenizeLine(line);          // per-char syntax class array
      var m = marks[li];
      var out = '', c = 0, n = line.length;
      while (c < n) {
        if (m && m[c]) {
          out += '<span class="err" title="' + escAttr(m[c]) + '">' + esc(line.charAt(c)) + '</span>';
          c++;
          continue;
        }
        var k = cls[c] || 'tk-var';
        var j = c;
        while (j < n && !(m && m[j]) && (cls[j] || 'tk-var') === k) j++;
        out += '<span class="' + k + '">' + esc(line.slice(c, j)) + '</span>';
        c = j;
      }
      // A diagnostic can point one past the end of the line (e.g. a missing
      // '}' that closes a record); render that as a trailing-space squiggle.
      if (m && m[n] !== undefined) {
        out += '<span class="err" title="' + escAttr(m[n]) + '"> </span>';
      }
      return out + (li < lines.length - 1 ? '\n' : '');
    }).join('');
    highlightEl.innerHTML = html;
  }

  /* ---- lightweight Dhall syntax highlighter ----
     Tokenizes a single line into (start, end, class) segments covering every
     column, so the error-squiggle overlay (which marks single columns) layers on
     top cleanly. Handles the Dhall subset: -- / {- -} comments, "strings" (with
     \escapes), integers/doubles, let/if/etc keywords, builtin types, List/map
     style builtins, and the Unicode + ASCII operators. */
  var KW = /^(let|in|if|then|else|merge|assert|as|with|using|missing|forall)$/;
  var TYPES = /^(Natural|Integer|Double|Text|Bool|List|Optional|Type|Kind)$/;
  var OPS2 = /^(->|\/\=|\=\=|\!\=|<=|>=|&&|\|\||\/\/|\/\=|∨|∧|≡|⫽|→|∀|λ)$/;

  function tokenizeLine(line) {
    var cls = new Array(line.length).fill('tk-var');
    var i = 0, n = line.length;
    function paint(a, b, k) { for (var x = a; x < b && x < n; x++) cls[x] = k; }
    while (i < n) {
      var ch = line[i];
      // line comment --
      if (line.startsWith('--', i)) { paint(i, n, 'tk-com'); break; }
      // block comment {- ... -}
      if (line.startsWith('{-', i)) {
        var e = line.indexOf('-}', i + 2);
        paint(i, e < 0 ? n : e + 2, 'tk-com');
        i = e < 0 ? n : e + 2;
        continue;
      }
      // string "..." with \escapes
      if (ch === '"') {
        var j = i + 1;
        while (j < n) {
          if (line[j] === '\\') { j += 2; continue; }
          if (line[j] === '"') { j++; break; }
          j++;
        }
        paint(i, j, 'tk-str');
        i = j;
        continue;
      }
      // number (optional leading -)
      if (/[0-9]/.test(ch) || (ch === '-' && /[0-9]/.test(line[i + 1] || ''))) {
        var j = i + (ch === '-' ? 1 : 0);
        while (j < n && /[0-9]/.test(line[j])) j++;
        if (line[j] === '.') { j++; while (j < n && /[0-9]/.test(line[j])) j++; }
        paint(i, j, 'tk-num');
        i = j;
        continue;
      }
      // identifier (optionally List/map style with a slash)
      if (/[A-Za-z_]/.test(ch)) {
        var j = i;
        while (j < n && /[A-Za-z0-9_]/.test(line[j])) j++;
        if (line[j] === '/' && /[A-Za-z_]/.test(line[j + 1] || '')) {
          j++;
          while (j < n && /[A-Za-z0-9_]/.test(line[j])) j++;
        }
        var w = line.slice(i, j);
        var k = KW.test(w) ? 'tk-kw'
              : TYPES.test(w) ? 'tk-type'
              : /^(True|False)$/.test(w) ? 'tk-bool'
              : w.indexOf('/') > 0 ? 'tk-builtin'
              : 'tk-var';
        paint(i, j, k);
        i = j;
        continue;
      }
      // operators (multi-char first)
      var two = line.slice(i, i + 2);
      if (OPS2.test(two)) { paint(i, i + 2, 'tk-op'); i += 2; continue; }
      if (/[+\-*/=:<>,.!?\\]/.test(ch) || /[\u2192\u2200\u2227\u2228\u2261\u2afd\u2a3e\u03bb]/.test(ch)) {
        paint(i, i + 1, 'tk-op'); i += 1; continue;
      }
      i += 1; // whitespace / brackets / other (left uncolored)
    }
    return cls;
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
