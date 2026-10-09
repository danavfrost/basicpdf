// Low-level PDF file access: xref (tables, streams, hybrid, /Prev chains),
// repair by scanning, lazy object loading, object streams, decryption.

import 'dart:typed_data';

import '../pdf_core.dart';
import 'filters.dart';
import 'lexer.dart';
import 'objects.dart';
import 'security.dart';

class XrefEntry {
  /// 0 = free, 1 = in file at [offset], 2 = in object stream [stream].
  final int type;
  final int offset; // type 1: byte offset; type 2: object stream number
  final int gen; // type 1: generation; type 2: index within stream
  const XrefEntry(this.type, this.offset, this.gen);
}

class _ObjStm {
  final Uint8List data;
  final int first;
  final Map<int, int> offsets; // objnum -> offset (relative to first)
  _ObjStm(this.data, this.first, this.offsets);
}

class PdfFile {
  final Uint8List data;
  final Map<int, XrefEntry> xref = {};
  PdfDict trailer = PdfDict();

  /// Byte offset given by the last startxref (for /Prev in updates).
  int startXref = -1;

  /// Whether the most recent xref section is an xref stream.
  bool lastSectionIsStream = false;

  /// True if the xref was unusable and objects were found by scanning.
  bool repaired = false;

  int headerOffset = 0;
  SecurityHandler? security;
  int? encryptObjNum;

  final Map<int, Object?> _cache = {};
  final Map<int, _ObjStm?> _objStms = {};
  final Set<int> _loading = {};
  Map<int, int>? _scanIndex;
  bool _chainDamaged = false;

  PdfFile._(this.data);

  /// Parses structure. Throws [PdfCoreException] if this isn't a PDF.
  static PdfFile parse(Uint8List data) {
    final f = PdfFile._(data);
    f._init();
    return f;
  }

  void _init() {
    final h = indexOf(
      data,
      '%PDF-',
      0,
      data.length < 1024 ? data.length : 1024,
    );
    if (h < 0) {
      // Not obviously a PDF; still try to repair if it has objects.
      if (indexOf(data, ' obj', 0) < 0) {
        throw const PdfCoreException("This file isn't a PDF");
      }
    } else {
      headerOffset = h;
    }
    var ok = false;
    try {
      ok = _readXrefChain();
    } catch (_) {
      ok = false;
    }
    if (ok && trailer['Encrypt'] == null) {
      try {
        final root = resolve(trailer['Root']);
        ok = root is PdfDict;
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      _repair();
    }
  }

  // -------------------------------------------------------------------------
  // xref

  int _findStartXref() {
    final p = lastIndexOf(data, 'startxref', data.length - 1);
    if (p < 0) return -1;
    final lx = Lexer(data, p + 9);
    final n = lx.nextToken();
    return n is int ? n : -1;
  }

  bool _readXrefChain() {
    final sx = _findStartXref();
    if (sx < 0) return false;
    startXref = sx;
    var offset = sx;
    final seen = <int>{};
    var first = true;
    final trailers = <PdfDict>[];
    while (offset >= 0 && !seen.contains(offset)) {
      seen.add(offset);
      var r = _readSection(offset, first);
      if (r == null && headerOffset > 0) {
        // offsets may be relative to a header preceded by junk
        r = _readSection(offset + headerOffset, first);
      }
      if (r == null) {
        if (first) return false;
        _chainDamaged = true;
        break; // damaged older section: keep what we have
      }
      trailers.add(r);
      first = false;
      final prev = intValue(trailers.last['Prev']);
      offset = prev ?? -1;
    }
    // Latest trailer wins; fill gaps from older ones.
    final t = PdfDict();
    for (final tr in trailers.reversed) {
      for (final e in tr.entries) {
        t[e.key] = e.value;
      }
    }
    final latest = trailers.first;
    for (final k in const ['Root', 'Info', 'ID', 'Encrypt', 'Size']) {
      if (latest[k] != null) t[k] = latest[k];
    }
    t.remove('Prev');
    t.remove('XRefStm');
    trailer = t;
    return t['Root'] != null;
  }

  void _put(int n, XrefEntry e) {
    if (n < 0) return;
    xref.putIfAbsent(n, () => e);
  }

  /// Reads one xref section at [offset]; returns its trailer or null.
  PdfDict? _readSection(int offset, bool isLatest) {
    if (offset < 0 || offset >= data.length) return null;
    final lx = Lexer(data, offset);
    lx.skipWhitespace();
    if (Lexer.matchAt(data, lx.pos, 'xref')) {
      lx.pos += 4;
      final tr = _readXrefTable(lx);
      if (tr == null) return null;
      if (isLatest) lastSectionIsStream = false;
      final xs = intValue(tr['XRefStm']);
      if (xs != null) {
        try {
          _readXrefStream(xs);
        } catch (_) {
          // hybrid stream damaged: table still usable
        }
      }
      return tr;
    }
    try {
      final d = _readXrefStream(lx.pos);
      if (d == null) return null;
      if (isLatest) lastSectionIsStream = true;
      return d;
    } catch (_) {
      return null;
    }
  }

  PdfDict? _readXrefTable(Lexer lx) {
    final local = <int, XrefEntry>{};
    while (true) {
      final save = lx.pos;
      final t = lx.nextToken();
      if (t is PdfKeyword && t.word == 'trailer') break;
      if (t is! int) {
        lx.pos = save;
        break;
      }
      final count = lx.nextToken();
      if (count is! int) return null;
      var start = t;
      for (var i = 0; i < count; i++) {
        final off = lx.nextToken();
        final gen = lx.nextToken();
        final kind = lx.nextToken();
        if (off is! int || gen is! int || kind is! PdfKeyword) return null;
        if (i == 0 && start == 1 && kind.word == 'f' && gen == 65535) {
          start = 0; // common off-by-one in broken writers
        }
        final num = start + i;
        if (kind.word == 'n') {
          local[num] = XrefEntry(1, off, gen);
        } else {
          local[num] = XrefEntry(0, off, gen);
        }
      }
    }
    lx.skipWhitespace();
    final tr = lx.parseObject();
    if (tr is! PdfDict) return null;
    local.forEach(_put);
    return tr;
  }

  PdfDict? _readXrefStream(int offset) {
    final obj = parseIndirectObject(
      data,
      offset,
      resolveLength: (o) => intValue(_resolveDuringBoot(o)),
    );
    final s = obj.value;
    if (s is! PdfStream) return null;
    final d = s.dict;
    if (d.name('Type') != 'XRef' && d['W'] == null) return null;
    final w = d['W'];
    if (w is! List || w.length < 3) return null;
    final ws = [for (final x in w) intValue(x) ?? 0];
    final size = intValue(d['Size']) ?? 0;
    final idx = d['Index'];
    final index = <int>[];
    if (idx is List) {
      for (final x in idx) {
        index.add(intValue(x) ?? 0);
      }
    } else {
      index.addAll([0, size]);
    }
    final bytes = decodeStreamData(s.data, d);
    final rowLen = ws[0] + ws[1] + ws[2];
    if (rowLen == 0) return d;
    var p = 0;
    int field(int width, int def) {
      if (width == 0) return def;
      var v = 0;
      for (var i = 0; i < width; i++) {
        v = (v << 8) | (p < bytes.length ? bytes[p] : 0);
        p++;
      }
      return v;
    }

    for (var i = 0; i + 1 < index.length; i += 2) {
      final start = index[i], count = index[i + 1];
      for (var j = 0; j < count; j++) {
        if (p + rowLen > bytes.length) break;
        final type = field(ws[0], 1);
        final a = field(ws[1], 0);
        final b = field(ws[2], 0);
        if (type == 0 || type == 1 || type == 2) {
          _put(start + j, XrefEntry(type, a, b));
        }
      }
    }
    return d;
  }

  Object? _resolveDuringBoot(Object? o) {
    if (o is PdfRef) {
      try {
        return getObject(o.num);
      } catch (_) {
        return null;
      }
    }
    return o;
  }

  // -------------------------------------------------------------------------
  // repair

  Map<int, int> _scanObjects() {
    final found = <int, int>{};
    final d = data;
    for (var i = 0; i + 3 <= d.length; i++) {
      if (d[i] != 0x6f || d[i + 1] != 0x62 || d[i + 2] != 0x6a) continue;
      if (i + 3 < d.length && !isWhite(d[i + 3]) && !isDelimiter(d[i + 3])) {
        continue;
      }
      // walk back: ws gen ws num
      var p = i - 1;
      if (p < 0 || !isWhite(d[p])) continue;
      while (p >= 0 && isWhite(d[p])) {
        p--;
      }
      final genEnd = p + 1;
      while (p >= 0 && d[p] >= 0x30 && d[p] <= 0x39) {
        p--;
      }
      if (p + 1 == genEnd) continue;
      if (p < 0 || !isWhite(d[p])) continue;
      while (p >= 0 && isWhite(d[p])) {
        p--;
      }
      final numEnd = p + 1;
      while (p >= 0 && d[p] >= 0x30 && d[p] <= 0x39) {
        p--;
      }
      if (p + 1 == numEnd) continue;
      if (p >= 0 && !isWhite(d[p]) && !isDelimiter(d[p])) continue;
      final num = int.tryParse(String.fromCharCodes(d, p + 1, numEnd));
      if (num == null) continue;
      found[num] = p + 1; // later definitions win
    }
    return found;
  }

  void _repair() {
    repaired = true;
    xref.clear();
    _cache.clear();
    _objStms.clear();
    lastSectionIsStream = false;
    final found = _scanObjects();
    _scanIndex = found;
    if (found.isEmpty) {
      throw const PdfCoreException("This PDF is damaged and can't be opened");
    }
    found.forEach((n, off) {
      xref[n] = XrefEntry(1, off, _genAt(off));
    });
    // trailers
    final t = PdfDict();
    var p = 0;
    while (true) {
      p = indexOf(data, 'trailer', p);
      if (p < 0) break;
      try {
        final lx = Lexer(data, p + 7);
        final d = lx.parseObject();
        if (d is PdfDict) {
          for (final e in d.entries) {
            t[e.key] = e.value;
          }
        }
      } catch (_) {}
      p += 7;
    }
    // xref streams and object streams
    final objStms = <int>[];
    final nums = found.keys.toList()..sort();
    for (final num in nums) {
      try {
        final o = parseIndirectObject(
          data,
          found[num]!,
          resolveLength: (o) => intValue(_resolveDuringBoot(o)),
        );
        final v = o.value;
        if (v is PdfStream) {
          final type = v.dict.name('Type');
          if (type == 'XRef') {
            for (final k in const ['Root', 'Info', 'ID', 'Encrypt']) {
              if (v.dict[k] != null) t[k] = v.dict[k];
            }
          } else if (type == 'ObjStm') {
            objStms.add(num);
          }
        }
      } catch (_) {}
    }
    t.remove('Prev');
    t.remove('XRefStm');
    trailer = t;
    if (t['Encrypt'] != null) {
      // Security must be set up before object streams can be read; the
      // caller does that. Remember them for later.
      _pendingObjStms = objStms;
    } else {
      _indexObjStms(objStms);
      if (resolve(t['Root']) is! PdfDict) _findCatalog();
    }
  }

  List<int>? _pendingObjStms;

  /// Checks the catalog is reachable (after security is set up); repairs
  /// the file by scanning if it isn't.
  void ensureRoot() {
    bool good() {
      try {
        return resolve(trailer['Root']) is PdfDict;
      } catch (_) {
        return false;
      }
    }

    if (good()) return;
    if (repaired) {
      throw const PdfCoreException("This PDF is damaged and can't be opened");
    }
    final sec = security;
    _repair();
    if (sec != null) {
      security = sec;
      finishRepair();
    }
    if (!good()) {
      throw const PdfCoreException("This PDF is damaged and can't be opened");
    }
  }

  /// Called after security is configured (repair of encrypted files).
  void finishRepair() {
    final p = _pendingObjStms;
    if (p != null) {
      _pendingObjStms = null;
      _indexObjStms(p);
      if (resolve(trailer['Root']) is! PdfDict) _findCatalog();
    }
  }

  void _indexObjStms(List<int> objStms) {
    for (final sn in objStms) {
      try {
        final os = _loadObjStm(sn);
        if (os == null) continue;
        var i = 0;
        for (final num in os.offsets.keys) {
          if (!xref.containsKey(num)) xref[num] = XrefEntry(2, sn, i);
          i++;
        }
      } catch (_) {}
    }
  }

  void _findCatalog() {
    final nums = xref.keys.toList()..sort();
    for (final n in nums.reversed) {
      try {
        final o = getObject(n);
        if (o is PdfDict && o.name('Type') == 'Catalog') {
          trailer['Root'] = PdfRef(n, xref[n]?.type == 1 ? xref[n]!.gen : 0);
          return;
        }
      } catch (_) {}
    }
    throw const PdfCoreException("This PDF is damaged and can't be opened");
  }

  int _genAt(int off) {
    final lx = Lexer(data, off);
    lx.nextToken();
    final g = lx.nextToken();
    return g is int ? g : 0;
  }

  // -------------------------------------------------------------------------
  // objects

  /// Number of objects parsed so far (for tests / diagnostics).
  int get loadedObjectCount => _cache.length;

  int get maxObjectNumber {
    var m = 0;
    for (final k in xref.keys) {
      if (k > m) m = k;
    }
    return m;
  }

  /// Size for the next update's trailer (one past the highest object number).
  int get size {
    final s = intValue(trailer['Size']) ?? 0;
    final m = maxObjectNumber + 1;
    return s > m ? s : m;
  }

  Object? resolve(Object? o) {
    var depth = 0;
    while (o is PdfRef) {
      if (depth++ > 32) return null;
      o = getObject(o.num);
    }
    return o;
  }

  int genOf(int num) {
    final e = xref[num];
    return e != null && e.type == 1 ? e.gen : 0;
  }

  Object? getObject(int num) {
    if (_cache.containsKey(num)) return _cache[num];
    if (_loading.contains(num)) return null; // cycle (e.g. /Length)
    _loading.add(num);
    try {
      final v = _load(num);
      _cache[num] = v;
      return v;
    } finally {
      _loading.remove(num);
    }
  }

  Object? _load(int num) {
    var e = xref[num];
    if (e == null && _chainDamaged) {
      _scanIndex ??= _scanObjects();
      final off = _scanIndex![num];
      if (off != null) e = XrefEntry(1, off, _genAt(off));
    }
    if (e == null || e.type == 0) return null;
    if (e.type == 2) {
      final os = _loadObjStm(e.offset);
      if (os == null) return null;
      final off = os.offsets[num];
      if (off == null) return null;
      final lx = Lexer(os.data, os.first + off);
      final v = lx.parseValue();
      return v is PdfKeyword ? null : v;
    }
    IndirectObject? obj;
    try {
      obj = _parseAt(e.offset);
      if (obj.num != num) obj = null;
    } catch (_) {
      obj = null;
    }
    if (obj == null && headerOffset > 0) {
      try {
        obj = _parseAt(e.offset + headerOffset);
        if (obj.num != num) obj = null;
      } catch (_) {
        obj = null;
      }
    }
    if (obj == null) {
      _scanIndex ??= _scanObjects();
      final off = _scanIndex![num];
      if (off == null) return null;
      try {
        obj = _parseAt(off);
      } catch (_) {
        return null;
      }
    }
    return _decryptObject(obj.value, num, obj.gen);
  }

  IndirectObject _parseAt(int off) => parseIndirectObject(
    data,
    off,
    resolveLength: (o) => intValue(resolve(o)),
  );

  Object? _decryptObject(Object? v, int num, int gen) {
    final sec = security;
    if (sec == null || num == encryptObjNum) return v;
    if (v is PdfStream) {
      final type = v.dict.name('Type');
      final skip =
          type == 'XRef' ||
          (type == 'Metadata' && !sec.encryptMetadata) ||
          _identityCrypt(v.dict);
      _decryptStrings(v.dict, sec, num, gen);
      if (!skip) v.data = sec.decryptStream(v.data, num, gen);
      return v;
    }
    return _decryptStrings(v, sec, num, gen);
  }

  bool _identityCrypt(PdfDict d) {
    final f = d['Filter'];
    final first = f is List && f.isNotEmpty ? f.first : f;
    if (first is PdfName && first.name == 'Crypt') {
      final p = d['DecodeParms'];
      final pd = p is List && p.isNotEmpty ? p.first : p;
      final name = pd is PdfDict ? pd.name('Name') : null;
      return name == null || name == 'Identity';
    }
    return false;
  }

  Object? _decryptStrings(Object? v, SecurityHandler sec, int num, int gen) {
    if (v is PdfString) {
      return PdfString(sec.decryptString(v.bytes, num, gen), hex: v.hex);
    }
    if (v is PdfDict) {
      for (final k in v.keys.toList()) {
        v.map[k] = _decryptStrings(v.map[k], sec, num, gen);
      }
    } else if (v is List) {
      for (var i = 0; i < v.length; i++) {
        v[i] = _decryptStrings(v[i], sec, num, gen);
      }
    }
    return v;
  }

  _ObjStm? _loadObjStm(int sn) {
    if (_objStms.containsKey(sn)) return _objStms[sn];
    _objStms[sn] = null;
    final s = getObject(sn);
    if (s is! PdfStream) return null;
    final dec = decodeStreamData(s.data, s.dict, resolve: resolve);
    final n = intValue(resolve(s.dict['N'])) ?? 0;
    final first = intValue(resolve(s.dict['First'])) ?? 0;
    final lx = Lexer(dec, 0, first <= dec.length ? first : dec.length);
    final offsets = <int, int>{};
    for (var i = 0; i < n; i++) {
      final a = lx.nextToken();
      final b = lx.nextToken();
      if (a is! int || b is! int) break;
      offsets[a] = b;
    }
    final os = _ObjStm(dec, first, offsets);
    _objStms[sn] = os;
    return os;
  }

  /// Sets up decryption. Must be called before loading other objects.
  void setupSecurity(String? password) {
    final encRef = trailer['Encrypt'];
    if (encRef == null) return;
    if (encRef is PdfRef) encryptObjNum = encRef.num;
    final enc = resolve(encRef);
    if (enc is! PdfDict) {
      throw const PdfCoreException("This PDF is damaged and can't be opened");
    }
    final id = trailer['ID'];
    Uint8List id0 = Uint8List(0);
    if (id is List && id.isNotEmpty) {
      final x = resolve(id[0]);
      if (x is PdfString) id0 = x.bytes;
    }
    // Objects loaded so far (during xref validation) were not decrypted.
    _cache.removeWhere((k, _) => k != encryptObjNum);
    _objStms.clear();
    security = SecurityHandler.open(enc, id0, password, resolve: resolve);
    finishRepair();
  }

  void useSecurity(SecurityHandler sec) {
    final encRef = trailer['Encrypt'];
    if (encRef is PdfRef) encryptObjNum = encRef.num;
    _cache.removeWhere((k, _) => k != encryptObjNum);
    _objStms.clear();
    security = sec;
    finishRepair();
  }
}
