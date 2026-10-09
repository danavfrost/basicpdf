import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';

import 'helpers.dart';

void expectRect(PdfRect r, List<double> ltwh, {double tol = 0.01}) {
  expect(r.left, closeTo(ltwh[0], tol), reason: '$r');
  expect(r.top, closeTo(ltwh[1], tol), reason: '$r');
  expect(r.width, closeTo(ltwh[2], tol), reason: '$r');
  expect(r.height, closeTo(ltwh[3], tol), reason: '$r');
}

void main() {
  group('form.pdf field model', () {
    late PdfEditDoc d;
    setUp(() => d = PdfEditDoc.open(fixture('form.pdf')));

    test('pages', () {
      expect(d.pages.length, 3);
      expect([d.pages[0].width, d.pages[0].height], [612, 792]);
      expect([d.pages[1].width, d.pages[1].height], [792, 612]); // /Rotate 90
      expect([d.pages[2].width, d.pages[2].height], [500, 600]); // CropBox
      expect(d.isEncrypted, isFalse);
      expect(d.isOwner, isTrue);
      expect(d.permissions.canLayoutFields, isTrue);
    });

    test('kinds and names', () {
      final kinds = {for (final f in d.fields) f.fullName: f.kind};
      expect(kinds, {
        'name': PdfFieldKind.text,
        'notes': PdfFieldKind.multilineText,
        'dup': PdfFieldKind.text,
        'person.first': PdfFieldKind.text,
        'person.age': PdfFieldKind.text,
        'agree': PdfFieldKind.checkbox,
        'color': PdfFieldKind.radio,
        'state': PdfFieldKind.comboBox,
        'fruit': PdfFieldKind.listBox,
        'sig': PdfFieldKind.signature,
        'reset': PdfFieldKind.unknown,
        'fixed': PdfFieldKind.text,
        'uni': PdfFieldKind.text,
        'rotated': PdfFieldKind.text,
        'cropped': PdfFieldKind.text,
      });
      expect(d.fields.length, 18);
      expect(d.fields.where((f) => f.fullName == 'dup').length, 2);
      expect(d.fields.where((f) => f.fullName == 'color').length, 3);
      // ids are "num gen" and unique
      final ids = d.fields.map((f) => f.id).toSet();
      expect(ids.length, 18);
      expect(ids.every((i) => RegExp(r'^\d+ \d+$').hasMatch(i)), isTrue);
    });

    test('values, flags and inherited attributes', () {
      final name = fieldNamed(d, 'name');
      expect(name.value, 'Alice');
      expect(name.fontSize, 10);
      expectRect(name.rect, [72, 92, 200, 20]);
      final notes = fieldNamed(d, 'notes');
      expect(notes.value, 'Line one\nLine two');
      expect(notes.required, isTrue);
      expect(notes.fontSize, 0);
      expect(fieldNamed(d, 'dup', 1).value, 'same');
      expect(fieldNamed(d, 'dup', 1).fontSize, 9);
      final age = fieldNamed(d, 'person.age');
      expect(age.maxLength, 3);
      expect(age.fontSize, 11); // DA inherited from parent
      expect(fieldNamed(d, 'fixed').readOnly, isTrue);
      expect(fieldNamed(d, 'fixed').fontSize, 0); // AcroForm DA
      expect(fieldNamed(d, 'uni').value, 'Grüße €');
    });

    test('buttons', () {
      final agree = fieldNamed(d, 'agree');
      expect(agree.value, 'Off');
      expect(agree.onValue, 'Yes');
      final radios = d.fields.where((f) => f.fullName == 'color').toList();
      expect(radios.map((r) => r.onValue), ['red', 'green', 'blue']);
      expect(radios.every((r) => r.value == 'green'), isTrue);
    });

    test('choices', () {
      final state = fieldNamed(d, 'state');
      expect(state.value, 'CA');
      expect(state.options, [('CA', 'California'), ('NY', 'New York')]);
      final fruit = fieldNamed(d, 'fruit');
      expect(fruit.value, 'Pear');
      expect(fruit.options, [
        ('Apple', 'Apple'),
        ('Pear', 'Pear'),
        ('Plum', 'Plum'),
      ]);
    });

    test('rotated and cropped pages map to display space', () {
      final rot = fieldNamed(d, 'rotated');
      expect(rot.pageIndex, 1);
      expectRect(rot.rect, [100, 100, 30, 200]);
      final crop = fieldNamed(d, 'cropped');
      expect(crop.pageIndex, 2);
      expectRect(crop.rect, [50, 80, 100, 20]);
    });

    test('other producers yield the same model', () {
      String sig(PdfEditDoc x) =>
          (x.fields
                  .map(
                    (f) =>
                        '${f.fullName}|${f.kind}|${f.pageIndex}|${f.value}|${f.onValue}|'
                        '${f.rect.left.round()},${f.rect.top.round()}',
                  )
                  .toList()
                ..sort())
              .join('\n');
      final base = sig(d);
      for (final n in ['form_objstm.pdf', 'form_linearized.pdf']) {
        expect(sig(PdfEditDoc.open(fixture(n))), base, reason: n);
      }
    });
  });

  group('page rotation', () {
    PdfEditDoc rotDoc() {
      final objs = <int, String>{
        1:
            '<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields '
            '[7 0 R 8 0 R 9 0 R 10 0 R] >> >>',
        2: '<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 >>',
      };
      for (var i = 0; i < 4; i++) {
        objs[3 + i] =
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] '
            '/CropBox [10 20 510 720] /Rotate ${i * 90} /Annots [${7 + i} 0 R] >>';
        objs[7 + i] =
            '<< /Type /Annot /Subtype /Widget /FT /Tx /T (f$i) '
            '/Rect [110 220 160 240] /P ${3 + i} 0 R >>';
      }
      return PdfEditDoc.open(buildPdf(objs));
    }

    test('display rects for 0/90/180/270', () {
      final d = rotDoc();
      // crop: x 10..510 (w 500), y 20..720 (h 700); widget user rect
      // [110 220 160 240] → unrotated display l=100 t=480 w=50 h=20
      expect([d.pages[0].width, d.pages[0].height], [500, 700]);
      expect([d.pages[1].width, d.pages[1].height], [700, 500]);
      expectRect(fieldNamed(d, 'f0').rect, [100, 480, 50, 20]);
      expectRect(fieldNamed(d, 'f1').rect, [700 - 500, 100, 20, 50]);
      expectRect(fieldNamed(d, 'f2').rect, [500 - 150, 700 - 500, 50, 20]);
      expectRect(fieldNamed(d, 'f3').rect, [480, 500 - 150, 20, 50]);
    });

    test('added and moved fields round-trip through display space', () {
      final d = rotDoc();
      const r = PdfRect(33, 44, 120, 30);
      final changes = <PdfChange>[
        for (var p = 0; p < 4; p++)
          AddField(p, r, PdfFieldKind.text, name: 'n$p'),
        MoveField(fieldNamed(d, 'f1').id, const PdfRect(5, 6, 70, 25)),
      ];
      final d2 = d.applyChanges(changes);
      for (var p = 0; p < 4; p++) {
        final f = fieldNamed(d2, 'n$p');
        expect(f.pageIndex, p);
        expectRect(f.rect, [33, 44, 120, 30]);
      }
      expectRect(fieldNamed(d2, 'f1').rect, [5, 6, 70, 25]);
      // added fields on rotated pages carry /MK /R so text is upright
      final tail = tailOf(d.bytes, d2.bytes);
      expect(RegExp(r'/R 90\b').hasMatch(tail), isTrue);
      expect(RegExp(r'/R 270\b').hasMatch(tail), isTrue);
      expect(tail.contains('/Matrix [0 1 -1 0'), isTrue);
    });
  });

  group('widget discovery', () {
    test('orphan widgets without AcroForm are found via /Annots', () {
      final objs = simpleDoc(pageExtra: '/Annots [5 0 R 6 0 R 7 0 R]');
      objs[5] =
          '<< /Type /Annot /Subtype /Widget /FT /Tx /T (orphan) '
          '/V (v) /Rect [0 0 10 10] >>';
      objs[6] = '<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] >>';
      objs[7] =
          '<< /Type /Annot /Subtype /Widget /Parent 8 0 R '
          '/Rect [20 0 30 10] >>';
      objs[8] = '<< /FT /Btn /T (kid) /V /On /Kids [7 0 R] >>';
      final d = PdfEditDoc.open(buildPdf(objs));
      expect(d.fields.map((f) => f.fullName), ['orphan', 'kid']);
      expect(fieldNamed(d, 'kid').kind, PdfFieldKind.checkbox);
      expect(fieldNamed(d, 'kid').value, 'On');
    });

    test('hidden widgets and widgets not on any page are skipped', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [5 0 R 6 0 R]',
        catalogExtra: '/AcroForm << /Fields [5 0 R 6 0 R 7 0 R] >>',
      );
      objs[5] = '<< /Subtype /Widget /FT /Tx /T (shown) /Rect [0 0 1 1] >>';
      objs[6] =
          '<< /Subtype /Widget /FT /Tx /T (hidden) /F 2 /Rect [0 0 1 1] >>';
      objs[7] = '<< /Subtype /Widget /FT /Tx /T (nowhere) /Rect [0 0 1 1] >>';
      final d = PdfEditDoc.open(buildPdf(objs));
      expect(d.fields.map((f) => f.fullName), ['shown']);
    });

    test('widget found through /P when missing from /Annots', () {
      final objs = simpleDoc(catalogExtra: '/AcroForm << /Fields [5 0 R] >>');
      objs[5] =
          '<< /Subtype /Widget /FT /Tx /T (viaP) /P 3 0 R '
          '/Rect [0 0 1 1] >>';
      final d = PdfEditDoc.open(buildPdf(objs));
      expect(fieldNamed(d, 'viaP').pageIndex, 0);
    });

    test('indirect /Annots and /Fields arrays, UTF-16 names', () {
      final objs = simpleDoc(
        pageExtra: '/Annots 9 0 R',
        catalogExtra: '/AcroForm 10 0 R',
      );
      objs[9] = '[5 0 R]';
      objs[10] = '<< /Fields 11 0 R >>';
      objs[11] = '[5 0 R]';
      objs[5] =
          '<< /Subtype /Widget /FT /Tx /T <FEFF00E9004C> '
          '/V <FEFF041F> /Rect [0 0 1 1] >>';
      final d = PdfEditDoc.open(buildPdf(objs));
      expect(d.fields.single.fullName, 'éL');
      expect(d.fields.single.value, 'П');
    });

    test('field ids are stable across applyChanges', () {
      final d = PdfEditDoc.open(fixture('form.pdf'));
      final d2 = d.applyChanges([SetFieldValue(fieldNamed(d, 'name').id, 'x')]);
      expect(
        d2.fields.map((f) => f.id).toList(),
        d.fields.map((f) => f.id).toList(),
      );
    });
  });
}
