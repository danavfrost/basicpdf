// Applies PdfChanges to a document through an Editor.

import '../pdf_core.dart';
import 'appearance.dart';
import 'filters.dart';
import 'model.dart';
import 'objects.dart';
import 'pdf_file.dart';
import 'text.dart';
import 'writer.dart';

const _standardFamilies = ['Helvetica', 'Arial', 'Times', 'Courier'];

class FontChoice {
  final String name;
  final Object font; // PdfRef or direct dict
  final FontMetrics metrics;
  const FontChoice(this.name, this.font, this.metrics);
}

PdfDict helveticaFontDict() => PdfDict({
  'Type': const PdfName('Font'),
  'Subtype': const PdfName('Type1'),
  'BaseFont': const PdfName('Helvetica'),
  'Encoding': const PdfName('WinAnsiEncoding'),
});

PdfDict zapfFontDict() => PdfDict({
  'Type': const PdfName('Font'),
  'Subtype': const PdfName('Type1'),
  'BaseFont': const PdfName('ZapfDingbats'),
});

class EditSession {
  final PdfFile file;
  final Editor ed;
  final List<PageModel> pages;
  final FormModel form;
  late final PdfRef catalogRef;
  PdfRef? _newRoot;

  final Map<String, WidgetEntry> _regen = {};
  final Set<String> _deleted = {};
  final List<WidgetEntry> _added = [];
  final Set<String> _names = {};
  bool _valuesSet = false;
  FontChoice? _helv;
  FontChoice? _zapf;

  EditSession(this.file, this.pages, this.form) : ed = Editor(file) {
    final root = file.trailer['Root'];
    if (root is PdfRef) {
      catalogRef = root;
    } else {
      catalogRef = ed.add(deepCopy(file.resolve(root)) ?? PdfDict());
      _newRoot = catalogRef;
    }
    for (final w in form.widgets) {
      _names.add(w.fullName);
    }
  }

  PdfDict get _catalog => ed.resolve(catalogRef) as PdfDict;

  // -------------------------------------------------------------------------
  // AcroForm access

  PdfDict? get acroForm {
    final a = ed.resolve(_catalog['AcroForm']);
    return a is PdfDict ? a : null;
  }

  PdfDict mutableAcroForm() {
    final cat = _catalog;
    final v = cat['AcroForm'];
    if (v is PdfRef && ed.resolve(v) is PdfDict) {
      return ed.mutable(v) as PdfDict;
    }
    final mc = ed.mutable(catalogRef) as PdfDict;
    if (v is PdfDict) return mc['AcroForm'] as PdfDict;
    final fontRef = ed.add(helveticaFontDict());
    final ref = ed.add(
      PdfDict({
        'Fields': <Object?>[],
        'DR': PdfDict({
          'Font': PdfDict({'Helv': fontRef}),
        }),
        'DA': PdfString.latin1('/Helv 0 Tf 0 g'),
      }),
    );
    mc['AcroForm'] = ref;
    _helv ??= FontChoice('Helv', fontRef, FontMetrics.helvetica);
    return ed.resolve(ref) as PdfDict;
  }

  PdfDict? _drFonts() {
    final af = acroForm;
    if (af == null) return null;
    final dr = ed.resolve(af['DR']);
    if (dr is! PdfDict) return null;
    final f = ed.resolve(dr['Font']);
    return f is PdfDict ? f : null;
  }

  bool _isWinAnsiStandard(PdfDict f, List<String> families) {
    final sub = f.name('Subtype');
    if (sub != 'Type1' && sub != 'TrueType') return false;
    final base = f.name('BaseFont');
    if (base == null || base.contains('+')) return false;
    if (!families.any((fam) => base.startsWith(fam))) return false;
    final enc = ed.resolve(f['Encoding']);
    if (enc is PdfName) {
      if (enc.name != 'WinAnsiEncoding') return false;
    } else if (enc is PdfDict) {
      if (enc.name('BaseEncoding') != 'WinAnsiEncoding' ||
          enc['Differences'] != null) {
        return false;
      }
    } else {
      return false;
    }
    final fd = ed.resolve(f['FontDescriptor']);
    if (fd is PdfDict &&
        (fd['FontFile'] != null ||
            fd['FontFile2'] != null ||
            fd['FontFile3'] != null)) {
      return false;
    }
    return true;
  }

  /// A WinAnsi Helvetica in the AcroForm /DR (added if missing).
  FontChoice helvFont() {
    if (_helv != null) return _helv!;
    final fonts = _drFonts();
    if (fonts != null) {
      // prefer /Helv
      final names = [
        if (fonts['Helv'] != null) 'Helv',
        ...fonts.keys.where((k) => k != 'Helv'),
      ];
      for (final k in names) {
        final f = ed.resolve(fonts[k]);
        if (f is PdfDict &&
            f.name('BaseFont') == 'Helvetica' &&
            _isWinAnsiStandard(f, const ['Helvetica'])) {
          return _helv = FontChoice(k, fonts[k]!, FontMetrics.helvetica);
        }
      }
    }
    if (acroForm == null) {
      mutableAcroForm(); // creates /DR with Helvetica
      return _helv!;
    }
    final ref = ed.add(helveticaFontDict());
    final name = _addDrFont('Helv', ref);
    return _helv = FontChoice(name, ref, FontMetrics.helvetica);
  }

  FontChoice zapfFont() {
    if (_zapf != null) return _zapf!;
    final fonts = _drFonts();
    if (fonts != null) {
      for (final k in fonts.keys) {
        final f = ed.resolve(fonts[k]);
        if (f is PdfDict && f.name('BaseFont') == 'ZapfDingbats') {
          return _zapf = FontChoice(k, fonts[k]!, FontMetrics.zapf);
        }
      }
    }
    final ref = ed.add(zapfFontDict());
    final name = _addDrFont('ZaDb', ref);
    return _zapf = FontChoice(name, ref, FontMetrics.zapf);
  }

  String _addDrFont(String preferred, PdfRef ref) {
    final af = mutableAcroForm();
    final dr = ed.subDict(af, 'DR', create: true)!;
    final fonts = ed.subDict(dr, 'Font', create: true)!;
    var name = preferred;
    var i = 0;
    while (fonts[name] != null) {
      name = '$preferred${++i}';
    }
    fonts[name] = ref;
    return name;
  }

  FontChoice fontFor(DaInfo da) {
    final fname = da.font;
    if (fname != null) {
      final fonts = _drFonts();
      final fo = fonts?[fname];
      final f = ed.resolve(fo);
      if (f is PdfDict &&
          fo != null &&
          _isWinAnsiStandard(f, _standardFamilies)) {
        final base = f.name('BaseFont')!;
        return FontChoice(
          fname,
          fo,
          base.startsWith('Courier')
              ? FontMetrics.courier
              : FontMetrics.helvetica,
        );
      }
    }
    return helvFont();
  }

  // -------------------------------------------------------------------------

  /// Mutable array [key] of an object, rewriting only the array object
  /// when it is indirect.
  List<Object?> _arrayIn(
    PdfDict readOwner,
    PdfDict Function() mutableOwner,
    String key,
  ) {
    final v = readOwner[key];
    if (v is PdfRef && ed.resolve(v) is List) {
      return ed.mutable(v) as List<Object?>;
    }
    return ed.subList(mutableOwner(), key, create: true)!;
  }

  List<Object?> _fieldsArray() {
    final af = acroForm ?? mutableAcroForm();
    return _arrayIn(af, mutableAcroForm, 'Fields');
  }

  List<Object?> _annotsArray(PdfRef pageRef) => _arrayIn(
    ed.resolve(pageRef) as PdfDict,
    () => ed.mutable(pageRef) as PdfDict,
    'Annots',
  );

  WidgetEntry _entry(String id) {
    if (_deleted.contains(id)) {
      throw PdfCoreException('Field $id was deleted');
    }
    final e = form.byId[id];
    if (e == null) throw PdfCoreException('Field $id not found');
    return e;
  }

  bool _sameNode(Object a, Object b) {
    if (a is PdfRef && b is PdfRef) return a.num == b.num;
    return identical(a, b);
  }

  List<WidgetEntry> _widgetsOf(WidgetEntry e) => [
    for (final w in form.widgets)
      if (_sameNode(w.fieldNode, e.fieldNode) && !_deleted.contains(w.id)) w,
  ];

  PdfDict _mutableNode(Object node) {
    if (node is PdfRef) return ed.mutable(node) as PdfDict;
    return node as PdfDict; // direct (not persisted)
  }

  PdfFieldKind _kind(List<Object> chain) {
    final ft = inheritedAttr(ed, chain, 'FT');
    final ff = intValue(inheritedAttr(ed, chain, 'Ff')) ?? 0;
    return fieldKind(ft is PdfName ? ft.name : null, ff);
  }

  void apply(PdfChange c) {
    switch (c) {
      case SetFieldValue():
        _setValue(c);
      case AddField():
        _addField(c);
      case MoveField():
        _move(c);
      case SetMultiline():
        _setMultiline(c);
      case DeleteField():
        _delete(c);
    }
  }

  void _setValue(SetFieldValue c) {
    final e = _entry(c.fieldId);
    final kind = _kind(e.chain);
    switch (kind) {
      case PdfFieldKind.text:
      case PdfFieldKind.multilineText:
        var v = c.value;
        final maxLen = intValue(inheritedAttr(ed, e.chain, 'MaxLen')) ?? 0;
        if (maxLen > 0 && v.runes.length > maxLen) {
          v = String.fromCharCodes(v.runes.take(maxLen));
        }
        final f = _mutableNode(e.fieldNode);
        f['V'] = encodeTextString(v);
        f.remove('RV');
        for (final w in _widgetsOf(e)) {
          _regen[w.id] = w;
        }
      case PdfFieldKind.comboBox:
      case PdfFieldKind.listBox:
        final f = _mutableNode(e.fieldNode);
        f['V'] = encodeTextString(c.value);
        if (kind == PdfFieldKind.listBox) {
          final opts = _options(e.chain);
          final i = opts.indexWhere((o) => o.$1 == c.value);
          if (i >= 0) {
            f['I'] = [i];
          } else {
            f.remove('I');
          }
        }
        f.remove('RV');
        for (final w in _widgetsOf(e)) {
          _regen[w.id] = w;
        }
      case PdfFieldKind.checkbox:
      case PdfFieldKind.radio:
        var value = c.value.isEmpty ? 'Off' : c.value;
        if (kind == PdfFieldKind.checkbox && value != 'Off') {
          // Map a generic "on" request to the widget's actual on-state.
          final own = onStates(ed, ed.resolve(e.ref) as PdfDict);
          if (own.isNotEmpty && !own.contains(value)) value = own.first;
        }
        final f = _mutableNode(e.fieldNode);
        f['V'] = PdfName(value);
        for (final w in _widgetsOf(e)) {
          final wd = ed.mutable(w.ref!) as PdfDict;
          var states = onStates(ed, wd);
          if (states.isEmpty) {
            // no appearance: create one so the state is visible
            _makeCheckAppearance(
              wd,
              value == 'Off' ? 'Yes' : value,
              radio: kind == PdfFieldKind.radio,
            );
            states = onStates(ed, wd);
          }
          wd['AS'] = PdfName(states.contains(value) ? value : 'Off');
        }
      case PdfFieldKind.signature:
      case PdfFieldKind.unknown:
        return;
    }
    _valuesSet = true;
  }

  List<(String, String)> _options(List<Object> chain) {
    final opt = inheritedAttr(ed, chain, 'Opt');
    final out = <(String, String)>[];
    if (opt is List) {
      for (final o in opt) {
        final r = ed.resolve(o);
        if (r is List && r.length >= 2) {
          out.add((textOf(ed.resolve(r[0])), textOf(ed.resolve(r[1]))));
        } else if (r is List && r.isNotEmpty) {
          final s = textOf(ed.resolve(r[0]));
          out.add((s, s));
        } else {
          final s = textOf(r);
          out.add((s, s));
        }
      }
    }
    return out;
  }

  String _autoName(PdfFieldKind kind) {
    final prefix = kind == PdfFieldKind.checkbox ? 'Check' : 'Text';
    var i = 1;
    while (_names.contains('$prefix$i')) {
      i++;
    }
    return '$prefix$i';
  }

  void _addField(AddField c) {
    if (c.kind != PdfFieldKind.text &&
        c.kind != PdfFieldKind.multilineText &&
        c.kind != PdfFieldKind.checkbox) {
      throw const PdfCoreException("That kind of field can't be added");
    }
    if (c.pageIndex < 0 || c.pageIndex >= pages.length) {
      throw const PdfCoreException('No such page');
    }
    final page = pages[c.pageIndex];
    final pageRef = page.ref;
    if (pageRef == null) {
      throw const PdfCoreException("Fields can't be added to this page");
    }
    var name = c.name ?? _autoName(c.kind);
    if (name.isEmpty) name = _autoName(c.kind);
    _names.add(name);
    final r = page.rectToUser(c.rect);
    final d = PdfDict({
      'Type': const PdfName('Annot'),
      'Subtype': const PdfName('Widget'),
      'Rect': [for (final x in r) _round(x)],
      'F': 4,
      'P': pageRef,
      'T': encodeTextString(name),
    });
    final mk = PdfDict({
      'BC': [0.5, 0.5, 0.5],
    });
    if (page.rotate != 0) mk['R'] = page.rotate;
    d['MK'] = mk;
    d['BS'] = PdfDict({'W': 1, 'S': const PdfName('S')});
    if (c.kind == PdfFieldKind.checkbox) {
      final zapf = zapfFont();
      d['FT'] = const PdfName('Btn');
      d['DA'] = PdfString.latin1('/${zapf.name} 0 Tf 0 g');
      mk['CA'] = PdfString.latin1('4');
      final on = c.value.isNotEmpty && c.value != 'Off';
      d['V'] = PdfName(on ? 'Yes' : 'Off');
      d['AS'] = PdfName(on ? 'Yes' : 'Off');
      _makeCheckAppearance(d, 'Yes', radio: false);
    } else {
      final helv = helvFont();
      d['FT'] = const PdfName('Tx');
      if (c.kind == PdfFieldKind.multilineText) d['Ff'] = ffMultiline;
      d['DA'] = PdfString.latin1('/${helv.name} 0 Tf 0 g');
      if (c.value.isNotEmpty) d['V'] = encodeTextString(c.value);
    }
    final ref = ed.add(d);
    _annotsArray(pageRef).add(ref);
    _fieldsArray().add(ref);
    final entry = WidgetEntry(ref, [ref], true, c.pageIndex, name, ref.id);
    _added.add(entry);
    if (c.kind != PdfFieldKind.checkbox) _regen[entry.id] = entry;
  }

  num _round(double v) {
    final r = (v * 1000).round() / 1000;
    return r == r.roundToDouble() ? r.round() : r;
  }

  void _move(MoveField c) {
    final e = _entry(c.fieldId);
    final page = pages[e.pageIndex];
    final r = page.rectToUser(c.rect);
    final wd = ed.mutable(e.ref!) as PdfDict;
    wd['Rect'] = [for (final x in r) _round(x)];
    final kind = _kind(e.chain);
    if (kind == PdfFieldKind.text ||
        kind == PdfFieldKind.multilineText ||
        kind == PdfFieldKind.comboBox ||
        kind == PdfFieldKind.listBox) {
      _regen[e.id] = e;
    }
  }

  void _setMultiline(SetMultiline c) {
    final e = _entry(c.fieldId);
    final kind = _kind(e.chain);
    if (kind != PdfFieldKind.text && kind != PdfFieldKind.multilineText) return;
    var ff = intValue(inheritedAttr(ed, e.chain, 'Ff')) ?? 0;
    ff = c.multiline ? (ff | ffMultiline) : (ff & ~ffMultiline);
    if (c.multiline) ff &= ~ffComb;
    _mutableNode(e.fieldNode)['Ff'] = ff;
    for (final w in _widgetsOf(e)) {
      _regen[w.id] = w;
    }
  }

  void _delete(DeleteField c) {
    final e = _entry(c.fieldId);
    final ref = e.ref!;
    _deleted.add(e.id);
    _regen.remove(e.id);
    // page /Annots
    final page = pages[e.pageIndex];
    if (page.ref != null) {
      final pd = ed.resolve(page.ref) as PdfDict;
      final annots = ed.resolve(pd['Annots']);
      if (annots is List &&
          annots.any((a) => a is PdfRef && a.num == ref.num)) {
        _annotsArray(page.ref!)
            .removeWhere((a) => a is PdfRef && a.num == ref.num);
      }
    }
    if (e.merged) {
      _removeNode(ref, e.chain.length > 1 ? e.chain[1] : null);
    } else {
      final parent = e.fieldNode;
      final pm = _mutableNode(parent);
      final kids = ed.subList(pm, 'Kids');
      kids?.removeWhere((k) => k is PdfRef && k.num == ref.num);
      if (kids == null || kids.isEmpty) {
        _removeNode(parent, e.chain.length > 1 ? e.chain[1] : null);
      }
    }
  }

  /// Removes field [node] from [parent]'s /Kids (or AcroForm /Fields),
  /// cascading upward when a parent becomes empty.
  void _removeNode(Object node, Object? parent) {
    bool same(Object? k) => k != null && _sameNode(k, node);
    final af = acroForm;
    if (af != null) {
      final co = ed.resolve(af['CO']);
      if (co is List && co.any(same)) {
        _arrayIn(af, mutableAcroForm, 'CO').removeWhere(same);
      }
    }
    if (parent == null) {
      if (af == null) return;
      final fields = ed.resolve(af['Fields']);
      if (fields is List && fields.any(same)) {
        _fieldsArray().removeWhere(same);
      }
      return;
    }
    final pm = _mutableNode(parent);
    final kids = ed.subList(pm, 'Kids');
    kids?.removeWhere(same);
    if (kids == null || kids.isEmpty) {
      // find grandparent via /Parent
      final gp = pm['Parent'];
      _removeNode(parent, gp);
    }
  }

  // -------------------------------------------------------------------------
  // appearances

  WidgetLook _look(PdfDict w) {
    final rect =
        rectOf([
          for (final x in (ed.resolve(w['Rect']) as List? ?? const []))
            ed.resolve(x),
        ]) ??
        [0.0, 0.0, 0.0, 0.0];
    final mk = ed.resolve(w['MK']);
    var rot = 0;
    String? bg, bc;
    if (mk is PdfDict) {
      rot = (intValue(ed.resolve(mk['R'])) ?? 0) % 360;
      if (rot < 0) rot += 360;
      rot = rot ~/ 90 * 90;
      bg = colorOp(ed.resolve(mk['BG']), stroke: false);
      bc = colorOp(ed.resolve(mk['BC']), stroke: true);
    }
    var bw = 1.0;
    var style = 'S';
    final bs = ed.resolve(w['BS']);
    if (bs is PdfDict) {
      bw = numValue(ed.resolve(bs['W'])) ?? 1;
      style = bs.name('S') ?? 'S';
    } else {
      final border = ed.resolve(w['Border']);
      if (border is List && border.length >= 3) {
        bw = numValue(ed.resolve(border[2])) ?? 1;
      }
    }
    return WidgetLook(
      width: rect[2] - rect[0],
      height: rect[3] - rect[1],
      rotation: rot,
      background: bg,
      border: bc,
      borderWidth: bw,
      borderStyle: style,
    );
  }

  void _makeCheckAppearance(PdfDict wd, String onName, {required bool radio}) {
    final zapf = zapfFont();
    final look = _look(wd);
    final mk = ed.resolve(wd['MK']);
    var glyph = radio ? 'l' : '4';
    if (mk is PdfDict && ed.resolve(mk['CA']) is PdfString) {
      final s = (ed.resolve(mk['CA']) as PdfString).latin1Value;
      if (s.isNotEmpty) glyph = s;
    }
    var da = wd['DA'];
    final daInfo = parseDA(da is PdfString ? da.latin1Value : '');
    final res = PdfDict({
      'Font': PdfDict({zapf.name: zapf.font}),
    });
    final onStream = look.formXObject(
      checkAppearanceContent(
        look,
        zapf.name,
        on: true,
        glyph: glyph,
        color: daInfo.color,
        size: daInfo.size,
      ),
      res,
    );
    final offStream = look.formXObject(
      checkAppearanceContent(look, zapf.name, on: false),
      null,
    );
    wd['AP'] = PdfDict({
      'N': PdfDict({onName: ed.add(onStream), 'Off': ed.add(offStream)}),
    });
  }

  /// The look and text layout the appearance of text widget [id] uses, or
  /// null if it isn't a text field. Doesn't modify the document.
  ({WidgetLook look, TextLayoutSpec spec})? textLayoutOf(String id) {
    final e = form.byId[id];
    if (e == null || _deleted.contains(id)) return null;
    final kind = _kind(e.chain);
    if (kind != PdfFieldKind.text && kind != PdfFieldKind.multilineText) {
      return null;
    }
    final wd = e.ref != null ? ed.resolve(e.ref) : ed.resolve(e.chain.first);
    if (wd is! PdfDict) return null;
    final (look, spec, _) = _textLayout(e, wd, kind);
    return (look: look, spec: spec);
  }

  (WidgetLook, TextLayoutSpec, FontChoice) _textLayout(
    WidgetEntry e,
    PdfDict wd,
    PdfFieldKind kind,
  ) {
    final chain = e.chain;
    final ff = intValue(inheritedAttr(ed, chain, 'Ff')) ?? 0;
    var da = inheritedAttr(ed, chain, 'DA');
    da ??= ed.resolve(acroForm?['DA']);
    final daInfo = parseDA(da is PdfString ? da.latin1Value : '');
    final font = fontFor(daInfo);
    final q = intValue(inheritedAttr(ed, chain, 'Q')) ?? 0;
    final maxLen = intValue(inheritedAttr(ed, chain, 'MaxLen')) ?? 0;
    final look = _look(wd);
    final spec = TextLayoutSpec(
      fontName: font.name,
      metrics: font.metrics,
      fontSize: daInfo.size,
      color: daInfo.color,
      quadding: q,
      multiline: kind == PdfFieldKind.multilineText,
      comb:
          kind == PdfFieldKind.text &&
          (ff & ffComb) != 0 &&
          (ff & (ffMultiline | ffPassword)) == 0,
      maxLen: maxLen,
      password: kind == PdfFieldKind.text && (ff & ffPassword) != 0,
    );
    return (look, spec, font);
  }

  void _regenerate(WidgetEntry e, {String? textOverride}) {
    final ref = e.ref;
    if (ref == null) return;
    final wd = ed.mutable(ref) as PdfDict;
    final chain = e.chain;
    final kind = _kind(chain);
    if (kind != PdfFieldKind.text &&
        kind != PdfFieldKind.multilineText &&
        kind != PdfFieldKind.comboBox &&
        kind != PdfFieldKind.listBox) {
      return;
    }
    final (look, spec, font) = _textLayout(e, wd, kind);
    final v = inheritedAttr(ed, chain, 'V');
    String content;
    if (kind == PdfFieldKind.listBox) {
      final opts = _options(chain);
      final values = <String>{};
      if (v is List) {
        for (final x in v) {
          values.add(textOf(ed.resolve(x)));
        }
      } else if (v != null) {
        values.add(textOf(v));
      }
      final sel = <int>{};
      for (var i = 0; i < opts.length; i++) {
        if (values.contains(opts[i].$1)) sel.add(i);
      }
      final ti = intValue(inheritedAttr(ed, chain, 'TI')) ?? 0;
      content = listBoxAppearanceContent(
        look,
        spec,
        [for (final o in opts) o.$2],
        sel,
        ti < 0 ? 0 : ti,
      );
    } else {
      var text =
          textOverride ??
          (v is List
              ? (v.isEmpty ? '' : textOf(ed.resolve(v.first)))
              : textOf(v));
      if (kind == PdfFieldKind.comboBox) {
        for (final o in _options(chain)) {
          if (o.$1 == text) {
            text = o.$2;
            break;
          }
        }
      }
      content = textAppearanceContent(look, spec, text);
    }
    final res = PdfDict({
      'Font': PdfDict({font.name: font.font}),
    });
    final stream = look.formXObject(content, res);
    wd['AP'] = PdfDict({'N': ed.add(compressStream(stream))});
  }

  /// Finishes the update and returns the new file bytes.
  List<int> finish() {
    for (final e in _regen.values) {
      if (!_deleted.contains(e.id)) _regenerate(e);
    }
    // Checkboxes without an off appearance get an empty one, so viewers
    // built on PDFium (Chrome, Android) don't frame them in grey.
    for (final w in form.widgets) {
      if (w.ref == null || _deleted.contains(w.id)) continue;
      final k = _kind(w.chain);
      if (k == PdfFieldKind.checkbox || k == PdfFieldKind.radio) {
        _addEmptyOffAppearance(w);
      }
    }
    final af = acroForm;
    if (af != null) {
      if (ed.resolve(af['NeedAppearances']) == true) {
        var allHave = true;
        for (final w in [...form.widgets, ..._added]) {
          if (_deleted.contains(w.id) || w.ref == null) continue;
          final kind = _kind(w.chain);
          final wd = ed.resolve(w.ref) as PdfDict;
          final hasAp = ed.resolve(wd['AP']) is PdfDict;
          if (!_regen.containsKey(w.id)) {
            switch (kind) {
              case PdfFieldKind.text:
              case PdfFieldKind.multilineText:
              case PdfFieldKind.comboBox:
              case PdfFieldKind.listBox:
                _regenerate(w);
                continue;
              case PdfFieldKind.checkbox:
              case PdfFieldKind.radio:
                _ensureCheckAppearance(w, wd, kind);
                continue;
              default:
                if (!hasAp) allHave = false;
            }
          }
        }
        if (allHave) mutableAcroForm()['NeedAppearances'] = false;
      }
      if (_valuesSet && af['XFA'] != null) {
        mutableAcroForm().remove('XFA');
        if (_catalog['NeedsRendering'] != null) {
          (ed.mutable(catalogRef) as PdfDict).remove('NeedsRendering');
        }
      }
    }
    final override = _newRoot != null ? PdfDict({'Root': _newRoot}) : null;
    return ed.write(trailerOverride: override);
  }

  /// Creates missing on/off appearances (and a missing /AS) for a check box
  /// or radio widget. Returns true if anything changed.
  bool _ensureCheckAppearance(WidgetEntry w, PdfDict wd, PdfFieldKind kind) {
    final v = inheritedAttr(ed, w.chain, 'V');
    if (onStates(ed, wd).isEmpty) {
      final mw = ed.mutable(w.ref!) as PdfDict;
      final as = ed.resolve(mw['AS']);
      var on = 'Yes';
      if (as is PdfName && as.name != 'Off') on = as.name;
      if (v is PdfName && v.name != 'Off' && kind == PdfFieldKind.checkbox) {
        on = v.name;
      }
      _makeCheckAppearance(mw, on, radio: kind == PdfFieldKind.radio);
      mw['AS'] = PdfName(v is PdfName && v.name == on ? on : 'Off');
      return true;
    }
    if (ed.resolve(wd['AS']) is! PdfName) {
      final states = onStates(ed, wd);
      final mw = ed.mutable(w.ref!) as PdfDict;
      mw['AS'] = PdfName(
        v is PdfName && states.contains(v.name) ? v.name : 'Off',
      );
      return true;
    }
    return false;
  }

  /// A check widget with no /Off appearance gets an empty one: without
  /// it PDFium draws a grey frame around the box when it's off, which the
  /// form's own artwork (e.g. a printed circle) doesn't have.
  bool _addEmptyOffAppearance(WidgetEntry w) {
    final wd = ed.resolve(w.ref);
    if (wd is! PdfDict) return false;
    final ap = ed.resolve(wd['AP']);
    if (ap is! PdfDict) return false;
    final n = ed.resolve(ap['N']);
    if (n is! PdfDict || n.containsKey('Off') || n.keys.isEmpty) return false;
    final look = _look(wd);
    final off = ed.add(look.formXObject('', null));
    final mw = ed.mutable(w.ref!) as PdfDict;
    mw['AP'] = PdfDict({
      ...ap.map,
      'N': PdfDict({...n.map, 'Off': off}),
    });
    return true;
  }

  static final _textShow = RegExp(r'\bT[jJ]\b');

  /// True if a text/choice widget has a value its appearance can't be
  /// showing: no /AP /N stream, or one that draws no text at all.
  bool _textNeedsAppearance(WidgetEntry w, PdfDict wd, PdfFieldKind kind) {
    final v = inheritedAttr(ed, w.chain, 'V');
    if (v == null) return false;
    if (kind != PdfFieldKind.listBox) {
      final text = v is List
          ? (v.isEmpty ? '' : textOf(ed.resolve(v.first)))
          : textOf(v);
      if (text.isEmpty) return false;
    }
    final ap = ed.resolve(wd['AP']);
    final n = ap is PdfDict ? ed.resolve(ap['N']) : null;
    if (n is! PdfStream) return true;
    try {
      final content = String.fromCharCodes(decodeStreamData(n.data, n.dict));
      return !_textShow.hasMatch(content);
    } catch (_) {
      return false; // can't inspect: trust it
    }
  }

  /// Generates the appearances a viewer needs to show the current values
  /// (missing or empty appearances, or /NeedAppearances true). Returns the
  /// update's bytes, or null when nothing needed doing.
  ///
  /// With [forEditing], also shows every checkbox/radio off and draws text
  /// fields that have a value without their text (see
  /// PdfEditDoc.editDisplayBytes).
  List<int>? displayUpdate({bool forEditing = false}) {
    final af = acroForm;
    final need = af != null && ed.resolve(af['NeedAppearances']) == true;
    var any = false;
    var hidden = false; // forEditing: something drawn differently
    var allHave = true;
    for (final w in form.widgets) {
      if (w.ref == null) continue;
      final wd = ed.resolve(w.ref);
      if (wd is! PdfDict) continue;
      final kind = _kind(w.chain);
      switch (kind) {
        case PdfFieldKind.text:
        case PdfFieldKind.multilineText:
          if (forEditing) {
            final v = inheritedAttr(ed, w.chain, 'V');
            final has = v is List ? v.isNotEmpty : textOf(v).isNotEmpty;
            final ap = ed.resolve(wd['AP']);
            final ff = intValue(inheritedAttr(ed, w.chain, 'Ff')) ?? 0;
            final readOnly = ff & 1 != 0; // shown as is, no editor on top
            if (readOnly) {
              if (need || _textNeedsAppearance(w, wd, kind)) {
                _regenerate(w);
                any = true;
              }
            } else if (has || (need && ap is! PdfDict)) {
              _regenerate(w, textOverride: '');
              any = true;
              hidden = hidden || has;
            }
          } else if (need || _textNeedsAppearance(w, wd, kind)) {
            _regenerate(w);
            any = true;
          }
        case PdfFieldKind.comboBox:
        case PdfFieldKind.listBox:
          if (need || _textNeedsAppearance(w, wd, kind)) {
            _regenerate(w);
            any = true;
          }
        case PdfFieldKind.checkbox:
        case PdfFieldKind.radio:
          if (_ensureCheckAppearance(w, wd, kind)) any = true;
          if (_addEmptyOffAppearance(w)) any = true;
          if (forEditing) {
            final cur = ed.resolve(w.ref) as PdfDict;
            final as = ed.resolve(cur['AS']);
            if (as is! PdfName || as.name != 'Off') {
              (ed.mutable(w.ref!) as PdfDict)['AS'] = const PdfName('Off');
              any = true;
              hidden = true;
            }
          }
        default:
          if (ed.resolve(wd['AP']) is! PdfDict) allHave = false;
      }
    }
    if (need && allHave) {
      mutableAcroForm()['NeedAppearances'] = false;
      any = true;
    }
    if (!any || (forEditing && !hidden)) return null;
    final override = _newRoot != null ? PdfDict({'Root': _newRoot}) : null;
    return ed.write(trailerOverride: override);
  }
}
