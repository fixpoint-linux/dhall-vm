// Headless smoke test for docs/dhall.js (emscripten MODULARIZE build).
// Usage: node tests/wasm-smoke.js
const createDhall = require('../docs/dhall.js');

function run(Module, mode, src) {
  const bytes = Module.lengthBytesUTF8(src); // bytes, not UTF-16 units!
  const srcPtr = Module._malloc(bytes + 1);
  Module.stringToUTF8(src, srcPtr, bytes + 1);
  const rc = Module._dhall_run(mode, srcPtr, bytes);
  Module._free(srcPtr);
  const outLen = Module._dhall_out_len();
  const out = outLen ? Module.UTF8ToString(Module._dhall_out(), outLen) : '';
  return { rc, out };
}

createDhall().then((Module) => {
  const cases = [
    [1, '1+1', 0, '2'],                              // normalize
    [0, '1', 0, 'Natural'],                          // typecheck
    [2, '{a=1,b=True}', 0, '{"a":1,"b":true}'],       // to-json
    [3, '{a=1}', 0, 'a = 1'],                         // to-toml
    [4, '{a=1}', 0, 'a: 1'],                          // to-yaml
    [0, '1 : Bool', 1, 'type mismatch'],              // type error
    // non-ASCII must not truncate the source (multi-byte comment char + Text)
    [2, '-- a \u2014 b\n{ greeting = "caf\u00e9" }', 0, '{"greeting":"café"}'],
    [4, '-- \u03bb\n{ x = 1 }', 0, 'x: 1'],
  ];
  let fail = 0;
  for (const [mode, src, wantRc, wantSubstr] of cases) {
    const { rc, out } = run(Module, mode, src);
    const ok = (rc === wantRc) && out.includes(wantSubstr);
    console.log(`mode=${mode} src=${JSON.stringify(src)} rc=${rc} wantRc=${wantRc} out=${JSON.stringify(out)} => ${ok ? 'PASS' : 'FAIL'}`);
    if (!ok) fail++;
  }
  process.exit(fail ? 1 : 0);
});
