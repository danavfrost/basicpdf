import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';

import 'helpers.dart';

/// Damaged inputs must never crash with anything but the contract's
/// exceptions, and must not hang.
void main() {
  void tryOpen(Uint8List b, String? pw) {
    try {
      final d = PdfEditDoc.open(b, password: pw);
      d.fields;
      d.pages;
    } on PdfCoreException {
      // fine
    } on PdfPasswordException {
      // fine
    }
  }

  for (final name in [
    'form.pdf',
    'form_objstm.pdf',
    'form_aes128.pdf',
    'form_rc4_40.pdf',
  ]) {
    test('$name: truncated and bit-flipped variants', () {
      final b = fixture(name);
      final pw = name.contains('aes') || name.contains('rc4') ? 'user' : null;
      final rnd = Random(42);
      for (var i = 0; i < 25; i++) {
        tryOpen(Uint8List.sublistView(b, 0, rnd.nextInt(b.length)), pw);
      }
      for (var i = 0; i < 60; i++) {
        final c = Uint8List.fromList(b);
        for (var k = 0; k < 1 + rnd.nextInt(8); k++) {
          c[rnd.nextInt(c.length)] = rnd.nextInt(256);
        }
        tryOpen(c, pw);
      }
    });
  }

  test('truncated file still opens via repair when objects are intact', () {
    final b = fixture('form.pdf');
    final s = str(b);
    final cut = s.lastIndexOf('xref');
    final d = PdfEditDoc.open(latin(s.substring(0, cut)));
    expect(d.fields.length, 18);
    expect(d.pages.length, 3);
  });
}
