// Hand-built PDF fixtures for core tests.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/core/src/edit_doc.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

Uint8List latin(String s) => Uint8List.fromList(latin1.encode(s));
String str(List<int> b) => latin1.decode(b);

/// Rows of an xref (type, field2, field3) keyed by object number.
typedef XrefRows = Map<int, (int, int, int)>;

enum XrefKind { table, stream, streamPredictor, none }

/// Builds a PDF from object bodies. [objects] maps object number → body
/// (the text between "n 0 obj" and "endobj"). [objStm] objects are stored
/// in an object stream (requires a stream xref kind).
Uint8List buildPdf(
  Map<int, String> objects, {
  String trailer = '/Root 1 0 R',
  XrefKind kind = XrefKind.table,
  Map<int, String> objStm = const {},
  String header = '%PDF-1.7\n%\xE2\xE3\xCF\xD3\n',
  String junkPrefix = '',
  int offsetError = 0,
}) {
  final sb = StringBuffer(junkPrefix + header);
  final rows = <int, (int, int, int)>{};
  int pos() => sb.length;
  final nums = objects.keys.toList()..sort();
  for (final n in nums) {
    rows[n] = (1, pos() - junkPrefix.length + offsetError, 0);
    sb.write('$n 0 obj\n${objects[n]}\nendobj\n');
  }
  var size =
      [...objects.keys, ...objStm.keys, 0].reduce((a, b) => a > b ? a : b) + 1;
  if (objStm.isNotEmpty) {
    final osNum = size++;
    final head = StringBuffer();
    final body = StringBuffer();
    var i = 0;
    for (final e in objStm.entries) {
      head.write('${e.key} ${latin1.encode(body.toString()).length} ');
      body.write('${e.value}\n');
      rows[e.key] = (2, osNum, i++);
    }
    final h = head.toString();
    final data = zlib.encode(latin1.encode(h + body.toString()));
    rows[osNum] = (1, pos() - junkPrefix.length, 0);
    sb.write(
      '$osNum 0 obj\n<< /Type /ObjStm /N ${objStm.length} '
      '/First ${h.length} /Filter /FlateDecode /Length ${data.length} >>\n'
      'stream\n${str(data)}\nendstream\nendobj\n',
    );
  }
  final xrefPos = pos() - junkPrefix.length;
  switch (kind) {
    case XrefKind.none:
      sb.write('trailer\n<< /Size $size $trailer >>\n%%EOF\n');
    case XrefKind.table:
      sb.write(xrefTable(rows, includeZero: true));
      sb.write(
        'trailer\n<< /Size $size $trailer >>\n'
        'startxref\n$xrefPos\n%%EOF\n',
      );
    case XrefKind.stream:
    case XrefKind.streamPredictor:
      final xn = size++;
      rows[xn] = (1, xrefPos, 0);
      sb.write(
        xrefStream(
          xn,
          rows,
          size,
          trailer,
          predictor: kind == XrefKind.streamPredictor,
          includeZero: true,
        ),
      );
      sb.write('startxref\n$xrefPos\n%%EOF\n');
  }
  return latin(sb.toString());
}

String xrefTable(XrefRows rows, {bool includeZero = false}) {
  final sb = StringBuffer('xref\n');
  if (includeZero) sb.write('0 1\n0000000000 65535 f \n');
  final nums = rows.keys.toList()..sort();
  for (final n in nums) {
    final r = rows[n]!;
    sb.write(
      '$n 1\n${r.$2.toString().padLeft(10, '0')} '
      '${r.$3.toString().padLeft(5, '0')} n \n',
    );
  }
  return sb.toString();
}

String xrefStream(
  int num,
  XrefRows rows,
  int size,
  String trailer, {
  bool predictor = false,
  bool includeZero = false,
  int? prev,
}) {
  final nums = rows.keys.toList()..sort();
  final index = <int>[];
  final raw = <List<int>>[];
  if (includeZero) {
    index.addAll([0, 1]);
    raw.add([0, 0, 0, 0, 0, 0xff, 0xff]);
  }
  for (final n in nums) {
    index.addAll([n, 1]);
    final r = rows[n]!;
    raw.add([
      r.$1,
      (r.$2 >> 24) & 0xff,
      (r.$2 >> 16) & 0xff,
      (r.$2 >> 8) & 0xff,
      r.$2 & 0xff,
      (r.$3 >> 8) & 0xff,
      r.$3 & 0xff,
    ]);
  }
  final bytes = <int>[];
  var prior = List<int>.filled(7, 0);
  for (final row in raw) {
    if (predictor) {
      bytes.add(2); // PNG Up
      for (var i = 0; i < 7; i++) {
        bytes.add((row[i] - prior[i]) & 0xff);
      }
      prior = row;
    } else {
      bytes.addAll(row);
    }
  }
  final data = zlib.encode(bytes);
  final dp = predictor ? '/DecodeParms << /Predictor 12 /Columns 7 >> ' : '';
  final pv = prev != null ? '/Prev $prev ' : '';
  return '$num 0 obj\n<< /Type /XRef /Size $size /W [1 4 2] '
      '/Index [${index.join(' ')}] $pv$trailer /Filter /FlateDecode $dp'
      '/Length ${data.length} >>\nstream\n${str(data)}\nendstream\nendobj\n';
}

/// Appends an incremental update section to [base].
Uint8List appendUpdate(
  Uint8List base,
  Map<int, String> objects, {
  String trailer = '/Root 1 0 R',
  bool stream = false,
  int? size,
}) {
  final s = str(base);
  final sx = s.lastIndexOf('startxref');
  final prev = int.parse(
    RegExp(r'startxref\s+(\d+)').firstMatch(s.substring(sx))!.group(1)!,
  );
  final sb = StringBuffer(s);
  final rows = <int, (int, int, int)>{};
  for (final n in (objects.keys.toList()..sort())) {
    rows[n] = (1, sb.length, 0);
    sb.write('$n 0 obj\n${objects[n]}\nendobj\n');
  }
  var sz = size ?? ([...objects.keys, 0].reduce((a, b) => a > b ? a : b) + 1);
  final xrefPos = sb.length;
  if (stream) {
    final xn = sz++;
    rows[xn] = (1, xrefPos, 0);
    sb.write(xrefStream(xn, rows, sz, trailer, prev: prev));
  } else {
    sb.write(xrefTable(rows));
    sb.write('trailer\n<< /Size $sz $trailer /Prev $prev >>\n');
  }
  sb.write('startxref\n$xrefPos\n%%EOF\n');
  return latin(sb.toString());
}

/// A minimal one-page document with optional extra page keys / annots.
Map<int, String> simpleDoc({
  String pageExtra = '',
  String catalogExtra = '',
  int pages = 1,
}) {
  final kids = [for (var i = 0; i < pages; i++) '${3 + i} 0 R'].join(' ');
  return {
    1: '<< /Type /Catalog /Pages 2 0 R $catalogExtra >>',
    2: '<< /Type /Pages /Kids [$kids] /Count $pages >>',
    for (var i = 0; i < pages; i++)
      3 + i:
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] $pageExtra >>',
  };
}

CorePdfEditDoc core(PdfEditDoc d) => d as CorePdfEditDoc;

PdfField fieldNamed(PdfEditDoc d, String name, [int index = 0]) =>
    d.fields.where((f) => f.fullName == name).elementAt(index);

bool isPrefix(List<int> a, List<int> b) {
  if (a.length > b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Bytes appended after [base] in [full], as Latin-1 text.
String tailOf(Uint8List base, Uint8List full) => str(full.sublist(base.length));
