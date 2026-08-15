// Headless smoke test for docs/dhall-lsp.js (emscripten MODULARIZE build of the
// LSP server). Drives initialize -> didOpen (diagnostics) -> didChange (full
// sync) -> textDocument/hover against the real wasm LSP core.
// Usage: node tests/lsp-wasm-smoke.js
const createDhallLsp = require('../docs/dhall-lsp.js');

const URI = 'file:///demo.dhall';

function handle(Module, json) {
  const bytes = Module.lengthBytesUTF8(json);
  const ptr = Module._malloc(bytes + 1);
  Module.stringToUTF8(json, ptr, bytes + 1);
  Module._lsp_handle(ptr, bytes);
  Module._free(ptr);
  const outLen = Module._lsp_out_len();
  return outLen ? Module.UTF8ToString(Module._lsp_out(), outLen) : '';
}

// Split the Content-Length-framed response stream into message bodies.
function parseFrames(buf) {
  const msgs = [];
  let i = 0;
  while (i < buf.length) {
    const end = buf.indexOf('\r\n\r\n', i);
    if (end < 0) break;
    const m = /Content-Length: (\d+)/i.exec(buf.slice(i, end));
    if (!m) break;
    const len = parseInt(m[1], 10);
    msgs.push(buf.slice(end + 4, end + 4 + len));
    i = end + 4 + len;
  }
  return msgs;
}

function msg(method, params, id) {
  const o = { jsonrpc: '2.0', method };
  if (params !== undefined) o.params = params;
  if (id !== undefined) o.id = id;
  return JSON.stringify(o);
}

createDhallLsp().then((Module) => {
  let fail = 0;
  function check(name, cond, detail) {
    console.log(`${name} => ${cond ? 'PASS' : 'FAIL'}${detail ? '  ' + detail : ''}`);
    if (!cond) fail++;
  }

  // initialize
  let out = handle(Module, msg('initialize', {}, 1));
  let frames = parseFrames(out).map(JSON.parse);
  check('initialize-capabilities',
    frames.some((f) => f.result && f.result.capabilities && f.result.capabilities.hoverProvider === true),
    out);

  // didOpen: 1 + "x" is a type error at line 0 char 2 (0-based)
  out = handle(Module, msg('textDocument/didOpen', {
    textDocument: { uri: URI, languageId: 'dhall', version: 1, text: '1 + "x"' },
  }));
  frames = parseFrames(out).map(JSON.parse);
  const diag = frames.find((f) => f.method === 'textDocument/publishDiagnostics');
  const d0 = diag && diag.params.diagnostics && diag.params.diagnostics[0];
  check('diagnostic-emitted', !!diag && !!d0, out);
  check('diagnostic-range', !!d0 && d0.range.start.line === 0 && d0.range.start.character === 2,
    d0 && JSON.stringify(d0.range));
  check('diagnostic-message', !!d0 && /different types/.test(d0.message), d0 && d0.message);

  // initialized is a notification with no reply: must NOT emit an empty frame
  out = handle(Module, msg('initialized', {}));
  check('no-empty-frame-on-initialized', out === '' || out.length === 0, JSON.stringify(out));

  // hover on the errored doc -> result null
  out = handle(Module, msg('textDocument/hover', {
    textDocument: { uri: URI }, position: { line: 0, character: 0 },
  }, 2));
  frames = parseFrames(out).map(JSON.parse);
  check('hover-null-on-error', frames.some((f) => f.id === 2 && f.result === null), out);

  // didChange (full sync) to a valid expression -> empty diagnostics
  out = handle(Module, msg('textDocument/didChange', {
    textDocument: { uri: URI, version: 2 },
    contentChanges: [{ text: '1 + 2' }],
  }));
  frames = parseFrames(out).map(JSON.parse);
  const diag2 = frames.find((f) => f.method === 'textDocument/publishDiagnostics');
  check('empty-diagnostics-after-fix',
    !!diag2 && Array.isArray(diag2.params.diagnostics) && diag2.params.diagnostics.length === 0, out);

  // hover on the valid doc -> inferred type Natural
  out = handle(Module, msg('textDocument/hover', {
    textDocument: { uri: URI }, position: { line: 0, character: 0 },
  }, 3));
  frames = parseFrames(out).map(JSON.parse);
  const h = frames.find((f) => f.id === 3);
  check('hover-type-natural', !!h && h.result && h.result.contents.value === 'Natural',
    h && JSON.stringify(h.result));

  process.exit(fail ? 1 : 0);
});
