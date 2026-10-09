import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';

void main() {
  group('PdfEditDoc.textFit', () {
    test('New-doc Body field: 44 lines fit, the 45th does not', () {
      final d = PdfEditDoc.open(PdfEditDoc.createTextDocument('hello'));
      final body = d.fields.single;
      final lines44 = List.filled(44, 'x').join('\n');
      expect(d.textFits(body, 'hello'), isTrue);
      expect(d.textFits(body, lines44), isTrue);
      expect(d.textFits(body, '$lines44\nx'), isFalse);
      // Trailing empty lines draw nothing.
      expect(d.textFits(body, '$lines44\n'), isTrue);
      final fit = d.textFit(body, 'hello');
      expect(fit.fontSize, 12);
      expect(fit.lineHeight, closeTo(14.4, 1e-9));
      expect(fit.monospace, isFalse);
    });

    test('Body field: one long wrapped paragraph overflows', () {
      final d = PdfEditDoc.open(PdfEditDoc.createTextDocument(''));
      final body = d.fields.single;
      final para = List.filled(2000, 'word').join(' ');
      expect(d.textFits(body, para), isFalse);
      expect(d.textFits(body, List.filled(200, 'word').join(' ')), isTrue);
    });

    test('auto-size single-line field shrinks, then overflows at 4 pt', () {
      final d0 = PdfEditDoc.open(PdfEditDoc.createTextDocument(''));
      final d = d0.applyChanges(const [
        AddField(0, PdfRect(100, 100, 100, 20), PdfFieldKind.text, name: 'T'),
      ]);
      final f = d.fields.firstWhere((f) => f.fullName == 'T');
      final short = d.textFit(f, 'abc');
      expect(short.fits, isTrue);
      final longer = d.textFit(f, 'a fairly long line of text here');
      expect(longer.fits, isTrue);
      expect(longer.fontSize, lessThan(short.fontSize));
      expect(d.textFits(f, List.filled(40, 'overflow').join(' ')), isFalse);
    });

    test('auto-size multi-line field shrinks before overflowing', () {
      final d0 = PdfEditDoc.open(PdfEditDoc.createTextDocument(''));
      final d = d0.applyChanges(const [
        AddField(
          0,
          PdfRect(100, 100, 120, 60),
          PdfFieldKind.multilineText,
          name: 'M',
        ),
      ]);
      final f = d.fields.firstWhere((f) => f.fullName == 'M');
      final some = List.filled(12, 'word').join(' ');
      final fit = d.textFit(f, some);
      expect(fit.fits, isTrue);
      expect(fit.fontSize, lessThan(12));
      expect(d.textFits(f, List.filled(400, 'word').join(' ')), isFalse);
    });

    test('non-text fields always fit', () {
      final d0 = PdfEditDoc.open(PdfEditDoc.createTextDocument(''));
      final d = d0.applyChanges(const [
        AddField(0, PdfRect(100, 100, 12, 12), PdfFieldKind.checkbox),
      ]);
      final cb = d.fields.firstWhere((f) => f.kind == PdfFieldKind.checkbox);
      expect(d.textFits(cb, 'anything at all'), isTrue);
    });
  });
}
