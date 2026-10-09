import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/doc_location.dart';
import '../../services/file_service.dart';
import '../../services/history_store.dart';

/// What the user chose in the Open dialog. [picked] carries bytes when a
/// system picker already read the file.
class OpenRequest {
  final DocLocation location;
  final PickedDoc? picked;
  const OpenRequest(this.location, [this.picked]);
}

Future<OpenRequest?> showOpenDialog(
  BuildContext context, {
  required HistoryStore history,
  required FileService files,
}) {
  return Navigator.of(context).push<OpenRequest>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => OpenDialog(history: history, files: files),
    ),
  );
}

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String formatWhen(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (t.year == n.year && t.month == n.month && t.day == n.day) {
    return 'Today ${two(t.hour)}:${two(t.minute)}';
  }
  final d = '${t.day} ${_monthNames[t.month - 1]}';
  return t.year == n.year ? d : '$d ${t.year}';
}

class OpenDialog extends StatefulWidget {
  const OpenDialog({
    super.key,
    required this.history,
    required this.files,
    this.initialTab = 0,
  });
  final HistoryStore history;
  final FileService files;
  final int initialTab;

  @override
  State<OpenDialog> createState() => _OpenDialogState();
}

/// Long-press menu for a History/Recent entry. Calls [onRemove] when the
/// user picks "Remove from history".
Future<void> showHistoryEntryMenu(
  BuildContext context,
  VoidCallback onRemove,
) async {
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final pos = box == null
      ? RelativeRect.fill
      : RelativeRect.fromRect(
          box.localToGlobal(box.size.center(Offset.zero), ancestor: overlay) &
              const Size(1, 1),
          Offset.zero & overlay.size,
        );
  final r = await showMenu<String>(
    context: context,
    position: pos,
    items: const [
      PopupMenuItem(value: 'remove', child: Text('Remove from history')),
    ],
  );
  if (r == 'remove') onRemove();
}

/// One remembered file (Home's Recent list and the Open dialog). Files that
/// are gone ("Missing") or that we lost access to are greyed out and can't
/// be opened, but long-press still offers "Remove from history".
class HistoryTile extends StatelessWidget {
  const HistoryTile({
    super.key,
    required this.entry,
    required this.status,
    required this.onOpen,
    this.onRemove,
  });

  final HistoryEntry entry;
  final Future<FileStatus> status;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  static const noAccessText = 'No access — open it again from Files';

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return FutureBuilder<FileStatus>(
      future: status,
      builder: (context, snap) {
        final st = snap.data ?? FileStatus.ok;
        final usable = st == FileStatus.ok;
        final sub = [
          if (e.location.folder.isNotEmpty) e.location.folder,
          formatWhen(e.lastOpened),
          if (st == FileStatus.missing) 'Missing',
          if (st == FileStatus.noAccess) noAccessText,
        ].join(' · ');
        final grey = Theme.of(context).disabledColor;
        return Builder(
          builder: (tileContext) => ListTile(
            key: ValueKey(e.location.key),
            leading: Icon(
              Icons.picture_as_pdf_outlined,
              color: usable ? null : grey,
            ),
            title: Text(
              e.location.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: usable ? null : TextStyle(color: grey),
            ),
            subtitle: Text(
              sub,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: usable ? null : TextStyle(color: grey),
            ),
            onTap: usable ? onOpen : null,
            onLongPress: onRemove == null
                ? null
                : () => showHistoryEntryMenu(tileContext, onRemove!),
          ),
        );
      },
    );
  }
}

class _OpenDialogState extends State<OpenDialog> {
  final _status = <String, Future<FileStatus>>{};

  @override
  void initState() {
    super.initState();
    widget.history.load();
  }

  Future<FileStatus> statusFuture(DocLocation l) =>
      _status.putIfAbsent(l.key, () => widget.files.status(l));

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text('Open'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Recent'),
              Tab(text: 'History'),
              Tab(text: 'Browse'),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: widget.history,
          builder: (context, _) => TabBarView(
            children: [
              _HistoryList(
                key: const PageStorageKey('recent'),
                entries: widget.history.recent,
                status: statusFuture,
                empty: 'Files you open will appear here.',
                onRemove: (e) => widget.history.remove(e.location),
              ),
              _HistoryTab(history: widget.history, status: statusFuture),
              widget.files.hasInAppBrowser
                  ? FolderBrowser(files: widget.files)
                  : _SystemBrowse(files: widget.files),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryTab extends StatefulWidget {
  const _HistoryTab({required this.history, required this.status});
  final HistoryStore history;
  final Future<FileStatus> Function(DocLocation) status;

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final entries = widget.history.all
        .where(
          (e) =>
              q.isEmpty ||
              e.location.name.toLowerCase().contains(q) ||
              e.location.folder.toLowerCase().contains(q),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SearchBar(
            hintText: 'Search history',
            leading: const Icon(Icons.search),
            elevation: const WidgetStatePropertyAll(0),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: _HistoryList(
            entries: entries,
            status: widget.status,
            empty: q.isEmpty ? 'No history yet.' : 'No matches.',
            onRemove: (e) => widget.history.remove(e.location),
          ),
        ),
      ],
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    super.key,
    required this.entries,
    required this.status,
    required this.empty,
    this.onRemove,
  });
  final List<HistoryEntry> entries;
  final Future<FileStatus> Function(DocLocation) status;
  final String empty;
  final void Function(HistoryEntry)? onRemove;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            empty,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        return HistoryTile(
          entry: e,
          status: status(e.location),
          onOpen: () => Navigator.of(context).pop(OpenRequest(e.location)),
          onRemove: onRemove == null ? null : () => onRemove!(e),
        );
      },
    );
  }
}

/// Android: Browse is the system picker (starts in Downloads).
class _SystemBrowse extends StatelessWidget {
  const _SystemBrowse({required this.files});
  final FileService files;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              'Pick a PDF from Downloads, Documents, Drive or any storage.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.search),
              label: const Text('Browse files…'),
              onPressed: () => _pick(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await files.pickDocument();
    if (picked != null && context.mounted) {
      Navigator.of(context).pop(OpenRequest(picked.location, picked));
    }
  }
}

/// iOS: in-app browser of the app Documents folder plus the Files picker.
class FolderBrowser extends StatefulWidget {
  const FolderBrowser({super.key, required this.files});
  final FileService files;

  @override
  State<FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends State<FolderBrowser> {
  String? _root;
  String? _dir;
  Future<List<FileSystemEntity>>? _listing;

  @override
  void initState() {
    super.initState();
    widget.files.browseRoot().then((r) {
      if (!mounted) return;
      setState(() {
        _root = r;
        _go(r);
      });
    });
  }

  void _go(String dir) {
    _dir = dir;
    _listing = widget.files
        .listDir(dir)
        .catchError((_) => <FileSystemEntity>[]);
  }

  String _name(FileSystemEntity e) =>
      e.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? e.path;

  Future<void> _pickSystem() async {
    final picked = await widget.files.pickDocument();
    if (picked != null && mounted) {
      Navigator.of(context).pop(OpenRequest(picked.location, picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final root = _root, dir = _dir;
    final scheme = Theme.of(context).colorScheme;
    final atRoot = dir == null || dir == root;
    final crumb = root == null || dir == null
        ? ''
        : 'On My iPhone ▸ Basic PDF${dir.substring(root.length).replaceAll('/', ' ▸ ')}';
    return Column(
      children: [
        ListTile(
          leading: atRoot
              ? const Icon(Icons.phone_iphone)
              : IconButton(
                  tooltip: 'Up',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: () =>
                      setState(() => _go(Directory(dir).parent.path)),
                ),
          // The breadcrumb gets the whole row (wrapping if needed) so it
          // isn't squeezed next to the button; the button sits below it.
          title: Text(crumb, key: const ValueKey('breadcrumb')),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _pickSystem,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Browse Files…'),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder<List<FileSystemEntity>>(
            future: _listing,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final items = snap.data!;
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No PDFs here. Put files in On My iPhone ▸ Basic PDF '
                      'with the Files app, or tap Browse Files…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final e = items[i];
                  final isDir = e is Directory;
                  return ListTile(
                    leading: Icon(
                      isDir
                          ? Icons.folder_outlined
                          : Icons.picture_as_pdf_outlined,
                    ),
                    title: Text(
                      Uri.decodeComponent(_name(e)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: isDir ? const Icon(Icons.chevron_right) : null,
                    onTap: () {
                      if (isDir) {
                        setState(
                          () => _go(
                            e.path.endsWith('/')
                                ? e.path.substring(0, e.path.length - 1)
                                : e.path,
                          ),
                        );
                      } else {
                        Navigator.of(context).pop(
                          OpenRequest(widget.files.locationForPath(e.path)),
                        );
                      }
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
