import 'package:flutter/widgets.dart';

import '../../core/pdf_core.dart';

enum LayoutTool { select, addText, addCheckbox }

/// A field box in the Fields (layout) tool: an existing widget or a new one.
class LayoutItem {
  LayoutItem({
    required this.id,
    required this.pageIndex,
    required this.rect,
    required this.kind,
    this.original,
  });

  final String id;
  final int pageIndex;
  PdfRect rect;
  PdfFieldKind kind;
  bool deleted = false;

  /// The widget this item came from; null for fields added in this session.
  final PdfField? original;

  bool get isNew => original == null;
  bool get isText =>
      kind == PdfFieldKind.text || kind == PdfFieldKind.multilineText;
  String get label =>
      original?.fullName ?? (isText ? 'New text box' : 'New checkbox');
}

/// Pending (not yet applied) edits for one document. ✓ turns them into
/// [PdfChange]s via [buildChanges].
class EditSession extends ChangeNotifier {
  EditSession(this.doc);

  final PdfEditDoc doc;

  /// Field values keyed by full name, so widgets of the same field stay in
  /// sync: name → (widget id that was edited, value).
  final Map<String, (String, String)> _values = {};

  bool _layout = false;
  LayoutTool _tool = LayoutTool.select;
  List<LayoutItem>? _items;
  String? _selectedId;
  int _newSeq = 0;

  bool get layoutMode => _layout;
  LayoutTool get tool => _tool;
  String? get selectedId => _selectedId;

  List<PdfField> get fields => doc.fields;

  set layoutMode(bool on) {
    if (on == _layout) return;
    _layout = on;
    _tool = LayoutTool.select;
    _selectedId = null;
    if (on) _items ??= _initialItems();
    notifyListeners();
  }

  set tool(LayoutTool t) {
    _tool = t;
    notifyListeners();
  }

  // ---- fill ----

  String valueOf(PdfField f) => _values[f.fullName]?.$2 ?? f.value;

  final Map<String, (String, PdfTextFit)> _fits = {};

  /// How the saved PDF will lay out this field's current value (font size,
  /// and whether it all fits — fields don't scroll in a saved PDF).
  PdfTextFit fitOf(PdfField f) {
    final v = valueOf(f);
    final c = _fits[f.id];
    if (c != null && c.$1 == v) return c.$2;
    final fit = doc.textFit(f, v);
    _fits[f.id] = (v, fit);
    return fit;
  }

  void setValue(PdfField f, String value) {
    if (valueOf(f) == value) return;
    _values[f.fullName] = (f.id, value);
    notifyListeners();
  }

  /// Checkbox: toggles between this widget's on value and Off.
  void toggleCheck(PdfField f) {
    final on = f.onValue ?? 'Yes';
    setValue(f, valueOf(f) == on ? 'Off' : on);
  }

  bool isChecked(PdfField f) {
    final v = valueOf(f);
    return v != 'Off' && v.isNotEmpty && (f.onValue == null || v == f.onValue);
  }

  // ---- moving between fields ----

  /// Called to bring [field] into view (and zoom in on it when it's too
  /// small to edit); [fontSize] is its text size in points.
  void Function(PdfField field, double fontSize)? onShowField;

  final Map<String, FocusNode> _focusNodes = {};
  String? _pendingFocus;
  List<PdfField>? _order;

  /// Editable text fields in reading order (see [readingOrder]).
  List<PdfField> get fillOrder => _order ??= readingOrder(
    doc.fields
        .where(
          (f) =>
              !f.readOnly &&
              (f.kind == PdfFieldKind.text ||
                  f.kind == PdfFieldKind.multilineText),
        )
        .toList(),
  );

  /// The text field after [f] in reading order, or null for the last one.
  PdfField? nextField(PdfField f) {
    final order = fillOrder;
    final i = order.indexWhere((x) => x.id == f.id);
    return i < 0 || i + 1 >= order.length ? null : order[i + 1];
  }

  void registerFocus(PdfField f, FocusNode node) {
    _focusNodes[f.id] = node;
    if (_pendingFocus == f.id) {
      _pendingFocus = null;
      node.requestFocus();
    }
  }

  void unregisterFocus(PdfField f, FocusNode node) {
    if (identical(_focusNodes[f.id], node)) _focusNodes.remove(f.id);
  }

  /// Focuses text field [f], scrolling its page into view first if its
  /// editor isn't built yet.
  void focusField(PdfField f) {
    final node = _focusNodes[f.id];
    if (node != null) {
      node.requestFocus();
      return;
    }
    _pendingFocus = f.id;
    onShowField?.call(f, fitOf(f).fontSize);
  }

  // ---- layout ----

  List<LayoutItem> _initialItems() => [
    for (final f in doc.fields)
      LayoutItem(
        id: f.id,
        pageIndex: f.pageIndex,
        rect: f.rect,
        kind: f.kind,
        original: f,
      ),
  ];

  List<LayoutItem> get items =>
      (_items ?? const <LayoutItem>[]).where((i) => !i.deleted).toList();

  List<LayoutItem> itemsOnPage(int page) =>
      items.where((i) => i.pageIndex == page).toList();

  LayoutItem? get selected =>
      items.where((i) => i.id == _selectedId).firstOrNull;

  void select(String? id) {
    _selectedId = id;
    notifyListeners();
  }

  LayoutItem addItem(int page, PdfRect rect, PdfFieldKind kind) {
    final item = LayoutItem(
      id: 'new:${_newSeq++}',
      pageIndex: page,
      rect: rect,
      kind: kind,
    );
    (_items ??= _initialItems()).add(item);
    _selectedId = item.id;
    _tool = LayoutTool.select;
    notifyListeners();
    return item;
  }

  void setRect(LayoutItem item, PdfRect rect) {
    item.rect = rect;
    notifyListeners();
  }

  void toggleMultiline(LayoutItem item) {
    if (!item.isText) return;
    item.kind = item.kind == PdfFieldKind.text
        ? PdfFieldKind.multilineText
        : PdfFieldKind.text;
    notifyListeners();
  }

  void delete(LayoutItem item) {
    item.deleted = true;
    if (_selectedId == item.id) _selectedId = null;
    notifyListeners();
  }

  // ---- result ----

  bool get hasChanges => buildChanges().isNotEmpty;

  List<PdfChange> buildChanges() {
    final all = _items ?? const <LayoutItem>[];
    final deleted = {
      for (final i in all)
        if (i.deleted && !i.isNew) i.id,
    };
    final out = <PdfChange>[];

    for (final MapEntry(key: name, value: (id, value)) in _values.entries) {
      final widgets = doc.fields.where((f) => f.fullName == name).toList();
      if (widgets.isEmpty || widgets.first.value == value) continue;
      var target = id;
      if (deleted.contains(target)) {
        final alive = widgets.where((w) => !deleted.contains(w.id));
        if (alive.isEmpty) continue;
        target = alive.first.id;
      }
      out.add(SetFieldValue(target, value));
    }

    for (final i in all) {
      final o = i.original;
      if (o == null || i.deleted) continue;
      if (!_sameRect(o.rect, i.rect)) out.add(MoveField(i.id, i.rect));
      if (i.kind != o.kind && i.isText) {
        out.add(SetMultiline(i.id, i.kind == PdfFieldKind.multilineText));
      }
    }
    for (final i in all) {
      if (i.isNew && !i.deleted) out.add(AddField(i.pageIndex, i.rect, i.kind));
    }
    for (final id in deleted) {
      out.add(DeleteField(id));
    }
    return out;
  }

  static bool _sameRect(PdfRect a, PdfRect b) =>
      (a.left - b.left).abs() < 0.01 &&
      (a.top - b.top).abs() < 0.01 &&
      (a.width - b.width).abs() < 0.01 &&
      (a.height - b.height).abs() < 0.01;
}

/// [fields] in reading order, page by page. Each page is cut recursively
/// at gaps no field crosses (XY-cut): into columns when the page is laid
/// out in columns whose rows don't line up (like a character sheet: read
/// one column at a time), otherwise into bands top to bottom, then each
/// band left to right, and so on. A block that can't be cut is read row by
/// row, left to right within a row.
List<PdfField> readingOrder(List<PdfField> fields) {
  final byPage = <int, List<PdfField>>{};
  for (final f in fields) {
    (byPage[f.pageIndex] ??= []).add(f);
  }
  final out = <PdfField>[];
  for (final page in byPage.keys.toList()..sort()) {
    _xyCut(byPage[page]!, out);
  }
  return out;
}

// Overlaps smaller than this (points) don't join two rows or columns.
const _cutSlack = 0.75;

// A horizontal gap at least this tall (points) separates sections.
const _sectionGap = 24.0;

void _xyCut(List<PdfField> fs, List<PdfField> out) {
  if (fs.length <= 1) {
    out.addAll(fs);
    return;
  }
  // Wide gaps across the whole block are section breaks: read them first.
  final sections = _split(fs, true, minGap: _sectionGap);
  if (sections.length > 1) {
    for (final g in sections) {
      _xyCut(g, out);
    }
    return;
  }
  final cols = _split(fs, false);
  final List<List<PdfField>> groups;
  if (cols.length > 1 && !_rowsAlign(cols)) {
    groups = cols;
  } else {
    final bands = _split(fs, true);
    groups = bands.length > 1 ? bands : cols;
  }
  if (groups.length <= 1) {
    out.addAll(_rows(fs));
    return;
  }
  for (final g in groups) {
    _xyCut(g, out);
  }
}

/// True when side-by-side [cols] form a grid: most fields have a field at
/// the same height in the neighbouring column (a form's rows), as opposed
/// to independent columns.
bool _rowsAlign(List<List<PdfField>> cols) {
  var hits = 0, total = 0;
  for (var i = 0; i + 1 < cols.length; i++) {
    final a = cols[i], b = cols[i + 1];
    final small = a.length <= b.length ? a : b;
    final other = identical(small, a) ? b : a;
    for (final f in small) {
      total++;
      if (other.any(
        (g) =>
            (g.rect.top - f.rect.top).abs() <= 1.5 ||
            (g.rect.bottom - f.rect.bottom).abs() <= 1.5,
      )) {
        hits++;
      }
    }
  }
  return total > 0 && hits >= total * 0.85;
}

/// Splits [fs] at gaps along y ([horizontal]) or x that no field crosses.
List<List<PdfField>> _split(
  List<PdfField> fs,
  bool horizontal, {
  double minGap = -_cutSlack,
}) {
  double lo(PdfField f) => horizontal ? f.rect.top : f.rect.left;
  double hi(PdfField f) => horizontal ? f.rect.bottom : f.rect.right;
  final sorted = [...fs]..sort((a, b) => lo(a).compareTo(lo(b)));
  final groups = <List<PdfField>>[];
  var cur = <PdfField>[];
  var end = double.negativeInfinity;
  for (final f in sorted) {
    if (cur.isNotEmpty && lo(f) >= end + minGap) {
      groups.add(cur);
      cur = [];
      end = double.negativeInfinity;
    }
    cur.add(f);
    if (hi(f) > end) end = hi(f);
  }
  if (cur.isNotEmpty) groups.add(cur);
  return groups;
}

/// Row by row (fields whose vertical middles are within each other's
/// height share a row), left to right.
List<PdfField> _rows(List<PdfField> fs) {
  final sorted = [...fs]..sort((a, b) => a.rect.top.compareTo(b.rect.top));
  final rows = <List<PdfField>>[];
  for (final f in sorted) {
    final mid = f.rect.top + f.rect.height / 2;
    final row = rows.isEmpty ? null : rows.last;
    final first = row?.first;
    if (first != null &&
        mid < first.rect.bottom &&
        first.rect.top + first.rect.height / 2 > f.rect.top) {
      row!.add(f);
    } else {
      rows.add([f]);
    }
  }
  return [
    for (final r in rows)
      ...(r..sort((a, b) => a.rect.left.compareTo(b.rect.left))),
  ];
}
