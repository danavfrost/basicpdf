import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/services/doc_location.dart';
import 'package:pdfedit/services/file_service.dart';

/// In-memory PdfEditDoc for UI tests.
class FakeEditDoc implements PdfEditDoc {
  FakeEditDoc(
    this.fields, {
    this.permissions = PdfPermissions.all,
    this.failWith,
  });
  final PdfCoreException? failWith;
  @override
  final List<PdfField> fields;
  @override
  final PdfPermissions permissions;
  final applied = <List<PdfChange>>[];

  @override
  Uint8List get bytes => Uint8List.fromList('%PDF-1.7 fake'.codeUnits);

  /// Distinct from [bytes] so tests can see which one the viewer got.
  @override
  Uint8List get displayBytes => _display;
  final _display = Uint8List.fromList('%PDF-1.7 display'.codeUnits);
  @override
  Uint8List get editDisplayBytes => _display;
  @override
  bool get isEncrypted => false;
  @override
  bool get isOwner => true;
  @override
  List<PdfPageInfo> get pages => const [PdfPageInfo(0, 612, 792)];

  /// Field ids whose current text should report "doesn't fit".
  final overflowing = <String>{};
  @override
  PdfTextFit textFit(PdfField field, String value) => PdfTextFit(
    fits: !(overflowing.contains(field.id) && value.length > 3),
    fontSize: field.fontSize > 0 ? field.fontSize : 12,
  );
  @override
  bool textFits(PdfField field, String value) => textFit(field, value).fits;
  @override
  PdfEditDoc applyChanges(List<PdfChange> changes) {
    if (failWith != null) throw failWith!;
    applied.add(changes);
    return this;
  }
}

/// FileService fake: no platform channels.
class FakeFileService extends FileService {
  FakeFileService({
    this.hasInAppBrowser = false,
    this.root = '/',
    this.missing = const {},
    this.noAccess = const {},
    this.picked,
  });

  @override
  final bool hasInAppBrowser;
  final String root;
  final Set<String> missing;
  final Set<String> noAccess;
  PickedDoc? picked;
  int pickCalls = 0;

  @override
  bool get usesSystemSaveAs => true;
  @override
  Future<String> browseRoot() async => root;
  @override
  Future<bool> exists(DocLocation location) async =>
      !missing.contains(location.name);
  @override
  Future<FileStatus> status(DocLocation location) async =>
      missing.contains(location.name)
      ? FileStatus.missing
      : noAccess.contains(location.name)
      ? FileStatus.noAccess
      : FileStatus.ok;
  @override
  Future<PickedDoc?> pickDocument() async {
    pickCalls++;
    return picked;
  }

  @override
  Future<(Uint8List, DocLocation)> read(DocLocation location) async =>
      throw const FileMissingException();
  @override
  Future<void> write(DocLocation location, Uint8List bytes) async {}
  @override
  Future<DocLocation?> saveAsSystem(
    String suggestedName,
    Uint8List bytes,
  ) async => null;
  @override
  Future<FolderTarget> defaultFolder() async =>
      const FolderTarget(LocationKind.path, '/', 'Docs');
  @override
  Future<FolderTarget?> pickFolder() async => null;
  @override
  Future<bool> existsInFolder(FolderTarget folder, String name) async => false;
  @override
  Future<DocLocation> writeInFolder(
    FolderTarget folder,
    String name,
    Uint8List bytes,
  ) async => FileService.pathLocation('${folder.ref}/$name');
  @override
  Future<PickedDoc?> initialDoc() async {
    final e = initialError;
    if (e != null) throw e;
    return null;
  }

  /// initialDoc() fails with this (e.g. no access to a shared file).
  Object? initialError;
  @override
  Stream<PickedDoc> get incoming => const Stream.empty();
}

DocLocation loc(String name, {String folder = 'Download'}) => DocLocation(
  kind: LocationKind.contentUri,
  ref: 'content://test/$name',
  name: name,
  folder: folder,
);

Future<Directory> tempDir() => Directory.systemTemp.createTemp('pdfedit_test');
