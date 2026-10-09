// QA (Android + iOS): the edit overlay must wrap multi-line text at the
// same words as the saved appearance. Compares, line by line, where the
// overlay's editor breaks lines (measured from its RenderEditable) with the
// core's wrapText at the appearance's font size and width.
//
// Android: tool/qa/android_run.sh integration_test/wrap_match_test.dart <log>
// iOS:     tool/qa/ios_run.sh integration_test/wrap_match_test.dart
//          (with tool/qa/ios_shooter.sh running for screenshots)
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/core/src/text.dart';
import 'package:pdfedit/services/doc_session.dart';
import 'package:pdfedit/services/file_service.dart';
import 'package:pdfedit/ui/edit/fill_overlay.dart';

import 'android_fixtures.dart';
import 'ios_helpers.dart' as ios;
import 'ios_helpers.dart' show log, wait, qaTest, qaDone, startApp;

/// Screenshot on either platform: iOS via the shooter's request files,
/// Android via the tool/qa/android_run.sh "[QA] SHOT" line.
Future<void> snap(WidgetTester t, String name) async {
  if (Platform.isIOS) return ios.shot(t, name);
  await wait(t, 800);
  log('SHOT $name');
  await wait(t, 1500);
}

String sampleText() {
  final b = StringBuffer();
  b.writeln(
    "The half-elf ranger/rogue drew a well-balanced longbow (+7 to "
    "hit, 1d8+4 piercing) and loosed two arrows at the hill giant's left "
    'eye — both hit. Self-contained, double-checked, rock-solid: the '
    'twenty-five-foot rope bridge held. See dndbeyond.com/characters/12345 '
    'or A/B/C; numbers like 1,000,000, -5, +10% and (parenthetical) notes.',
  );
  b.writeln(
    'Supercalifragilisticexpialidociousandaverylongwordthatexceedsthe'
    'widthofthelineentirelyandmustbebrokenbycharacters, then normal words.',
  );
  for (var p = 1; p <= 30; p++) {
    b.writeln(
      'Paragraph $p. Lorem ipsum dolor sit amet, consectetur '
      'adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore '
      'magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation.',
    );
  }
  return b.toString().trimRight();
}

List<int> coreLineStarts(String text, PdfField f, PdfTextFit fit) {
  final innerW = f.rect.width - 2 * fit.inset;
  final m = fit.monospace ? FontMetrics.courier : FontMetrics.helvetica;
  final out = <int>[];
  for (final l in wrapText(text, innerW, fit.fontSize, m)) {
    for (var i = l.start; i < l.end; i++) {
      if (!' \t\r\n'.contains(text[i])) {
        out.add(i);
        break;
      }
    }
  }
  return out;
}

/// Where the overlay editor of [box] starts each visible line.
List<int> editorLineStarts(WidgetTester t, Finder box) {
  final st = t.state<EditableTextState>(
    find.descendant(of: box, matching: find.byType(EditableText)),
  );
  final re = st.renderEditable;
  final text = st.textEditingValue.text;
  final out = <int>[];
  double? lastTop;
  for (var i = 0; i < text.length; i++) {
    if (' \t\r\n'.contains(text[i])) continue;
    final boxes = re.getBoxesForSelection(
      TextSelection(baseOffset: i, extentOffset: i + 1),
    );
    if (boxes.isEmpty) continue;
    final top = boxes.first.top;
    if (lastTop == null || (top - lastTop).abs() > 0.5) {
      out.add(i);
      lastTop = top;
    }
  }
  return out;
}

/// Compares the overlay and core line breaks of text field [f]; returns
/// the number of differing lines.
int compareWrap(WidgetTester t, DocSession s, PdfField f, String tag) {
  final box = find.byKey(ValueKey('text:${f.id}'));
  final st = t.state<EditableTextState>(
    find.descendant(of: box, matching: find.byType(EditableText)),
  );
  final text = st.textEditingValue.text;
  final fit = s.editDoc!.textFit(f, text);
  final ed = editorLineStarts(t, box);
  final core = coreLineStarts(text, f, fit);
  final edSet = ed.toSet(), coreSet = core.toSet();
  final diff = {
    ...edSet.difference(coreSet),
    ...coreSet.difference(edSet),
  }.toList()..sort();
  final editorBox = t.renderObject(
    find.descendant(of: box, matching: find.byType(EditableText)),
  ) as RenderBox;
  log(
    '$tag ${f.fullName}: fs=${fit.fontSize.toStringAsFixed(2)} '
    'inset=${fit.inset} boxW=${f.rect.width.toStringAsFixed(1)}pt '
    'editorW=${editorBox.size.width.toStringAsFixed(2)}px '
    'lines editor=${ed.length} core=${core.length} differing=${diff.length}',
  );
  // Vertical metrics: line pitch and first baseline vs the PDF's.
  final re = st.renderEditable;
  final scale = t.getSize(box).width / f.rect.width;
  if (ed.length > 2) {
    final b0 = re
        .getBoxesForSelection(
          TextSelection(baseOffset: ed.first, extentOffset: ed.first + 1),
        )
        .first;
    final bn = re
        .getBoxesForSelection(
          TextSelection(baseOffset: ed.last, extentOffset: ed.last + 1),
        )
        .first;
    double gy(double y) => re.localToGlobal(Offset(0, y)).dy;
    final pitch = (gy(bn.top) - gy(b0.top)) / (ed.length - 1);
    final baseline = gy(
      re.computeDistanceToActualBaseline(TextBaseline.alphabetic),
    );
    final want = t.getTopLeft(box).dy + fit.firstBaseline! * scale;
    log(
      '$tag pitch ${pitch.toStringAsFixed(3)}px want '
      '${(fit.lineHeight * scale).toStringAsFixed(3)}px; first baseline '
      '${(baseline - want).toStringAsFixed(2)}px off the PDF\'s',
    );
  }
  for (final i in diff.take(8)) {
    final a = math.max(0, i - 25), b = math.min(text.length, i + 15);
    log(
      '  $tag diff@$i ${edSet.contains(i) ? "editor" : "core"} breaks before: '
      '"${text.substring(a, i)}|${text.substring(i, b)}"',
    );
  }
  return diff.length;
}

/// Device text measurement vs the core's Helvetica widths.
void logFontMetrics() {
  const sample =
      'Paragraph 23. Lorem ipsum dolor sit amet, consectetur '
      'adipiscing elit, sed do eiusmod';
  final core = FontMetrics.helvetica.width(sample, 12);
  for (final px in [7.6, 12.0, 15.2, 30.0]) {
    final tp = TextPainter(
      text: TextSpan(
        text: sample,
        style: TextStyle(
          fontFamily: 'Liberation Sans',
          fontSize: px,
          letterSpacing: 0,
          fontFeatures: noKerning,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    log(
      'font size ${px}px: Liberation width ${tp.width.toStringAsFixed(3)}px '
      'core Helvetica ${(core * px / 12).toStringAsFixed(3)}px '
      'ratio ${(tp.width / (core * px / 12)).toStringAsFixed(5)}',
    );
    tp.dispose();
  }
}

/// The corpus of test/ui/wrap_parity_test.dart laid out with TextPainter
/// at the pixel sizes the overlay uses on this device.
void corpusParity(double scale) {
  const corpus = [
    "The half-elf ranger/rogue drew a well-balanced longbow (+7 to hit, "
        "1d8+4 piercing) and loosed two arrows at the hill giant's left eye "
        '\u2014 both hit. Self-contained, double-checked, rock-solid: the '
        'twenty-five-foot rope bridge held. See dndbeyond.com/characters/12345 '
        'or A/B/C; numbers like 1,000,000, -5, +10% and (parenthetical) notes.',
    'Second Wind (1/short rest): regain 1d10+5 HP. Action Surge\u2014one '
        'more action. Spells: Fire Bolt, Mage Hand, Shield (1st-level), '
        'Misty Step (2nd-level). Darkvision 60 ft. Dwarven Resilience: '
        'advantage vs. poison. Languages: Common, Dwarvish, Thieves\u2019 Cant.',
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod '
        'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim '
        'veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip.',
  ];
  var lines = 0, borderline = 0, wrong = 0;
  for (final text in corpus) {
    for (final fs in [12.0, 9.5, 7.35]) {
      for (var w = 90.0; w <= 470; w += 7.3) {
        final tp = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontFamily: 'Liberation Sans',
              fontSize: (fs * scale * 64).floorToDouble() / 64,
              letterSpacing: 0,
              fontFeatures: noKerning,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: w * (fs * scale * 64).floorToDouble() / 64 / fs);
        final got = <int>[];
        double? lastTop;
        for (var i = 0; i < text.length; i++) {
          if (text[i] == ' ') continue;
          final b = tp.getBoxesForSelection(
            TextSelection(baseOffset: i, extentOffset: i + 1),
          );
          if (b.isEmpty) continue;
          if (lastTop == null || (b.first.top - lastTop).abs() > 0.5) {
            got.add(i);
            lastTop = b.first.top;
          }
        }
        tp.dispose();
        int firstDiff(List<int> a, List<int> b) {
          for (var i = 0; i < a.length && i < b.length; i++) {
            if (a[i] != b[i]) return i;
          }
          return a.length == b.length ? -1 : math.min(a.length, b.length);
        }

        List<int> starts(double ww) {
          final out = <int>[];
          for (final l in wrapText(text, ww, fs, FontMetrics.helvetica)) {
            for (var i = l.start; i < l.end; i++) {
              if (text[i] != ' ') {
                out.add(i);
                break;
              }
            }
          }
          return out;
        }

        final want = starts(w);
        final at = firstDiff(got, want);
        lines += at < 0 ? want.length : at;
        if (at < 0) continue;
        final near = [0.999, 1.001].any((k) {
          final d = firstDiff(got, starts(w * k));
          return d < 0 || d > at;
        });
        if (near) {
          borderline++;
        } else {
          wrong++;
          log('corpus MISMATCH scale=$scale fs=$fs w=$w line $at');
        }
      }
    }
  }
  log(
    'corpus parity scale=$scale: lines=$lines borderline(<0.1%)=$borderline '
    'wrong=$wrong',
  );
  expect(wrong, 0);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  qaDone();

  qaTest('wrap: corpus parity at overlay pixel sizes', (t) async {
    final qa = await startApp(t);
    expect(qa, isNotNull);
    for (final scale in [0.6447, 0.6626, 1.0, 1.3, 2.17]) {
      corpusParity(scale);
    }
  });

  qaTest('wrap: New doc Body1 overlay vs PDF', (t) async {
    logFontMetrics();
    final qa = await startApp(t);
    final s = qa.session;
    log(
      'textScaler ${MediaQuery.textScalerOf(t.element(find.byType(Scaffold).first))} '
      'dpr ${t.view.devicePixelRatio}',
    );
    await t.tap(find.byKey(const ValueKey('home-new')));
    await wait(t, 800);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 800);
    await t.enterText(find.byKey(const ValueKey('draft-field')), sampleText());
    await wait(t, 500);
    FocusManager.instance.primaryFocus?.unfocus();
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 3000);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    final body = s.editDoc!.fields.firstWhere((f) => f.fullName == 'Body1');
    final n1 = compareWrap(t, s, body, '1x');
    await snap(t, 'w1_overlay_1x');
    FocusManager.instance.primaryFocus?.unfocus();
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2500);
    await snap(t, 'w2_rendered_1x');

    // Zoomed in (scale changes the pixel font size and so the rounding).
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    final c = Offset(size.width / 2, size.height * 0.4);
    final a = await t.startGesture(c - const Offset(50, 0), pointer: 11);
    final b = await t.startGesture(c + const Offset(50, 0), pointer: 12);
    for (var i = 0; i < 20; i++) {
      await a.moveBy(const Offset(-4, 0));
      await b.moveBy(const Offset(4, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await wait(t, 1500);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    final n2 = compareWrap(t, s, body, 'zoom');
    await snap(t, 'w3_overlay_zoom');
    FocusManager.instance.primaryFocus?.unfocus();
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2000);
    await snap(t, 'w4_rendered_zoom');
    expect(n1 + n2, 0);
  });

  qaTest('wrap: bordered multi-line field (form comments)', (t) async {
    final qa = await startApp(t);
    final s = qa.session;
    final dir = Platform.isIOS
        ? await getTemporaryDirectory()
        : await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/qa_wrap_form.pdf');
    final bytes = base64Decode(qaFormB64);
    await file.writeAsBytes(bytes);
    expect(
      await s.open(
        bytes,
        location: FileService.pathLocation(file.path),
        askPassword: (_) async => null,
      ),
      isTrue,
    );
    await wait(t, 2000);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1200);
    final f = s.editDoc!.fields.firstWhere((f) => f.fullName == 'comments');
    final box = find.byKey(ValueKey('text:${f.id}'));
    await t.enterText(
      find.descendant(of: box, matching: find.byType(TextField)),
      'Second Wind: regain 1d10 + fighter level HP. Action Surge: one '
      'more action. Two-Weapon Fighting, darkvision 60 ft, half-orc.',
    );
    await wait(t, 800);
    final n = compareWrap(t, s, f, 'form');
    await snap(t, 'w5_form_overlay');
    FocusManager.instance.primaryFocus?.unfocus();
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2500);
    await snap(t, 'w6_form_rendered');
    expect(n, 0);
  });
}
