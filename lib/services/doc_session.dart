import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:pdfrx/pdfrx.dart' as rx;

import '../core/pdf_core.dart';
import 'doc_location.dart';

/// Shown by the UI: asks for a password, calling [tryPassword] for each
/// attempt (so a wrong one can shake the dialog and ask again). Returns the
/// accepted password, or null when the user cancelled.
typedef PasswordAsk = Future<String?> Function(
  Future<bool> Function(String password) tryPassword,
);

/// A user-presentable reason a document could not be opened.
class OpenFailure implements Exception {
  final String message;
  const OpenFailure(this.message);
  @override
  String toString() => message;
}

/// Opens bytes for display. Throws [rx.PdfPasswordException] when a
/// (different) password is needed.
typedef ViewOpener = Future<rx.PdfDocument> Function(
  Uint8List bytes,
  String? password,
);

/// Opens bytes for editing (the PDF core).
typedef EditOpener = PdfEditDoc Function(Uint8List bytes, String? password);

/// The app's current document: bytes + password + source location + dirty
/// flag, or a New draft. Every edit produces new bytes through the core and
/// the viewer reopens them from memory.
class DocSession extends ChangeNotifier {
  DocSession({ViewOpener? openView, EditOpener? openEdit})
    : _openView = openView ?? _defaultOpenView,
      _openEdit = openEdit ?? _defaultOpenEdit;

  final ViewOpener _openView;
  final EditOpener _openEdit;

  static int _seq = 0;
  static Future<rx.PdfDocument> _defaultOpenView(
    Uint8List bytes,
    String? password,
  ) async {
    await rx.pdfrxFlutterInitialize();
    var asked = false;
    return rx.PdfDocument.openData(
      bytes,
      sourceName: 'pdfedit-mem-${_seq++}',
      // Only the first page is measured up front (2000-page files took
      // 12-35 s otherwise). The layout uses the core's page sizes; pages
      // render fine before pdfrx has measured them.
      useProgressiveLoading: true,
      firstAttemptByEmptyPassword: password == null,
      passwordProvider: password == null
          ? null
          : () {
              if (asked) return null;
              asked = true;
              return password;
            },
    );
  }

  static PdfEditDoc _defaultOpenEdit(Uint8List bytes, String? password) =>
      PdfEditDoc.open(bytes, password: password);

  Uint8List? _bytes;
  String? _password;
  DocLocation? _location;
  bool _writable = false;
  bool _dirty = false;
  bool _isDraft = false;
  String _draftText = '';
  String _title = '';
  PdfEditDoc? _editDoc;
  String? _editUnavailable;
  rx.PdfDocument? _viewDoc;
  int _generation = 0;
  int _serial = 0;

  // The view shows PdfEditDoc.editDisplayBytes (fields drawn empty for
  // the fill controls on top) rather than displayBytes.
  bool _editView = false;
  bool _viewIsEdit = false;
  int _editViewRequest = 0;

  bool get hasDocument => _bytes != null || _isDraft;
  Uint8List? get bytes => _bytes;
  String? get password => _password;
  DocLocation? get location => _location;

  /// Save can write back to [location].
  bool get canSaveInPlace => _location != null && _writable && !_isDraft;
  bool get dirty => _dirty || (_isDraft && _draftText.isNotEmpty);
  bool get isDraft => _isDraft;
  String get draftText => _draftText;
  String get title => _title;
  PdfEditDoc? get editDoc => _editDoc;

  /// Why editing isn't possible for this document (core couldn't read it).
  String? get editUnavailable => _editUnavailable;
  rx.PdfDocument? get viewDoc => _viewDoc;

  /// Increments whenever the displayed bytes change.
  int get generation => _generation;

  /// Increments when a different document (or draft) is shown; edits that
  /// only change the bytes of the same document keep it.
  int get serial => _serial;

  bool get isLocked {
    final d = _editDoc;
    return d != null && !d.permissions.canEditFields;
  }

  bool get isLayoutLocked {
    final d = _editDoc;
    return d != null && !d.permissions.canLayoutFields;
  }

  /// Opens [bytes]. Returns false if the user cancelled the password prompt.
  /// Throws [OpenFailure] if the file can't be displayed.
  Future<bool> open(
    Uint8List bytes, {
    DocLocation? location,
    bool writable = true,
    required PasswordAsk askPassword,
  }) async {
    rx.PdfDocument? view;
    String? pw;
    try {
      view = await _openView(bytes, null);
    } on rx.PdfPasswordException {
      pw = await askPassword((candidate) async {
        try {
          view = await _openView(bytes, candidate);
          return true;
        } on rx.PdfPasswordException {
          return false;
        }
      });
      if (pw == null || view == null) return false;
    } on rx.PdfException catch (e) {
      throw OpenFailure(
        e.errorCode == 4
            ? "Can't open this kind of protected PDF."
            : "Can't open this file. It may be damaged or not a PDF.",
      );
    } catch (e) {
      throw const OpenFailure("Can't open this file.");
    }
    final (edit, unavailable) = _tryOpenEdit(bytes, pw);
    var shown = view!;
    if (edit != null) shown = await _viewFor(edit, pw, fallback: shown);
    _serial++;
    _install(
      bytes: bytes,
      password: pw,
      view: shown,
      editDoc: edit,
      editUnavailable: unavailable,
      location: location,
      writable: writable,
      title: location?.name ?? 'Untitled.pdf',
      dirty: false,
    );
    return true;
  }

  void _install({
    required Uint8List bytes,
    required String? password,
    required rx.PdfDocument view,
    required DocLocation? location,
    required bool writable,
    required String title,
    required bool dirty,
    required PdfEditDoc? editDoc,
    String? editUnavailable,
  }) {
    final old = _viewDoc;
    _bytes = bytes;
    _password = password;
    _location = location;
    _writable = writable;
    _title = title;
    _dirty = dirty;
    _isDraft = false;
    _draftText = '';
    _viewDoc = view;
    _editView = false;
    _viewIsEdit = false;
    _editViewRequest++;
    _generation++;
    _editDoc = editDoc;
    _editUnavailable = editDoc == null ? editUnavailable : null;
    notifyListeners();
    _disposeLater(old);
  }

  (PdfEditDoc?, String?) _tryOpenEdit(Uint8List bytes, String? password) {
    try {
      return (_openEdit(bytes, password), null);
    } on PdfCoreException catch (e) {
      return (null, e.message);
    } on PdfPasswordException {
      return (null, 'This file needs a password to edit.');
    } catch (e) {
      debugPrint('PdfEditDoc.open failed: $e');
      return (null, "Editing isn't available for this file.");
    }
  }

  /// The viewer shows [PdfEditDoc.displayBytes] (adds generated appearances
  /// for fields that have values but none drawn); saving uses `bytes`.
  /// [fallback] is a viewer already open on `bytes`.
  Future<rx.PdfDocument> _viewFor(
    PdfEditDoc doc,
    String? password, {
    rx.PdfDocument? fallback,
  }) async {
    Uint8List display;
    try {
      display = doc.displayBytes;
    } catch (e) {
      debugPrint('displayBytes failed: $e');
      display = doc.bytes;
    }
    if (fallback != null && identical(display, doc.bytes)) return fallback;
    try {
      final v = await _openView(display, password);
      if (fallback != null) _disposeLater(fallback);
      return v;
    } catch (e) {
      if (fallback != null) return fallback;
      if (identical(display, doc.bytes)) rethrow;
      return _openView(doc.bytes, password);
    }
  }

  void _disposeLater(rx.PdfDocument? doc) {
    if (doc == null) return;
    // Let the page widgets switch to the new document first.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      Timer(const Duration(milliseconds: 500), () => doc.dispose());
    });
  }

  /// While filling fields the pages are drawn with checkboxes off and text
  /// fields empty ([PdfEditDoc.editDisplayBytes]) so the fill controls on
  /// top are the only thing showing a field's content; [on] false goes
  /// back to the normal view. Keeps the document (and the reading
  /// position): only the page pictures are redrawn.
  Future<void> setEditView(bool on) async {
    final doc = _editDoc;
    if (doc == null || on == _editView) return;
    final req = ++_editViewRequest;
    if (!on && !_viewIsEdit) {
      _editView = false;
      return;
    }
    Uint8List want;
    Uint8List normal;
    try {
      normal = doc.displayBytes;
      want = on ? doc.editDisplayBytes : normal;
    } catch (_) {
      return;
    }
    if (on && identical(want, normal)) {
      _editView = true; // nothing to hide: the normal view will do
      return;
    }
    rx.PdfDocument view;
    try {
      view = await _openView(want, _password);
    } catch (e) {
      debugPrint('edit view failed: $e');
      return;
    }
    if (req != _editViewRequest || !identical(doc, _editDoc)) {
      _disposeLater(view);
      return;
    }
    final old = _viewDoc;
    _viewDoc = view;
    _editView = on;
    _viewIsEdit = on;
    _generation++;
    notifyListeners();
    _disposeLater(old);
  }

  /// Starts a New draft (blank sheet).
  void newDraft() {
    final old = _viewDoc;
    _bytes = null;
    _password = null;
    _location = null;
    _writable = false;
    _dirty = false;
    _isDraft = true;
    _draftText = '';
    _title = 'Untitled.pdf';
    _editDoc = null;
    _editUnavailable = null;
    _viewDoc = null;
    _generation++;
    _serial++;
    notifyListeners();
    _disposeLater(old);
  }

  set draftText(String text) {
    if (text == _draftText) return;
    final wasDirty = dirty;
    _draftText = text;
    if (dirty != wasDirty) notifyListeners();
  }

  /// Turns the draft into a real PDF (SPEC §1.4).
  Future<void> commitDraft() async {
    final bytes = PdfEditDoc.createTextDocument(_draftText);
    final (edit, unavailable) = _tryOpenEdit(bytes, null);
    final view = edit != null
        ? await _viewFor(edit, null)
        : await _openView(bytes, null);
    _serial++;
    _install(
      bytes: bytes,
      password: null,
      view: view,
      editDoc: edit,
      editUnavailable: unavailable,
      location: null,
      writable: false,
      title: _title,
      dirty: true,
    );
  }

  /// Applies [changes] via the core and reloads the viewer from the result.
  Future<void> applyChanges(List<PdfChange> changes) async {
    final doc = _editDoc;
    if (doc == null || changes.isEmpty) return;
    final next = doc.applyChanges(changes);
    final view = await _viewFor(next, _password);
    _install(
      bytes: next.bytes,
      password: _password,
      view: view,
      location: _location,
      writable: _writable,
      title: _title,
      dirty: true,
      editDoc: next,
    );
  }

  /// Tries [ownerPassword] to lift permission limits. True on success.
  bool unlockWithOwnerPassword(String ownerPassword) {
    final bytes = _bytes;
    if (bytes == null) return false;
    try {
      final d = _openEdit(bytes, ownerPassword);
      if (!d.isOwner) return false;
      _editDoc = d;
      _editUnavailable = null;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// After a successful save to [location].
  void markSaved(DocLocation location) {
    _location = location;
    _writable = true;
    _title = location.name;
    _dirty = false;
    notifyListeners();
  }

  /// Location was refreshed (e.g. stale bookmark) without other changes.
  void updateLocation(DocLocation location) {
    _location = location;
  }

  void close() {
    final old = _viewDoc;
    _bytes = null;
    _password = null;
    _location = null;
    _writable = false;
    _dirty = false;
    _isDraft = false;
    _draftText = '';
    _title = '';
    _editDoc = null;
    _editUnavailable = null;
    _viewDoc = null;
    _generation++;
    notifyListeners();
    _disposeLater(old);
  }
}
