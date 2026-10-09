import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/core/src/filters.dart';
import 'package:pdfedit/core/src/objects.dart';

import 'helpers.dart';

/// Decoded normal appearance stream of a widget (by field id).
String apOf(PdfEditDoc d, String id, [String? state]) {
  final f = core(d).file;
  final num = int.parse(id.split(' ').first);
  final w = f.resolve(PdfRef(num, 0)) as PdfDict;
  final ap = f.resolve(w['AP']) as PdfDict;
  var n = f.resolve(ap['N']);
  if (n is PdfDict) n = f.resolve(n[state ?? 'Yes']);
  final s = n as PdfStream;
  return str(decodeStreamData(s.data, s.dict));
}

PdfDict widgetDict(PdfEditDoc d, String id) {
  final f = core(d).file;
  return f.resolve(PdfRef(int.parse(id.split(' ').first), 0)) as PdfDict;
}

PdfDict acroForm(PdfEditDoc d) {
  final f = core(d).file;
  final cat = f.resolve(f.trailer['Root']) as PdfDict;
  return f.resolve(cat['AcroForm']) as PdfDict;
}

void main() {
  late PdfEditDoc form;
  setUp(() => form = PdfEditDoc.open(fixture('form.pdf')));

  group('incremental structure', () {
    test('original bytes are an exact prefix; table xref; /Prev; same ID', () {
      final b = fixture('form.pdf');
      final d2 = form.applyChanges([
        SetFieldValue(fieldNamed(form, 'name').id, 'Bob'),
      ]);
      expect(isPrefix(b, d2.bytes), isTrue);
      final tail = tailOf(b, d2.bytes);
      expect(tail.contains('\nxref\n'), isTrue);
      expect(tail.contains('trailer'), isTrue);
      final oldStart = core(form).file.startXref;
      expect(tail.contains('/Prev $oldStart'), isTrue);
      expect(tail.trimRight().endsWith('%%EOF'), isTrue);
      final id0 = (core(form).file.trailer['ID'] as List)[0] as PdfString;
      final newId = (core(d2).file.trailer['ID'] as List)[0] as PdfString;
      expect(newId, id0);
      // the old document is unchanged (immutable)
      expect(fieldNamed(form, 'name').value, 'Alice');
      expect(identical(form.bytes, b) || form.bytes.length == b.length, isTrue);
    });

    test('xref-stream files get an xref stream update', () {
      final b = fixture('form_objstm.pdf');
      final d = PdfEditDoc.open(b);
      final d2 = d.applyChanges([SetFieldValue(fieldNamed(d, 'name').id, 'Q')]);
      final tail = tailOf(b, d2.bytes);
      expect(tail.contains('/Type /XRef'), isTrue);
      expect(tail.contains('trailer'), isFalse);
      expect(core(d2).file.lastSectionIsStream, isTrue);
      expect(fieldNamed(PdfEditDoc.open(d2.bytes), 'name').value, 'Q');
    });

    test('linearized file update', () {
      final b = fixture('form_linearized.pdf');
      final d = PdfEditDoc.open(b);
      final d2 = d.applyChanges([
        SetFieldValue(fieldNamed(d, 'notes').id, 'lin'),
      ]);
      expect(fieldNamed(PdfEditDoc.open(d2.bytes), 'notes').value, 'lin');
    });

    test('successive updates chain and keep earlier values', () {
      var d = form;
      final sizes = <int>[d.bytes.length];
      for (var i = 0; i < 4; i++) {
        d = d.applyChanges([SetFieldValue(fieldNamed(d, 'name').id, 'v$i')]);
        sizes.add(d.bytes.length);
      }
      expect(fieldNamed(PdfEditDoc.open(d.bytes), 'name').value, 'v3');
      for (var i = 1; i < sizes.length; i++) {
        expect(sizes[i], greaterThan(sizes[i - 1]));
      }
      // Helvetica is added to /DR at most once
      final all = str(d.bytes);
      expect(
        RegExp('/BaseFont /Helvetica\\b').allMatches(all).length,
        lessThanOrEqualTo(2),
      );
    });

    test('empty change list returns the same document', () {
      expect(identical(form.applyChanges(const []), form), isTrue);
    });

    test('unknown field id throws', () {
      expect(
        () => form.applyChanges([const SetFieldValue('999 0', 'x')]),
        throwsA(isA<PdfCoreException>()),
      );
    });
  });

  group('SetFieldValue', () {
    test('text: /V and appearance with DA font size, clip, /Tx BMC', () {
      final id = fieldNamed(form, 'name').id;
      final d2 = form.applyChanges([SetFieldValue(id, 'Bob (b) \\ x')]);
      expect(fieldNamed(d2, 'name').value, 'Bob (b) \\ x');
      final ap = apOf(d2, id);
      expect(ap, contains('/Tx BMC'));
      expect(ap, contains('EMC'));
      expect(ap, contains(' re W n'));
      expect(ap, contains('/Helv 10 Tf'));
      expect(ap, contains(r'(Bob \(b\) \\ x) Tj'));
      // background from /MK /BG and border from /MK /BC
      expect(ap, contains('1 1 0.8 rg'));
      expect(ap, contains('0 0 0 RG'));
      final w = widgetDict(d2, id);
      final bbox = (core(d2).file.resolve(
        (core(d2).file.resolve(w['AP']) as PdfDict)['N'],
      ) as PdfStream).dict['BBox'];
      expect(bbox, [0, 0, 200, 20]);
    });

    test('MaxLen truncates; comb places one glyph per cell', () {
      final id = fieldNamed(form, 'person.age').id;
      final d2 = form.applyChanges([SetFieldValue(id, '12345')]);
      expect(fieldNamed(d2, 'person.age').value, '123');
      final ap = apOf(d2, id);
      expect(RegExp(r'Tm \(\d\) Tj').allMatches(ap).length, 3);
    });

    test('multiline wraps; Q=1 centres; auto font size', () {
      final id = fieldNamed(form, 'notes').id;
      final d2 = form.applyChanges([SetFieldValue(id, '${'word ' * 60}\nend')]);
      final ap = apOf(d2, id);
      final lines = RegExp(r'1 0 0 1 ([\d.]+) ([\d.-]+) Tm').allMatches(ap);
      expect(lines.length, greaterThan(3));
      final xs = lines.map((m) => double.parse(m.group(1)!)).toList();
      expect(xs.last, greaterThan(100)); // centred, not at the left pad
      expect(ap, contains('0 0 1 rg')); // DA colour kept
    });

    test('multiline auto size shrinks to fit', () {
      final id = fieldNamed(form, 'notes').id;
      final d2 = form.applyChanges([SetFieldValue(id, 'long text ' * 200)]);
      final m = RegExp(r'/Helv ([\d.]+) Tf').firstMatch(apOf(d2, id))!;
      expect(double.parse(m.group(1)!), lessThan(12));
    });

    test('field with two widgets: both appearances regenerated', () {
      final a = fieldNamed(form, 'dup', 0), b = fieldNamed(form, 'dup', 1);
      final d2 = form.applyChanges([SetFieldValue(b.id, 'shared')]);
      expect(apOf(d2, a.id), contains('(shared) Tj'));
      expect(apOf(d2, b.id), contains('(shared) Tj'));
      expect(fieldNamed(d2, 'dup', 0).value, 'shared');
      // /V lives on the parent field, not on the widgets
      expect(widgetDict(d2, a.id)['V'], isNull);
    });

    test('non-Latin-1 text: /V keeps Unicode, appearance shows ?', () {
      final id = fieldNamed(form, 'uni').id;
      final d2 = form.applyChanges([SetFieldValue(id, 'Привет “q” é')]);
      expect(fieldNamed(d2, 'uni').value, 'Привет “q” é');
      final ap = apOf(d2, id);
      expect(ap, contains(r'(?????? \223q\224 \351) Tj'));
      expect(PdfEditDoc.canDrawText('“q” é €'), isTrue);
      expect(PdfEditDoc.canDrawText('Привет'), isFalse);
    });

    test('checkbox on/off sets /V and /AS', () {
      final f = fieldNamed(form, 'agree');
      final on = form.applyChanges([SetFieldValue(f.id, f.onValue!)]);
      expect(fieldNamed(on, 'agree').value, 'Yes');
      expect(widgetDict(on, f.id)['AS'], const PdfName('Yes'));
      final off = on.applyChanges([SetFieldValue(f.id, 'Off')]);
      expect(fieldNamed(off, 'agree').value, 'Off');
      expect(widgetDict(off, f.id)['AS'], const PdfName('Off'));
    });

    test('radio sets /V on the parent and /AS on every kid', () {
      final radios = form.fields.where((f) => f.fullName == 'color').toList();
      final d2 = form.applyChanges([SetFieldValue(radios[2].id, 'blue')]);
      final r2 = d2.fields.where((f) => f.fullName == 'color').toList();
      expect(r2.every((r) => r.value == 'blue'), isTrue);
      expect(
        [for (final r in radios) widgetDict(d2, r.id)['AS']],
        [const PdfName('Off'), const PdfName('Off'), const PdfName('blue')],
      );
      final off = d2.applyChanges([SetFieldValue(radios[0].id, 'Off')]);
      expect(fieldNamed(off, 'color').value, 'Off');
    });

    test('combo shows display text; list box sets /I and highlights', () {
      final s = fieldNamed(form, 'state'), l = fieldNamed(form, 'fruit');
      final d2 = form.applyChanges([
        SetFieldValue(s.id, 'NY'),
        SetFieldValue(l.id, 'Plum'),
      ]);
      expect(fieldNamed(d2, 'state').value, 'NY');
      expect(apOf(d2, s.id), contains('(New York) Tj'));
      expect(fieldNamed(d2, 'fruit').value, 'Plum');
      expect(widgetDict(d2, l.id)['I'], [2]);
      final lap = apOf(d2, l.id);
      expect(lap, contains('(Plum) Tj'));
      expect(lap, contains('re f'));
    });

    test('signature and pushbutton values are ignored', () {
      final d2 = form.applyChanges([
        SetFieldValue(fieldNamed(form, 'sig').id, 'x'),
        SetFieldValue(fieldNamed(form, 'reset').id, 'x'),
      ]);
      expect(fieldNamed(d2, 'sig').value, '');
    });

    test('NeedAppearances: regenerated then cleared', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [5 0 R 6 0 R]',
        catalogExtra:
            '/AcroForm << /Fields [5 0 R 6 0 R] '
            '/NeedAppearances true /DA (/Helv 0 Tf 0 g) >>',
      );
      objs[5] =
          '<< /Subtype /Widget /FT /Tx /T (a) /V (stale) '
          '/Rect [0 0 100 20] >>';
      objs[6] =
          '<< /Subtype /Widget /FT /Btn /T (b) /V /Yes '
          '/Rect [0 30 10 40] >>';
      final d = PdfEditDoc.open(buildPdf(objs));
      final d2 = d.applyChanges([SetFieldValue(fieldNamed(d, 'b').id, 'Yes')]);
      expect(acroForm(d2)['NeedAppearances'], false);
      expect(apOf(d2, fieldNamed(d2, 'a').id), contains('(stale) Tj'));
      expect(
        widgetDict(d2, fieldNamed(d2, 'b').id)['AS'],
        const PdfName('Yes'),
      );
    });

    test('NeedAppearances stays when a widget has no appearance', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [5 0 R 6 0 R]',
        catalogExtra:
            '/AcroForm << /Fields [5 0 R 6 0 R] '
            '/NeedAppearances true >>',
      );
      objs[5] = '<< /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 100 20] >>';
      objs[6] =
          '<< /Subtype /Widget /FT /Btn /Ff 65536 /T (push) '
          '/Rect [0 30 10 40] >>';
      final d = PdfEditDoc.open(buildPdf(objs));
      final d2 = d.applyChanges([SetFieldValue(fieldNamed(d, 'a').id, 'x')]);
      expect(acroForm(d2)['NeedAppearances'], true);
    });

    test('XFA is dropped when values change', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [5 0 R]',
        catalogExtra: '/AcroForm << /Fields [5 0 R] /XFA 9 0 R >>',
      );
      objs[5] = '<< /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 100 20] >>';
      objs[9] = '<< /Length 3 >>\nstream\nxfa\nendstream';
      final d = PdfEditDoc.open(buildPdf(objs));
      final d2 = d.applyChanges([SetFieldValue(fieldNamed(d, 'a').id, 'x')]);
      expect(acroForm(d2)['XFA'], isNull);
    });

    test('font: embedded DA font falls back to Helvetica in /DR', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [5 0 R 6 0 R]',
        catalogExtra:
            '/AcroForm << /Fields [5 0 R 6 0 R] '
            '/DR << /Font << /Emb 7 0 R /Cour 8 0 R >> >> >>',
      );
      objs[5] =
          '<< /Subtype /Widget /FT /Tx /T (a) /DA (/Emb 8 Tf 0 g) '
          '/Rect [0 0 100 20] >>';
      objs[6] =
          '<< /Subtype /Widget /FT /Tx /T (b) /DA (/Cour 9 Tf 1 0 0 rg) '
          '/Rect [0 30 100 50] >>';
      objs[7] =
          '<< /Type /Font /Subtype /TrueType /BaseFont /ABCDEF+Foo '
          '/Encoding /WinAnsiEncoding >>';
      objs[8] =
          '<< /Type /Font /Subtype /Type1 /BaseFont /Courier '
          '/Encoding /WinAnsiEncoding >>';
      final d = PdfEditDoc.open(buildPdf(objs));
      final d2 = d.applyChanges([
        SetFieldValue(fieldNamed(d, 'a').id, 'x'),
        SetFieldValue(fieldNamed(d, 'b').id, 'y'),
      ]);
      expect(apOf(d2, fieldNamed(d2, 'a').id), contains('/Helv 8 Tf'));
      expect(apOf(d2, fieldNamed(d2, 'b').id), contains('/Cour 9 Tf 1 0 0 rg'));
      final f = core(d2).file;
      final dr = f.resolve(acroForm(d2)['DR']) as PdfDict;
      final fonts = f.resolve(dr['Font']) as PdfDict;
      expect(fonts.keys, containsAll(['Emb', 'Cour', 'Helv']));
    });
  });

  group('AddField', () {
    test('plain PDF: creates AcroForm, /DR, rewrites catalog and page', () {
      final b = buildPdf(simpleDoc());
      final d = PdfEditDoc.open(b);
      expect(d.fields, isEmpty);
      final d2 = d.applyChanges(const [
        AddField(0, PdfRect(50, 60, 200, 24), PdfFieldKind.text, value: 'hi'),
        AddField(0, PdfRect(50, 100, 200, 80), PdfFieldKind.multilineText),
        AddField(0, PdfRect(50, 200, 14, 14), PdfFieldKind.checkbox),
        AddField(
          0,
          PdfRect(80, 200, 14, 14),
          PdfFieldKind.checkbox,
          value: 'Yes',
        ),
        AddField(
          0,
          PdfRect(50, 300, 100, 20),
          PdfFieldKind.text,
          name: 'custom',
        ),
      ]);
      final tail = tailOf(b, d2.bytes);
      expect(RegExp(r'(^|\n)1 0 obj').hasMatch(tail), isTrue); // catalog
      expect(RegExp(r'(^|\n)3 0 obj').hasMatch(tail), isTrue); // page
      expect(RegExp('/BaseFont /Helvetica').allMatches(tail).length, 1);
      expect(d2.fields.map((f) => f.fullName), [
        'Text1',
        'Text2',
        'Check1',
        'Check2',
        'custom',
      ]);
      expect(d2.fields.map((f) => f.kind), [
        PdfFieldKind.text,
        PdfFieldKind.multilineText,
        PdfFieldKind.checkbox,
        PdfFieldKind.checkbox,
        PdfFieldKind.text,
      ]);
      expect(fieldNamed(d2, 'Text1').value, 'hi');
      expect(fieldNamed(d2, 'Check1').value, 'Off');
      expect(fieldNamed(d2, 'Check2').value, 'Yes');
      expect(fieldNamed(d2, 'Check1').onValue, 'Yes');
      expectRect(fieldNamed(d2, 'Text1').rect, [50, 60, 200, 24]);
      final af = acroForm(d2);
      final f = core(d2).file;
      final fonts =
          f.resolve((f.resolve(af['DR']) as PdfDict)['Font']) as PdfDict;
      expect(fonts.keys, containsAll(['Helv', 'ZaDb']));
      expect(apOf(d2, fieldNamed(d2, 'Text1').id), contains('(hi) Tj'));
      final check = apOf(d2, fieldNamed(d2, 'Check2').id, 'Yes');
      expect(check, contains('/ZaDb'));
      expect(check, contains('(4) Tj'));
      expect(
        apOf(d2, fieldNamed(d2, 'Check2').id, 'Off'),
        isNot(contains('Tj')),
      );
      // round trip: set the new checkbox
      final d3 = d2.applyChanges([
        SetFieldValue(fieldNamed(d2, 'Check1').id, 'Yes'),
      ]);
      expect(fieldNamed(d3, 'Check1').value, 'Yes');
    });

    test('auto names skip existing names', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [5 0 R]',
        catalogExtra: '/AcroForm << /Fields [5 0 R] >>',
      );
      objs[5] = '<< /Subtype /Widget /FT /Tx /T (Text1) /Rect [0 0 1 1] >>';
      final d = PdfEditDoc.open(buildPdf(objs));
      final d2 = d.applyChanges(const [
        AddField(0, PdfRect(0, 0, 50, 20), PdfFieldKind.text),
      ]);
      expect(d2.fields.last.fullName, 'Text2');
    });

    test('indirect /Annots array is rewritten, page is not', () {
      final objs = simpleDoc(
        pageExtra: '/Annots 9 0 R',
        catalogExtra: '/AcroForm 10 0 R',
      );
      objs[9] = '[]';
      objs[10] = '<< /Fields [] /DR << /Font << /Helv 11 0 R >> >> >>';
      objs[11] =
          '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
          '/Encoding /WinAnsiEncoding >>';
      final b = buildPdf(objs);
      final d2 = PdfEditDoc.open(b).applyChanges(const [
        AddField(0, PdfRect(0, 0, 50, 20), PdfFieldKind.text),
      ]);
      final tail = tailOf(b, d2.bytes);
      bool has(int n) => RegExp('(^|\n)$n 0 obj').hasMatch(tail);
      expect(has(9), isTrue);
      expect(has(10), isTrue);
      expect(has(3), isFalse);
      expect(has(1), isFalse);
      expect(tail.contains('/BaseFont'), isFalse); // existing Helv reused
      expect(d2.fields.single.fullName, 'Text1');
    });

    test('direct /Annots array', () {
      final objs = simpleDoc(
        pageExtra: '/Annots [<< /Subtype /Link /Rect [0 0 1 1] >>]',
      );
      final d2 = PdfEditDoc.open(buildPdf(objs)).applyChanges(const [
        AddField(0, PdfRect(0, 0, 50, 20), PdfFieldKind.text),
      ]);
      final f = core(d2).file;
      final page = f.resolve(const PdfRef(3, 0)) as PdfDict;
      expect((page['Annots'] as List).length, 2);
    });

    test('rejects unsupported kinds and bad pages', () {
      expect(
        () => form.applyChanges(const [
          AddField(0, PdfRect(0, 0, 9, 9), PdfFieldKind.radio),
        ]),
        throwsA(isA<PdfCoreException>()),
      );
      expect(
        () => form.applyChanges(const [
          AddField(7, PdfRect(0, 0, 9, 9), PdfFieldKind.text),
        ]),
        throwsA(isA<PdfCoreException>()),
      );
    });
  });

  group('MoveField / SetMultiline / DeleteField', () {
    test('move changes /Rect and regenerates with the new BBox', () {
      final id = fieldNamed(form, 'name').id;
      final d2 = form.applyChanges([
        MoveField(id, const PdfRect(10, 20, 300, 40)),
      ]);
      expectRect(fieldNamed(d2, 'name').rect, [10, 20, 300, 40]);
      final f = core(d2).file;
      final w = widgetDict(d2, id);
      final n = f.resolve((f.resolve(w['AP']) as PdfDict)['N']) as PdfStream;
      expect(n.dict['BBox'], [0, 0, 300, 40]);
      expect(apOf(d2, id), contains('(Alice) Tj'));
    });

    test('set multiline toggles Ff bit 13', () {
      final id = fieldNamed(form, 'name').id;
      final d2 = form.applyChanges([SetMultiline(id, true)]);
      expect(fieldNamed(d2, 'name').kind, PdfFieldKind.multilineText);
      expect(widgetDict(d2, id)['Ff'], 4096);
      final d3 = d2.applyChanges([SetMultiline(id, false)]);
      expect(fieldNamed(d3, 'name').kind, PdfFieldKind.text);
      final notes = fieldNamed(form, 'notes').id;
      final d4 = form.applyChanges([SetMultiline(notes, false)]);
      expect(fieldNamed(d4, 'notes').kind, PdfFieldKind.text);
      expect(fieldNamed(d4, 'notes').required, isTrue); // other bits kept
    });

    test('delete merged field', () {
      final id = fieldNamed(form, 'name').id;
      final d2 = form.applyChanges([DeleteField(id)]);
      expect(d2.fields.any((f) => f.fullName == 'name'), isFalse);
      expect(d2.fields.length, 17);
      final f = core(d2).file;
      final fields = f.resolve(acroForm(d2)['Fields']) as List;
      expect(fields.any((r) => r is PdfRef && r.id == id), isFalse);
    });

    test('delete radio kids one by one', () {
      final radios = form.fields.where((f) => f.fullName == 'color').toList();
      final d2 = form.applyChanges([DeleteField(radios[0].id)]);
      expect(d2.fields.where((f) => f.fullName == 'color').length, 2);
      final d3 = d2.applyChanges([
        DeleteField(radios[1].id),
        DeleteField(radios[2].id),
      ]);
      expect(d3.fields.any((f) => f.fullName == 'color'), isFalse);
      final f = core(d3).file;
      final fields = f.resolve(acroForm(d3)['Fields']) as List;
      expect(
        fields.length,
        (f.resolve(acroForm(form)['Fields']) as List).length - 1,
      );
    });

    test('delete children in a hierarchy removes the empty parent', () {
      final a = fieldNamed(form, 'person.first').id;
      final b = fieldNamed(form, 'person.age').id;
      final d2 = form.applyChanges([DeleteField(a)]);
      expect(d2.fields.any((f) => f.fullName == 'person.age'), isTrue);
      final d3 = d2.applyChanges([DeleteField(b)]);
      expect(d3.fields.any((f) => f.fullName.startsWith('person')), isFalse);
      final f = core(d3).file;
      final fields = f.resolve(acroForm(d3)['Fields']) as List;
      expect(
        fields.length,
        (core(form).file.resolve(acroForm(form)['Fields']) as List).length - 1,
      );
    });

    test('using a deleted id in the same batch throws', () {
      final id = fieldNamed(form, 'name').id;
      expect(
        () => form.applyChanges([DeleteField(id), SetFieldValue(id, 'x')]),
        throwsA(isA<PdfCoreException>()),
      );
    });

    test('delete then add in one batch', () {
      final id = fieldNamed(form, 'name').id;
      final d2 = form.applyChanges([
        DeleteField(id),
        const AddField(
          0,
          PdfRect(10, 10, 100, 20),
          PdfFieldKind.text,
          name: 'name',
        ),
      ]);
      expect(d2.fields.where((f) => f.fullName == 'name').length, 1);
      expect(fieldNamed(d2, 'name').id, isNot(id));
    });
  });
}

void expectRect(PdfRect r, List<double> ltwh) {
  expect(r.left, closeTo(ltwh[0], 0.01), reason: '$r');
  expect(r.top, closeTo(ltwh[1], 0.01), reason: '$r');
  expect(r.width, closeTo(ltwh[2], 0.01), reason: '$r');
  expect(r.height, closeTo(ltwh[3], 0.01), reason: '$r');
}
