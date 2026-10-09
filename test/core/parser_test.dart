import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/core/src/filters.dart';
import 'package:pdfedit/core/src/lexer.dart';
import 'package:pdfedit/core/src/objects.dart';
import 'package:pdfedit/core/src/pdf_file.dart';

import 'helpers.dart';

Object? parse(String s) => Lexer(latin(s)).parseValue();

void main() {
  group('lexer', () {
    test('numbers, booleans, null', () {
      expect(parse('42'), 42);
      expect(parse('-17'), -17);
      expect(parse('3.5'), 3.5);
      expect(parse('-.25'), -0.25);
      expect(parse('4.'), 4.0);
      expect(parse('+7'), 7);
      expect(parse('true'), true);
      expect(parse('false'), false);
      expect(parse('[null]'), [null]);
    });

    test('names with # escapes', () {
      expect(parse('/Name'), const PdfName('Name'));
      expect(parse('/A#20B'), const PdfName('A B'));
      expect(parse('/Off'), const PdfName('Off'));
      expect(parse('/'), const PdfName(''));
    });

    test('literal strings with escapes, nesting, octal, line continuation', () {
      PdfString s(String src) => parse(src) as PdfString;
      expect(s(r'(hello)').latin1Value, 'hello');
      expect(s(r'(a (nested) b)').latin1Value, 'a (nested) b');
      expect(
        s(r'(esc \( \) \\ \n\r\t\b\f)').latin1Value,
        'esc ( ) \\ \n\r\t\b\f',
      );
      expect(s(r'(\101\102C\7)').latin1Value, 'ABC\x07');
      expect(s('(split \\\nline)').latin1Value, 'split line');
      expect(s('(cr\r\nlf)').latin1Value, 'cr\nlf');
    });

    test('hex strings (odd length, whitespace)', () {
      final s = parse('<48 65 6C6C 6F7>') as PdfString;
      expect(s.latin1Value, 'Hellop');
      expect(s.hex, isTrue);
    });

    test('arrays, dicts, refs', () {
      final d = parse(
        '<< /A [1 2 0 R 3] /B << /C (x) >> /D 5 0 R /E null >>',
      ) as PdfDict;
      expect(d['A'], [1, const PdfRef(2, 0), 3]);
      expect((d['B'] as PdfDict)['C'], PdfString.latin1('x'));
      expect(d['D'], const PdfRef(5, 0));
      expect(d.containsKey('E'), isFalse);
    });

    test('comments are skipped', () {
      final d = parse('<< /A 1 % comment /B 2\n /C 3 >>') as PdfDict;
      expect(d['A'], 1);
      expect(d['B'], isNull);
      expect(d['C'], 3);
    });

    test('indirect object with stream and wrong /Length', () {
      final src = latin(
        '7 0 obj\n<< /Length 999 >>\nstream\nabcdef\n'
        'endstream\nendobj\n',
      );
      final o = parseIndirectObject(src, 0);
      expect(o.num, 7);
      expect(str((o.value as PdfStream).data), 'abcdef');
    });

    test('serialisation round-trips', () {
      final d = PdfDict({
        'Name': const PdfName('A B#'),
        'Str': PdfString.latin1('p(a)r\\en\n'),
        'Arr': [1, 2.5, -0.125, const PdfRef(3, 0), true, null],
        'Hex': PdfString(Uint8List.fromList([0, 255]), hex: true),
      });
      final back = parse(str(serializeObject(d))) as PdfDict;
      expect(back['Name'], const PdfName('A B#'));
      expect(back['Str'], PdfString.latin1('p(a)r\\en\n'));
      expect(back['Arr'], [1, 2.5, -0.125, const PdfRef(3, 0), true, null]);
      expect((back['Hex'] as PdfString).bytes, [0, 255]);
    });

    test('formatNumber', () {
      expect(formatNumber(1.0), '1');
      expect(formatNumber(0.5), '0.5');
      expect(formatNumber(-0.00001), '0');
      expect(formatNumber(12.34567), '12.3457');
    });
  });

  group('filters', () {
    test('FlateDecode and truncated data', () {
      final raw = latin('hello hello hello hello');
      final enc = Uint8List.fromList(zlib.encode(raw));
      expect(flateDecode(enc), raw);
      // missing checksum / truncated tail still yields data
      final cut = Uint8List.sublistView(enc, 0, enc.length - 4);
      expect(str(flateDecode(cut)), startsWith('hello'));
    });

    test('ASCIIHex, ASCII85, RunLength', () {
      expect(str(asciiHexDecode(latin('48 65 6c6C6F>'))), 'Hello');
      expect(str(asciiHexDecode(latin('414>'))), 'A@');
      expect(str(ascii85Decode(latin('<~87cURD]i,"Ebo80~>'))), 'Hello World!');
      expect(str(ascii85Decode(latin('87cURD]i,"Ebo7~>'))), 'Hello World');
      expect(ascii85Decode(latin('z~>')), [0, 0, 0, 0]);
      expect(
        runLengthDecode(Uint8List.fromList([2, 65, 66, 67, 254, 68, 128])),
        latin('ABCDDD'),
      );
    });

    test('LZW', () {
      // "-----A---B" encoded (example from the PDF spec)
      final enc = Uint8List.fromList([
        0x80,
        0x0B,
        0x60,
        0x50,
        0x22,
        0x0C,
        0x0C,
        0x85,
        0x01,
      ]);
      expect(str(lzwDecode(enc)), '-----A---B');
    });

    test('PNG predictors (Up, Sub, Paeth)', () {
      final parms = PdfDict({'Predictor': 12, 'Columns': 3});
      // rows: [1,2,3], [4,6,8] encoded with Up
      final data = Uint8List.fromList([2, 1, 2, 3, 2, 3, 4, 5]);
      expect(applyPredictor(data, parms), [1, 2, 3, 4, 6, 8]);
      final sub = Uint8List.fromList([1, 1, 1, 1]);
      expect(applyPredictor(sub, parms), [1, 2, 3]);
      final paeth = Uint8List.fromList([4, 5, 0, 0, 4, 1, 0, 0]);
      expect(applyPredictor(paeth, parms), [5, 5, 5, 6, 6, 6]);
    });

    test('decodeStreamData chains filters', () {
      final hexText = zlib
          .encode(latin('chained'))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final hex = latin('$hexText>');
      final d = PdfDict({
        'Filter': [
          const PdfName('ASCIIHexDecode'),
          const PdfName('FlateDecode'),
        ],
      });
      expect(str(decodeStreamData(hex, d)), 'chained');
    });
  });

  group('xref', () {
    test('classic table', () {
      final f = PdfFile.parse(buildPdf(simpleDoc()));
      expect(f.repaired, isFalse);
      expect(f.lastSectionIsStream, isFalse);
      expect((f.resolve(f.trailer['Root']) as PdfDict).name('Type'), 'Catalog');
    });

    test('xref stream with PNG predictor', () {
      for (final k in [XrefKind.stream, XrefKind.streamPredictor]) {
        final f = PdfFile.parse(buildPdf(simpleDoc(), kind: k));
        expect(f.repaired, isFalse, reason: '$k');
        expect(f.lastSectionIsStream, isTrue);
        expect(PdfEditDoc.open(f.data).pages.length, 1);
      }
    });

    test('object streams', () {
      final objs = simpleDoc(pages: 2);
      final inStm = {2: objs.remove(2)!, 4: objs.remove(4)!};
      final bytes = buildPdf(objs, objStm: inStm, kind: XrefKind.stream);
      final f = PdfFile.parse(bytes);
      expect(f.xref[2]!.type, 2);
      final d = PdfEditDoc.open(bytes);
      expect(d.pages.length, 2);
    });

    test('hybrid file (table + /XRefStm)', () {
      // Objects 2 (Pages) lives only in an object stream referenced from
      // the hybrid xref stream.
      final objs = simpleDoc();
      final pagesBody = objs.remove(2)!;
      var sb = StringBuffer('%PDF-1.5\n');
      final rows = <int, (int, int, int)>{};
      for (final n in [1, 3]) {
        rows[n] = (1, sb.length, 0);
        sb.write('$n 0 obj\n${objs[n]}\nendobj\n');
      }
      final head = '2 0 ';
      final osData = zlib.encode(latin(head + pagesBody));
      final osPos = sb.length;
      sb.write(
        '10 0 obj\n<< /Type /ObjStm /N 1 /First ${head.length} '
        '/Filter /FlateDecode /Length ${osData.length} >>\nstream\n'
        '${str(osData)}\nendstream\nendobj\n',
      );
      rows[10] = (1, osPos, 0);
      final xsPos = sb.length;
      sb.write(xrefStream(11, {2: (2, 10, 0)}, 12, ''));
      final xrefPos = sb.length;
      sb.write(xrefTable(rows, includeZero: true));
      sb.write(
        'trailer\n<< /Size 12 /Root 1 0 R /XRefStm $xsPos >>\n'
        'startxref\n$xrefPos\n%%EOF\n',
      );
      final f = PdfFile.parse(latin(sb.toString()));
      expect(f.repaired, isFalse);
      expect(f.lastSectionIsStream, isFalse);
      expect(f.xref[2]!.type, 2);
      expect(PdfEditDoc.open(f.data).pages.length, 1);
    });

    test('incremental updates: newer objects win across /Prev chain', () {
      final base = buildPdf(simpleDoc());
      final u1 = appendUpdate(base, {
        3: '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>',
      }, size: 4);
      final u2 = appendUpdate(
        u1,
        {3: '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 500 600] >>'},
        size: 4,
        stream: true,
      );
      final d1 = PdfEditDoc.open(u1);
      expect(d1.pages.single.width, 300);
      final d2 = PdfEditDoc.open(u2);
      expect(d2.pages.single.width, 500);
      expect(core(d2).file.lastSectionIsStream, isTrue);
    });

    test('damaged older section in /Prev chain: objects found by scan', () {
      final base = buildPdf(simpleDoc());
      // corrupt the original xref table, then add an update on top
      var s = str(base);
      s = s.replaceFirst('xref\n0 1', 'xrXX\n0 1');
      final u = appendUpdate(latin(s), {4: '<< /Unrelated true >>'}, size: 5);
      final d = PdfEditDoc.open(u);
      expect(d.pages.length, 1);
      expect(core(d).file.repaired, isFalse);
    });

    test('broken offsets fall back to scanning', () {
      final bytes = buildPdf(simpleDoc(), offsetError: 7);
      final d = PdfEditDoc.open(bytes);
      expect(d.pages.length, 1);
    });

    test('missing xref and startxref → repaired', () {
      final bytes = buildPdf(simpleDoc(pages: 3), kind: XrefKind.none);
      final d = PdfEditDoc.open(bytes);
      expect(core(d).file.repaired, isTrue);
      expect(d.pages.length, 3);
    });

    test('garbage startxref → repaired; repaired file can be updated', () {
      var s = str(buildPdf(simpleDoc()));
      s = s.replaceFirst(RegExp(r'startxref\s+\d+'), 'startxref\n999999');
      final d = PdfEditDoc.open(latin(s));
      expect(core(d).file.repaired, isTrue);
      final d2 = d.applyChanges([
        const AddField(
          0,
          PdfRect(10, 10, 100, 20),
          PdfFieldKind.text,
          value: 'x',
        ),
      ]);
      expect(d2.fields.single.value, 'x');
      expect(isPrefix(latin(s), d2.bytes), isTrue);
    });

    test('junk before header: offsets relative to header', () {
      final bytes = buildPdf(simpleDoc(), junkPrefix: 'GARBAGE-PREFIX\n');
      final d = PdfEditDoc.open(bytes);
      expect(d.pages.length, 1);
    });

    test('off-by-one first subsection (starts at 1 with free entry)', () {
      var s = str(buildPdf(simpleDoc()));
      // Rewrite the "0 1 / 0000000000 65535 f" header as subsection "1 1"
      // followed by entries meant for 0..
      s = s.replaceFirst('xref\n0 1\n', 'xref\n1 1\n');
      final d = PdfEditDoc.open(latin(s));
      expect(d.pages.length, 1);
    });

    test('indirect /Length', () {
      final objs = simpleDoc(pageExtra: '/Contents 9 0 R');
      objs[9] = '<< /Length 10 0 R >>\nstream\nBT ET\nendstream';
      objs[10] = '5';
      final d = PdfEditDoc.open(buildPdf(objs));
      final c = core(d).file.resolve(const PdfRef(9, 0)) as PdfStream;
      expect(str(c.data), 'BT ET');
    });

    test('not a PDF', () {
      expect(
        () => PdfEditDoc.open(latin('hello world')),
        throwsA(isA<PdfCoreException>()),
      );
      expect(
        () => PdfEditDoc.open(Uint8List(0)),
        throwsA(isA<PdfCoreException>()),
      );
    });

    test('page tree inheritance (MediaBox, CropBox, Rotate)', () {
      final objs = {
        1: '<< /Type /Catalog /Pages 2 0 R >>',
        2:
            '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 3 '
            '/MediaBox [0 0 400 500] /Rotate 90 >>',
        3: '<< /Type /Page /Parent 2 0 R >>',
        4:
            '<< /Type /Pages /Parent 2 0 R /Kids [5 0 R] /Count 1 '
            '/CropBox [10 20 210 320] >>',
        5: '<< /Type /Page /Parent 4 0 R /Rotate -90 >>',
      };
      final d = PdfEditDoc.open(buildPdf(objs));
      expect(d.pages.length, 2);
      expect([d.pages[0].width, d.pages[0].height], [500, 400]);
      expect([d.pages[1].width, d.pages[1].height], [300, 200]);
    });

    test('lazy loading: a 500-page document parses few objects', () {
      final objs = <int, String>{1: '<< /Type /Catalog /Pages 2 0 R >>'};
      final kids = <String>[];
      var n = 3;
      for (var i = 0; i < 500; i++) {
        final page = n++, content = n++;
        kids.add('$page 0 R');
        objs[page] =
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/Contents $content 0 R >>';
        objs[content] =
            '<< /Length 20 >>\nstream\nBT /F1 12 Tf (p$i) Tj\nendstream';
      }
      objs[2] = '<< /Type /Pages /Kids [${kids.join(' ')}] /Count 500 >>';
      final bytes = buildPdf(objs);
      final sw = Stopwatch()..start();
      final d = PdfEditDoc.open(bytes);
      sw.stop();
      expect(d.pages.length, 500);
      // Only catalog, page tree and pages were loaded — no content streams.
      final loaded = core(d).file.loadedObjectCount;
      expect(loaded, lessThanOrEqualTo(503));
      expect(identical(d.bytes, bytes), isTrue);
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });
}
