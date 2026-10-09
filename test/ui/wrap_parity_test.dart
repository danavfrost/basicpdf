// The edit overlay must wrap multi-line text at the same words as the
// saved appearance. With the bundled Liberation Sans (Helvetica's widths)
// loaded, Flutter's line breaks are compared with the core's wrapText.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/core/src/text.dart';
import 'package:pdfedit/ui/edit/edit_session.dart';
import 'package:pdfedit/ui/edit/fill_overlay.dart';

const corpus = [
  "The half-elf ranger/rogue drew a well-balanced longbow (+7 to hit, "
      "1d8+4 piercing) and loosed two arrows at the hill giant's left eye "
      '— both hit. Self-contained, double-checked, rock-solid: the '
      'twenty-five-foot rope bridge held. See dndbeyond.com/characters/12345 '
      'or A/B/C; numbers like 1,000,000, -5, +10% and (parenthetical) notes.',
  'Second Wind (1/short rest): regain 1d10+5 HP. Action Surge—one '
      'more action. Spells: Fire Bolt, Mage Hand, Shield (1st-level), '
      'Misty Step (2nd-level). Darkvision 60 ft. Dwarven Resilience: '
      'advantage vs. poison. Languages: Common, Dwarvish, Thieves’ Cant.',
  'He alone dug his way out—and has been looking for the one who set '
      'the charges ever since. Half-orc, half-mad, all-in. It’s a '
      '“friend” of the Lords’ Alliance/Zhentarim double-agent.',
  'Supercalifragilisticexpialidociousandaverylongwordthatexceedsthewidth '
      'then a few normal words, https://www.example.com/a/very/long/path?x=1 '
      'and the end.',
  'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod '
      'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim '
      'veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip.',
];

Future<void> loadFonts() async {
  final l = FontLoader('Liberation Sans')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('assets/fonts/LiberationSans-Regular.ttf').readAsBytesSync(),
        ),
      ),
    );
  await l.load();
}

List<int> coreStarts(String text, double width, double fs) {
  final out = <int>[];
  for (final l in wrapText(text, width, fs, FontMetrics.helvetica)) {
    for (var i = l.start; i < l.end; i++) {
      if (!' \t\r\n'.contains(text[i])) {
        out.add(i);
        break;
      }
    }
  }
  return out;
}

/// Index of the first visible character of every laid-out line.
List<int> flutterStarts(String text, List<TextBox> Function(int) boxOf) {
  final out = <int>[];
  double? lastTop;
  for (var i = 0; i < text.length; i++) {
    if (' \t\r\n'.contains(text[i])) continue;
    final b = boxOf(i);
    if (b.isEmpty) continue;
    if (lastTop == null || (b.first.top - lastTop).abs() > 0.5) {
      out.add(i);
      lastTop = b.first.top;
    }
  }
  return out;
}

int firstDifference(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length
      ? -1
      : (a.length < b.length ? a.length : b.length);
}

/// True if the core, wrapping at a width 0.05 % narrower or wider, breaks
/// line [at] the way Flutter did ([got]).
bool nearlyFits(String text, List<int> got, int at, double w, double fs) {
  for (final k in [1 - 0.0005, 1 + 0.0005]) {
    final d = firstDifference(got, coreStarts(text, w * k, fs));
    if (d < 0 || d > at) return true;
  }
  return false;
}

void main() {
  setUpAll(loadFonts);

  testWidgets('Flutter and the core break lines at the same places', (t) async {
    var lines = 0, borderline = 0;
    for (final text in corpus) {
      for (final fs in [12.0, 9.5, 7.35]) {
        for (var w = 90.0; w <= 470; w += 7.3) {
          final tp = TextPainter(
            text: TextSpan(
              text: text,
              style: TextStyle(
                fontFamily: 'Liberation Sans',
                fontSize: fs,
                letterSpacing: 0,
                fontFeatures: noKerning,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: w);
          final got = flutterStarts(
            text,
            (i) => tp.getBoxesForSelection(
              TextSelection(baseOffset: i, extentOffset: i + 1),
            ),
          );
          tp.dispose();
          final want = coreStarts(text, w, fs);
          final at = firstDifference(got, want);
          lines += at < 0 ? want.length : at;
          if (at < 0) continue;
          // Liberation's advances are Helvetica's rounded to 1/2048 em, so
          // a line that the next piece *almost* fits (within 0.05 %) may
          // go either way. Anything else is a real rule difference.
          final reason = 'fs=$fs w=$w line $at "${text.substring(0, 20)}"';
          expect(nearlyFits(text, got, at, w, fs), isTrue, reason: reason);
          borderline++;
        }
      }
    }
    expect(lines, greaterThan(2000));
    expect(borderline, lessThan(lines / 200));
  });

  testWidgets('the fill overlay editor wraps like the saved New page', (
    t,
  ) async {
    final text = corpus.join('\n');
    final doc = PdfEditDoc.open(PdfEditDoc.createTextDocument(text));
    final body = doc.fields.single;
    for (final scale in [0.6447, 1.0, 1.73]) {
      final session = EditSession(doc);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 612 * scale,
                height: 792 * scale,
                child: FillOverlay(
                  session: session,
                  pageIndex: 0,
                  scale: scale,
                ),
              ),
            ),
          ),
        ),
      );
      final st = t.state<EditableTextState>(find.byType(EditableText));
      final re = st.renderEditable;
      final fit = doc.textFit(body, body.value);
      final innerW = body.rect.width - 2 * fit.inset;
      // The editor wraps at the appearance's text width, in proportion to
      // the font size it actually uses (a whole number of 1/64 px).
      final px = st.widget.style.fontSize!;
      expect(px * 64, (px * 64).roundToDouble());
      expect(
        (re.size.width - re.cursorWidth - 1) / px,
        closeTo(innerW / fit.fontSize, 1e-6),
      );
      final want = coreStarts(body.value, innerW, fit.fontSize);
      final got = flutterStarts(
        body.value,
        (i) => re.getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1),
        ),
      );
      expect(got, want, reason: 'scale $scale');
      // On screen, lines are exactly the page's line spacing apart and the
      // text is the page's size (within the 1/64 px rounding).
      double gy(int i) => re
          .localToGlobal(
            re
                .getBoxesForSelection(
                  TextSelection(baseOffset: i, extentOffset: i + 1),
                )
                .first
                .toRect()
                .topLeft,
          )
          .dy;
      expect(
        (gy(want.last) - gy(want[1])) / (want.length - 2),
        closeTo(fit.lineHeight * scale, 0.001),
      );
      final shown =
          re.localToGlobal(const Offset(100, 0)).dx -
          re.localToGlobal(Offset.zero).dx;
      expect(px * shown / 100, closeTo(fit.fontSize * scale, 1 / 64));
      // The first baseline is where the appearance draws it.
      final boxTop = t.getTopLeft(find.byKey(ValueKey('text:${body.id}'))).dy;
      final baseline = re
          .localToGlobal(
            Offset(
              0,
              re.computeDistanceToActualBaseline(TextBaseline.alphabetic),
            ),
          )
          .dy;
      expect(baseline - boxTop, closeTo(fit.firstBaseline! * scale, 0.05));
    }
  });

  testWidgets('character sheet: text sits where the appearance draws it', (
    t,
  ) async {
    final doc = PdfEditDoc.open(
      File('test/fixtures/character_sheet.pdf').readAsBytesSync(),
    );
    PdfField named(String n) => doc.fields.firstWhere((f) => f.fullName == n);
    const scale = 1.5;
    final session = EditSession(doc);
    final samples = {
      'STR': '16', // centred, auto size
      'STRmod': '+3',
      'Acrobatics': '+5', // 14 x 9 pt box
      'CharacterName': 'Brannoc Ironvein', // left
      'Features and Traits': 'Second Wind: regain 1d10 + 5 HP.',
    };
    for (final e in samples.entries) {
      session.setValue(named(e.key), e.value);
    }
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 612 * scale,
              height: 792 * scale,
              child: FillOverlay(session: session, pageIndex: 0, scale: scale),
            ),
          ),
        ),
      ),
    );
    for (final e in samples.entries) {
      final f = named(e.key);
      final fit = doc.textFit(f, e.value);
      final box = find.byKey(ValueKey('text:${f.id}'));
      final st = t.state<EditableTextState>(
        find.descendant(of: box, matching: find.byType(EditableText)),
      );
      final re = st.renderEditable;
      final first = re
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .first;
      final origin = t.getTopLeft(box);
      final x = re.localToGlobal(Offset(first.left, 0)).dx - origin.dx;
      final line = e.value.split('\n').first;
      final innerW = f.rect.width - 2 * fit.inset;
      final words = wrapText(
        e.value,
        innerW,
        fit.fontSize,
        FontMetrics.helvetica,
      );
      final firstLine = line.substring(words.first.start, words.first.end);
      final tw = FontMetrics.helvetica.width(firstLine, fit.fontSize);
      final wantX = switch (fit.quadding) {
        1 => fit.inset + (innerW - tw) / 2,
        2 => fit.inset + innerW - tw,
        _ => fit.inset,
      };
      expect(x, closeTo(wantX * scale, 0.1), reason: '${e.key} x');
      final baseline =
          re
              .localToGlobal(
                Offset(
                  0,
                  re.computeDistanceToActualBaseline(TextBaseline.alphabetic),
                ),
              )
              .dy -
          origin.dy;
      expect(
        baseline,
        closeTo(fit.firstBaseline! * scale, 0.1),
        reason: '${e.key} baseline',
      );
    }
  }, skip: !File('test/fixtures/character_sheet.pdf').existsSync());
}
