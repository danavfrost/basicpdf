// Tokenizer / object parser for PDF syntax.

import 'dart:typed_data';

import 'objects.dart';

class PdfParseError implements Exception {
  final String message;
  final int offset;
  PdfParseError(this.message, this.offset);
  @override
  String toString() => 'PdfParseError($message @ $offset)';
}

bool isWhite(int c) =>
    c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09 || c == 0x0c || c == 0;

bool isDelimiter(int c) =>
    c == 0x28 ||
    c == 0x29 ||
    c == 0x3c ||
    c == 0x3e ||
    c == 0x5b ||
    c == 0x5d ||
    c == 0x7b ||
    c == 0x7d ||
    c == 0x2f ||
    c == 0x25;

int _hexVal(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x37;
  if (c >= 0x61 && c <= 0x66) return c - 0x57;
  return -1;
}

/// Resolves /Length references while parsing streams.
typedef LengthResolver = int? Function(Object? lengthValue);

class Lexer {
  final Uint8List data;
  int pos;
  final int end;
  Lexer(this.data, [this.pos = 0, int? end]) : end = end ?? data.length;

  bool get atEnd => pos >= end;

  int peekByte() => pos < end ? data[pos] : -1;

  void skipWhitespace() {
    while (pos < end) {
      final c = data[pos];
      if (isWhite(c)) {
        pos++;
      } else if (c == 0x25) {
        // comment
        while (pos < end && data[pos] != 0x0a && data[pos] != 0x0d) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  /// Reads the next token: a number, keyword, name, string, or one of the
  /// structural markers '[', ']', '<<', '>>'. Returns null at end.
  Object? nextToken() {
    skipWhitespace();
    if (pos >= end) return null;
    final c = data[pos];
    switch (c) {
      case 0x2f: // /
        return _readName();
      case 0x28: // (
        return _readLiteralString();
      case 0x3c: // <
        if (pos + 1 < end && data[pos + 1] == 0x3c) {
          pos += 2;
          return const _Marker('<<');
        }
        return _readHexString();
      case 0x3e: // >
        if (pos + 1 < end && data[pos + 1] == 0x3e) {
          pos += 2;
          return const _Marker('>>');
        }
        pos++;
        return const _Marker('>');
      case 0x5b:
        pos++;
        return const _Marker('[');
      case 0x5d:
        pos++;
        return const _Marker(']');
      case 0x7b:
        pos++;
        return const _Marker('{');
      case 0x7d:
        pos++;
        return const _Marker('}');
      case 0x29:
        pos++;
        return const _Marker(')');
    }
    if ((c >= 0x30 && c <= 0x39) || c == 0x2b || c == 0x2d || c == 0x2e) {
      final n = _readNumber();
      if (n != null) return n;
    }
    // keyword
    final start = pos;
    while (pos < end && !isWhite(data[pos]) && !isDelimiter(data[pos])) {
      pos++;
    }
    if (pos == start) {
      pos++;
      return PdfKeyword(String.fromCharCode(c));
    }
    final word = String.fromCharCodes(data, start, pos);
    switch (word) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null':
        return const PdfKeyword('null');
    }
    return PdfKeyword(word);
  }

  num? _readNumber() {
    final start = pos;
    var p = pos;
    var sawDigit = false;
    var sawDot = false;
    if (data[p] == 0x2b || data[p] == 0x2d) p++;
    // tolerate "--5" style doubled signs
    while (p < end && (data[p] == 0x2d || data[p] == 0x2b)) {
      p++;
    }
    while (p < end) {
      final c = data[p];
      if (c >= 0x30 && c <= 0x39) {
        sawDigit = true;
      } else if (c == 0x2e && !sawDot) {
        sawDot = true;
      } else {
        break;
      }
      p++;
    }
    if (!sawDigit) {
      if (sawDot || p > start) {
        // "-" or "." alone: treat as 0
        pos = p;
        return 0;
      }
      return null;
    }
    // a number must be followed by a delimiter/whitespace; otherwise it's a
    // keyword-ish token (e.g. "1abc"). Be lenient: just stop here.
    var s = String.fromCharCodes(data, start, p);
    pos = p;
    final neg = s.contains('-');
    s = s.replaceAll('+', '').replaceAll('-', '');
    if (!sawDot) {
      final v = int.tryParse(s);
      if (v != null) return neg ? -v : v;
      final d = double.tryParse(s) ?? 0.0;
      return neg ? -d : d;
    }
    if (s.startsWith('.')) s = '0$s';
    if (s.endsWith('.')) s = '${s}0';
    final d = double.tryParse(s) ?? 0.0;
    return neg ? -d : d;
  }

  PdfName _readName() {
    pos++; // '/'
    final out = <int>[];
    while (pos < end) {
      final c = data[pos];
      if (isWhite(c) || isDelimiter(c)) break;
      if (c == 0x23 && pos + 2 < end) {
        final h1 = _hexVal(data[pos + 1]), h2 = _hexVal(data[pos + 2]);
        if (h1 >= 0 && h2 >= 0) {
          out.add(h1 * 16 + h2);
          pos += 3;
          continue;
        }
      }
      out.add(c);
      pos++;
    }
    return PdfName(String.fromCharCodes(out));
  }

  PdfString _readLiteralString() {
    pos++; // '('
    final out = BytesBuilder(copy: false);
    final buf = <int>[];
    var depth = 1;
    while (pos < end) {
      var c = data[pos++];
      if (c == 0x28) {
        depth++;
        buf.add(c);
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        buf.add(c);
      } else if (c == 0x5c) {
        if (pos >= end) break;
        c = data[pos++];
        switch (c) {
          case 0x6e:
            buf.add(0x0a);
          case 0x72:
            buf.add(0x0d);
          case 0x74:
            buf.add(0x09);
          case 0x62:
            buf.add(0x08);
          case 0x66:
            buf.add(0x0c);
          case 0x0d:
            if (pos < end && data[pos] == 0x0a) pos++;
          case 0x0a:
            break;
          default:
            if (c >= 0x30 && c <= 0x37) {
              var v = c - 0x30;
              for (var i = 0; i < 2 && pos < end; i++) {
                final d = data[pos];
                if (d < 0x30 || d > 0x37) break;
                v = v * 8 + (d - 0x30);
                pos++;
              }
              buf.add(v & 0xff);
            } else {
              buf.add(c);
            }
        }
      } else if (c == 0x0d) {
        // EOL normalisation: CR or CRLF -> LF
        if (pos < end && data[pos] == 0x0a) pos++;
        buf.add(0x0a);
      } else {
        buf.add(c);
      }
    }
    out.add(buf);
    return PdfString(out.takeBytes());
  }

  PdfString _readHexString() {
    pos++; // '<'
    final out = <int>[];
    var hi = -1;
    while (pos < end) {
      final c = data[pos++];
      if (c == 0x3e) break;
      final v = _hexVal(c);
      if (v < 0) continue;
      if (hi < 0) {
        hi = v;
      } else {
        out.add(hi * 16 + v);
        hi = -1;
      }
    }
    if (hi >= 0) out.add(hi * 16);
    return PdfString(Uint8List.fromList(out), hex: true);
  }

  /// Parses one complete direct object (resolving "n g R" references).
  /// Returns a [PdfKeyword] for bare keywords.
  Object? parseObject({int depth = 0}) {
    if (depth > 200) throw PdfParseError('nesting too deep', pos);
    final t = nextToken();
    return _complete(t, depth);
  }

  Object? _complete(Object? t, int depth) {
    if (t is _Marker) {
      switch (t.s) {
        case '[':
          final list = <Object?>[];
          while (true) {
            skipWhitespace();
            if (pos >= end) break; // unterminated: be lenient
            if (data[pos] == 0x5d) {
              pos++;
              break;
            }
            final save = pos;
            final tok = nextToken();
            if (tok is PdfKeyword &&
                (tok.word == 'endobj' || tok.word == 'stream')) {
              pos = save;
              break;
            }
            if (tok is _Marker && (tok.s == '>>' || tok.s == '>')) {
              continue; // stray
            }
            final v = _completeWithRef(tok, depth + 1);
            if (v is PdfKeyword) {
              if (v.word == 'null') list.add(null);
            } else {
              list.add(v);
            }
          }
          return list;
        case '<<':
          final dict = PdfDict();
          while (true) {
            skipWhitespace();
            if (pos >= end) break;
            final save = pos;
            final tok = nextToken();
            if (tok is _Marker && tok.s == '>>') break;
            if (tok is PdfKeyword &&
                (tok.word == 'endobj' || tok.word == 'stream')) {
              pos = save;
              break;
            }
            if (tok is! PdfName) continue; // junk key: skip
            skipWhitespace();
            if (pos < end &&
                data[pos] == 0x3e &&
                pos + 1 < end &&
                data[pos + 1] == 0x3e) {
              // key without value
              continue;
            }
            final save2 = pos;
            final vt = nextToken();
            if (vt is _Marker && vt.s == '>>') {
              pos = save2;
              continue;
            }
            final v = _completeWithRef(vt, depth + 1);
            if (v is PdfKeyword) {
              if (v.word == 'endobj' || v.word == 'stream') {
                pos = save2;
                break;
              }
              continue; // null or junk → absent
            }
            dict[tok.name] = v;
          }
          return dict;
      }
      return null;
    }
    return t;
  }

  Object? _completeWithRef(Object? tok, int depth) {
    if (tok is int && tok >= 0) {
      // possible "n g R"
      final save = pos;
      final t2 = nextToken();
      if (t2 is int && t2 >= 0) {
        final t3 = nextToken();
        if (t3 is PdfKeyword && t3.word == 'R') return PdfRef(tok, t2);
      }
      pos = save;
      return tok;
    }
    return _complete(tok, depth);
  }

  /// Parses a top-level value, including "n g R".
  Object? parseValue() {
    final t = nextToken();
    return _completeWithRef(t, 0);
  }

  /// Checks whether the bytes at [p] equal [word].
  static bool matchAt(Uint8List data, int p, String word) {
    if (p < 0 || p + word.length > data.length) return false;
    for (var i = 0; i < word.length; i++) {
      if (data[p + i] != word.codeUnitAt(i)) return false;
    }
    return true;
  }
}

class _Marker {
  final String s;
  const _Marker(this.s);
}

/// Result of parsing "n g obj ... endobj".
class IndirectObject {
  final int num;
  final int gen;
  final Object? value;
  IndirectObject(this.num, this.gen, this.value);
}

int indexOf(Uint8List data, String word, int from, [int? end]) {
  final e = (end ?? data.length) - word.length;
  final first = word.codeUnitAt(0);
  outer:
  for (var i = from < 0 ? 0 : from; i <= e; i++) {
    if (data[i] != first) continue;
    for (var j = 1; j < word.length; j++) {
      if (data[i + j] != word.codeUnitAt(j)) continue outer;
    }
    return i;
  }
  return -1;
}

int lastIndexOf(Uint8List data, String word, int from, [int start = 0]) {
  var i = from;
  if (i > data.length - word.length) i = data.length - word.length;
  final first = word.codeUnitAt(0);
  outer:
  for (; i >= start; i--) {
    if (data[i] != first) continue;
    for (var j = 1; j < word.length; j++) {
      if (data[i + j] != word.codeUnitAt(j)) continue outer;
    }
    return i;
  }
  return -1;
}

/// Parses an indirect object at [offset]. [resolveLength] resolves an
/// indirect /Length. Throws [PdfParseError] when the bytes aren't an object.
IndirectObject parseIndirectObject(
  Uint8List data,
  int offset, {
  LengthResolver? resolveLength,
}) {
  final lx = Lexer(data, offset);
  final n = lx.nextToken();
  final g = lx.nextToken();
  final kw = lx.nextToken();
  if (n is! int || g is! int || kw is! PdfKeyword || kw.word != 'obj') {
    throw PdfParseError('not an object header', offset);
  }
  var value = lx.parseValue();
  if (value is PdfKeyword) {
    value = null; // "null" or junk
  }
  if (value is PdfDict) {
    final save = lx.pos;
    final t = lx.nextToken();
    if (t is PdfKeyword && t.word == 'stream') {
      value = PdfStream(
        value,
        readStreamData(data, lx.pos, value, resolveLength: resolveLength),
      );
    } else {
      lx.pos = save;
    }
  }
  return IndirectObject(n, g, value);
}

/// Reads stream data starting right after the 'stream' keyword at [p].
Uint8List readStreamData(
  Uint8List data,
  int p,
  PdfDict dict, {
  LengthResolver? resolveLength,
}) {
  // skip EOL after 'stream'
  if (p < data.length && data[p] == 0x0d) p++;
  if (p < data.length && data[p] == 0x0a) p++;
  final start = p;
  final lenObj = dict['Length'];
  int? len;
  if (lenObj is int) {
    len = lenObj;
  } else if (lenObj is PdfRef && resolveLength != null) {
    try {
      len = resolveLength(lenObj);
    } catch (_) {
      len = null;
    }
  }
  if (len != null && len >= 0 && start + len <= data.length) {
    // verify "endstream" follows
    var q = start + len;
    while (q < data.length && q < start + len + 64 && isWhite(data[q])) {
      q++;
    }
    if (Lexer.matchAt(data, q, 'endstream')) {
      return Uint8List.sublistView(data, start, start + len);
    }
  }
  // fall back to searching for endstream
  var e = indexOf(data, 'endstream', start);
  if (e < 0) {
    final eo = indexOf(data, 'endobj', start);
    e = eo < 0 ? data.length : eo;
  }
  var stop = e;
  if (stop > start && data[stop - 1] == 0x0a) stop--;
  if (stop > start && data[stop - 1] == 0x0d) stop--;
  return Uint8List.sublistView(data, start, stop);
}
