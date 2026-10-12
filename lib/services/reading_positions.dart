import 'dart:convert';
import 'dart:io';

/// Where the reader was in a document: the page at the top of the view and
/// how far into it (0..1). Independent of zoom, screen size and rotation.
class ReadingPosition {
  final int page;
  final double fraction;

  /// Page count of the document it was saved for (sanity check on restore:
  /// a different file at the same location is not given this position).
  final int pageCount;

  const ReadingPosition(this.page, this.fraction, this.pageCount);

  /// True when this position belongs to a document with [pages] pages.
  bool fits(int pages) =>
      pages == pageCount && page >= 0 && page < pages && fraction.isFinite;

  Map<String, dynamic> toJson(DateTime at) => {
    'page': page,
    'fraction': double.parse(fraction.toStringAsFixed(4)),
    'pages': pageCount,
    'at': at.toIso8601String(),
  };

  static (ReadingPosition, DateTime)? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final page = j['page'], frac = j['fraction'], pages = j['pages'];
    final at = DateTime.tryParse('${j['at']}');
    if (page is! int || frac is! num || pages is! int || at == null) {
      return null;
    }
    return (ReadingPosition(page, frac.toDouble().clamp(0.0, 1.0), pages), at);
  }

  @override
  bool operator ==(Object other) =>
      other is ReadingPosition &&
      other.page == page &&
      (other.fraction - fraction).abs() < 1e-4 &&
      other.pageCount == pageCount;

  @override
  int get hashCode => Object.hash(page, (fraction * 1e4).round(), pageCount);

  @override
  String toString() => 'ReadingPosition($page, $fraction of $pageCount)';
}

/// Last reading position per file, keyed by [DocLocation.key] (the same
/// identity History uses), persisted as `positions.json` next to
/// `history.json` in the app support dir. Writes are atomic (temp + rename)
/// and merged with what is on disk, like [HistoryStore].
class ReadingPositions {
  /// Oldest positions beyond this are dropped.
  static const maxEntries = 500;

  final Future<Directory> Function() _dir;
  final DateTime Function() _now;
  final _entries = <String, (ReadingPosition, DateTime)>{};
  Future<void>? _loading;

  /// Writes run one after another (null: none yet).
  Future<void>? _saving;

  ReadingPositions(this._dir, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  Future<File> get _file async => File('${(await _dir()).path}/positions.json');

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final disk = await _readDisk();
    if (disk != null) {
      // Anything set before loading finished is newer.
      _entries.addAll({...disk, ..._entries});
    }
  }

  Future<Map<String, (ReadingPosition, DateTime)>?> _readDisk() async {
    try {
      final f = await _file;
      if (!await f.exists()) return null;
      final data = jsonDecode(await f.readAsString());
      if (data is! Map<String, dynamic>) return null;
      return {
        for (final e in data.entries) e.key: ?ReadingPosition.fromJson(e.value),
      };
    } catch (_) {
      return null; // corrupt: start over
    }
  }

  /// The saved position for [key] if it fits a document of [pageCount]
  /// pages (call after [load]).
  ReadingPosition? get(String key, int pageCount) {
    final p = _entries[key]?.$1;
    return p != null && p.fits(pageCount) ? p : null;
  }

  Future<void> set(String key, ReadingPosition position) {
    final cur = _entries[key]?.$1;
    if (cur == position) return _saving ?? Future.value();
    final at = _now();
    return _mutate((m) => m[key] = (position, at));
  }

  Future<void> remove(String key) => _mutate((m) => m.remove(key));

  Future<void> _mutate(
    void Function(Map<String, (ReadingPosition, DateTime)> m) change,
  ) {
    change(_entries);
    return _saving = (_saving ?? Future<void>.value()).then((_) async {
      try {
        await load();
        final disk = await _readDisk();
        if (disk != null) {
          change(disk);
          _entries
            ..clear()
            ..addAll(disk);
        }
        if (_entries.length > maxEntries) {
          final byAge = _entries.entries.toList()
            ..sort((a, b) => b.value.$2.compareTo(a.value.$2));
          for (final e in byAge.skip(maxEntries)) {
            _entries.remove(e.key);
          }
        }
        final snapshot = jsonEncode({
          for (final e in _entries.entries)
            e.key: e.value.$1.toJson(e.value.$2),
        });
        final f = await _file;
        await f.parent.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(snapshot, flush: true);
        await tmp.rename(f.path);
      } catch (_) {}
    });
  }
}
