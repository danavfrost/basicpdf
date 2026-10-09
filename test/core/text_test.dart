import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/core/src/appearance.dart';
import 'package:pdfedit/core/src/model.dart';
import 'package:pdfedit/core/src/objects.dart';
import 'package:pdfedit/core/src/text.dart';

List<String> wrap(String s, double width, [double fs = 10]) => [
  for (final r in wrapText(s, width, fs, FontMetrics.helvetica))
    s.substring(r.start, r.end),
];

void main() {
  test('Helvetica widths', () {
    expect(helveticaWidths.length, 256);
    expect(
      FontMetrics.helvetica.unitsWidth('Hello'),
      722 + 556 + 222 + 222 + 556,
    );
    expect(FontMetrics.helvetica.width('W', 10), 9.44);
    expect(FontMetrics.helvetica.unitsWidth('é€'), 556 + 556);
    expect(FontMetrics.courier.unitsWidth('iii'), 1800);
  });

  test('text string decode/encode', () {
    expect(decodeTextString(Uint8List.fromList([0xFE, 0xFF, 0x04, 0x1F])), 'П');
    expect(decodeTextString(Uint8List.fromList([0xFF, 0xFE, 0x1F, 0x04])), 'П');
    expect(
      decodeTextString(Uint8List.fromList([0xEF, 0xBB, 0xBF, 0xC3, 0xA9])),
      'é',
    );
    expect(decodeTextString(Uint8List.fromList([0x80, 0xA0, 0xE9])), '•€é');
    expect(encodeTextString('plain é').bytes, [...'plain '.codeUnits, 0xE9]);
    final u = encodeTextString('€ П');
    expect(u.bytes.sublist(0, 2), [0xFE, 0xFF]);
    expect(decodeTextString(u.bytes), '€ П');
    for (final s in ['', 'a\nb', 'Grüße', '“smart” — dash', '😀']) {
      expect(decodeTextString(encodeTextString(s).bytes), s);
    }
  });

  test('WinAnsi encoding', () {
    expect(encodeWinAnsi('A€“”é'), [0x41, 0x80, 0x93, 0x94, 0xE9]);
    expect(encodeWinAnsi('Пa😀'), [0x3F, 0x61, 0x3F]);
    expect(canEncodeWinAnsi('hello\nworld’'), isTrue);
    expect(canEncodeWinAnsi('漢'), isFalse);
    expect(pdfLiteral('a(b)\\cé'), r'(a\(b\)\\c\351)');
  });

  test('word wrap', () {
    // "aaa " widths: a=556 → 5.56pt at 10pt
    expect(wrap('aaa bbb ccc', 50), ['aaa bbb', 'ccc']);
    expect(wrap('aaa bbb ccc', 1000), ['aaa bbb ccc']);
    expect(wrap('one\ntwo\r\nthree\rfour', 1000), [
      'one',
      'two',
      'three',
      'four',
    ]);
    expect(wrap('a\n\nb', 1000), ['a', '', 'b']);
    expect(wrap('', 100), ['']);
    expect(wrap('trailing\n', 1000), ['trailing', '']);
    // long word broken by characters
    expect(wrap('aaaaaaaaaa', 30), ['aaaaa', 'aaaaa']);
    // leading indentation on the first line is kept
    expect(wrap('   indented', 1000), ['   indented']);
    // many spaces at a wrap point are dropped
    expect(wrap('aaa      bbb', 25), ['aaa', 'bbb']);
  });

  test('word wrap breaks inside words where Flutter does (UAX #14)', () {
    // Break points allowed inside a word, found by making the line just
    // wide enough for the words before it plus the word's first k letters.
    List<String> breaks(String word) {
      const lead = 'Lorem ipsum dolor sit amet ';
      final out = <String>[];
      for (var k = 1; k < word.length; k++) {
        final s = '$lead$word';
        final first = s.substring(0, lead.length + k);
        final w = FontMetrics.helvetica.width(first, 10);
        if (wrap(s, w + 0.001).first == first) out.add(word.substring(0, k));
      }
      return out;
    }

    expect(breaks('double-checked'), ['double-']);
    expect(breaks('a-b-c'), ['a-', 'a-b-']);
    expect(breaks('a--b'), ['a--']);
    expect(breaks('5-foot'), ['5-']);
    expect(breaks('DC-15'), isEmpty); // hyphen before a digit
    expect(breaks('-word'), isEmpty); // leading minus
    expect(breaks("rock-'n'"), isEmpty); // before a quote
    expect(breaks('well-.'), isEmpty);
    expect(breaks('pre-(x)'), ['pre-']);
    expect(breaks('ranger/rogue'), ['ranger/']);
    expect(breaks('1/day'), ['1/']);
    expect(breaks('com/12345'), ['com/']);
    expect(breaks('1/2'), isEmpty);
    expect(breaks('2d6+3/2'), isEmpty);
    expect(breaks('eye—both'), ['eye', 'eye—']);
    expect(breaks('(—a'), ['(—']);
    expect(breaks('1–3'), ['1–']);
    expect(breaks('–a'), isEmpty);
    expect(breaks('a?b'), ['a?']);
    for (final w in ['a.b', 'a,b', 'a+b', 'a%b', 'a)b', 'a’b', 'it’s']) {
      expect(breaks(w), isEmpty, reason: w);
    }
  });

  test(
    'word wrap: a word too long for any line starts on the current line',
    () {
      // Flutter fills the current line with its first letters.
      expect(wrap('ab ${'c' * 12}', 50), ['ab ccccccc', 'ccccc']);
      // ...but a word that fits on a line of its own moves down whole.
      expect(wrap('ab ${'c' * 8}', 50), ['ab', 'cccccccc']);
      // Not even one letter fits after the first word: next line.
      expect(wrap('aaaaaaaa ${'c' * 12}', 47), [
        'aaaaaaaa',
        'ccccccccc',
        'ccc',
      ]);
    },
  );

  test('firstBaselineFor matches where the appearance draws line 1', () {
    for (final multi in [false, true]) {
      for (final (look, fs) in [
        (const WidgetLook(width: 100, height: 20), 10.0),
        (const WidgetLook(width: 100, height: 60, border: '0 G'), 12.0),
        (const WidgetLook(width: 14.4, height: 8.6), 5.0),
      ]) {
        final spec = TextLayoutSpec(
          fontName: 'Helv',
          metrics: FontMetrics.helvetica,
          fontSize: fs,
          multiline: multi,
        );
        final y = double.parse(
          RegExp(r'1 0 0 1 [\d.]+ ([\d.-]+) Tm')
              .firstMatch(textAppearanceContent(look, spec, 'Ag'))!
              .group(1)!,
        );
        expect(firstBaselineFor(look, spec, fs), closeTo(look.bh - y, 0.001));
      }
    }
  });

  test('DA parsing', () {
    final a = parseDA('/Helv 12 Tf 0 g');
    expect(a.font, 'Helv');
    expect(a.size, 12);
    expect(a.color, '0 g');
    final b = parseDA('0.2 0.4 0.6 rg /F1 0 Tf');
    expect(b.font, 'F1');
    expect(b.size, 0);
    expect(b.color, '0.2 0.4 0.6 rg');
    expect(parseDA('').font, isNull);
    expect(parseDA('/X 9 Tf 0 0 0 1 k').color, '0 0 0 1 k');
  });

  test('appearance: single-line alignment and comb', () {
    const look = WidgetLook(width: 100, height: 20);
    String lay(int q) => textAppearanceContent(
      look,
      TextLayoutSpec(
        fontName: 'Helv',
        metrics: FontMetrics.helvetica,
        fontSize: 10,
        quadding: q,
      ),
      'ab',
    );
    double x(String s) =>
        double.parse(RegExp(r'1 0 0 1 ([\d.]+) ').firstMatch(s)!.group(1)!);
    final w = FontMetrics.helvetica.width('ab', 10);
    expect(x(lay(0)), 2);
    expect(x(lay(1)), closeTo(2 + (96 - w) / 2, 0.001));
    expect(x(lay(2)), closeTo(98 - w, 0.001));
    final comb = textAppearanceContent(
      look,
      const TextLayoutSpec(
        fontName: 'Helv',
        metrics: FontMetrics.helvetica,
        fontSize: 10,
        comb: true,
        maxLen: 4,
      ),
      'abcdef',
    );
    expect(RegExp(r'Tm \(.\) Tj').allMatches(comb).length, 4);
    final pw = textAppearanceContent(
      look,
      const TextLayoutSpec(
        fontName: 'Helv',
        metrics: FontMetrics.helvetica,
        fontSize: 10,
        password: true,
      ),
      'secret',
    );
    expect(pw, contains('(******) Tj'));
    expect(pw, isNot(contains('secret')));
  });

  test('appearance: auto size single line fits width', () {
    const look = WidgetLook(width: 60, height: 20);
    final s = textAppearanceContent(
      look,
      const TextLayoutSpec(
        fontName: 'Helv',
        metrics: FontMetrics.helvetica,
        fontSize: 0,
      ),
      'a fairly long value',
    );
    final fs = double.parse(
      RegExp(r'/Helv ([\d.]+) Tf').firstMatch(s)!.group(1)!,
    );
    expect(
      FontMetrics.helvetica.width('a fairly long value', fs),
      lessThanOrEqualTo(56.001),
    );
  });

  test('appearance: rotation matrix and bbox', () {
    const look = WidgetLook(width: 100, height: 20, rotation: 90);
    final st = look.formXObject('', null);
    expect(st.dict['BBox'], [0, 0, 20, 100]);
    expect(st.dict['Matrix'], [0, 1, -1, 0, 100, 0]);
  });

  test('page geometry inverse transforms', () {
    for (final r in [0, 90, 180, 270]) {
      final p = PageModel(0, null, PdfDict(), 10, 20, 410, 620, r);
      const rect = PdfRect(12, 34, 56, 78);
      final u = p.rectToUser(rect);
      final back = p.rectToDisplay(u);
      expect(back.left, closeTo(12, 1e-9));
      expect(back.top, closeTo(34, 1e-9));
      expect(back.width, closeTo(56, 1e-9));
      expect(back.height, closeTo(78, 1e-9));
    }
  });
}
