import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'doc_location.dart';

/// The file can't be read any more (deleted, moved, access revoked).
class FileMissingException implements Exception {
  final String message;
  const FileMissingException([this.message = 'File not found']);
  @override
  String toString() => message;
}

/// Whether a remembered document can be opened again.
enum FileStatus {
  ok,

  /// The file is gone (deleted or moved).
  missing,

  /// The file may still exist but our access expired (Android "Open with"
  /// grants that weren't persistable, iOS bookmarks that went stale).
  noAccess,
}

/// Platform file access. Android goes through the Storage Access Framework
/// (content:// URIs with persisted permissions); iOS uses the app Documents
/// folder plus security-scoped bookmarks for files picked elsewhere.
abstract class FileService {
  /// iOS: true — Browse shows an in-app listing of the app Documents folder.
  /// Android: false — Browse is the system picker only.
  bool get hasInAppBrowser;

  /// Android: Save As goes straight to the system "create document" screen.
  bool get usesSystemSaveAs;

  /// Root folder of the in-app browser (iOS app Documents).
  Future<String> browseRoot();

  /// Folders and .pdf files in [dir], folders first, then by name.
  Future<List<FileSystemEntity>> listDir(String dir) async {
    final out = <FileSystemEntity>[];
    await for (final e in Directory(dir).list(followLinks: false)) {
      final name =
          e.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
      if (name.startsWith('.')) continue;
      if (e is Directory ||
          (e is File && name.toLowerCase().endsWith('.pdf'))) {
        out.add(e);
      }
    }
    out.sort((a, b) {
      final ad = a is Directory, bd = b is Directory;
      if (ad != bd) return ad ? -1 : 1;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });
    return out;
  }

  /// System document picker. Null if cancelled.
  Future<PickedDoc?> pickDocument();

  /// Reads the file. May return a refreshed location (iOS stale bookmark).
  /// Throws [FileMissingException] when it can't be opened any more.
  Future<(Uint8List, DocLocation)> read(DocLocation location);

  /// Writes [bytes] back to [location]. Throws on failure.
  Future<void> write(DocLocation location, Uint8List bytes);

  /// Whether [location] still resolves to a readable file.
  Future<bool> exists(DocLocation location);

  /// Like [exists], but tells a missing file from one we lost access to.
  Future<FileStatus> status(DocLocation location) async =>
      await exists(location) ? FileStatus.ok : FileStatus.missing;

  /// Android: ACTION_CREATE_DOCUMENT in Documents with [suggestedName],
  /// writes [bytes]. Null if cancelled.
  Future<DocLocation?> saveAsSystem(String suggestedName, Uint8List bytes);

  /// iOS Save As default folder (app Documents).
  Future<FolderTarget> defaultFolder();

  /// iOS: system folder picker. Null if cancelled.
  Future<FolderTarget?> pickFolder();

  /// Whether [name] already exists in [folder] (best effort).
  Future<bool> existsInFolder(FolderTarget folder, String name);

  Future<DocLocation> writeInFolder(
    FolderTarget folder,
    String name,
    Uint8List bytes,
  );

  /// A document another app asked us to open at launch.
  Future<PickedDoc?> initialDoc();

  /// Documents handed to us while running.
  Stream<PickedDoc> get incoming;

  /// Location to remember for a file at [path] (in-app browser).
  DocLocation locationForPath(String path) => pathLocation(path);

  /// Location for a plain file path.
  static DocLocation pathLocation(String path) {
    final f = File(path);
    final parts = f.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return DocLocation(
      kind: LocationKind.path,
      ref: path,
      name: parts.isEmpty ? path : Uri.decodeComponent(parts.last),
      folder: parts.length < 2
          ? ''
          : Uri.decodeComponent(parts[parts.length - 2]),
    );
  }
}

class PlatformFileService extends FileService {
  static const _channel = MethodChannel('com.halworks.basicpdf/files');
  final _incoming = StreamController<PickedDoc>.broadcast();

  PlatformFileService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'incoming' && call.arguments is Map) {
        final doc = await _pickedFrom(call.arguments as Map);
        if (doc != null) _incoming.add(doc);
      }
      return null;
    });
  }

  // File contents never cross the method channel (the codec copies them
  // several times; large PDFs ran Android out of heap). The platform side
  // copies a document into a temp file and hands us its path; for writes
  // we write a temp file and hand over its path. The consumer deletes it.

  /// Reads the temp file the platform side described in [m] and deletes it.
  static Future<Uint8List?> _takeFile(Map? m) async {
    final legacy = m?['bytes'];
    if (legacy is Uint8List) return legacy;
    final path = m?['path'];
    if (path is! String) return null;
    final f = File(path);
    try {
      return await f.readAsBytes();
    } finally {
      if (m?['temp'] == true) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }

  static int _outSeq = 0;

  /// Writes [bytes] to a fresh temp file for the platform side to consume.
  static Future<String> _outFile(Uint8List bytes) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/xfer-out');
    await dir.create(recursive: true);
    final f = File(
      '${dir.path}/out-${DateTime.now().microsecondsSinceEpoch}-${_outSeq++}.pdf',
    );
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  /// Runs [call] with a temp file holding [bytes]; removes it afterwards if
  /// the platform side didn't (e.g. the call failed before reaching it).
  static Future<T> _withOutFile<T>(
    Uint8List bytes,
    Future<T> Function(String path) call,
  ) async {
    final path = await _outFile(bytes);
    try {
      return await call(path);
    } finally {
      final f = File(path);
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  // iOS changes the app container path on updates, so files in our
  // Documents folder are stored relative to it ("~docs/name.pdf").
  static const _docsPrefix = '~docs/';
  String? _docs;

  Future<String> _docsDir() async =>
      _docs ??= (await getApplicationDocumentsDirectory()).path;

  Future<String> _resolve(String ref) async => ref.startsWith(_docsPrefix)
      ? '${await _docsDir()}/${ref.substring(_docsPrefix.length)}'
      : ref;

  @override
  DocLocation locationForPath(String path) {
    final loc = FileService.pathLocation(path);
    final docs = _docs;
    if (docs != null && path.startsWith('$docs/')) {
      return DocLocation(
        kind: LocationKind.path,
        ref: '$_docsPrefix${path.substring(docs.length + 1)}',
        name: loc.name,
        folder: path.substring(docs.length + 1).contains('/')
            ? loc.folder
            : 'On My iPhone ▸ Basic PDF',
      );
    }
    return loc;
  }

  @override
  bool get hasInAppBrowser => Platform.isIOS;
  @override
  bool get usesSystemSaveAs => Platform.isAndroid;

  @override
  Future<String> browseRoot() => _docsDir();

  static DocLocation? _locationFrom(Map m) {
    final kind = switch (m['kind']) {
      'contentUri' => LocationKind.contentUri,
      'bookmark' => LocationKind.bookmark,
      'path' => LocationKind.path,
      _ => null,
    };
    final ref = m['ref'];
    if (kind == null || ref is! String) return null;
    return DocLocation(
      kind: kind,
      ref: ref,
      name: (m['name'] as String?) ?? 'Document.pdf',
      folder: (m['folder'] as String?) ?? '',
      id: m['id'] as String?,
    );
  }

  static Future<PickedDoc?> _pickedFrom(Map m) async {
    final loc = _locationFrom(m);
    final bytes = await _takeFile(m);
    if (loc == null || bytes == null) return null;
    return PickedDoc(loc, bytes, writable: m['writable'] != false);
  }

  @override
  Future<PickedDoc?> pickDocument() async {
    final r = await _channel.invokeMethod<Map>('pickDocument');
    return r == null ? null : await _pickedFrom(r);
  }

  @override
  Future<(Uint8List, DocLocation)> read(DocLocation location) async {
    switch (location.kind) {
      case LocationKind.path:
        final f = File(await _resolve(location.ref));
        if (!await f.exists()) throw const FileMissingException();
        return (await f.readAsBytes(), location);
      case LocationKind.contentUri:
      case LocationKind.bookmark:
        try {
          final r = await _channel.invokeMethod<Map>('read', {
            'kind': location.kind.name,
            'ref': location.ref,
          });
          final bytes = await _takeFile(r);
          if (bytes == null) throw const FileMissingException();
          final newRef = r?['ref'];
          return (
            bytes,
            newRef is String && newRef != location.ref
                ? location.copyWith(ref: newRef)
                : location,
          );
        } on PlatformException catch (e) {
          throw FileMissingException(e.message ?? 'File not available');
        }
    }
  }

  @override
  Future<void> write(DocLocation location, Uint8List bytes) async {
    switch (location.kind) {
      case LocationKind.path:
        await _atomicWrite(File(await _resolve(location.ref)), bytes);
      case LocationKind.contentUri:
      case LocationKind.bookmark:
        await _withOutFile(
          bytes,
          (path) => _channel.invokeMethod('write', {
            'kind': location.kind.name,
            'ref': location.ref,
            'path': path,
          }),
        );
    }
  }

  static Future<void> _atomicWrite(File f, Uint8List bytes) async {
    final tmp = File('${f.path}.pdfedit-tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<bool> exists(DocLocation location) async {
    if (location.kind == LocationKind.path) {
      return File(await _resolve(location.ref)).exists();
    }
    try {
      return await _channel.invokeMethod<bool>('exists', {
            'kind': location.kind.name,
            'ref': location.ref,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<FileStatus> status(DocLocation location) async {
    if (location.kind == LocationKind.path) {
      return await File(await _resolve(location.ref)).exists()
          ? FileStatus.ok
          : FileStatus.missing;
    }
    try {
      final r = await _channel.invokeMethod<String>('status', {
        'kind': location.kind.name,
        'ref': location.ref,
      });
      return switch (r) {
        'ok' => FileStatus.ok,
        'noAccess' => FileStatus.noAccess,
        _ => FileStatus.missing,
      };
    } on PlatformException {
      return FileStatus.missing;
    } on MissingPluginException {
      return await exists(location) ? FileStatus.ok : FileStatus.missing;
    }
  }

  @override
  Future<DocLocation?> saveAsSystem(
    String suggestedName,
    Uint8List bytes,
  ) async {
    final r = await _withOutFile(
      bytes,
      (path) => _channel.invokeMethod<Map>('createDocument', {
        'name': suggestedName,
        'path': path,
      }),
    );
    return r == null ? null : _locationFrom(r);
  }

  @override
  Future<FolderTarget> defaultFolder() async {
    return FolderTarget(
      LocationKind.path,
      await _docsDir(),
      'On My iPhone ▸ Basic PDF',
    );
  }

  @override
  Future<FolderTarget?> pickFolder() async {
    final r = await _channel.invokeMethod<Map>('pickFolder');
    if (r == null) return null;
    return FolderTarget(
      LocationKind.bookmark,
      r['ref'] as String,
      (r['name'] as String?) ?? 'Folder',
    );
  }

  @override
  Future<bool> existsInFolder(FolderTarget folder, String name) async {
    if (folder.kind == LocationKind.path) {
      return File('${folder.ref}/$name').exists();
    }
    try {
      return await _channel.invokeMethod<bool>('existsInFolder', {
            'ref': folder.ref,
            'name': name,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<DocLocation> writeInFolder(
    FolderTarget folder,
    String name,
    Uint8List bytes,
  ) async {
    if (folder.kind == LocationKind.path) {
      final path = '${folder.ref}/$name';
      await _atomicWrite(File(path), bytes);
      await _docsDir();
      return locationForPath(path);
    }
    final r = await _withOutFile(
      bytes,
      (path) => _channel.invokeMethod<Map>('writeInFolder', {
        'ref': folder.ref,
        'name': name,
        'path': path,
      }),
    );
    final loc = r == null ? null : _locationFrom(r);
    if (loc == null) throw const FileMissingException('Could not save');
    return loc;
  }

  @override
  Future<PickedDoc?> initialDoc() async {
    try {
      final r = await _channel.invokeMethod<Map>('initialDoc');
      return r == null ? null : await _pickedFrom(r);
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Stream<PickedDoc> get incoming => _incoming.stream;
}
