// PdfEditDoc implementation.

import 'dart:typed_data';

import '../pdf_core.dart';
import 'appearance.dart';
import 'edit_session.dart';
import 'model.dart';
import 'objects.dart';
import 'pdf_file.dart';
import 'security.dart';
import 'text.dart' show FontMetrics;

class _FileSource implements ObjectSource {
  final PdfFile f;
  _FileSource(this.f);
  @override
  Object? resolve(Object? o) => f.resolve(o);
}

class CorePdfEditDoc extends PdfEditDoc {
  final PdfFile file;
  final String? _password;
  late final List<PageModel> pageModels;
  late final FormModel form;
  late final List<PdfField> _fields;
  late final List<PdfPageInfo> _pages;

  CorePdfEditDoc._(this.file, this._password);

  static CorePdfEditDoc open(
    Uint8List bytes, {
    String? password,
    SecurityHandler? reuse,
  }) {
    try {
      final f = PdfFile.parse(bytes);
      if (reuse != null) {
        f.useSecurity(reuse);
      } else {
        f.setupSecurity(password);
      }
      f.ensureRoot();
      final d = CorePdfEditDoc._(f, password);
      d._load();
      return d;
    } on PdfPasswordException {
      rethrow;
    } on PdfCoreException {
      rethrow;
    } catch (_) {
      throw const PdfCoreException("This PDF is damaged and can't be opened");
    }
  }

  void _load() {
    final src = _FileSource(file);
    final catalog = file.resolve(file.trailer['Root']);
    if (catalog is! PdfDict) {
      throw const PdfCoreException("This PDF is damaged and can't be opened");
    }
    pageModels = loadPages(src, catalog);
    if (pageModels.isEmpty) {
      throw const PdfCoreException('This PDF has no pages');
    }
    _pages = List.unmodifiable([for (final p in pageModels) p.info]);
    FormModel fm;
    try {
      fm = loadForm(src, catalog, pageModels);
    } catch (_) {
      fm = FormModel(const []);
    }
    form = fm;
    final acro = file.resolve(catalog['AcroForm']);
    final list = <PdfField>[];
    for (final w in form.widgets) {
      try {
        list.add(
          buildField(
            src,
            w,
            pageModels[w.pageIndex],
            acro is PdfDict ? acro : null,
          ),
        );
      } catch (_) {
        // skip malformed widget
      }
    }
    _fields = List.unmodifiable(list);
  }

  @override
  Uint8List get bytes => file.data;

  Uint8List? _displayBytes;

  @override
  Uint8List get displayBytes {
    final cached = _displayBytes;
    if (cached != null) return cached;
    Uint8List result = file.data;
    try {
      final out = EditSession(file, pageModels, form).displayUpdate();
      if (out != null) {
        result = out is Uint8List ? out : Uint8List.fromList(out);
      }
    } catch (_) {
      result = file.data; // rendering the original is the safe fallback
    }
    return _displayBytes = result;
  }

  Uint8List? _editDisplayBytes;

  @override
  Uint8List get editDisplayBytes {
    final cached = _editDisplayBytes;
    if (cached != null) return cached;
    Uint8List result = displayBytes;
    try {
      final out = EditSession(
        file,
        pageModels,
        form,
      ).displayUpdate(forEditing: true);
      if (out != null) {
        result = out is Uint8List ? out : Uint8List.fromList(out);
      }
    } catch (_) {
      result = displayBytes;
    }
    return _editDisplayBytes = result;
  }

  @override
  bool get isEncrypted => file.security != null;

  @override
  bool get isOwner => file.security == null || file.security!.isOwner;

  @override
  PdfPermissions get permissions =>
      file.security?.permissions ?? PdfPermissions.all;

  @override
  List<PdfPageInfo> get pages => _pages;

  @override
  List<PdfField> get fields => _fields;

  EditSession? _layoutSession;
  final Map<String, ({WidgetLook look, TextLayoutSpec spec})?> _layouts = {};

  @override
  PdfTextFit textFit(PdfField field, String value) {
    final fallback = PdfTextFit(
      fits: true,
      fontSize: field.fontSize > 0 ? field.fontSize : 12,
    );
    if (field.kind != PdfFieldKind.text &&
        field.kind != PdfFieldKind.multilineText) {
      return fallback;
    }
    try {
      final layout = _layouts.putIfAbsent(field.id, () {
        // A scratch session that is never finished: reading only.
        final s = _layoutSession ??= EditSession(file, pageModels, form);
        return s.textLayoutOf(field.id);
      });
      if (layout == null) return fallback;
      final r = textFitFor(layout.look, layout.spec, value);
      return PdfTextFit(
        fits: r.fits,
        fontSize: r.fontSize,
        inset: layout.look.effectiveBorder + textPadding,
        insetY: layout.look.effectiveBorder + textPaddingV,
        lineHeight: r.fontSize * lineHeightFactor,
        monospace: identical(layout.spec.metrics, FontMetrics.courier),
        firstBaseline: firstBaselineFor(layout.look, layout.spec, r.fontSize),
        quadding: layout.spec.comb ? 0 : layout.spec.quadding,
      );
    } catch (_) {
      return fallback;
    }
  }

  @override
  PdfEditDoc applyChanges(List<PdfChange> changes) {
    if (changes.isEmpty) return this;
    List<int> out;
    try {
      final s = EditSession(file, pageModels, form);
      for (final c in changes) {
        s.apply(c);
      }
      out = s.finish();
    } on PdfCoreException {
      rethrow;
    } catch (_) {
      throw const PdfCoreException("Couldn't save changes to this PDF");
    }
    final b = out is Uint8List ? out : Uint8List.fromList(out);
    return CorePdfEditDoc.open(b, password: _password, reuse: file.security);
  }
}
