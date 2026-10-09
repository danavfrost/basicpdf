import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/core/src/appearance.dart';
import 'package:pdfedit/core/src/filters.dart';
import 'package:pdfedit/core/src/new_doc.dart';
import 'package:pdfedit/core/src/objects.dart';
import 'package:pdfedit/core/src/text.dart';

import 'helpers.dart';

const fieldW = 468.0, fieldH = 648.0;

int wrappedLines(String s) =>
    wrapText(s, textWidthFor(fieldW, 0), 12, FontMetrics.helvetica).length;

String ap(PdfEditDoc d, PdfField f) {
  final file = core(d).file;
  final w = file.resolve(PdfRef(int.parse(f.id.split(' ')[0]), 0)) as PdfDict;
  final s = file.resolve((file.resolve(w['AP']) as PdfDict)['N']) as PdfStream;
  return str(decodeStreamData(s.data, s.dict));
}

void main() {
  test('lines per page', () {
    expect(linesThatFit(fieldH, 0, 12), 44);
  });

  test('empty text → one page with one empty field', () {
    final b = PdfEditDoc.createTextDocument('');
    expect(str(b.sublist(0, 8)), '%PDF-1.7');
    final d = PdfEditDoc.open(b);
    expect(d.pages.length, 1);
    expect([d.pages.single.width, d.pages.single.height], [612, 792]);
    final f = d.fields.single;
    expect(f.fullName, 'Body1');
    expect(f.kind, PdfFieldKind.multilineText);
    expect(f.value, '');
    expect(f.fontSize, 12);
    expect(f.rect.left, 72);
    expect(f.rect.top, 72);
    expect(f.rect.width, fieldW);
    expect(f.rect.height, fieldH);
    expect(core(d).file.repaired, isFalse);
  });

  test('short text, explicit newlines preserved', () {
    const text = 'Dear Bob,\n\nThanks for the (great) pie.\r\nCheers\n';
    final d = PdfEditDoc.open(PdfEditDoc.createTextDocument(text));
    expect(d.fields.single.value, text);
    final a = ap(d, d.fields.single);
    expect(a, contains('/Helv 12 Tf'));
    expect(a, contains(r'(Thanks for the \(great\) pie.) Tj'));
    expect(a, contains('/Tx BMC'));
    final acro = core(d).file.resolve(
      (core(d).file.resolve(core(d).file.trailer['Root'])
          as PdfDict)['AcroForm'],
    ) as PdfDict;
    expect((acro['DA'] as PdfString).latin1Value, '/Helv 12 Tf 0 g');
    expect(acro['DR'], isNotNull);
  });

  test('long text flows across pages; each field holds what fits', () {
    final paras = List.generate(
      40,
      (i) =>
          'Paragraph $i: ${'lorem ipsum dolor sit amet consectetur ' * (i % 7 + 1)}'
              .trim(),
    );
    final text = paras.join('\n');
    final d = PdfEditDoc.open(PdfEditDoc.createTextDocument(text));
    expect(d.pages.length, greaterThan(1));
    expect(d.fields.length, d.pages.length);
    for (var i = 0; i < d.fields.length; i++) {
      final f = d.fields[i];
      expect(f.fullName, 'Body${i + 1}');
      expect(f.pageIndex, i);
      final n = wrappedLines(f.value);
      expect(n, lessThanOrEqualTo(44));
      if (i < d.fields.length - 1) expect(n, 44); // full pages
    }
    // concatenating page values (with the dropped break) restores the text
    final joined = d.fields.map((f) => f.value).toList();
    var rebuilt = joined.first;
    for (final v in joined.skip(1)) {
      final sep = text.substring(
        rebuilt.length,
        text.indexOf(v, rebuilt.length),
      );
      expect(sep.trim(), isEmpty);
      rebuilt += sep + v;
    }
    expect(rebuilt, text);
  });

  test('one huge word is broken by characters', () {
    final word = 'x' * 3000;
    final d = PdfEditDoc.open(PdfEditDoc.createTextDocument(word));
    expect(d.fields.map((f) => f.value).join(), word);
  });

  test('blank lines across a page boundary', () {
    final text = List.filled(100, '').join('\n'); // 100 empty lines
    final d = PdfEditDoc.open(PdfEditDoc.createTextDocument(text));
    expect(d.pages.length, 3);
    var total = 0;
    for (final f in d.fields) {
      total += wrappedLines(f.value);
    }
    expect(total, 100);
  });

  test('non-Latin text keeps value, appearance uses ?', () {
    final d = PdfEditDoc.open(PdfEditDoc.createTextDocument('日本 ok'));
    expect(d.fields.single.value, '日本 ok');
    expect(ap(d, d.fields.single), contains('(?? ok) Tj'));
  });

  test('paginateText matches the generated document', () {
    final text = 'abc ' * 5000;
    final pages = paginateText(text);
    final d = PdfEditDoc.open(createTextDocumentBytes(text));
    expect(d.fields.map((f) => f.value).toList(), pages);
  });

  test('editing a generated document', () {
    final b = PdfEditDoc.createTextDocument('first version');
    final d = PdfEditDoc.open(b);
    final d2 = d.applyChanges([
      SetFieldValue(d.fields.single.id, 'second\nversion'),
    ]);
    expect(isPrefix(b, d2.bytes), isTrue);
    final r = PdfEditDoc.open(d2.bytes);
    expect(r.fields.single.value, 'second\nversion');
    expect(ap(r, r.fields.single), contains('(version) Tj'));
    expect(ap(r, r.fields.single), contains('/Helv 12 Tf'));
  });
}
