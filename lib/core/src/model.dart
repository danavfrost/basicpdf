// Page tree and AcroForm model.

import '../pdf_core.dart';
import 'filters.dart';
import 'lexer.dart';
import 'objects.dart';
import 'text.dart';

/// Anything that can resolve references (the file, or an editor's view).
abstract class ObjectSource {
  Object? resolve(Object? o);
}

class PageModel {
  final int index;
  final PdfRef? ref;
  final PdfDict dict;
  final double x0, y0, x1, y1; // CropBox ∩ MediaBox, user space
  final int rotate; // 0, 90, 180, 270

  PageModel(
    this.index,
    this.ref,
    this.dict,
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.rotate,
  );

  double get w => x1 - x0;
  double get h => y1 - y0;
  double get displayWidth => rotate % 180 == 0 ? w : h;
  double get displayHeight => rotate % 180 == 0 ? h : w;

  PdfPageInfo get info => PdfPageInfo(index, displayWidth, displayHeight);

  (double, double) toDisplay(double x, double y) {
    final ux = x - x0, uy = y1 - y;
    switch (rotate) {
      case 90:
        return (h - uy, ux);
      case 180:
        return (w - ux, h - uy);
      case 270:
        return (uy, w - ux);
      default:
        return (ux, uy);
    }
  }

  (double, double) toUser(double dx, double dy) {
    double ux, uy;
    switch (rotate) {
      case 90:
        ux = dy;
        uy = h - dx;
      case 180:
        ux = w - dx;
        uy = h - dy;
      case 270:
        ux = w - dy;
        uy = dx;
      default:
        ux = dx;
        uy = dy;
    }
    return (ux + x0, y1 - uy);
  }

  /// User-space rect [llx, lly, urx, ury] → display rect.
  PdfRect rectToDisplay(List<double> r) {
    final (ax, ay) = toDisplay(r[0], r[1]);
    final (bx, by) = toDisplay(r[2], r[3]);
    final l = ax < bx ? ax : bx, t = ay < by ? ay : by;
    return PdfRect(l, t, (ax - bx).abs(), (ay - by).abs());
  }

  /// Display rect → normalised user-space rect [llx, lly, urx, ury].
  List<double> rectToUser(PdfRect r) {
    final (ax, ay) = toUser(r.left, r.top);
    final (bx, by) = toUser(r.right, r.bottom);
    return [
      ax < bx ? ax : bx,
      ay < by ? ay : by,
      ax > bx ? ax : bx,
      ay > by ? ay : by,
    ];
  }
}

List<double>? rectOf(Object? o) {
  if (o is! List || o.length < 4) return null;
  final v = [for (var i = 0; i < 4; i++) numValue(o[i]) ?? 0.0];
  return [
    v[0] < v[2] ? v[0] : v[2],
    v[1] < v[3] ? v[1] : v[3],
    v[0] > v[2] ? v[0] : v[2],
    v[1] > v[3] ? v[1] : v[3],
  ];
}

List<PageModel> loadPages(ObjectSource src, PdfDict catalog) {
  final pages = <PageModel>[];
  final visited = <int>{};
  void walk(Object? node, Object? media, Object? crop, Object? rot, int depth) {
    if (depth > 64) return;
    PdfRef? ref;
    if (node is PdfRef) {
      if (visited.contains(node.num)) return;
      visited.add(node.num);
      ref = node;
    }
    final d = src.resolve(node);
    if (d is! PdfDict) return;
    media = d['MediaBox'] ?? media;
    crop = d['CropBox'] ?? crop;
    rot = d['Rotate'] ?? rot;
    final kids = src.resolve(d['Kids']);
    final type = d.name('Type');
    if (type == 'Pages' || (type != 'Page' && kids is List)) {
      if (kids is List) {
        for (final k in kids) {
          walk(k, media, crop, rot, depth + 1);
        }
      }
      return;
    }
    final mb =
        rectOf(
          src.resolve(media) is List
              ? [for (final x in src.resolve(media) as List) src.resolve(x)]
              : null,
        ) ??
        [0.0, 0.0, 612.0, 792.0];
    var cb =
        rectOf(
          src.resolve(crop) is List
              ? [for (final x in src.resolve(crop) as List) src.resolve(x)]
              : null,
        ) ??
        mb;
    // intersect
    cb = [
      cb[0] > mb[0] ? cb[0] : mb[0],
      cb[1] > mb[1] ? cb[1] : mb[1],
      cb[2] < mb[2] ? cb[2] : mb[2],
      cb[3] < mb[3] ? cb[3] : mb[3],
    ];
    if (cb[2] <= cb[0] || cb[3] <= cb[1]) cb = mb;
    var r = (intValue(src.resolve(rot)) ?? 0) % 360;
    if (r < 0) r += 360;
    r = (r ~/ 90) * 90;
    pages.add(PageModel(pages.length, ref, d, cb[0], cb[1], cb[2], cb[3], r));
  }

  walk(catalog['Pages'], null, null, null, 0);
  return pages;
}

// ---------------------------------------------------------------------------
// Default appearance string

class DaInfo {
  final String? font;
  final double size;
  final String color; // e.g. "0 g"
  const DaInfo(this.font, this.size, this.color);
}

DaInfo parseDA(String da) {
  final lx = Lexer(PdfString.latin1(da).bytes);
  final ops = <Object?>[];
  String? font;
  var size = 0.0;
  var color = '0 g';
  while (true) {
    final t = lx.nextToken();
    if (t == null) break;
    if (t is PdfKeyword) {
      switch (t.word) {
        case 'Tf':
          if (ops.length >= 2 && ops[ops.length - 2] is PdfName) {
            font = (ops[ops.length - 2] as PdfName).name;
            size = numValue(ops.last) ?? 0;
          }
        case 'g':
          if (ops.isNotEmpty) color = '${_n(ops.last)} g';
        case 'rg':
          if (ops.length >= 3) {
            color =
                '${_n(ops[ops.length - 3])} ${_n(ops[ops.length - 2])} ${_n(ops.last)} rg';
          }
        case 'k':
          if (ops.length >= 4) {
            color =
                '${_n(ops[ops.length - 4])} ${_n(ops[ops.length - 3])} ${_n(ops[ops.length - 2])} ${_n(ops.last)} k';
          }
      }
      ops.clear();
    } else {
      ops.add(t);
    }
  }
  return DaInfo(font, size < 0 ? 0 : size, color);
}

String _n(Object? o) => formatNumber(numValue(o) ?? 0);

// ---------------------------------------------------------------------------
// Fields

const int ffReadOnly = 1;
const int ffRequired = 1 << 1;
const int ffMultiline = 1 << 12;
const int ffPassword = 1 << 13;
const int ffNoToggleToOff = 1 << 14;
const int ffRadio = 1 << 15;
const int ffPushbutton = 1 << 16;
const int ffCombo = 1 << 17;
const int ffDoNotScroll = 1 << 23;
const int ffComb = 1 << 24;

/// One widget annotation and the field it belongs to.
class WidgetEntry {
  /// Widget reference (null for a direct annotation dictionary).
  final PdfRef? ref;

  /// Terminal field → root field, as refs (or direct dicts).
  final List<Object> chain;

  /// True if the widget dict is also the terminal field dict.
  final bool merged;
  final int pageIndex;
  final String fullName;
  final String id;
  WidgetEntry(
    this.ref,
    this.chain,
    this.merged,
    this.pageIndex,
    this.fullName,
    this.id,
  );

  Object get fieldNode => chain.first;
}

/// Looks up an inheritable field attribute along [chain].
Object? inheritedAttr(ObjectSource src, List<Object> chain, String key) {
  for (final n in chain) {
    final d = src.resolve(n);
    if (d is PdfDict && d[key] != null) return src.resolve(d[key]);
  }
  return null;
}

PdfFieldKind fieldKind(String? ft, int ff) {
  switch (ft) {
    case 'Tx':
      return (ff & ffMultiline) != 0
          ? PdfFieldKind.multilineText
          : PdfFieldKind.text;
    case 'Btn':
      if ((ff & ffPushbutton) != 0) return PdfFieldKind.unknown;
      return (ff & ffRadio) != 0 ? PdfFieldKind.radio : PdfFieldKind.checkbox;
    case 'Ch':
      return (ff & ffCombo) != 0 ? PdfFieldKind.comboBox : PdfFieldKind.listBox;
    case 'Sig':
      return PdfFieldKind.signature;
  }
  return PdfFieldKind.unknown;
}

/// Non-Off appearance state names of a widget's /AP /N.
List<String> onStates(ObjectSource src, PdfDict widget) {
  final ap = src.resolve(widget['AP']);
  if (ap is! PdfDict) return const [];
  final n = src.resolve(ap['N']);
  if (n is! PdfDict) return const [];
  return [
    for (final k in n.keys)
      if (k != 'Off') k,
  ];
}

class FormModel {
  final List<WidgetEntry> widgets;
  final Map<String, WidgetEntry> byId;
  FormModel(this.widgets) : byId = {for (final w in widgets) w.id: w};
}

String widgetId(PdfRef? ref, int page, int idx) =>
    ref != null ? ref.id : 'p$page:$idx';

FormModel loadForm(ObjectSource src, PdfDict catalog, List<PageModel> pages) {
  // Map annotation object numbers to pages.
  final annotPage = <int, int>{};
  final pageByNum = <int, int>{};
  for (final p in pages) {
    if (p.ref != null) pageByNum[p.ref!.num] = p.index;
    final annots = src.resolve(p.dict['Annots']);
    if (annots is List) {
      for (final a in annots) {
        if (a is PdfRef) annotPage.putIfAbsent(a.num, () => p.index);
      }
    }
  }
  final widgets = <WidgetEntry>[];
  final seenWidgets = <int>{};
  final seenNodes = <int>{};

  int? pageOf(PdfRef ref, PdfDict w) {
    final pi = annotPage[ref.num];
    if (pi != null) return pi;
    final p = w['P'];
    if (p is PdfRef) return pageByNum[p.num];
    return null;
  }

  bool visible(PdfDict w) {
    final f = intValue(src.resolve(w['F'])) ?? 0;
    return (f & 2) == 0 && (f & 32) == 0;
  }

  void addWidget(
    PdfRef ref,
    PdfDict w,
    List<Object> chain,
    bool merged,
    String name,
  ) {
    if (seenWidgets.contains(ref.num)) return;
    seenWidgets.add(ref.num);
    final pi = pageOf(ref, w);
    if (pi == null || !visible(w)) return;
    widgets.add(WidgetEntry(ref, chain, merged, pi, name, ref.id));
  }

  void visit(Object node, List<Object> parents, String parentName, int depth) {
    if (depth > 32) return;
    if (node is PdfRef) {
      if (seenNodes.contains(node.num)) return;
      seenNodes.add(node.num);
    }
    final d = src.resolve(node);
    if (d is! PdfDict) return;
    final t = d['T'];
    final name = t == null
        ? parentName
        : (parentName.isEmpty
              ? textOf(src.resolve(t))
              : '$parentName.${textOf(src.resolve(t))}');
    final chain = [node, ...parents];
    final kids = src.resolve(d['Kids']);
    if (kids is List && kids.isNotEmpty) {
      for (final k in kids) {
        final kd = src.resolve(k);
        if (kd is! PdfDict) continue;
        final isField =
            kd['T'] != null ||
            kd['Kids'] != null ||
            kd['FT'] != null && kd.name('Subtype') != 'Widget';
        if (isField) {
          visit(k as Object, chain, name, depth + 1);
        } else if (k is PdfRef) {
          addWidget(k, kd, chain, false, name);
        }
      }
    } else if (node is PdfRef) {
      addWidget(node, d, chain, true, name);
    }
  }

  final acro = src.resolve(catalog['AcroForm']);
  var hasFields = false;
  if (acro is PdfDict) {
    final fields = src.resolve(acro['Fields']);
    if (fields is List) {
      for (final f in fields) {
        if (f != null) {
          hasFields = true;
          visit(f, const [], '', 0);
        }
      }
    }
  }
  if (!hasFields) {
    // Orphan widgets (no AcroForm): find them through page /Annots.
    for (final p in pages) {
      final annots = src.resolve(p.dict['Annots']);
      if (annots is! List) continue;
      for (final a in annots) {
        if (a is! PdfRef || seenWidgets.contains(a.num)) continue;
        final w = src.resolve(a);
        if (w is! PdfDict || w.name('Subtype') != 'Widget') continue;
        // build chain via /Parent
        final chain = <Object>[];
        Object? n = w['T'] != null || w['Parent'] == null ? a : w['Parent'];
        final merged = identical(n, a);
        var guard = 0;
        while (n != null && guard++ < 32) {
          chain.add(n);
          final nd = src.resolve(n);
          n = nd is PdfDict ? nd['Parent'] : null;
        }
        if (inheritedAttr(src, chain, 'FT') == null) continue;
        final names = <String>[];
        for (final c in chain.reversed) {
          final cd = src.resolve(c);
          if (cd is PdfDict && cd['T'] != null) {
            names.add(textOf(src.resolve(cd['T'])));
          }
        }
        addWidget(a, w, chain, merged, names.join('.'));
      }
    }
  }
  return FormModel(widgets);
}

/// Builds the public PdfField for a widget.
PdfField buildField(
  ObjectSource src,
  WidgetEntry e,
  PageModel page,
  PdfDict? acroForm,
) {
  final w = src.resolve(e.ref) as PdfDict;
  final ft = (inheritedAttr(src, e.chain, 'FT') as PdfName?)?.name;
  final ff = intValue(inheritedAttr(src, e.chain, 'Ff')) ?? 0;
  final kind = fieldKind(ft, ff);
  final rect =
      rectOf([
        for (final x in (src.resolve(w['Rect']) as List? ?? const []))
          src.resolve(x),
      ]) ??
      [0.0, 0.0, 0.0, 0.0];
  final v = inheritedAttr(src, e.chain, 'V');
  String value;
  String? onValue;
  switch (kind) {
    case PdfFieldKind.checkbox:
    case PdfFieldKind.radio:
      final states = onStates(src, w);
      onValue = states.isNotEmpty ? states.first : 'Yes';
      if (v is PdfName) {
        value = v.name;
      } else if (v is PdfString) {
        value = v.latin1Value;
      } else {
        final as = src.resolve(w['AS']);
        value = as is PdfName && as.name != 'Off' ? as.name : 'Off';
      }
      if (value.isEmpty) value = 'Off';
    case PdfFieldKind.comboBox:
    case PdfFieldKind.listBox:
      if (v is List) {
        value = v.isEmpty ? '' : textOf(src.resolve(v.first));
      } else {
        value = textOf(v);
      }
    default:
      value = textOf(v);
  }
  final options = <(String, String)>[];
  final opt = inheritedAttr(src, e.chain, 'Opt');
  if (opt is List &&
      (kind == PdfFieldKind.comboBox || kind == PdfFieldKind.listBox)) {
    for (final o in opt) {
      final r = src.resolve(o);
      if (r is List && r.length >= 2) {
        options.add((textOf(src.resolve(r[0])), textOf(src.resolve(r[1]))));
      } else if (r is List && r.length == 1) {
        final s = textOf(src.resolve(r[0]));
        options.add((s, s));
      } else {
        final s = textOf(r);
        options.add((s, s));
      }
    }
  }
  var da = inheritedAttr(src, e.chain, 'DA');
  if (da == null && acroForm != null) da = src.resolve(acroForm['DA']);
  final daInfo = parseDA(da is PdfString ? da.latin1Value : '');
  final maxLen = intValue(inheritedAttr(src, e.chain, 'MaxLen')) ?? 0;
  var mkRot = 0;
  final mk = src.resolve(w['MK']);
  if (mk is PdfDict) mkRot = intValue(src.resolve(mk['R'])) ?? 0;
  // /MK /R turns text counter-clockwise in user space; /Rotate turns the
  // page clockwise for display. Net clockwise angle on screen:
  var rotation = (page.rotate - mkRot) % 360;
  if (rotation < 0) rotation += 360;
  rotation = rotation ~/ 90 * 90;
  PdfCheckMark? checkMark;
  if (kind == PdfFieldKind.checkbox || kind == PdfFieldKind.radio) {
    try {
      checkMark = checkMarkOf(src, w, kind, onValue, daInfo, rect);
    } catch (_) {
      checkMark = null;
    }
  }
  return PdfField(
    checkMark: checkMark,
    rotation: rotation,
    id: e.id,
    fullName: e.fullName,
    kind: kind,
    pageIndex: e.pageIndex,
    rect: page.rectToDisplay(rect),
    value: value,
    onValue: onValue,
    options: options,
    readOnly: (ff & ffReadOnly) != 0,
    required: (ff & ffRequired) != 0,
    fontSize: daInfo.size,
    maxLength: maxLen < 0 ? 0 : maxLen,
  );
}

/// ZapfDingbats advance widths (1/1000 em) of the usual check glyphs.
double zapfAdvance(int code) {
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

final _tfRe = RegExp(r'/(\S+)\s+([-+\d.]+)\s+Tf');
final _tdRe = RegExp(r'([-+\d.]+)\s+([-+\d.]+)\s+Td');
final _tmRe = RegExp(
  r'[-+\d.]+\s+[-+\d.]+\s+[-+\d.]+\s+[-+\d.]+\s+([-+\d.]+)\s+([-+\d.]+)\s+Tm',
);
final _tjRe = RegExp(r'\((\\?.)\)\s*Tj');
final _colorRe = RegExp(
  r'(?:^|\s)((?:[-+\d.]+\s+){1,4})(g|rg|k)(?=\s)',
  multiLine: true,
);

int _argb(List<double> c, String op) {
  double r, g, b;
  if (op == 'g') {
    r = g = b = c[0];
  } else if (op == 'rg') {
    r = c[0];
    g = c[1];
    b = c[2];
  } else {
    final k = c[3];
    r = (1 - c[0]) * (1 - k);
    g = (1 - c[1]) * (1 - k);
    b = (1 - c[2]) * (1 - k);
  }
  int ch(double v) => (v.clamp(0.0, 1.0) * 255).round();
  return 0xFF000000 | ch(r) << 16 | ch(g) << 8 | ch(b);
}

int? _colorIn(String s) {
  int? out;
  for (final m in _colorRe.allMatches(s)) {
    final nums = [
      for (final t in m.group(1)!.trim().split(RegExp(r'\s+')))
        double.tryParse(t) ?? 0,
    ];
    final op = m.group(2)!;
    final need = op == 'g' ? 1 : (op == 'rg' ? 3 : 4);
    if (nums.length < need) continue;
    out = _argb(nums.sublist(nums.length - need), op);
  }
  return out;
}

/// The "on" mark of check widget [w]: read from its on-appearance when
/// that is a single ZapfDingbats glyph, else laid out from /MK /CA.
PdfCheckMark? checkMarkOf(
  ObjectSource src,
  PdfDict w,
  PdfFieldKind kind,
  String? onValue,
  DaInfo da,
  List<double> rect,
) {
  final mk = src.resolve(w['MK']);
  var rot = 0;
  var glyph = kind == PdfFieldKind.radio ? 'l' : '4';
  var border = 0.0;
  if (mk is PdfDict) {
    rot = ((intValue(src.resolve(mk['R'])) ?? 0) % 360 + 360) % 360 ~/ 90 * 90;
    final ca = src.resolve(mk['CA']);
    if (ca is PdfString && ca.latin1Value.isNotEmpty) {
      glyph = ca.latin1Value.substring(0, 1);
    }
    final bc = src.resolve(mk['BC']);
    if (bc is List && bc.isNotEmpty) {
      final bs = src.resolve(w['BS']);
      border = bs is PdfDict ? (numValue(src.resolve(bs['W'])) ?? 1) : 1;
    }
  }
  var w0 = rect[2] - rect[0], h0 = rect[3] - rect[1];
  if (rot == 90 || rot == 270) (w0, h0) = (h0, w0);
  final daColor = _colorIn(da.color) ?? 0xFF000000;

  // The PDF's own on-appearance, when it's one ZapfDingbats glyph.
  final ap = src.resolve(w['AP']);
  final n = ap is PdfDict ? src.resolve(ap['N']) : null;
  final on = n is PdfDict && onValue != null ? src.resolve(n[onValue]) : null;
  if (on is PdfStream) {
    final content = String.fromCharCodes(decodeStreamData(on.data, on.dict));
    final tf = _tfRe.firstMatch(content);
    final tj = _tjRe.firstMatch(content);
    final pos = _tdRe.firstMatch(content) ?? _tmRe.firstMatch(content);
    var zapf = false;
    if (tf != null) {
      final res = src.resolve(on.dict['Resources']);
      final fonts = res is PdfDict ? src.resolve(res['Font']) : null;
      final f = fonts is PdfDict ? src.resolve(fonts[tf.group(1)!]) : null;
      zapf = f is PdfDict
          ? f.name('BaseFont') == 'ZapfDingbats'
          : const {'ZaDb', 'ZapfDingbats'}.contains(tf.group(1));
    }
    if (zapf &&
        tj != null &&
        pos != null &&
        _tjRe.allMatches(content).length == 1) {
      final size = double.tryParse(tf!.group(2)!) ?? 0;
      var ch = tj.group(1)!;
      if (ch.length == 2) ch = ch.substring(1);
      final bbox = src.resolve(on.dict['BBox']);
      var bx = 0.0, by = 0.0, bh = h0;
      if (bbox is List && bbox.length == 4) {
        final b = [for (final x in bbox) numValue(src.resolve(x)) ?? 0];
        bx = b[0] < b[2] ? b[0] : b[2];
        by = b[1] < b[3] ? b[1] : b[3];
        bh = (b[3] - b[1]).abs();
      }
      final x = (double.tryParse(pos.group(1)!) ?? 0) - bx;
      final y = (double.tryParse(pos.group(2)!) ?? 0) - by;
      if (size > 0) {
        return PdfCheckMark(
          glyph: ch,
          size: size,
          x: x,
          y: bh - y,
          color: _colorIn(content.substring(0, tj.start)) ?? daColor,
        );
      }
    }
  }
  // As the core generates it (see checkAppearanceContent).
  final code = glyph.codeUnitAt(0) & 0xff;
  final gw = zapfAdvance(code) / 1000;
  var fs = da.size;
  if (fs <= 0) {
    final inner = (w0 < h0 ? w0 : h0) - 2 * border - 2;
    fs = inner * 0.8 / (gw > 0.8 ? gw : 0.8);
    if (fs < 1) fs = 1;
  }
  return PdfCheckMark(
    glyph: glyph,
    size: fs,
    x: (w0 - gw * fs) / 2,
    y: h0 - (h0 - 0.7 * fs) / 2,
    color: daColor,
  );
}
