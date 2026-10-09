import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';

import 'helpers.dart';

/// Forms written by other producers (ReportLab; pypdf encryption).
void main() {
  for (final name in [
    'reportlab_form.pdf',
    'pypdf_aes256.pdf',
    'pypdf_rc4_128.pdf',
  ]) {
    test('$name: read and round-trip every field kind', () {
      final pw = name.startsWith('pypdf') ? 'user' : null;
      final b = fixture(name);
      final d = PdfEditDoc.open(b, password: pw);
      expect(fieldNamed(d, 'rl_text').value, 'hello');
      expect(fieldNamed(d, 'rl_multi').kind, PdfFieldKind.multilineText);
      expect(fieldNamed(d, 'rl_check').value, 'Yes');
      final radios = d.fields.where((f) => f.fullName == 'rl_radio').toList();
      expect(radios.map((r) => r.onValue), ['one', 'two', 'three']);
      expect(radios.first.value, 'two');
      expect(fieldNamed(d, 'rl_choice').options.map((o) => o.$1), [
        'A',
        'B',
        'C',
      ]);
      final d2 = d.applyChanges([
        SetFieldValue(fieldNamed(d, 'rl_text').id, 'changed'),
        SetFieldValue(fieldNamed(d, 'rl_multi').id, 'multi\nchanged'),
        SetFieldValue(fieldNamed(d, 'rl_check').id, 'Off'),
        SetFieldValue(radios[2].id, 'three'),
        SetFieldValue(fieldNamed(d, 'rl_choice').id, 'C'),
        SetFieldValue(fieldNamed(d, 'rl_list').id, 'X'),
      ]);
      expect(isPrefix(b, d2.bytes), isTrue);
      final r = PdfEditDoc.open(d2.bytes, password: pw);
      expect(fieldNamed(r, 'rl_text').value, 'changed');
      expect(fieldNamed(r, 'rl_multi').value, 'multi\nchanged');
      expect(fieldNamed(r, 'rl_check').value, 'Off');
      expect(
        r.fields.where((f) => f.fullName == 'rl_radio').map((f) => f.value),
        ['three', 'three', 'three'],
      );
      expect(fieldNamed(r, 'rl_choice').value, 'C');
      expect(fieldNamed(r, 'rl_list').value, 'X');
    });
  }

  test('checkbox "on" request maps to the widget on-state', () {
    final objs = simpleDoc(
      pageExtra: '/Annots [5 0 R]',
      catalogExtra: '/AcroForm << /Fields [5 0 R] >>',
    );
    objs[5] =
        '<< /Subtype /Widget /FT /Btn /T (c) /V /Off /AS /Off '
        '/Rect [0 0 10 10] /AP << /N << /On 6 0 R /Off 6 0 R >> >> >>';
    objs[6] = '<< /Length 0 >>\nstream\n\nendstream';
    final d = PdfEditDoc.open(buildPdf(objs));
    expect(d.fields.single.onValue, 'On');
    final d2 = d.applyChanges([SetFieldValue(d.fields.single.id, 'Yes')]);
    expect(d2.fields.single.value, 'On');
  });
}
