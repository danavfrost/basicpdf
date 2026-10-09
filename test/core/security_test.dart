import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/core/src/objects.dart';
import 'package:pdfedit/core/src/security.dart';

import 'helpers.dart';

const encrypted = [
  'form_rc4_40.pdf',
  'form_rc4_128.pdf',
  'form_aes128.pdf',
  'form_aes256_r5.pdf',
  'form_aes256.pdf',
  'form_aes128_objstm_nometa.pdf',
];

const ownerOnly = [
  'form_rc4_128_owneronly.pdf',
  'form_aes128_owneronly.pdf',
  'form_aes256_owneronly.pdf',
];

void main() {
  group('primitives', () {
    test('RC4 known vector', () {
      final out = rc4(latin('Key'), latin('Plaintext'));
      expect(out, [0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3]);
    });

    test('AES encrypt/decrypt round trip with padding', () {
      final key = Uint8List.fromList(List.generate(16, (i) => i));
      for (final len in [0, 1, 15, 16, 17, 100]) {
        final data = Uint8List.fromList(List.generate(len, (i) => i * 7));
        final enc = aesEncrypt(key, data);
        expect(enc.length % 16, 0);
        expect(aesDecrypt(key, enc), data);
      }
    });

    test('AES-128 FIPS-197 vector', () {
      final key = List.generate(16, (i) => i);
      final pt = [
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, //
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
      ];
      final ct = aesCbc(true, key, List.filled(16, 0), pt);
      expect(ct, [
        0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, //
        0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a,
      ]);
    });
  });

  group('open encrypted fixtures', () {
    for (final name in encrypted) {
      test(name, () {
        final b = fixture(name);
        expect(
          () => PdfEditDoc.open(b),
          throwsA(
            isA<PdfPasswordException>().having(
              (e) => e.wrongPassword,
              'wrong',
              isFalse,
            ),
          ),
        );
        expect(
          () => PdfEditDoc.open(b, password: 'nope'),
          throwsA(
            isA<PdfPasswordException>().having(
              (e) => e.wrongPassword,
              'wrong',
              isTrue,
            ),
          ),
        );
        final u = PdfEditDoc.open(b, password: 'user');
        expect(u.isEncrypted, isTrue);
        expect(u.isOwner, isFalse);
        expect(fieldNamed(u, 'name').value, 'Alice');
        expect(fieldNamed(u, 'uni').value, 'Grüße €');
        expect(fieldNamed(u, 'notes').value, 'Line one\nLine two');
        final o = PdfEditDoc.open(b, password: 'owner');
        expect(o.isOwner, isTrue);
        expect(o.permissions.canModify, isTrue);
        expect(o.permissions.canLayoutFields, isTrue);
        expect(o.fields.length, u.fields.length);
      });
    }

    for (final name in ownerOnly) {
      test('$name: empty user password, restricted permissions', () {
        final b = fixture(name);
        final d = PdfEditDoc.open(b);
        expect(d.isEncrypted, isTrue);
        expect(d.isOwner, isFalse);
        expect(d.permissions.canModify, isFalse);
        expect(d.permissions.canFillForms, isFalse);
        expect(d.permissions.canAnnotate, isFalse);
        expect(d.permissions.canEditFields, isFalse);
        expect(fieldNamed(d, 'name').value, 'Alice');
        final o = PdfEditDoc.open(b, password: 'owner');
        expect(o.isOwner, isTrue);
        expect(o.permissions.canEditFields, isTrue);
        expect(
          () => PdfEditDoc.open(b, password: 'user'),
          throwsA(
            isA<PdfPasswordException>().having(
              (e) => e.wrongPassword,
              'wrong',
              isTrue,
            ),
          ),
        );
      });
    }
  });

  group('permission bits', () {
    PdfPermissions perms(int r, int p) {
      // Build a handler for an RC4 doc with an empty user password.
      final id0 = Uint8List.fromList(List.generate(16, (i) => i));
      final o = SecurityHandler.computeO(r, r == 2 ? 5 : 16, latin('own'), []);
      final key = SecurityHandler.computeKey(
        r,
        r == 2 ? 5 : 16,
        [],
        o,
        p,
        id0,
        true,
      );
      final u = SecurityHandler.computeU(r, key, id0);
      final enc = PdfDict({
        'Filter': const PdfName('Standard'),
        'V': r == 2 ? 1 : 2,
        'R': r,
        'Length': r == 2 ? 40 : 128,
        'P': p,
        'O': PdfString(o),
        'U': PdfString(u),
      });
      final h = SecurityHandler.open(enc, id0, null);
      expect(h.isOwner, isFalse);
      return h.permissions;
    }

    test('R3: fill-forms bit 9 alone allows filling, not layout', () {
      // bits: 9 (fill) set; 4 (modify) and 6 (annotate) clear
      final p = perms(3, -4 & ~(1 << 3) & ~(1 << 5));
      expect(p.canModify, isFalse);
      expect(p.canAnnotate, isFalse);
      expect(p.canFillForms, isTrue);
      expect(p.canEditFields, isTrue);
      expect(p.canLayoutFields, isFalse);
    });

    test('R3: everything allowed', () {
      final p = perms(3, -4);
      expect(p.canModify && p.canAnnotate && p.canFillForms, isTrue);
    });

    test('R2: fill follows annotate bit', () {
      final p = perms(2, -4 & ~(1 << 5));
      expect(p.canFillForms, isFalse);
      expect(p.canModify, isTrue);
    });

    test('owner password with empty owner string → owner', () {
      final id0 = Uint8List(16);
      final o = SecurityHandler.computeO(3, 16, [], latin('u'));
      final key = SecurityHandler.computeKey(
        3,
        16,
        latin('u'),
        o,
        -64,
        id0,
        true,
      );
      final u = SecurityHandler.computeU(3, key, id0);
      final enc = PdfDict({
        'Filter': const PdfName('Standard'),
        'V': 2,
        'R': 3,
        'Length': 128,
        'P': -64,
        'O': PdfString(o),
        'U': PdfString(u),
      });
      final h = SecurityHandler.open(enc, id0, 'u');
      // owner password == user password when the owner one is empty
      expect(h.isOwner, isTrue);
    });
  });

  test('unsupported security handler', () {
    final objs = simpleDoc();
    objs[9] = '<< /Filter /Adobe.PubSec /V 4 /R 4 >>';
    final b = buildPdf(
      objs,
      trailer: '/Root 1 0 R /Encrypt 9 0 R /ID [<00112233> <00112233>]',
    );
    expect(
      () => PdfEditDoc.open(b),
      throwsA(
        isA<PdfCoreException>().having(
          (e) => e.message,
          'message',
          "This kind of protected PDF isn't supported",
        ),
      ),
    );
  });

  group('encrypted round trips', () {
    for (final name in [...encrypted, ...ownerOnly]) {
      test(name, () {
        final b = fixture(name);
        final pw = name.contains('owneronly') ? 'owner' : 'user';
        final d = PdfEditDoc.open(b, password: pw);
        final d2 = d.applyChanges([
          SetFieldValue(fieldNamed(d, 'name').id, 'Zoë (secret)'),
          SetFieldValue(fieldNamed(d, 'agree').id, 'Yes'),
          SetFieldValue(fieldNamed(d, 'state').id, 'NY'),
          const AddField(
            0,
            PdfRect(400, 100, 120, 20),
            PdfFieldKind.text,
            value: 'new',
          ),
        ]);
        expect(isPrefix(b, d2.bytes), isTrue);
        final tail = tailOf(b, d2.bytes);
        // values must not be in plain text
        expect(tail.contains('secret'), isFalse);
        expect(tail.contains('/Encrypt'), isTrue);
        // reopen with the same password from scratch
        final r = PdfEditDoc.open(d2.bytes, password: pw);
        expect(fieldNamed(r, 'name').value, 'Zoë (secret)');
        expect(fieldNamed(r, 'agree').value, 'Yes');
        expect(fieldNamed(r, 'state').value, 'NY');
        expect(fieldNamed(r, 'Text1').value, 'new');
        expect(fieldNamed(r, 'uni').value, 'Grüße €');
        if (!name.contains('owneronly')) {
          expect(
            () => PdfEditDoc.open(d2.bytes),
            throwsA(isA<PdfPasswordException>()),
          );
          final o = PdfEditDoc.open(d2.bytes, password: 'owner');
          expect(fieldNamed(o, 'name').value, 'Zoë (secret)');
        } else {
          expect(fieldNamed(PdfEditDoc.open(d2.bytes), 'Text1').value, 'new');
        }
        // a second update on top of the first
        final d3 = r.applyChanges([
          SetFieldValue(fieldNamed(r, 'Text1').id, 'again'),
        ]);
        expect(isPrefix(d2.bytes, d3.bytes), isTrue);
        final r3 = PdfEditDoc.open(d3.bytes, password: pw);
        expect(fieldNamed(r3, 'Text1').value, 'again');
        expect(fieldNamed(r3, 'name').value, 'Zoë (secret)');
      });
    }
  });
}
