// Standard security handler (PDF 32000-1 §7.6.3, ISO 32000-2 for R6).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart' as pc;

import '../pdf_core.dart';
import 'objects.dart';

const List<int> _pad = [
  0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, //
  0xFF, 0xFA, 0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
  0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
];

Uint8List rc4(List<int> key, List<int> data) {
  final s = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 0xff;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
  }
  final out = Uint8List(data.length);
  var i = 0;
  j = 0;
  for (var k = 0; k < data.length; k++) {
    i = (i + 1) & 0xff;
    j = (j + s[i]) & 0xff;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
    out[k] = data[k] ^ s[(s[i] + s[j]) & 0xff];
  }
  return out;
}

Uint8List md5(List<int> data) => Uint8List.fromList(c.md5.convert(data).bytes);

/// AES-CBC without padding handling. [data] length must be a multiple of 16.
Uint8List aesCbc(bool encrypt, List<int> key, List<int> iv, List<int> data) {
  final cipher = pc.CBCBlockCipher(pc.AESEngine())
    ..init(
      encrypt,
      pc.ParametersWithIV(
        pc.KeyParameter(Uint8List.fromList(key)),
        Uint8List.fromList(iv),
      ),
    );
  final input = data is Uint8List ? data : Uint8List.fromList(data);
  final out = Uint8List(input.length);
  for (var off = 0; off + 16 <= input.length; off += 16) {
    cipher.processBlock(input, off, out, off);
  }
  return out;
}

/// AES-CBC decrypt of "IV + ciphertext" with PKCS#5 padding (lenient).
Uint8List aesDecrypt(List<int> key, Uint8List data) {
  if (data.length < 32) {
    if (data.length <= 16) return Uint8List(0);
  }
  final iv = Uint8List.sublistView(data, 0, 16);
  var n = (data.length - 16) ~/ 16 * 16;
  if (n == 0) return Uint8List(0);
  final plain = aesCbc(false, key, iv, Uint8List.sublistView(data, 16, 16 + n));
  final p = plain[plain.length - 1];
  if (p >= 1 && p <= 16 && p <= plain.length) {
    var ok = true;
    for (var i = plain.length - p; i < plain.length; i++) {
      if (plain[i] != p) {
        ok = false;
        break;
      }
    }
    if (ok) return Uint8List.sublistView(plain, 0, plain.length - p);
  }
  return plain;
}

final Random _rng = Random.secure();

Uint8List randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

Uint8List aesEncrypt(List<int> key, List<int> data, {List<int>? iv}) {
  final ivb = iv ?? randomBytes(16);
  final p = 16 - data.length % 16;
  final padded = Uint8List(data.length + p)
    ..setAll(0, data)
    ..fillRange(data.length, data.length + p, p);
  final enc = aesCbc(true, key, ivb, padded);
  return Uint8List(16 + enc.length)
    ..setAll(0, ivb)
    ..setAll(16, enc);
}

enum CryptMethod { identity, rc4, aesv2, aesv3 }

class SecurityHandler {
  final int v;
  final int r;
  final int p;
  final Uint8List key;
  final CryptMethod stmMethod;
  final CryptMethod strMethod;
  final bool encryptMetadata;
  final bool isOwner;

  SecurityHandler._(
    this.v,
    this.r,
    this.p,
    this.key,
    this.stmMethod,
    this.strMethod,
    this.encryptMetadata,
    this.isOwner,
  );

  /// Authenticates against the /Encrypt dictionary.
  static SecurityHandler open(
    PdfDict enc,
    Uint8List id0,
    String? password, {
    Object? Function(Object?)? resolve,
  }) {
    Object? res(Object? o) => resolve == null ? o : resolve(o);
    final filter = enc.name('Filter');
    if (filter != 'Standard') {
      throw const PdfCoreException(
        "This kind of protected PDF isn't supported",
      );
    }
    final v = intValue(res(enc['V'])) ?? 0;
    final r = intValue(res(enc['R'])) ?? 2;
    final p = intValue(res(enc['P'])) ?? -1;
    final o = _bytes(res(enc['O']));
    final u = _bytes(res(enc['U']));
    final encMeta = res(enc['EncryptMetadata']) != false;
    var lengthBits = intValue(res(enc['Length'])) ?? 40;
    var stm = CryptMethod.rc4, str = CryptMethod.rc4;
    if (v == 4 || v == 5) {
      final cf = res(enc['CF']);
      CryptMethod method(String? name) {
        if (name == null || name == 'Identity') return CryptMethod.identity;
        final d = cf is PdfDict ? res(cf[name]) : null;
        if (d is! PdfDict) return CryptMethod.identity;
        switch (d.name('CFM')) {
          case 'V2':
            final l = intValue(res(d['Length']));
            if (l != null) lengthBits = l <= 32 ? l * 8 : l;
            return CryptMethod.rc4;
          case 'AESV2':
            return CryptMethod.aesv2;
          case 'AESV3':
            return CryptMethod.aesv3;
          case 'None':
            return CryptMethod.identity;
        }
        throw const PdfCoreException(
          "This kind of protected PDF isn't supported",
        );
      }

      stm = method(enc.name('StmF'));
      str = method(enc.name('StrF'));
      if (stm == CryptMethod.aesv2 || str == CryptMethod.aesv2) {
        lengthBits = 128;
      }
    } else if (v == 1 || v == 0) {
      lengthBits = 40;
    } else if (v != 2 && v != 3) {
      throw const PdfCoreException(
        "This kind of protected PDF isn't supported",
      );
    }
    if (r < 2 || r > 6) {
      throw const PdfCoreException(
        "This kind of protected PDF isn't supported",
      );
    }

    if (r >= 5) {
      final oe = _bytes(res(enc['OE']));
      final ue = _bytes(res(enc['UE']));
      final pw = password ?? '';
      var pwb = utf8.encode(pw);
      if (pwb.length > 127) pwb = pwb.sublist(0, 127);
      if (o.length < 48 || u.length < 48) {
        throw const PdfCoreException('This PDF is damaged');
      }
      // owner first
      final u48 = u.sublist(0, 48);
      final ohash = _hashR56(r, pwb, o.sublist(32, 40), u48);
      if (_eq(ohash, o.sublist(0, 32))) {
        final k = _hashR56(r, pwb, o.sublist(40, 48), u48);
        final key = aesCbc(false, k, Uint8List(16), oe.sublist(0, 32));
        return SecurityHandler._(v, r, p, key, stm, str, encMeta, true);
      }
      final uhash = _hashR56(r, pwb, u.sublist(32, 40), const []);
      if (_eq(uhash, u.sublist(0, 32))) {
        final k = _hashR56(r, pwb, u.sublist(40, 48), const []);
        final key = aesCbc(false, k, Uint8List(16), ue.sublist(0, 32));
        return SecurityHandler._(v, r, p, key, stm, str, encMeta, false);
      }
      throw PdfPasswordException(wrongPassword: password != null);
    }

    final n = r == 2 ? 5 : (lengthBits ~/ 8).clamp(5, 16);
    final candidates = <List<int>>[];
    final pw = password ?? '';
    candidates.add(_pdfDocPassword(pw));
    final u8 = utf8.encode(pw);
    if (!_eq(u8, candidates.first)) candidates.add(u8);

    for (final cand in candidates) {
      // owner password → recover user password
      final userPw = _ownerToUser(r, n, cand, o);
      final key = _key(r, n, userPw, o, p, id0, encMeta);
      if (_checkUser(r, key, u, id0)) {
        return SecurityHandler._(v, r, p, key, stm, str, encMeta, true);
      }
    }
    for (final cand in candidates) {
      final key = _key(r, n, cand, o, p, id0, encMeta);
      if (_checkUser(r, key, u, id0)) {
        return SecurityHandler._(v, r, p, key, stm, str, encMeta, false);
      }
    }
    throw PdfPasswordException(wrongPassword: password != null);
  }

  PdfPermissions get permissions {
    if (isOwner) return PdfPermissions.all;
    bool bit(int b) => (p & (1 << (b - 1))) != 0;
    final modify = bit(4);
    final annotate = bit(6);
    final fill = r >= 3 ? (bit(9) || annotate) : annotate;
    return PdfPermissions(
      canModify: modify,
      canFillForms: fill,
      canAnnotate: annotate,
    );
  }

  Uint8List _objectKey(int num, int gen, CryptMethod m) {
    if (m == CryptMethod.aesv3) return key;
    final b = <int>[
      ...key,
      num & 0xff,
      (num >> 8) & 0xff,
      (num >> 16) & 0xff,
      gen & 0xff,
      (gen >> 8) & 0xff,
      if (m == CryptMethod.aesv2) ...[0x73, 0x41, 0x6c, 0x54],
    ];
    final h = md5(b);
    final len = min(key.length + 5, 16);
    return Uint8List.sublistView(h, 0, len);
  }

  Uint8List _decrypt(Uint8List data, int num, int gen, CryptMethod m) {
    switch (m) {
      case CryptMethod.identity:
        return data;
      case CryptMethod.rc4:
        return rc4(_objectKey(num, gen, m), data);
      case CryptMethod.aesv2:
      case CryptMethod.aesv3:
        return aesDecrypt(_objectKey(num, gen, m), data);
    }
  }

  Uint8List _encrypt(Uint8List data, int num, int gen, CryptMethod m) {
    switch (m) {
      case CryptMethod.identity:
        return data;
      case CryptMethod.rc4:
        return rc4(_objectKey(num, gen, m), data);
      case CryptMethod.aesv2:
      case CryptMethod.aesv3:
        return aesEncrypt(_objectKey(num, gen, m), data);
    }
  }

  Uint8List decryptString(Uint8List d, int num, int gen) =>
      _decrypt(d, num, gen, strMethod);
  Uint8List decryptStream(Uint8List d, int num, int gen) =>
      _decrypt(d, num, gen, stmMethod);
  Uint8List encryptString(Uint8List d, int num, int gen) =>
      _encrypt(d, num, gen, strMethod);
  Uint8List encryptStream(Uint8List d, int num, int gen) =>
      _encrypt(d, num, gen, stmMethod);

  // -------------------------------------------------------------------------

  static Uint8List _bytes(Object? o) => o is PdfString ? o.bytes : Uint8List(0);

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<int> _pdfDocPassword(String pw) {
    final out = <int>[];
    for (final r in pw.runes) {
      out.add(r < 256 ? r : 0x3f);
    }
    return out;
  }

  static List<int> _padPw(List<int> pw) {
    final out = <int>[...pw.take(32)];
    out.addAll(_pad.take(32 - out.length));
    return out;
  }

  /// Algorithm 2.
  static Uint8List _key(
    int r,
    int n,
    List<int> pw,
    Uint8List o,
    int p,
    Uint8List id0,
    bool encMeta,
  ) {
    final b = <int>[
      ..._padPw(pw),
      ...o.take(32),
      p & 0xff,
      (p >> 8) & 0xff,
      (p >> 16) & 0xff,
      (p >> 24) & 0xff,
      ...id0,
      if (r >= 4 && !encMeta) ...[0xff, 0xff, 0xff, 0xff],
    ];
    var h = md5(b);
    if (r >= 3) {
      for (var i = 0; i < 50; i++) {
        h = md5(Uint8List.sublistView(h, 0, n));
      }
    }
    return Uint8List.fromList(h.sublist(0, n));
  }

  /// Algorithm 4/5: computes /U for a key.
  static Uint8List computeU(int r, Uint8List key, Uint8List id0) {
    if (r == 2) return rc4(key, _pad);
    var x = rc4(key, md5([..._pad, ...id0]));
    for (var i = 1; i <= 19; i++) {
      x = rc4([for (final k in key) k ^ i], x);
    }
    return Uint8List.fromList([...x, ...List<int>.filled(16, 0)]);
  }

  static bool _checkUser(int r, Uint8List key, Uint8List u, Uint8List id0) {
    final cu = computeU(r, key, id0);
    if (r == 2) return u.length >= 32 && _eq(cu, u.sublist(0, 32));
    return u.length >= 16 && _eq(cu.sublist(0, 16), u.sublist(0, 16));
  }

  static Uint8List _ownerRc4Key(int r, int n, List<int> ownerPw) {
    var h = md5(_padPw(ownerPw));
    if (r >= 3) {
      for (var i = 0; i < 50; i++) {
        h = md5(h);
      }
    }
    return Uint8List.fromList(h.sublist(0, n));
  }

  static List<int> _ownerToUser(int r, int n, List<int> ownerPw, Uint8List o) {
    final k = _ownerRc4Key(r, n, ownerPw);
    final oo = o.length > 32 ? o.sublist(0, 32) : o;
    if (r == 2) return rc4(k, oo);
    var x = Uint8List.fromList(oo);
    for (var i = 19; i >= 0; i--) {
      x = rc4([for (final b in k) b ^ i], x);
    }
    return x;
  }

  /// Algorithm 3: computes /O (used by tests and fixture generation).
  static Uint8List computeO(int r, int n, List<int> ownerPw, List<int> userPw) {
    final k = _ownerRc4Key(r, n, ownerPw.isEmpty ? userPw : ownerPw);
    var x = rc4(k, _padPw(userPw));
    if (r >= 3) {
      for (var i = 1; i <= 19; i++) {
        x = rc4([for (final b in k) b ^ i], x);
      }
    }
    return x;
  }

  static Uint8List computeKey(
    int r,
    int n,
    List<int> userPw,
    Uint8List o,
    int p,
    Uint8List id0,
    bool encMeta,
  ) => _key(r, n, userPw, o, p, id0, encMeta);

  /// Algorithm 2.A/2.B hash for R5 (plain SHA-256) and R6.
  static Uint8List _hashR56(
    int r,
    List<int> pw,
    List<int> salt,
    List<int> udata,
  ) {
    var k = Uint8List.fromList(
      c.sha256.convert([...pw, ...salt, ...udata]).bytes,
    );
    if (r == 5) return k;
    var i = 0;
    while (true) {
      final unit = [...pw, ...k, ...udata];
      final k1 = Uint8List(unit.length * 64);
      for (var j = 0; j < 64; j++) {
        k1.setAll(j * unit.length, unit);
      }
      final e = aesCbc(true, k.sublist(0, 16), k.sublist(16, 32), k1);
      var sum = 0;
      for (var j = 0; j < 16; j++) {
        sum += e[j];
      }
      switch (sum % 3) {
        case 0:
          k = Uint8List.fromList(c.sha256.convert(e).bytes);
        case 1:
          k = Uint8List.fromList(c.sha384.convert(e).bytes);
        default:
          k = Uint8List.fromList(c.sha512.convert(e).bytes);
      }
      i++;
      if (i >= 64 && e[e.length - 1] <= i - 32) break;
    }
    return k.sublist(0, 32);
  }

  static Uint8List hashR56(
    int r,
    List<int> pw,
    List<int> salt,
    List<int> udata,
  ) => _hashR56(r, pw, salt, udata);
}
