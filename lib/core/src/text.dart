// Text encodings (PDFDocEncoding, UTF-16, WinAnsi), Helvetica metrics,
// and word wrapping.

import 'dart:convert';
import 'dart:typed_data';

import 'filters.dart';
import 'objects.dart';

const Map<int, int> _pdfDocSpecial = {
  0x18: 0x02D8, 0x19: 0x02C7, 0x1A: 0x02C6, 0x1B: 0x02D9, //
  0x1C: 0x02DD, 0x1D: 0x02DB, 0x1E: 0x02DA, 0x1F: 0x02DC,
  0x80: 0x2022, 0x81: 0x2020, 0x82: 0x2021, 0x83: 0x2026,
  0x84: 0x2014, 0x85: 0x2013, 0x86: 0x0192, 0x87: 0x2044,
  0x88: 0x2039, 0x89: 0x203A, 0x8A: 0x2212, 0x8B: 0x2030,
  0x8C: 0x201E, 0x8D: 0x201C, 0x8E: 0x201D, 0x8F: 0x2018,
  0x90: 0x2019, 0x91: 0x201A, 0x92: 0x2122, 0x93: 0xFB01,
  0x94: 0xFB02, 0x95: 0x0141, 0x96: 0x0152, 0x97: 0x0160,
  0x98: 0x0178, 0x99: 0x017D, 0x9A: 0x0131, 0x9B: 0x0142,
  0x9C: 0x0153, 0x9D: 0x0161, 0x9E: 0x017E, 0xA0: 0x20AC,
};

/// Decodes a PDF text string (UTF-16BE/LE with BOM, UTF-8 with BOM, or
/// PDFDocEncoding).
String decodeTextString(Uint8List b) {
  if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
    final units = <int>[];
    for (var i = 2; i + 1 < b.length; i += 2) {
      units.add((b[i] << 8) | b[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
    final units = <int>[];
    for (var i = 2; i + 1 < b.length; i += 2) {
      units.add((b[i + 1] << 8) | b[i]);
    }
    return String.fromCharCodes(units);
  }
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
    return utf8.decode(b.sublist(3), allowMalformed: true);
  }
  final sb = StringBuffer();
  for (final c in b) {
    sb.writeCharCode(_pdfDocSpecial[c] ?? c);
  }
  return sb.toString();
}

String textOf(Object? o) {
  if (o is PdfString) return decodeTextString(o.bytes);
  if (o is PdfName) return o.name;
  if (o is PdfStream) {
    try {
      return decodeTextString(decodeStreamData(o.data, o.dict));
    } catch (_) {
      return '';
    }
  }
  if (o is num) return formatNumber(o);
  return '';
}

/// Encodes [s] as a PDF text string: PDFDocEncoding when possible,
/// otherwise UTF-16BE with BOM.
PdfString encodeTextString(String s) {
  final out = <int>[];
  var simple = true;
  for (final r in s.runes) {
    if ((r >= 0x20 && r < 0x7F) ||
        r == 0x0A ||
        r == 0x0D ||
        r == 0x09 ||
        (r >= 0xA1 && r <= 0xFF && r != 0xAD)) {
      out.add(r);
    } else {
      simple = false;
      break;
    }
  }
  if (simple) return PdfString(Uint8List.fromList(out));
  final u = <int>[0xFE, 0xFF];
  for (final cu in s.codeUnits) {
    u
      ..add(cu >> 8)
      ..add(cu & 0xff);
  }
  return PdfString(Uint8List.fromList(u));
}

const Map<int, int> _winAnsiSpecial = {
  0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, //
  0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A,
  0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92,
  0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
  0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C,
  0x017E: 0x9E, 0x0178: 0x9F,
};

/// WinAnsi code for a UTF-16 code unit, or -1 if not encodable.
int winAnsiCode(int cu) {
  if (cu >= 0x20 && cu < 0x7F) return cu;
  if (cu >= 0xA0 && cu <= 0xFF) return cu;
  if (cu == 0x09) return 0x20;
  return _winAnsiSpecial[cu] ?? -1;
}

/// True if every character of [s] (ignoring line breaks) can be drawn with
/// WinAnsi-encoded Helvetica.
bool canEncodeWinAnsi(String s) {
  for (final cu in s.codeUnits) {
    if (cu == 0x0A || cu == 0x0D) continue;
    if (winAnsiCode(cu) < 0) return false;
  }
  return true;
}

/// Encodes for a WinAnsi font; unencodable characters become '?'.
Uint8List encodeWinAnsi(String s) {
  final out = <int>[];
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final cu = units[i];
    if (cu >= 0xD800 && cu <= 0xDBFF && i + 1 < units.length) {
      final lo = units[i + 1];
      if (lo >= 0xDC00 && lo <= 0xDFFF) i++;
      out.add(0x3F);
      continue;
    }
    final c = winAnsiCode(cu);
    out.add(c < 0 ? 0x3F : c);
  }
  return Uint8List.fromList(out);
}

/// Helvetica glyph widths (1/1000 em) indexed by WinAnsi code (from the
/// Adobe Helvetica AFM).
const List<int> helveticaWidths = [
  // 0-31: control codes
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  // 32-47:  space ! " # $ % & ' ( ) * + , - . /
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278,
  278,
  // 48-63: 0-9 : ; < = > ?
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584,
  556,
  // 64-79: @ A-O
  1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722,
  778,
  // 80-95: P-Z [ \ ] ^ _
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469,
  556,
  // 96-111: ` a-o
  333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556,
  556,
  // 112-127: p-z { | } ~ (127 undefined)
  556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
  0,
  // 128-143: € _ ‚ ƒ „ … † ‡ ˆ ‰ Š ‹ Œ _ Ž _
  556, 0, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000, 0, 611, 0,
  // 144-159: _ ‘ ’ “ ” • – — ˜ ™ š › œ _ ž Ÿ
  0, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 0, 500, 667,
  // 160-175: nbsp ¡ ¢ £ ¤ ¥ ¦ § ¨ © ª « ¬ shy ® ¯
  278, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737,
  333,
  // 176-191: ° ± ² ³ ´ µ ¶ · ¸ ¹ º » ¼ ½ ¾ ¿
  400, 584, 333, 333, 333, 556, 537, 278, 333, 333, 365, 556, 834, 834, 834,
  611,
  // 192-207: À Á Â Ã Ä Å Æ Ç È É Ê Ë Ì Í Î Ï
  667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278,
  278,
  // 208-223: Ð Ñ Ò Ó Ô Õ Ö × Ø Ù Ú Û Ü Ý Þ ß
  722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667,
  611,
  // 224-239: à á â ã ä å æ ç è é ê ë ì í î ï
  556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278,
  278,
  // 240-255: ð ñ ò ó ô õ ö ÷ ø ù ú û ü ý þ ÿ
  556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556, 500, 556,
  500,
];

/// Font metrics used for layout.
class FontMetrics {
  final List<int>? widths; // null → fixed width
  final int fixedWidth;
  final double ascent; // in 1/1000 em
  final double descent; // negative
  const FontMetrics._(this.widths, this.fixedWidth, this.ascent, this.descent);

  static const helvetica = FontMetrics._(helveticaWidths, 0, 718, -207);
  static const courier = FontMetrics._(null, 600, 629, -157);
  static const zapf = FontMetrics._(null, 846, 820, -143);

  int codeWidth(int code) {
    final w = widths;
    if (w == null) return fixedWidth;
    final v = w[code & 0xff];
    return v == 0 ? 556 : v;
  }

  /// Width in 1/1000 em of a UTF-16 string as drawn (unencodable → '?').
  double unitsWidth(String s, [int start = 0, int? end]) {
    var t = 0.0;
    final e = end ?? s.length;
    for (var i = start; i < e; i++) {
      final cu = s.codeUnitAt(i);
      if (cu >= 0xDC00 && cu <= 0xDFFF) continue; // low surrogate
      final c = winAnsiCode(cu);
      t += codeWidth(c < 0 ? 0x3F : c);
    }
    return t;
  }

  double width(String s, double fontSize, [int start = 0, int? end]) =>
      unitsWidth(s, start, end) * fontSize / 1000;
}

class LineRange {
  final int start;
  final int end;
  const LineRange(this.start, this.end);
  @override
  String toString() => 'LineRange($start, $end)';
}

bool _isSpace(int cu) => cu == 0x20 || cu == 0x09;

bool _isDigit(int cu) => cu >= 0x30 && cu <= 0x39;

const _emDash = 0x2014;

/// Characters a line may not start with when the break would come right
/// before them (UAX #14 classes CL, CP, EX, IS, SY, QU, BA, HY, IN).
bool _noBreakBefore(int cu) {
  switch (cu) {
    case 0x29: // )
    case 0x5D: // ]
    case 0x7D: // }
    case 0x21: // !
    case 0x3F: // ?
    case 0x2C: // ,
    case 0x2E: // .
    case 0x3A: // :
    case 0x3B: // ;
    case 0x2F: // /
    case 0x2D: // -
    case 0x27: // '
    case 0x22: // "
    case 0x7C: // |
    case 0xAB: // «
    case 0xBB: // »
    case 0xAD: // soft hyphen
    case 0x2010: // hyphen
    case 0x2013: // en dash
    case 0x2018: // ‘
    case 0x2019: // ’
    case 0x201C: // “
    case 0x201D: // ”
    case 0x2026: // …
      return true;
  }
  return false;
}

/// Whether a line may break between t[i] and t[i + 1], both non-space
/// characters of the word starting at [ws]. Matches what Flutter's text
/// engine does for these characters (measured, ICU line breaking).
bool _breakAfter(String t, int ws, int i) {
  final c = t.codeUnitAt(i), n = t.codeUnitAt(i + 1);
  if (n == _emDash) {
    // A break is allowed before an em dash, except after an opening
    // bracket or quote, or another em dash.
    switch (c) {
      case 0x28: // (
      case 0x5B: // [
      case 0x7B: // {
      case 0x22: // "
      case 0x27: // '
      case 0xAB: // «
      case 0x2018: // ‘
      case 0x201C: // “
      case _emDash:
        return false;
    }
    return true;
  }
  if (_noBreakBefore(n)) return false;
  switch (c) {
    case 0x2D: // hyphen-minus: not at a word start, not before a digit
      return i > ws && !_isDigit(n);
    case 0x2010: // hyphen
    case 0x2013: // en dash
    case 0xAD: // soft hyphen
      return i > ws;
    case 0x2F: // slash: not inside a number like 1/2
      return !(_isDigit(n) && i > ws && _isDigit(t.codeUnitAt(i - 1)));
    case _emDash:
    case 0x21: // !
    case 0x3F: // ?
    case 0x7C: // |
    case 0x7D: // }
    case 0x2026: // …
      return true;
  }
  return false;
}

/// End of the unbreakable piece of a word that starts at [ws] (a word is a
/// run of non-space characters ending at or before [pe]).
int _pieceEnd(String t, int ws, int pe) {
  var i = ws;
  while (i < pe && !_isSpace(t.codeUnitAt(i))) {
    if (i + 1 < pe &&
        !_isSpace(t.codeUnitAt(i + 1)) &&
        _breakAfter(t, _wordStart(t, i), i)) {
      return i + 1;
    }
    i++;
  }
  return i;
}

int _wordStart(String t, int i) {
  while (i > 0 &&
      !_isSpace(t.codeUnitAt(i - 1)) &&
      t.codeUnitAt(i - 1) != 0x0A &&
      t.codeUnitAt(i - 1) != 0x0D) {
    i--;
  }
  return i;
}

/// Greedy word wrap of [text] into lines no wider than [maxWidth] points.
/// Explicit line breaks (\n, \r\n, \r) always break. Returned ranges index
/// into [text]; trailing spaces at soft breaks are excluded.
///
/// Lines break where Flutter's text engine (ICU, UAX #14) breaks them, so
/// the edit overlay wraps at the same words as the saved appearance: at
/// spaces, and also after hyphens, slashes and dashes inside a word (see
/// [_breakAfter]). A piece too wide for any line starts on the current line
/// and is split by characters.
List<LineRange> wrapText(
  String text,
  double maxWidth,
  double fontSize,
  FontMetrics m,
) {
  final lines = <LineRange>[];
  final maxUnits = fontSize <= 0 ? double.infinity : maxWidth * 1000 / fontSize;
  var ps = 0;
  final n = text.length;
  while (true) {
    // find paragraph end
    var pe = ps;
    while (pe < n &&
        text.codeUnitAt(pe) != 0x0A &&
        text.codeUnitAt(pe) != 0x0D) {
      pe++;
    }
    _wrapParagraph(text, ps, pe, maxUnits, m, lines);
    if (pe >= n) break;
    // skip line break
    if (text.codeUnitAt(pe) == 0x0D &&
        pe + 1 < n &&
        text.codeUnitAt(pe + 1) == 0x0A) {
      ps = pe + 2;
    } else {
      ps = pe + 1;
    }
  }
  return lines;
}

void _wrapParagraph(
  String t,
  int ps,
  int pe,
  double maxUnits,
  FontMetrics m,
  List<LineRange> out,
) {
  if (ps == pe) {
    out.add(LineRange(ps, ps));
    return;
  }
  var lineStart = ps;
  var lineEnd = ps; // end of last piece on line
  var lineUnits = 0.0;
  var hasWord = false;
  var pos = ps;
  var pendingSpaceStart = -1;
  while (pos < pe) {
    if (_isSpace(t.codeUnitAt(pos))) {
      pendingSpaceStart = pos;
      while (pos < pe && _isSpace(t.codeUnitAt(pos))) {
        pos++;
      }
      continue;
    }
    final ws = pos;
    pos = _pieceEnd(t, ws, pe);
    final we = pos;
    // width if appended to current line (including preceding spaces)
    final from = hasWord ? lineEnd : lineStart;
    final add = m.unitsWidth(t, from, we);
    if (lineUnits + add <= maxUnits) {
      lineUnits += add;
      lineEnd = we;
      hasWord = true;
    } else if (m.unitsWidth(t, ws, we) <= maxUnits) {
      // Next line.
      if (hasWord) out.add(LineRange(lineStart, lineEnd));
      lineStart = ws;
      lineEnd = we;
      lineUnits = m.unitsWidth(t, ws, we);
      hasWord = true;
    } else {
      // Too wide for any line: split it by characters. Like Flutter's
      // text engine, it starts on the current line if at least two of its
      // characters fit there, otherwise on the next line.
      var start = hasWord ? lineStart : ws;
      var cu = hasWord ? lineUnits + m.unitsWidth(t, lineEnd, ws) : 0.0;
      var i = ws;
      while (i < we) {
        var j = i, count = 0;
        while (j < we) {
          final step =
              (t.codeUnitAt(j) >= 0xD800 &&
                  t.codeUnitAt(j) <= 0xDBFF &&
                  j + 1 < we)
              ? 2
              : 1;
          final cw = m.unitsWidth(t, j, j + step);
          if (cu + cw > maxUnits && (j > i || start < i)) break;
          cu += cw;
          j += step;
          count++;
        }
        if (j < we && start < i && count < 2) {
          // Too little room after the words already on the line.
          out.add(LineRange(start, lineEnd));
          start = i;
          cu = 0;
          continue;
        }
        if (j >= we) {
          lineStart = start;
          lineEnd = we;
          lineUnits = cu;
          hasWord = true;
        } else {
          out.add(LineRange(start, j));
          start = j;
          cu = 0;
        }
        i = j;
      }
    }
    pendingSpaceStart = -1;
  }
  if (hasWord) {
    out.add(LineRange(lineStart, lineEnd));
  } else {
    // only spaces
    out.add(LineRange(ps, pendingSpaceStart >= 0 ? pe : ps));
  }
}
