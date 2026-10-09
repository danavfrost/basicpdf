/// Where a document lives, in a form that can be persisted in History and
/// used later to read it again and write it back.
enum LocationKind {
  /// A plain filesystem path (iOS app Documents folder, tests).
  path,

  /// An Android content:// URI (Storage Access Framework).
  contentUri,

  /// An iOS security-scoped bookmark (base64) for a file outside the sandbox.
  bookmark,
}

class DocLocation {
  final LocationKind kind;

  /// Path, content URI, or base64 bookmark data, depending on [kind].
  final String ref;

  /// File name shown to the user (e.g. "form.pdf").
  final String name;

  /// Folder / provider shown under the name ("Download", "iCloud Drive", ...).
  final String folder;

  /// Stable identity for de-duplicating History. For bookmarks the bookmark
  /// data can change when refreshed, so the resolved path is used instead.
  final String id;

  const DocLocation({
    required this.kind,
    required this.ref,
    required this.name,
    this.folder = '',
    String? id,
  }) : id = id ?? ref;

  String get key => '${kind.name}:$id';

  DocLocation copyWith({String? ref, String? name, String? folder}) =>
      DocLocation(
        kind: kind,
        ref: ref ?? this.ref,
        name: name ?? this.name,
        folder: folder ?? this.folder,
        id: id,
      );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'ref': ref,
    'name': name,
    'folder': folder,
    'id': id,
  };

  static DocLocation? fromJson(Map<String, dynamic> j) {
    final kind = LocationKind.values
        .where((k) => k.name == j['kind'])
        .firstOrNull;
    final ref = j['ref'];
    if (kind == null || ref is! String) return null;
    return DocLocation(
      kind: kind,
      ref: ref,
      name: (j['name'] as String?) ?? 'Untitled.pdf',
      folder: (j['folder'] as String?) ?? '',
      id: j['id'] as String?,
    );
  }

  @override
  bool operator ==(Object other) => other is DocLocation && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// A file the user picked or that another app handed us, with its bytes.
class PickedDoc {
  final DocLocation location;
  final List<int> bytes;

  /// False when we only got read access (Save then falls back to Save As).
  final bool writable;
  const PickedDoc(this.location, this.bytes, {this.writable = true});
}

/// A folder chosen as a Save As target (iOS).
class FolderTarget {
  final LocationKind kind; // path or bookmark
  final String ref;
  final String displayName;
  const FolderTarget(this.kind, this.ref, this.displayName);
}
