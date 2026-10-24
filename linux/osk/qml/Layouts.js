// Key geometry, ported 1:1 from the v2 design mockup (y700/linux/osk-design/y700-keyboard-mockup.html).
// Coordinates are in vivo's canvas units: pad_*_land = 1024 x 222, pad_pinyin_26_float = 364 x 210.
// Each key: { k: id, t: type, x, w, r: row, rs: row span, fn: function-key tint, ch: text to commit }
.pragma library

var HINT_ZH = { q:'1',w:'2',e:'3',r:'4',t:'5',y:'6',u:'7',i:'8',o:'9',p:'0',a:'~',s:'!',d:'@',f:'#',g:'%',h:'“',j:'”',k:'*',l:'?',z:'(',x:')',c:'-',v:'_',b:'：',n:'；',m:'/' };
var HINT_EN = { q:'1',w:'2',e:'3',r:'4',t:'5',y:'6',u:'7',i:'8',o:'9',p:'0',a:'~',s:'!',d:'@',f:'#',g:'%',h:"'",j:'&',k:'*',l:'?',z:'(',x:')',c:'-',v:'_',b:':',n:';',m:'\\' };
var ACCENT = { a:'àáâä', e:'èéêë', i:'ìíîï', o:'òóôö', u:'ùúûü', c:'ç', n:'ñ', y:'ÿ' };

function hints(zh) { return zh ? HINT_ZH : HINT_EN; }

// long-press strip for a letter: 大写 · 角标 · 小写 (+ accented letters in English)
function alternates(k, zh) {
    var hint = hints(zh)[k], items = [k.toUpperCase(), hint, k];
    if (k === 'a' || k === 'q') items = [hint, k.toUpperCase(), k];
    if (k === 'l' || k === 'p') items = [k.toUpperCase(), k, hint];
    if (!zh && ACCENT[k]) items = items.concat(ACCENT[k].split(''));
    return items;
}

// Japanese (mozc, romaji) uses the Chinese grid; 分词 becomes the long-vowel mark ー
function sepKey(zh, ja) { return ja ? { k: 'chouon', t: 'punct', ch: 'ー' } : zh ? { k: 'sep', t: 'sep' } : { k: 'shift', t: 'shift' }; }
function comma(zh, ja) { return ja ? '、' : zh ? '，' : ','; }
function period(zh, ja) { return zh ? '。' : '.'; }
function put(L, o, x, w, r, fn) { var d = {}; for (var p in o) d[p] = o[p]; d.x = x; d.w = w; d.r = r; if (fn) d.fn = true; L.push(d); }

function mainRows(zh, ja) {
    var L = [], i, s;
    s = 'qwertyuiop';
    for (i = 0; i < 10; i++) put(L, { k: s[i], t: 'char' }, i === 0 ? 8 : i === 9 ? 924 : 108 + 102 * (i - 1), i === 0 || i === 9 ? 92 : 94, 0);
    s = 'asdfghjkl';
    for (i = 0; i < 9; i++) put(L, { k: s[i], t: 'char' }, 57 + 102 * i, 94, 1);
    put(L, sepKey(zh, ja), 8, 143, 2, true);
    s = 'zxcvbnm';
    for (i = 0; i < 7; i++) put(L, { k: s[i], t: 'char' }, 159 + 102 * i, 94, 2);
    put(L, { k: 'del', t: 'del' }, 873, 143, 2, true);
    if (zh) {
        put(L, { k: 'sym', t: 'sym' }, 8, 143, 3, true);
        put(L, { k: '123', t: 'num' }, 159, 94, 3, true);
    } else { // pad_en_26_land: 符 and 123 share the 143 slot; the word-mode key becomes @
        put(L, { k: 'sym', t: 'sym' }, 8, 67, 3, true);
        put(L, { k: '123', t: 'num' }, 83, 68, 3, true);
        put(L, { k: 'at', t: 'punct', ch: '@' }, 159, 94, 3);
    }
    put(L, { k: 'comma', t: 'punct', ch: comma(zh, ja) }, 261, 94, 3);
    put(L, { k: 'space', t: 'space' }, 363, 298, 3);
    put(L, { k: 'period', t: 'punct', ch: period(zh, ja) }, 669, 94, 3);
    put(L, { k: 'lang', t: 'lang' }, 771, 94, 3, true);
    put(L, { k: 'enter', t: 'enter', send: true }, 873, 143, 3, true);
    return L;
}

function splitRows(zh, ja) { // pad_pinyin_26_land_split: key 42, pitch 46, the middle of the canvas is empty
    var L = [], P = 46, W = 42, i, s;
    s = 'qwert'; for (i = 0; i < 5; i++) put(L, { k: s[i], t: 'char' }, 8 + P * i, W, 0);
    s = 'yuiop'; for (i = 0; i < 5; i++) put(L, { k: s[i], t: 'char' }, 790 + P * i, W, 0);
    s = 'asdfg'; for (i = 0; i < 5; i++) put(L, { k: s[i], t: 'char' }, 29 + P * i, W, 1);
    s = 'ghjkl'; for (i = 0; i < 5; i++) put(L, { k: s[i], id: s[i] === 'g' ? 'g2' : s[i], t: 'char' }, 767 + P * i, W, 1);
    put(L, sepKey(zh, ja), 8, 63, 2, true);
    s = 'zxcv'; for (i = 0; i < 4; i++) put(L, { k: s[i], t: 'char' }, 75 + P * i, W, 2);
    s = 'vbnm'; for (i = 0; i < 4; i++) put(L, { k: s[i], id: s[i] === 'v' ? 'v2' : s[i], t: 'char' }, 769 + P * i, W, 2);
    put(L, { k: 'del', t: 'del' }, 953, 63, 2, true);
    put(L, { k: 'sym', t: 'sym' }, 8, 64, 3, true);
    put(L, { k: '123', t: 'num' }, 76, 42, 3, true);
    put(L, { k: 'comma', t: 'punct', ch: comma(zh, ja) }, 122, 44, 3);
    put(L, { k: 'space', t: 'space' }, 170, 86, 3);
    put(L, { k: 'space', id: 'space2', t: 'space' }, 768, 88, 3);
    put(L, { k: 'period', t: 'punct', ch: period(zh, ja) }, 860, 42, 3);
    put(L, { k: 'lang', t: 'lang' }, 906, 42, 3, true);
    put(L, { k: 'enter', t: 'enter', send: true }, 952, 64, 3, true);
    return L;
}

function floatRows(zh, ja) { // pad_pinyin_26_float, canvas 364 x 210: key 30, pitch 36
    var L = [], i, s;
    s = 'qwertyuiop'; for (i = 0; i < 10; i++) put(L, { k: s[i], t: 'char' }, 5 + 36 * i, 30, 0);
    s = 'asdfghjkl'; for (i = 0; i < 9; i++) put(L, { k: s[i], t: 'char' }, 23 + 36 * i, 30, 1);
    put(L, sepKey(zh, ja), 5, 48, 2, true);
    s = 'zxcvbnm'; for (i = 0; i < 7; i++) put(L, { k: s[i], t: 'char' }, 59 + 36 * i, 30, 2);
    put(L, { k: 'del', t: 'del' }, 311, 48, 2, true);
    put(L, { k: 'sym', t: 'sym' }, 5, 48, 3, true);
    put(L, { k: '123', t: 'num' }, 59, 39, 3, true);
    put(L, { k: 'comma', t: 'punct', ch: comma(zh, ja) }, 104, 30, 3);
    put(L, { k: 'space', t: 'space' }, 140, 86, 3);
    put(L, { k: 'period', t: 'punct', ch: period(zh, ja) }, 232, 30, 3);
    put(L, { k: 'lang', t: 'lang' }, 268, 37, 3, true);
    put(L, { k: 'enter', t: 'enter', send: true }, 311, 48, 3, true);
    return L;
}

function portRows(zh, ja) { // pad_pinyin_26_normal (portrait), canvas 640 x 206: key 56 (cell 64), wide keys 84 (cell 92)
    var L = [], i, s;
    s = 'qwertyuiop'; for (i = 0; i < 10; i++) put(L, { k: s[i], t: 'char' }, 8 + 64 * i, 56, 0);
    s = 'asdfghjkl'; for (i = 0; i < 9; i++) put(L, { k: s[i], t: 'char' }, 36 + 64 * i, 56, 1);
    put(L, sepKey(zh, ja), 8, 84, 2, true);
    s = 'zxcvbnm'; for (i = 0; i < 7; i++) put(L, { k: s[i], t: 'char' }, 100 + 64 * i, 56, 2);
    put(L, { k: 'del', t: 'del' }, 548, 84, 2, true);
    if (zh) {
        put(L, { k: 'sym', t: 'sym' }, 8, 84, 3, true);
        put(L, { k: '123', t: 'num' }, 100, 59, 3, true);
    } else {
        put(L, { k: 'sym', t: 'sym' }, 8, 38, 3, true);
        put(L, { k: '123', t: 'num' }, 54, 38, 3, true);
        put(L, { k: 'at', t: 'punct', ch: '@' }, 100, 59, 3);
    }
    put(L, { k: 'comma', t: 'punct', ch: comma(zh, ja) }, 167, 59, 3);
    put(L, { k: 'space', t: 'space' }, 234, 172, 3);
    put(L, { k: 'period', t: 'punct', ch: period(zh, ja) }, 414, 59, 3);
    put(L, { k: 'lang', t: 'lang' }, 481, 59, 3, true);
    put(L, { k: 'enter', t: 'enter', send: true }, 548, 84, 3, true);
    return L;
}
// pad_pinyin_26_port_split: the landscape halves on a 640 canvas with a 124 gap (right half moves left by 384)
function portSplitRows(zh, ja) {
    return splitRows(zh, ja).map(function (d) { var o = {}; for (var p in d) o[p] = d[p]; if (d.x >= 512) o.x = d.x - 384; return o; });
}

var NUM_LIST = ['@', '%', '/', '-', '+', '*', ':', '#', '_', '(', ')', '=', '¥', '$'];
function numRows() { // vivo pad_num_land (1024 canvas)
    var L = [], xs = [195, 409, 623], n;
    put(L, { k: 'list', t: 'list', rs: 3 }, 8, 179, 0, true);
    for (n = 1; n <= 9; n++) put(L, { k: 'd' + n, t: 'digit', ch: String(n) }, xs[(n - 1) % 3], 206, Math.floor((n - 1) / 3));
    put(L, { k: 'del', t: 'del' }, 837, 179, 0, true);
    put(L, { k: 'dot', t: 'digit', ch: '.' }, 837, 179, 1, true);
    put(L, { k: 'at', t: 'digit', ch: '@' }, 837, 179, 2, true);
    put(L, { k: 'sym', t: 'sym' }, 8, 179, 3, true);
    put(L, { k: 'back', t: 'back' }, 195, 129, 3, true);
    put(L, { k: 'd0', t: 'digit', ch: '0' }, 332, 360, 3);
    put(L, { k: 'space', t: 'space' }, 700, 129, 3, true);
    put(L, { k: 'enter', t: 'enter' }, 837, 179, 3, true);
    return L;
}

// { defs, cw, ch, ry: row tops, kh: key height } in canvas units
function rows(mode, layout, zh, portrait, ja) {
    if (layout === 'num') return { defs: numRows(), cw: 1024, ch: 222, ry: [4, 60, 116, 172], kh: 50 };
    if (mode === 'float') return { defs: floatRows(zh, ja), cw: 364, ch: 210, ry: [3, 57, 111, 165], kh: 44 };
    if (portrait && mode === 'split') return { defs: portSplitRows(zh, ja), cw: 640, ch: 222, ry: [4, 60, 116, 172], kh: 50 };
    if (portrait) return { defs: portRows(zh, ja), cw: 640, ch: 206, ry: [4, 56, 108, 160], kh: 46 };
    return { defs: mode === 'split' ? splitRows(zh, ja) : mainRows(zh, ja), cw: 1024, ch: 222, ry: [4, 60, 116, 172], kh: 50 };
}

// vivo: the key area is 222 dp high in landscape and 226 dp in portrait (1 dp = 4/3 px here):
// a portrait keyboard is as tall as a landscape one, only narrower
function metrics(mode, hadj, portrait) {
    if (mode === 'float') return { W: 485, band: 61, keyH: 279 * hadj, bot: 30, fs: 0.83 };
    return { W: 1600, band: 76, keyH: (portrait ? 301 : 296) * hadj, bot: 16, fs: mode === 'split' ? 0.94 : 1 };
}

// width of each half of the split keyboard's glass, as a fraction of the keyboard width
function splitHalf(portrait) { return portrait ? 258 / 640 : 265 / 1024; }
