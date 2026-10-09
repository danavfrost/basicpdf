import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/pdf_core.dart';
import '../../services/doc_location.dart';
import '../../services/doc_session.dart';
import '../../services/file_service.dart';
import '../../services/history_store.dart';
import '../../services/settings_store.dart';
import '../dialogs/about.dart';
import '../dialogs/password_dialog.dart';
import '../dialogs/save_as_dialog.dart';
import '../dialogs/unsaved_dialog.dart';
import '../edit/edit_session.dart';
import '../edit/fill_overlay.dart';
import '../edit/layout_overlay.dart';
import '../new_doc/draft_sheet.dart';
import '../open/open_dialog.dart';
import 'auto_hide.dart';
import 'home_view.dart';
import 'pages_view.dart';

/// The main (and only) screen: Home when nothing is open, otherwise the
/// page list with the auto-hiding top bar, edit mode and Fields tool.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({
    super.key,
    required this.session,
    required this.history,
    required this.files,
    required this.settings,
  });

  final DocSession session;
  final HistoryStore history;
  final FileService files;
  final SettingsStore settings;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

enum _Menu { newDoc, open, save, saveAs, darkMode, about }

class _ViewerScreenState extends State<ViewerScreen> {
  final _autoHide = AutoHideController();
  final _pages = PagesController();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<PickedDoc>? _incomingSub;

  bool _editing = false;
  EditSession? _edit;

  /// The last edit session's values, drawn (quietly) for a moment after
  /// editing ends while the pages redraw with them, so nothing blinks.
  EditSession? _linger;
  Timer? _lingerTimer;

  /// Inline (in the bar) error from the last ✓, e.g. the core's message.
  String? _editError;
  bool _busy = false;

  DocSession get session => widget.session;
  FileService get files => widget.files;

  @override
  void initState() {
    super.initState();
    session.addListener(_onSession);
    widget.history.load();
    _incomingSub = files.incoming.listen(
      _openIncoming,
      onError: (Object _) => _snack("Couldn't open that file."),
    );
    files.initialDoc().then(
      (d) {
        if (d != null && mounted) _openIncoming(d);
      },
      // E.g. the app that sent it didn't grant access to it.
      onError: (Object _) {
        if (mounted) _snack("Couldn't open that file.");
      },
    );
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _incomingSub?.cancel();
    _autoHide.dispose();
    _lingerTimer?.cancel();
    _edit?.dispose();
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  void _snack(String text) {
    _messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<T?> _withBusy<T>(Future<T> Function() f) async {
    setState(() => _busy = true);
    try {
      return await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------- state

  bool get _hasPendingEdits => _editing && _edit != null && _edit!.hasChanges;

  bool get _dirty => session.dirty || _hasPendingEdits;

  void _setEditing(bool on, {EditSession? edit}) {
    final old = _edit;
    old?.removeListener(_onSession);
    old?.onShowField = null;
    edit?.addListener(_onSession);
    edit?.onShowField = _showField;
    final lingerOld = _linger;
    _lingerTimer?.cancel();
    setState(() {
      _editing = on;
      _edit = on ? edit : null;
      _editError = null;
      _linger = !on && old != null && !old.layoutMode ? old : null;
    });
    if (_linger != null) {
      _lingerTimer = Timer(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        final l = _linger;
        setState(() => _linger = null);
        if (l != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => l.dispose());
        }
      });
    }
    if (lingerOld != null && lingerOld != _linger) {
      WidgetsBinding.instance.addPostFrameCallback((_) => lingerOld.dispose());
    }
    if (old != null && old != edit && old != _linger) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    _autoHide.pinned = on;
    // While filling, the pages show fields empty (checkboxes off, no
    // text) and the fill controls show the values.
    if (!session.isDraft) unawaited(session.setEditView(on && edit != null));
  }

  // -------------------------------------------------------------- editing

  Future<void> _onEditPressed() async {
    if (session.isDraft) {
      _setEditing(true);
      return;
    }
    final doc = session.editDoc;
    if (doc == null) {
      _snack(session.editUnavailable ?? "This file can't be edited.");
      return;
    }
    if (session.isLocked && !await _unlock()) return;
    _setEditing(true, edit: EditSession(session.editDoc!));
  }

  /// Brings a field being filled into view, zooming in when its text would
  /// be too small to edit comfortably.
  void _showField(PdfField f, double fontPt) {
    final c = _pages;
    if (!c.isAttached) return;
    final vertical = f.rotation % 180 == 90;
    final zoom = comfortableZoom(
      fontPt: fontPt,
      fieldWidthPt: vertical ? f.rect.height : f.rect.width,
      basePointScale: c.basePointScale(f.pageIndex),
      currentZoom: c.zoom,
      viewWidth: c.viewSize.width,
    );
    c.reveal(
      f.pageIndex,
      Rect.fromLTWH(f.rect.left, f.rect.top, f.rect.width, f.rect.height),
      zoom: zoom,
    );
  }

  Future<bool> _unlock() async {
    final pw = await showPasswordDialog(
      context,
      title: 'Editing is restricted',
      message:
          'The author limited editing of this PDF. '
          'Enter the owner password to unlock it.',
      action: 'Unlock',
      tryPassword: (pw) async => session.unlockWithOwnerPassword(pw),
    );
    return pw != null;
  }

  /// ✓ — applies pending edits. Returns false if applying failed.
  Future<bool> _onDone() async {
    if (session.isDraft) {
      if (session.draftText.isEmpty) {
        _setEditing(false);
        return true;
      }
      final ok = await _withBusy(() async {
        try {
          await session.commitDraft();
          return true;
        } catch (e) {
          setState(
            () => _editError = _errorText(e, "Couldn't create the PDF."),
          );
          return false;
        }
      });
      if (ok == true) _setEditing(false);
      return ok == true;
    }
    final edit = _edit;
    final changes = edit?.buildChanges() ?? const <PdfChange>[];
    if (changes.isEmpty) {
      _setEditing(false);
      return true;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final ok = await _withBusy(() async {
      try {
        await session.applyChanges(changes);
        return true;
      } catch (e) {
        setState(
          () => _editError = _errorText(e, "Couldn't apply the changes."),
        );
        return false;
      }
    });
    if (ok == true) _setEditing(false);
    return ok == true;
  }

  String _errorText(Object e, String fallback) =>
      e is PdfCoreException ? e.message : fallback;

  Future<void> _toggleFields() async {
    final edit = _edit;
    if (edit == null) return;
    if (!edit.layoutMode && session.isLayoutLocked) {
      if (!await _unlock()) return;
      // The unlocked document has new permissions; keep pending values.
    }
    FocusManager.instance.primaryFocus?.unfocus();
    edit.layoutMode = !edit.layoutMode;
    setState(() {});
  }

  // ----------------------------------------------------------- open / new

  /// Unsaved-changes guard. True when it's OK to replace the document.
  Future<bool> _guard() =>
      confirmLeave(context, dirty: _dirty, title: session.title, save: _save);

  Future<void> _onNew() async {
    if (!await _guard()) return;
    _setEditing(false);
    session.newDraft();
  }

  Future<void> _onOpen() async {
    if (!await _guard()) return;
    if (!mounted) return;
    final req = await showOpenDialog(
      context,
      history: widget.history,
      files: files,
    );
    if (req == null || !mounted) return;
    await _openRequest(req);
  }

  Future<void> _openRecent(DocLocation loc) => _openRequest(OpenRequest(loc));

  Future<void> _openIncoming(PickedDoc doc) async {
    if (!await _guard()) return;
    await _openRequest(OpenRequest(doc.location, doc));
  }

  Future<void> _openRequest(OpenRequest req) async {
    await _withBusy(() async {
      Uint8List bytes;
      var location = req.location;
      var writable = true;
      final picked = req.picked;
      if (picked != null) {
        final pb = picked.bytes;
        bytes = pb is Uint8List ? pb : Uint8List.fromList(pb);
        writable = picked.writable;
      } else {
        try {
          final (b, loc) = await files.read(location);
          bytes = b;
          if (loc.ref != location.ref) {
            location = loc;
            unawaited(widget.history.update(loc));
          }
        } on FileMissingException {
          _snack('“${location.name}” is missing or no longer accessible.');
          return;
        } catch (_) {
          _snack('Couldn’t read “${location.name}”.');
          return;
        }
      }
      try {
        final ok = await session.open(
          bytes,
          location: location,
          writable: writable,
          askPassword: (tryPw) =>
              showPasswordDialog(context, tryPassword: tryPw),
        );
        if (!ok) return;
        _setEditing(false);
        _autoHide.show();
        await widget.history.touch(location);
      } on OpenFailure catch (e) {
        _snack(e.message);
      }
    });
  }

  // ----------------------------------------------------------------- save

  /// Commits a draft / pending edits so [session.bytes] is current.
  Future<bool> _flushEdits() async {
    if (session.isDraft || _hasPendingEdits) return _onDone();
    return true;
  }

  Future<bool> _save() async {
    if (!await _flushEdits()) return false;
    final bytes = session.bytes, loc = session.location;
    if (bytes == null) return false;
    if (session.canSaveInPlace && loc != null) {
      final ok = await _withBusy(() async {
        try {
          await files.write(loc, bytes);
          session.markSaved(loc);
          return true;
        } catch (_) {
          return false;
        }
      });
      if (ok == true) {
        _snack('Saved');
        return true;
      }
      // Can't write back (read-only grant, moved...): fall back to Save As.
    }
    return _saveAs();
  }

  Future<bool> _saveAs() async {
    if (!await _flushEdits()) return false;
    final bytes = session.bytes;
    if (bytes == null || !mounted) return false;
    final name = normalizePdfName(session.title);
    DocLocation? saved;
    try {
      if (files.usesSystemSaveAs) {
        saved = await files.saveAsSystem(name, bytes);
      } else {
        final r = await showSaveAsDialog(
          context,
          files: files,
          initialName: name,
        );
        if (r == null) return false;
        saved = await _withBusy(() => files.writeInFolder(r.$2, r.$1, bytes));
      }
    } catch (e) {
      _snack('Couldn’t save the file.');
      return false;
    }
    if (saved == null) return false;
    session.markSaved(saved);
    await widget.history.touch(saved);
    _snack('Saved “${saved.name}”');
    return true;
  }

  // ----------------------------------------------------------------- back

  Future<void> _onBack() async {
    if (_editing) {
      await _onDone();
      return;
    }
    if (!session.hasDocument) return;
    if (!await _guard()) return;
    session.close();
  }

  Future<void> _onMenu(_Menu m) async {
    switch (m) {
      case _Menu.newDoc:
        await _onNew();
      case _Menu.open:
        await _onOpen();
      case _Menu.save:
        await _save();
      case _Menu.saveAs:
        await _saveAs();
      case _Menu.darkMode:
        await widget.settings.setDark(
          Theme.of(context).brightness != Brightness.dark,
        );
      case _Menu.about:
        await showAbout(context);
    }
  }

  // ---------------------------------------------------------------- build

  bool get _showToolRow =>
      _editing &&
      (_editError != null ||
          (!session.isDraft &&
              _edit != null &&
              (_edit!.layoutMode || _edit!.fields.isEmpty)));

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final barHeight = mq.padding.top + kToolbarHeight + (_showToolRow ? 48 : 0);
    return ScaffoldMessenger(
      key: _messenger,
      child: PopScope(
        canPop: !session.hasDocument && !_editing,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _onBack();
        },
        child: Scaffold(
          body: Stack(
            children: [
              AutoHideScaffold(
                controller: _autoHide,
                bar: _bar(context),
                child: _body(barHeight),
              ),
              // Keeps the status bar readable while the top bar is hidden.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: mq.padding.top,
                child: ColoredBox(color: Theme.of(context).colorScheme.surface),
              ),
              if (_busy)
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(double barHeight) {
    if (!session.hasDocument) {
      return HomeView(
        history: widget.history,
        files: files,
        topPadding: barHeight,
        onNew: _onNew,
        onOpen: _onOpen,
        onOpenRecent: _openRecent,
      );
    }
    if (session.isDraft) {
      return DraftSheet(
        key: ValueKey('draft-${session.serial}'),
        text: session.draftText,
        editing: _editing,
        topPadding: barHeight,
        onChanged: (t) => session.draftText = t,
        onTap: _autoHide.show,
      );
    }
    final doc = session.viewDoc;
    if (doc == null) return const SizedBox.shrink();
    final edit = _edit;
    // The core already knows every page size; pdfrx measures pages
    // progressively, so lay out from the core's sizes.
    final corePages = session.editDoc?.pages;
    return PagesView.forDocument(
      key: ValueKey('doc-${session.serial}'),
      document: doc,
      pageSizes: corePages == null
          ? null
          : [for (final p in corePages) Size(p.width, p.height)],
      topPadding: barHeight,
      onTap: _autoHide.show,
      controller: _pages,
      overlayBuilder: !_editing || edit == null
          ? (_linger == null
                ? null
                : (context, page, size, scale) => FillOverlay(
                    session: _linger!,
                    pageIndex: page,
                    scale: scale,
                    quiet: true,
                  ))
          : (context, page, size, scale) => edit.layoutMode
                ? LayoutOverlay(
                    session: edit,
                    pageIndex: page,
                    pageSize: size,
                    scale: scale,
                  )
                : FillOverlay(session: edit, pageIndex: page, scale: scale),
    );
  }

  PreferredSizeWidget _bar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasDoc = session.hasDocument;
    final title = hasDoc ? session.title : 'Basic PDF';
    final titleWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (hasDoc && _dirty)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Container(
              key: const ValueKey('dirty-dot'),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );

    final edit = _edit;
    final List<Widget> actions;
    if (_editing) {
      actions = [
        if (!session.isDraft && edit != null)
          IconButton(
            key: const ValueKey('fields-button'),
            tooltip: edit.layoutMode ? 'Back to filling' : 'Fields',
            isSelected: edit.layoutMode,
            icon: session.isLayoutLocked
                ? const LockedIcon(Icons.dashboard_customize_outlined)
                : const Icon(Icons.dashboard_customize_outlined),
            selectedIcon: const Icon(Icons.dashboard_customize),
            onPressed: _busy ? null : _toggleFields,
          ),
        IconButton(
          key: const ValueKey('done-button'),
          tooltip: 'Done',
          icon: const Icon(Icons.check),
          onPressed: _busy ? null : _onDone,
        ),
      ];
    } else {
      actions = [
        if (hasDoc)
          IconButton(
            key: const ValueKey('edit-button'),
            tooltip: session.isLocked ? 'Edit (restricted)' : 'Edit',
            icon: session.isLocked
                ? const LockedIcon(Icons.edit_outlined)
                : const Icon(Icons.edit_outlined),
            onPressed: _busy ? null : _onEditPressed,
          ),
        PopupMenuButton<_Menu>(
          key: const ValueKey('overflow-menu'),
          tooltip: 'More',
          onSelected: _onMenu,
          itemBuilder: (context) => [
            const PopupMenuItem(value: _Menu.newDoc, child: Text('New')),
            const PopupMenuItem(value: _Menu.open, child: Text('Open')),
            PopupMenuItem(
              value: _Menu.save,
              enabled: hasDoc,
              child: const Text('Save'),
            ),
            PopupMenuItem(
              value: _Menu.saveAs,
              enabled: hasDoc,
              child: const Text('Save As'),
            ),
            PopupMenuItem(
              key: const ValueKey('dark-mode'),
              value: _Menu.darkMode,
              child: Row(
                children: [
                  const Expanded(child: Text('Dark mode')),
                  IgnorePointer(
                    child: Switch(
                      key: const ValueKey('dark-mode-switch'),
                      value: Theme.of(context).brightness == Brightness.dark,
                      onChanged: (_) {},
                    ),
                  ),
                ],
              ),
            ),
            const PopupMenuItem(value: _Menu.about, child: Text('About')),
          ],
        ),
      ];
    }

    return AppBar(
      title: titleWidget,
      automaticallyImplyLeading: false,
      leading: hasDoc && !_editing && Platform.isIOS
          ? IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: _onBack,
            )
          : null,
      actions: actions,
      bottom: !_showToolRow
          ? null
          : _editError != null
          ? _errorRow(_editError!)
          : _toolRow(edit!),
    );
  }

  PreferredSizeWidget _errorRow(String message) {
    final scheme = Theme.of(context).colorScheme;
    return PreferredSize(
      preferredSize: const Size.fromHeight(48),
      child: Container(
        key: const ValueKey('edit-error'),
        height: 48,
        color: scheme.errorContainer,
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: Icon(Icons.close, color: scheme.onErrorContainer),
              onPressed: () => setState(() => _editError = null),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _toolRow(EditSession edit) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(48),
      child: SizedBox(
        height: 48,
        child: ListenableBuilder(
          listenable: edit,
          builder: (context, _) {
            if (!edit.layoutMode) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'No fillable fields — tap Fields to add text boxes.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              );
            }
            return ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                ChoiceChip(
                  key: const ValueKey('add-text'),
                  avatar: const Icon(Icons.text_fields, size: 18),
                  label: const Text('Text box'),
                  selected: edit.tool == LayoutTool.addText,
                  onSelected: (s) =>
                      edit.tool = s ? LayoutTool.addText : LayoutTool.select,
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  key: const ValueKey('add-check'),
                  avatar: const Icon(Icons.check_box_outlined, size: 18),
                  label: const Text('Checkbox'),
                  selected: edit.tool == LayoutTool.addCheckbox,
                  onSelected: (s) => edit.tool = s
                      ? LayoutTool.addCheckbox
                      : LayoutTool.select,
                ),
                const SizedBox(width: 12),
                Center(
                  child: Text(
                    switch (edit.tool) {
                      LayoutTool.addText => 'Drag on the page to draw a box',
                      LayoutTool.addCheckbox => 'Tap the page to place it',
                      LayoutTool.select =>
                        'Tap a field to move, resize or delete',
                    },
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// [icon] with a small neutral lock in its corner (restricted PDFs). Not a
/// notification badge: no colour fill, just the lock on the bar background.
class LockedIcon extends StatelessWidget {
  const LockedIcon(this.icon, {super.key});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final bg =
        Theme.of(context).appBarTheme.backgroundColor ??
        Theme.of(context).colorScheme.surface;
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon),
          Positioned(
            right: -3,
            bottom: -3,
            child: DecoratedBox(
              key: const ValueKey('lock-overlay'),
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Padding(
                padding: const EdgeInsets.all(1),
                child: Icon(
                  Icons.lock,
                  size: 11,
                  color: iconTheme.color?.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
