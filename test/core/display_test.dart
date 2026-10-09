import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/core/src/filters.dart';
import 'package:pdfedit/core/src/objects.dart';

import 'helpers.dart';

String? apText(PdfEditDoc d, String id) {
  final f = core(d).file;
  final w = f.resolve(PdfRef(int.parse(id.split(' ').first), 0)) as PdfDict;
  final ap = f.resolve(w['AP']);
  if (ap is! PdfDict) return null;
  final n = f.resolve(ap['N']);
  if (n is! PdfStream) return null;
  return str(decodeStreamData(n.data, n.dict));
}

void main() {
  group('displayBytes', () {
    for (final (name, pw) in [
      ('form.pdf', null),
      ('form_aes256.pdf', 'user'),
      ('form_rc4_128_owneronly.pdf', null),
      ('form_objstm.pdf', null),
    ]) {
      test('$name: missing/empty appearances are generated', () {
        final b = fixture(name);
        final d = PdfEditDoc.open(b, password: pw);
        // The fixture's "name" has an empty placeholder appearance
        // ("/Tx BMC EMC") and "notes" none at all.
        final disp = d.displayBytes;
        expect(identical(d.bytes, b), isTrue); // bytes untouched
        expect(identical(disp, d.bytes), isFalse);
        expect(isPrefix(b, disp), isTrue);
        expect(identical(d.displayBytes, disp), isTrue); // cached
        final r = PdfEditDoc.open(disp, password: pw);
        expect(apText(r, fieldNamed(r, 'name').id), contains('(Alice) Tj'));
        expect(apText(r, fieldNamed(r, 'notes').id), contains('(Line two) Tj'));
        expect(
          apText(r, fieldNamed(r, 'state').id),
          contains('(California) Tj'),
        );
        expect(apText(r, fieldNamed(r, 'uni').id), isNotNull);
        // radio kids got on/off appearances with /AS following /V
        final green = fieldNamed(r, 'color', 1);
        final w = core(r).file.resolve(
          PdfRef(int.parse(green.id.split(' ').first), 0),
        ) as PdfDict;
        expect(w['AS'], const PdfName('green'));
        // values unchanged
        expect(
          [for (final f in r.fields) f.value],
          [for (final f in d.fields) f.value],
        );
        // and the display version needs nothing more
        expect(identical(r.displayBytes, r.bytes), isTrue);
      });
    }

    test('complete documents return the identical bytes instance', () {
      final b = PdfEditDoc.createTextDocument('hello');
      final d = PdfEditDoc.open(b);
      expect(identical(d.displayBytes, d.bytes), isTrue);
      final plain = PdfEditDoc.open(buildPdf(simpleDoc()));
      expect(identical(plain.displayBytes, plain.bytes), isTrue);
      final e = d.applyChanges([SetFieldValue(d.fields.single.id, 'x')]);
      expect(identical(e.displayBytes, e.bytes), isTrue);
    });

    test('empty values with no appearance need nothing', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [5 0 R]',
        catalogExtra: '/AcroForm << /Fields [5 0 R] >>',
      );
      objs[5] = '<< /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 50 20] >>';
      final d = PdfEditDoc.open(buildPdf(objs));
      expect(identical(d.displayBytes, d.bytes), isTrue);
    });

    test('NeedAppearances true: regenerated and cleared in display only', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [5 0 R]',
        catalogExtra: '/AcroForm 9 0 R',
      );
      objs[9] = '<< /Fields [5 0 R] /NeedAppearances true >>';
      objs[5] =
          '<< /Subtype /Widget /FT /Tx /T (a) /V (val) /Rect [0 0 50 20] '
          '/AP << /N 6 0 R >> >>';
      objs[6] = '<< /Length 22 >>\nstream\n/Tx BMC BT (old) Tj ET\nendstream';
      final b = buildPdf(objs);
      final d = PdfEditDoc.open(b);
      final r = PdfEditDoc.open(d.displayBytes);
      expect(apText(r, r.fields.single.id), contains('(val) Tj'));
      final af = core(r).file.resolve(const PdfRef(9, 0)) as PdfDict;
      expect(af['NeedAppearances'], false);
      expect(identical(d.bytes, b), isTrue);
    });

    test('existing non-empty appearance is trusted', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [5 0 R]',
        catalogExtra: '/AcroForm << /Fields [5 0 R] >>',
      );
      objs[5] =
          '<< /Subtype /Widget /FT /Tx /T (a) /V (val) /Rect [0 0 50 20] '
          '/AP << /N 6 0 R >> >>';
      objs[6] = '<< /Length 22 >>\nstream\n/Tx BMC BT (val) Tj ET\nendstream';
      final d = PdfEditDoc.open(buildPdf(objs));
      expect(identical(d.displayBytes, d.bytes), isTrue);
    });
  });

  group('field rotation', () {
    test('page /Rotate combined with /MK /R', () {
      final objs = <int, String>{
        1: '<< /Type /Catalog /Pages 2 0 R >>',
        2: '<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>',
        3:
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] '
            '/Annots [6 0 R 7 0 R] >>',
        4:
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Rotate 90 '
            '/Annots [8 0 R 9 0 R] >>',
        5:
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Rotate 270 '
            '/Annots [10 0 R] >>',
        6: '<< /Subtype /Widget /FT /Tx /T (p0) /Rect [0 0 50 20] >>',
        7: '<< /Subtype /Widget /FT /Tx /T (p0r90) /MK << /R 90 >> /Rect [0 0 20 50] >>',
        8: '<< /Subtype /Widget /FT /Tx /T (p90) /Rect [0 0 50 20] >>',
        9: '<< /Subtype /Widget /FT /Tx /T (p90r90) /MK << /R 90 >> /Rect [0 0 20 50] >>',
        10: '<< /Subtype /Widget /FT /Tx /T (p270r270) /MK << /R 270 >> /Rect [0 0 20 50] >>',
      };
      final d = PdfEditDoc.open(buildPdf(objs));
      expect(
        {for (final f in d.fields) f.fullName: f.rotation},
        {
          'p0': 0,
          'p0r90': 270, // text turned CCW on an upright page
          'p90': 90, // page turned CW, text follows
          'p90r90': 0, // compensated: upright
          'p270r270': 0,
        },
      );
    });

    test('fields added on rotated pages read upright', () {
      final d = PdfEditDoc.open(fixture('form.pdf'));
      expect(fieldNamed(d, 'rotated').rotation, 0);
      final d2 = d.applyChanges(const [
        AddField(1, PdfRect(10, 10, 100, 20), PdfFieldKind.text, name: 'up'),
      ]);
      expect(fieldNamed(d2, 'up').rotation, 0);
      expect(
        const PdfField(
          id: '1 0',
          fullName: 'x',
          kind: PdfFieldKind.text,
          pageIndex: 0,
          rect: PdfRect(0, 0, 1, 1),
        ).rotation,
        0,
      );
    });
  });

  group('timing', () {
    for (final pages in [500, 2000]) {
      test('$pages-page generated document', () {
        // ~44 lines of text per page, one field per page
        final text = List.generate(
          pages * 44,
          (i) => 'Line $i of the test',
        ).join('\n');
        final b = PdfEditDoc.createTextDocument(text);
        final sw = Stopwatch()..start();
        final d = PdfEditDoc.open(b);
        final openMs = sw.elapsedMilliseconds;
        sw.reset();
        final n = d.pages.length, f = d.fields.length;
        final getMs = sw.elapsedMicroseconds;
        sw.reset();
        final disp = d.displayBytes;
        final dispMs = sw.elapsedMilliseconds;
        // ignore: avoid_print
        print(
          '$pages pages (${b.length ~/ 1024} KB): open ${openMs}ms, '
          'pages+fields getters ${getMs}us, displayBytes ${dispMs}ms',
        );
        expect(n, pages);
        expect(f, pages);
        expect(identical(disp, d.bytes), isTrue);
        expect(openMs, lessThan(1000));
      });
    }
  });
}
