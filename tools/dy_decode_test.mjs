// 用合成数据验证抖音 protobuf 解码逻辑（不依赖设备）。
// 运行：node tools/dy_decode_test.mjs
import fs from 'node:fs';
import zlib from 'node:zlib';

const dart = fs.readFileSync('app/lib/services/comment_capture.dart', 'utf8');
const m = dart.match(/const String _douyinHookScript = r'''([\s\S]*?)''';/);
if (!m) {
  console.error('hook script not found');
  process.exit(1);
}
const hook = m[1];

// ---- 最小 protobuf 编码器（测试用）----
const vi = (n) => {
  const out = [];
  while (n > 127) { out.push((n & 0x7f) | 0x80); n >>>= 7; }
  out.push(n);
  return Buffer.from(out);
};
const tag = (f, w) => vi((f << 3) | w);
const lenField = (f, buf) => Buffer.concat([tag(f, 2), vi(buf.length), buf]);
const strField = (f, s) => lenField(f, Buffer.from(s, 'utf8'));

const chat = Buffer.concat([
  lenField(2, Buffer.concat([vi(1), vi(1), strField(3, '测试用户')])), // user
  strField(3, '你好抖音'),
]);
const message = Buffer.concat([strField(1, 'WebcastChatMessage'), lenField(2, chat), vi(3)]);
const response = lenField(1, message);
const gz = zlib.gzipSync(response);

const pushFrame = Buffer.concat([
  vi(1), vi(1),                    // seqid
  strField(6, 'gzip'),             // payloadEncoding
  strField(7, 'msg'),              // payloadType
  lenField(8, gz),                 // payload
]);

// ---- 在 Node 里跑 hook ----
const posted = [];
const sandbox = {
  window: {},
  LiveComments: { postMessage: (s) => posted.push(JSON.parse(s)) },
  TextDecoder,
  Blob,
  Response,
  DecompressionStream,
  Uint8Array,
  Math,
  JSON,
  Date,
  Promise,
  setInterval: () => 0,
  clearInterval: () => {},
};
sandbox.window = sandbox; // hook 里用 window.__lcHooked

const fn = new Function('window', 'LiveComments', 'TextDecoder', 'Blob', 'Response',
  'DecompressionStream', 'Uint8Array', 'setInterval', 'clearInterval', hook + '\nreturn window;');

// 先放一个假的 WebSocket 基类，让 hook 去包装它（和浏览器里一致）
const holder = {};
function BaseWS(url) { holder.sock = this; this.listeners = {}; }
BaseWS.prototype.addEventListener = function (ev, cb) { this.listeners[ev] = cb; };
sandbox.window.WebSocket = BaseWS;

const w = fn(sandbox.window, sandbox.LiveComments, TextDecoder, Blob, Response,
  DecompressionStream, Uint8Array, () => 0, () => {});

w.WebSocket('wss://example.invalid');

const ab = pushFrame.buffer.slice(pushFrame.byteOffset, pushFrame.byteOffset + pushFrame.byteLength);
holder.sock.listeners['message']({ data: ab });

setTimeout(() => {
  console.log('posted:', JSON.stringify(posted, null, 1));
  const ok = posted.some((p) => p.t === 'c' && p.x === '你好抖音' && p.u === '测试用户');
  console.log(ok ? 'DECODE_OK' : 'DECODE_FAIL');
  process.exit(ok ? 0 : 2);
}, 500);
