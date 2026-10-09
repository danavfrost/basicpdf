// Appearance stream generation for widgets.

import 'dart:typed_data';

import 'objects.dart';
import 'text.dart';

String _f(num n) => formatNumber(n);

/// Colour operator from an /MK colour array ([] → null).
String? colorOp(Object? arr, {required bool stroke}) {
  if (arr is! List || arr.isEmpty) return null;
  final v = [for (final x in arr) _f(numValue(x) ?? 0)];
  switch (v.length) {
    case 1:
      return '${v[0]} ${stroke ? 'G' : 'g'}';
    case 3:
      return '${v.join(' ')} ${stroke ? 'RG' : 'rg'}';
    case 4:
      return '${v.join(' ')} ${stroke ? 'K' : 'k'}';
  }
  return null;
}

/// PDF literal string of WinAnsi-encoded [s] for use in content streams.
String pdfLiteral(String s) {
  final b = encodeWinAnsi(s);
  final sb = StringBuffer('(');
  for (final c in b) {
    if (c == 0x28 || c == 0x29 || c == 0x5c) {
      sb
        ..write('\\')
        ..writeCharCode(c);
    } else if (c < 0x20 || c > 0x7e) {
      sb.write('\\${c.toRadixString(8).padLeft(3, '0')}');
    } else {
      sb.writeCharCode(c);
    }
  }
  sb.write(')');
  return sb.toString();
}

/// Name token (with # escapes) for content streams.
String nameToken(String name) {
  final w = PdfWriterBuffer()..writeName(name);
  return String.fromCharCodes(w.takeBytes());
}

class WidgetLook {
  final double width, height; // /Rect size
  final int rotation; // /MK /R
  final String? background; // fill op
  final String? border; // stroke op
  final double borderWidth;
  final String borderStyle; // S, D, B, I, U
  const WidgetLook({
    required this.width,
    required this.height,
    this.rotation = 0,
    this.background,
    this.border,
    this.borderWidth = 1,
    this.borderStyle = 'S',
  });

  bool get swapped => rotation == 90 || rotation == 270;

  /// BBox width/height in form space (rotated orientation).
  double get bw => swapped ? height : width;
  double get bh => swapped ? width : height;
  double get effectiveBorder => border == null ? 0 : borderWidth;

  List<double>? get matrix {
    switch (rotation) {
      case 90:
        return [0, 1, -1, 0, width, 0];
      case 180:
        return [-1, 0, 0, -1, width, height];
      case 270:
        return [0, -1, 1, 0, 0, height];
    }
    return null;
  }

  String frame() {
    final sb = StringBuffer();
    final w = bw, h = bh;
    if (background != null) {
      sb.write('q $background 0 0 ${_f(w)} ${_f(h)} re f Q\n');
    }
    if (border != null && borderWidth > 0) {
      final b = borderWidth;
      sb.write('q $border ${_f(b)} w ');
      if (borderStyle == 'D') sb.write('[3] 0 d ');
      if (borderStyle == 'U') {
        sb.write('0 ${_f(b / 2)} m ${_f(w)} ${_f(b / 2)} l S Q\n');
      } else {
        sb.write(
          '${_f(b / 2)} ${_f(b / 2)} ${_f(w - b)} ${_f(h - b)} re S Q\n',
        );
      }
    }
    return sb.toString();
  }

  PdfStream formXObject(String content, PdfDict? resources) {
    final d = PdfDict({
      'Type': const PdfName('XObject'),
      'Subtype': const PdfName('Form'),
      'BBox': [0, 0, _r(bw), _r(bh)],
    });
    final m = matrix;
    if (m != null) d['Matrix'] = [for (final x in m) _r(x)];
    if (resources != null) d['Resources'] = resources;
    return PdfStream(d, Uint8List.fromList(content.codeUnits));
  }
}

num _r(double v) {
  final r = (v * 10000).round() / 10000;
  return r == r.roundToDouble() ? r.round() : r;
}

class TextLayoutSpec {
  final String fontName;
  final FontMetrics metrics;
  final double fontSize; // 0 = auto
  final String color;
  final int quadding;
  final bool multiline;
  final bool comb;
  final int maxLen;
  final bool password;
  const TextLayoutSpec({
    required this.fontName,
    required this.metrics,
    required this.fontSize,
    this.color = '0 g',
    this.quadding = 0,
    this.multiline = false,
    this.comb = false,
    this.maxLen = 0,
    this.password = false,
  });
}

const double lineHeightFactor = 1.2;

/// Space between the border and the text, left and right.
const double textPadding = 2;

/// Space between the border and the text, top and bottom of a multi-line
/// field (pdf.js uses 1 pt too).
const double textPaddingV = 1;

/// Auto-size single-line text: the font size is the inner box height
/// divided by this (pdf.js's line factor, without its extra 1 pt padding,
/// so the small boxes of dense forms stay readable), at most
/// [maxAutoFontSize], then shrunk to fit the width.
const double autoLineFactor = 1.35;
const double maxAutoFontSize = 12;
const double minAutoFontSize = 4;

/// Auto font size of single-line [text] in a box of form-space size
/// [w]×[h] with border [b] (see [autoLineFactor]).
double autoSingleLineSize(
  double w,
  double h,
  double b,
  String text,
  FontMetrics m, {
  int combCells = 0,
}) {
  var fs = (h - 2 * b) / autoLineFactor;
  if (fs > maxAutoFontSize) fs = maxAutoFontSize;
  if (combCells > 0) {
    final byW = (w / combCells - 1) / (m.codeWidth(0x57) / 1000); // 'W'
    if (byW < fs) fs = byW;
  } else {
    final tw = m.unitsWidth(text) / 1000;
    final innerW = textWidthFor(w, b);
    if (tw > 0 && innerW / tw < fs) fs = innerW / tw;
  }
  return fs < minAutoFontSize ? minAutoFontSize : fs;
}

/// Number of whole lines of [fontSize] text that fit in a multi-line box of
/// inner height [boxHeight] (form space) with border [border].
int linesThatFit(double boxHeight, double border, double fontSize) {
  final t = border + textPaddingV;
  final n = ((boxHeight - 2 * t) / (fontSize * lineHeightFactor) + 1e-6)
      .floor();
  return n < 0 ? 0 : n;
}

/// Inner text width of a box (wrapping width).
double textWidthFor(double boxWidth, double border) =>
    boxWidth - 2 * (border + textPadding);

/// How [textAppearanceContent] lays out [value]: the font size it uses
/// (auto size resolved) and whether every character ends up visible.
({bool fits, double fontSize}) textFitFor(
  WidgetLook look,
  TextLayoutSpec spec,
  String value,
) {
  final w = look.bw, h = look.bh;
  final b = look.effectiveBorder;
  final m = spec.metrics;
  final text = spec.password ? '*' * value.runes.length : value;
  final innerW = textWidthFor(w, b);
  double fs = spec.fontSize;
  if (spec.multiline) {
    List<LineRange> lines;
    if (fs <= 0) {
      fs = 12;
      while (true) {
        lines = wrapText(text, innerW, fs, m);
        if (fs <= 4 || lines.length <= linesThatFit(h, b, fs)) break;
        fs -= 0.5;
      }
    } else {
      lines = wrapText(text, innerW, fs, m);
    }
    if (text.isEmpty) return (fits: true, fontSize: fs);
    // Trailing empty lines draw nothing, so they can't be "lost".
    var used = lines.length;
    while (used > 0 && lines[used - 1].start == lines[used - 1].end) {
      used--;
    }
    return (fits: used <= linesThatFit(h, b, fs), fontSize: fs);
  }
  final flat = text.replaceAll(RegExp(r'\r\n|\r|\n'), ' ');
  final combCells = spec.comb && spec.maxLen > 0 ? spec.maxLen : 0;
  if (fs <= 0) {
    fs = autoSingleLineSize(w, h, b, flat, m, combCells: combCells);
  }
  if (combCells > 0) {
    return (fits: flat.runes.length <= combCells, fontSize: fs);
  }
  return (fits: m.width(flat, fs) <= innerW + 0.01, fontSize: fs);
}

/// Distance from the top of the box to the first line's baseline in the
/// appearance [textAppearanceContent] draws at font size [fs].
double firstBaselineFor(WidgetLook look, TextLayoutSpec spec, double fs) {
  final h = look.bh, b = look.effectiveBorder;
  if (spec.multiline) return b + textPaddingV + fs * 0.9;
  final m = spec.metrics;
  final asc = m.ascent / 1000, desc = m.descent / 1000;
  return h - ((h - (asc - desc) * fs) / 2 - desc * fs);
}

String textAppearanceContent(
  WidgetLook look,
  TextLayoutSpec spec,
  String value,
) {
  final w = look.bw, h = look.bh;
  final b = look.effectiveBorder;
  final m = spec.metrics;
  var text = spec.password ? '*' * value.runes.length : value;
  final sb = StringBuffer(look.frame());
  sb.write('/Tx BMC\nq\n');
  sb.write('${_f(b)} ${_f(b)} ${_f(w - 2 * b)} ${_f(h - 2 * b)} re W n\n');
  final innerW = textWidthFor(w, b);
  double fs = spec.fontSize;
  final asc = m.ascent / 1000, desc = m.descent / 1000;

  if (spec.multiline) {
    List<LineRange> lines;
    if (fs <= 0) {
      fs = 12;
      while (true) {
        lines = wrapText(text, innerW, fs, m);
        if (fs <= 4 || lines.length <= linesThatFit(h, b, fs)) break;
        fs -= 0.5;
      }
    } else {
      lines = wrapText(text, innerW, fs, m);
    }
    final lh = fs * lineHeightFactor;
    final top = h - b - textPaddingV;
    if (text.isNotEmpty) {
      sb.write('BT\n${nameToken(spec.fontName)} ${_f(fs)} Tf ${spec.color}\n');
      for (var i = 0; i < lines.length; i++) {
        final baseline = top - i * lh - fs * 0.9;
        if (baseline < -lh) break; // clipped anyway
        final s = text.substring(lines[i].start, lines[i].end);
        final tw = m.width(s, fs);
        final x = _alignX(spec.quadding, b + textPadding, innerW, tw);
        sb.write('1 0 0 1 ${_f(x)} ${_f(baseline)} Tm ${pdfLiteral(s)} Tj\n');
      }
      sb.write('ET\n');
    }
  } else {
    text = text.replaceAll(RegExp(r'\r\n|\r|\n'), ' ');
    final combCells = spec.comb && spec.maxLen > 0 ? spec.maxLen : 0;
    if (combCells > 0 && text.length > combCells) {
      text = text.substring(0, combCells);
    }
    if (fs <= 0) {
      fs = autoSingleLineSize(w, h, b, text, m, combCells: combCells);
    }
    final y = (h - (asc - desc) * fs) / 2 - desc * fs;
    if (text.isNotEmpty) {
      sb.write('BT\n${nameToken(spec.fontName)} ${_f(fs)} Tf ${spec.color}\n');
      if (combCells > 0) {
        final cell = w / combCells;
        var i = 0;
        for (final r in text.runes) {
          final ch = String.fromCharCode(r);
          final cw = m.width(ch, fs);
          final x = i * cell + (cell - cw) / 2;
          sb.write('1 0 0 1 ${_f(x)} ${_f(y)} Tm ${pdfLiteral(ch)} Tj\n');
          i++;
        }
      } else {
        final tw = m.width(text, fs);
        final x = _alignX(spec.quadding, b + textPadding, innerW, tw);
        sb.write('1 0 0 1 ${_f(x)} ${_f(y)} Tm ${pdfLiteral(text)} Tj\n');
      }
      sb.write('ET\n');
    }
  }
  sb.write('Q\nEMC\n');
  return sb.toString();
}

double _alignX(int q, double left, double innerW, double tw) {
  switch (q) {
    case 1:
      return left + (innerW - tw) / 2;
    case 2:
      return left + innerW - tw;
  }
  return left;
}

/// List box: options from [topIndex], selected ones highlighted.
String listBoxAppearanceContent(
  WidgetLook look,
  TextLayoutSpec spec,
  List<String> items,
  Set<int> selected,
  int topIndex,
) {
  final w = look.bw, h = look.bh;
  final b = look.effectiveBorder;
  final m = spec.metrics;
  final fs = spec.fontSize <= 0 ? 12.0 : spec.fontSize;
  final lh = fs * lineHeightFactor;
  final sb = StringBuffer(look.frame());
  sb.write('/Tx BMC\nq\n');
  sb.write('${_f(b)} ${_f(b)} ${_f(w - 2 * b)} ${_f(h - 2 * b)} re W n\n');
  final top = h - b - textPadding;
  final innerW = textWidthFor(w, b);
  for (var i = topIndex; i < items.length; i++) {
    final row = i - topIndex;
    final rowTop = top - row * lh;
    if (rowTop - lh < -lh) break;
    if (selected.contains(i)) {
      sb.write(
        '0.6 0.757 0.855 rg ${_f(b)} ${_f(rowTop - lh)} '
        '${_f(w - 2 * b)} ${_f(lh)} re f\n',
      );
    }
    final tw = m.width(items[i], fs);
    final x = _alignX(spec.quadding, b + textPadding, innerW, tw);
    sb.write(
      'BT ${nameToken(spec.fontName)} ${_f(fs)} Tf ${spec.color} '
      '1 0 0 1 ${_f(x)} ${_f(rowTop - fs * 0.9)} Tm '
      '${pdfLiteral(items[i])} Tj ET\n',
    );
  }
  sb.write('Q\nEMC\n');
  return sb.toString();
}

/// Check box / radio "on" appearance using a ZapfDingbats glyph.
String checkAppearanceContent(
  WidgetLook look,
  String zapfName, {
  required bool on,
  String glyph = '4',
  String color = '0 g',
  double size = 0,
}) {
  final sb = StringBuffer(look.frame());
  if (on) {
    final w = look.bw, h = look.bh;
    final b = look.effectiveBorder;
    final code = glyph.isEmpty ? 0x34 : glyph.codeUnitAt(0) & 0xff;
    final gw = _zapfWidth(code) / 1000;
    var fs = size;
    if (fs <= 0) {
      final inner = (w < h ? w : h) - 2 * b - 2;
      fs = inner * 0.8 / (gw > 0.8 ? gw : 0.8);
      if (fs < 1) fs = 1;
    }
    final x = (w - gw * fs) / 2;
    final y = (h - 0.7 * fs) / 2;
    final lit = code == 0x28 || code == 0x29 || code == 0x5c
        ? '(\\${String.fromCharCode(code)})'
        : '(${String.fromCharCode(code)})';
    sb.write(
      'q BT ${nameToken(zapfName)} ${_f(fs)} Tf $color ${_f(x)} ${_f(y)} Td '
      '$lit Tj ET Q\n',
    );
  }
  return sb.toString();
}

int _zapfWidth(int code) {
  switch (code) {
    case 0x34: // check
      return 760;
    case 0x6c: // filled circle
      return 791;
    case 0x6e: // square
      return 762;
    case 0x75: // diamond
      return 759;
    case 0x38: // cross
      return 838;
    case 0x48: // star
      return 816;
  }
  return 800;
}
