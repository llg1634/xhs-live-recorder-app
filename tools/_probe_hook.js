(function(){
  if (window.__hookInstalled) { return; }
  window.__hookInstalled = true;
  window.__probe = {ws: [], frames: 0, comments: 0, bin: 0, methods: {}, chats: 0};

  function post(o) {
    try { ProbeBridge.postMessage(JSON.stringify(o)); } catch (e) {}
  }
  function str(u8) {
    try { return new TextDecoder('utf-8').decode(u8); } catch (e) { return ''; }
  }
  function b64utf8(b64) {
    try {
      var bin = atob(b64), n = bin.length, out = new Uint8Array(n);
      for (var i = 0; i < n; i++) out[i] = bin.charCodeAt(i);
      return new TextDecoder('utf-8').decode(out);
    } catch (e) { return null; }
  }

  // ---- 最小 protobuf 解析（只够解抖音推流） ----
  function varint(u8, pos) {
    var r = 0, shift = 0, b;
    do { b = u8[pos++]; r += (b & 0x7f) * Math.pow(2, shift); shift += 7; } while (b & 0x80);
    return [r, pos];
  }
  function fields(u8) {
    var out = [], pos = 0;
    while (pos < u8.length) {
      var t = varint(u8, pos); pos = t[1];
      var tag = t[0], f = Math.floor(tag / 8), w = tag & 7;
      if (w === 0) { var v = varint(u8, pos); out.push({f: f, w: 0, n: v[0]}); pos = v[1]; }
      else if (w === 2) {
        var l = varint(u8, pos); pos = l[1];
        out.push({f: f, w: 2, b: u8.subarray(pos, pos + l[0])});
        pos += l[0];
      } else if (w === 5) { out.push({f: f, w: 5}); pos += 4; }
      else if (w === 1) { out.push({f: f, w: 1}); pos += 8; }
      else break;
    }
    return out;
  }
  function getB(list, f) { for (var i = 0; i < list.length; i++) if (list[i].f === f && list[i].w === 2) return list[i].b; return null; }
  function getAllB(list, f) { var o = []; for (var i = 0; i < list.length; i++) if (list[i].f === f && list[i].w === 2) o.push(list[i].b); return o; }

  function gunzip(bytes) {
    return new Promise(function (resolve) {
      try {
        if (typeof DecompressionStream === 'undefined') { resolve(null); return; }
        var ds = new DecompressionStream('gzip');
        var stream = new Blob([bytes]).stream().pipeThrough(ds);
        new Response(stream).arrayBuffer().then(
          function (ab) { resolve(new Uint8Array(ab)); },
          function () { resolve(null); });
      } catch (e) { resolve(null); }
    });
  }

  function handleDouyin(buf) {
    var u8 = new Uint8Array(buf);
    window.__probe.bin++;
    var pf = fields(u8);
    var payload = getB(pf, 8);
    var encoding = getB(pf, 6) ? str(getB(pf, 6)) : '';
    var ptype = getB(pf, 7) ? str(getB(pf, 7)) : '';
    if (window.__probe.bin <= 2) {
      post({t: 'notice', text: 'BIN len=' + u8.length + ' enc=' + encoding + ' type=' + ptype});
    }
    if (!payload) return;
    var parse = function (bytes) {
      var resp = fields(bytes);
      var msgs = getAllB(resp, 1);
      for (var i = 0; i < msgs.length; i++) {
        var mf = fields(msgs[i]);
        var method = getB(mf, 1) ? str(getB(mf, 1)) : '';
        var body = getB(mf, 2);
        if (!method) continue;
        window.__probe.methods[method] = (window.__probe.methods[method] || 0) + 1;
        if (method === 'WebcastChatMessage' && body) {
          var cf = fields(body);
          var content = getB(cf, 3) ? str(getB(cf, 3)) : '';
          var nick = '';
          var userBuf = getB(cf, 2);
          if (userBuf) {
            var uf = fields(userBuf);
            nick = getB(uf, 3) ? str(getB(uf, 3)) : '';
          }
          if (content) {
            window.__probe.chats++;
            post({t: 'dychat', u: nick, x: content.slice(0, 200)});
          }
        }
      }
    };
    if (encoding === 'gzip') {
      gunzip(payload).then(function (out) { if (out) parse(out); });
    } else {
      parse(payload);
    }
  }

  // ---- 小红书：文本 JSON 帧 ----
  function handleXhs(data) {
    var outer;
    try { outer = JSON.parse(data); } catch (e) { return; }
    if (!outer || !outer.b || !outer.b.d || !Array.isArray(outer.b.d.b)) return;
    var list = outer.b.d.b;
    for (var i = 0; i < list.length; i++) {
      var item = list[i];
      if (!item || !item.d) continue;
      var txt = b64utf8(item.d);
      if (!txt) continue;
      var payload;
      try { payload = JSON.parse(txt); } catch (e) { continue; }
      var cd = payload.customData;
      if (typeof cd === 'string') { try { cd = JSON.parse(cd); } catch (e) { continue; } }
      if (!cd || cd.type !== 'text') continue;
      var text = cd.desc || cd.content || cd.text || '';
      if (!text) continue;
      var user = (cd.profile && cd.profile.nickname) ||
                 (cd.userInfo && cd.userInfo.nickname) || '';
      post({t: 'comment', text: user ? user + '：' + text : String(text)});
    }
  }

  function handleFrame(data) {
    window.__probe.frames++;
    post({t: 'frame', n: 1});
    if (typeof data === 'string') { handleXhs(data); return; }
    if (data instanceof ArrayBuffer) { handleDouyin(data); }
  }

  var OWS = window.WebSocket;
  function WS(u, p) {
    try { window.__probe.ws.push(String(u)); post({t: 'ws', url: String(u)}); } catch (e) {}
    var sock = new OWS(u, p);
    try {
      sock.binaryType = 'arraybuffer';
      sock.addEventListener('message', function (ev) { handleFrame(ev.data); });
    } catch (e) {}
    return sock;
  }
  WS.prototype = OWS.prototype;
  WS.CONNECTING = 0; WS.OPEN = 1; WS.CLOSING = 2; WS.CLOSED = 3;
  window.WebSocket = WS;

  var OW = window.Worker;
  if (OW) {
    function W(src, opt) { try { post({t: 'worker', src: String(src).slice(0, 160)}); } catch (e) {} return new OW(src, opt); }
    W.prototype = OW.prototype;
    window.Worker = W;
  }

  setInterval(function () {
    post({t: 'stats', bin: window.__probe.bin, chats: window.__probe.chats,
          methods: window.__probe.methods});
  }, 15000);

  post({t: 'notice', text: 'hook installed ua=' + navigator.userAgent});
})();
