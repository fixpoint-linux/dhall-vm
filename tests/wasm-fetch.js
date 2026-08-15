'use strict';
const http = require('http');
const crypto = require('crypto');
const path = require('path');

function installSyncXHR() {
  const { spawnSync } = require('child_process');
  const HELPER = String.raw`
    const http = require('http');
    const url = process.argv[1];
    http.get(url, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        process.stdout.write(String(res.statusCode) + '\n');
        process.stdout.write(Buffer.concat(chunks));
      });
    }).on('error', () => { process.stdout.write('0\n'); });
  `;
  globalThis.XMLHttpRequest = class {
    constructor() { this.status = 0; this.response = null; this.readyState = 0; }
    open(_m, url, _async) { this._url = url; }
    set responseType(_) {}
    send() {
      const r = spawnSync(process.execPath, ['-e', HELPER, this._url], { maxBuffer: 64 * 1024 * 1024 });
      const out = r.stdout || Buffer.alloc(0);
      const nl = out.indexOf(10);
      this.status = parseInt(out.toString('utf8', 0, nl < 0 ? out.length : nl), 10) || 0;
      const body = nl < 0 ? Buffer.alloc(0) : out.subarray(nl + 1);
      this.response = body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength);
      this.readyState = 4;
    }
    abort() {}
  };
}
installSyncXHR();

const createDhall = require(path.join(__dirname, '..', 'docs', 'dhall.js'));

const BODY = '42\n';
const SHA = crypto.createHash('sha256').update(BODY, 'utf8').digest('hex');

const server = http.createServer((req, res) => {
  if (req.url === '/missing') { res.writeHead(404, { 'Content-Length': '4' }); res.end('nope'); return; }
  res.writeHead(200, { 'Content-Length': String(Buffer.byteLength(BODY)) });
  res.end(BODY);
});

server.on('error', () => { console.log('SKIP wasm-fetch: cannot bind loopback port'); process.exit(0); });
server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  const url = `http://127.0.0.1:${port}/x.dhall`;
  const missing = `http://127.0.0.1:${port}/missing`;

  function run(Module, mode, src) {
    const bytes = Module.lengthBytesUTF8(src);
    const p = Module._malloc(bytes + 1);
    Module.stringToUTF8(src, p, bytes + 1);
    const rc = Module._dhall_run(mode, p, bytes);
    Module._free(p);
    const n = Module._dhall_out_len();
    const out = n ? Module.UTF8ToString(Module._dhall_out(), n) : '';
    return { rc, out };
  }

  createDhall().then((Module) => {
    let fail = 0;
    let { rc, out } = run(Module, 1, `${url} sha256:${SHA}`);
    const ok1 = rc === 0 && out.trim() === '42';
    console.log(`fetch+sha256+normalize => rc=${rc} out=${JSON.stringify(out)} ${ok1 ? 'PASS' : 'FAIL'}`);
    if (!ok1) fail++;

    ({ rc, out } = run(Module, 1, `${missing} sha256:${SHA} ? 99`));
    const ok2 = rc === 0 && out.trim() === '99';
    console.log(`404 -> '?' fallback => rc=${rc} out=${JSON.stringify(out)} ${ok2 ? 'PASS' : 'FAIL'}`);
    if (!ok2) fail++;

    server.close();
    process.exit(fail ? 1 : 0);
  });
});
