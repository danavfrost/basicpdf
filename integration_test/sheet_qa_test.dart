// QA (Android + iOS): the 5e character sheet (test/fixtures/
// character_sheet.pdf) — open time, scrolling, edit overlay alignment and
// tap target sizes, a representative fill, overflow notes, zoomed editing,
// Save As, reopen.
//
// The sheet must be on the device first:
//  Android: tool/qa/android_run.sh (on "[QA] PUSH" it copies
//           it into the app's documents dir with run-as), Save As taps the system
//           SAVE button at the coordinates in [_androidSaveTap].
//  iOS:     copy it to <container>/Documents/qa/Character Sheet.pdf, then
//           tool/qa/ios_run.sh integration_test/sheet_qa_test.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/services/file_service.dart';
import 'package:pdfedit/ui/edit/fill_overlay.dart';
import 'package:pdfedit/ui/viewer/pages_view.dart';

import 'ios_helpers.dart' as ios;
import 'ios_helpers.dart'
    show QaApp, log, wait, until, qaTest, qaDone, startApp, menu;

const _androidSaveTap = '927 2274';

Future<void> snap(WidgetTester t, String name) async {
  if (Platform.isIOS) return ios.shot(t, name);
  await wait(t, 800);
  log('SHOT $name');
  await wait(t, 1500);
}

const values = <String, String>{
  'CharacterName': 'Brannoc Ironvein',
  'ClassLevel': 'Fighter 5 / Rogue 1',
  'Background': 'Soldier',
  'PlayerName': 'Test Player',
  'Race ': 'Mountain Dwarf',
  'Alignment': 'Lawful Neutral',
  'XP': '6,500',
  'STR': '16',
  'STRmod': '+3',
  'DEX': '12',
  'DEXmod ': '+1',
  'CON': '15',
  'CONmod': '+2',
  'ProfBonus': '+3',
  'Athletics': '+6',
  'Perception ': '+4',
  'AC': '18',
  'Initiative': '+1',
  'Speed': '25 ft',
  'HPMax': '52',
  'HPCurrent': '47',
  'HD': '5d10 + 1d8',
  'Passive': '14',
  'Wpn Name': 'Warhammer',
  'Wpn1 AtkBonus': '+6',
  'Wpn1 Damage': '1d8+3 bludgeoning',
  'GP': '127',
  'PersonalityTraits ':
      'I face problems head-on. A simple, direct solution is the best '
      'path to success.',
  'Equipment':
      'Chain mail, shield, warhammer, light crossbow and 20 bolts, '
      "explorer's pack, insignia of rank (Ironguard), dice set.",
  'Features and Traits':
      'Second Wind: bonus action, regain 1d10 + fighter level HP. '
      'Once per short rest.\n'
      'Action Surge: one additional action. Once per short rest.\n'
      'Fighting Style (Defense): +1 AC while wearing armor.\n'
      'Darkvision 60 ft. Dwarven Resilience: advantage on saves '
      'against poison, resistance to poison damage.\n'
      'Sneak Attack 1d6. Thieves’ Cant. Expertise: Athletics, '
      'thieves’ tools.',
};

/// Proficiency dots: STR save, Athletics, Investigation (by position on
/// page 1, see the core test).
const checks = ['Check Box 11', 'Check Box 26', 'Check Box 31'];

Map<int, Rect> pageRects(WidgetTester t) => {
  for (final e in find.byType(PdfPageImage).evaluate())
    (e.widget as PdfPageImage).page.pageNumber - 1:
        (e.renderObject as RenderBox).localToGlobal(Offset.zero) &
        (e.renderObject as RenderBox).size,
};

Rect? fieldOnScreen(WidgetTester t, PdfEditDoc doc, PdfField f) {
  final pr = pageRects(t)[f.pageIndex];
  if (pr == null) return null;
  final k = pr.width / doc.pages[f.pageIndex].width;
  return Rect.fromLTWH(
    pr.left + f.rect.left * k,
    pr.top + f.rect.top * k,
    f.rect.width * k,
    f.rect.height * k,
  );
}

/// Worst distance between a text overlay and its field, on screen.
double checkAlignment(WidgetTester t, PdfEditDoc doc, String tag) {
  var worst = 0.0, n = 0;
  for (final f in doc.fields) {
    final finder = find.byKey(ValueKey('text:${f.id}'));
    if (finder.evaluate().isEmpty) continue;
    final want = fieldOnScreen(t, doc, f);
    if (want == null) continue;
    final box = t.renderObject(finder) as RenderBox;
    final got = box.localToGlobal(Offset.zero) & box.size;
    // Tiny boxes are drawn at least 8 px; compare the top-left corner.
    final err = math.max(
      (want.left - got.left).abs(),
      (want.top - got.top).abs(),
    );
    worst = math.max(worst, err);
    n++;
  }
  log('$tag alignment: $n text overlays, worst ${worst.toStringAsFixed(2)} px');
  return worst;
}

void logTapTargets(WidgetTester t, PdfEditDoc doc) {
  final pr = pageRects(t)[0]!;
  final k = pr.width / doc.pages[0].width;
  final sizes = <String, List<double>>{};
  for (final f in doc.fields.where((f) => f.pageIndex == 0)) {
    final m = math.min(f.rect.width, f.rect.height) * k;
    (sizes[f.kind.name] ??= []).add(m);
  }
  for (final e in sizes.entries) {
    final l = e.value..sort();
    log(
      'tap targets p1 ${e.key}: n=${l.length} smallest side '
      'min=${l.first.toStringAsFixed(1)}dp median='
      '${l[l.length ~/ 2].toStringAsFixed(1)}dp '
      '<24dp: ${l.where((x) => x < 24).length} <12dp: ${l.where((x) => x < 12).length}',
    );
  }
  log('scale at 1x: ${k.toStringAsFixed(3)} dp/pt');
}

Future<void> reveal(WidgetTester t, Finder f) async {
  if (f.evaluate().isEmpty ||
      !t
          .getRect(f)
          .overlaps(
            Offset.zero & t.view.physicalSize / t.view.devicePixelRatio,
          )) {
    await t.scrollUntilVisible(
      f,
      200,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await wait(t, 200);
}

/// Scrolls the viewer so page-point [y] of page [page] is near the top.
Future<void> scrollToPagePoint(
  WidgetTester t,
  PdfEditDoc doc,
  int page,
  double y,
) async {
  for (var i = 0; i < 40; i++) {
    final pr = pageRects(t)[page];
    if (pr != null) {
      final k = pr.width / doc.pages[page].width;
      final target = pr.top + y * k;
      final d = target - 140;
      if (d.abs() < 20) break;
      await t.drag(
        find.byType(Scrollable).last,
        Offset(0, -d.clamp(-400.0, 400.0)),
      );
    } else {
      await t.drag(find.byType(Scrollable).last, const Offset(0, -400));
    }
    await wait(t, 250);
  }
  await wait(t, 600);
}

Future<File> sheetFile() async {
  if (Platform.isAndroid) {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/qa/Character Sheet.pdf');
    if (!f.existsSync()) log('PUSH');
    for (var i = 0; i < 100 && !f.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return f;
  }
  return File('${await ios.docsDir()}/qa/Character Sheet.pdf');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  qaDone();

  qaTest('character sheet: open, fill, save as, reopen', (t) async {
    final file = await sheetFile();
    final original = await file.readAsBytes();
    log('sheet ${original.length} bytes at ${file.path}');
    final QaApp qa = await startApp(t);
    final s = qa.session;
    await qa.history.touch(FileService.pathLocation(file.path));
    await wait(t, 500);

    // ---- open from Recent: time to first page image.
    final sw = Stopwatch()..start();
    await t.tap(find.text('Character Sheet.pdf').first);
    int? editMs;
    while (sw.elapsedMilliseconds < 15000) {
      await t.pump(const Duration(milliseconds: 16));
      editMs ??= s.editDoc != null ? sw.elapsedMilliseconds : null;
      final imgs = find.byType(RawImage).evaluate();
      if (imgs.any((e) => (e.widget as RawImage).image != null)) break;
    }
    log(
      'open: doc ready ${editMs}ms, first page image ${sw.elapsedMilliseconds}ms',
    );
    await wait(t, 1500);
    final doc = s.editDoc!;
    log('fields ${doc.fields.length} pages ${doc.pages.length}');
    await snap(t, 's01_open');

    // ---- scroll performance: fling through all pages and back.
    final timings = <FrameTiming>[];
    void onT(List<FrameTiming> l) => timings.addAll(l);
    SchedulerBinding.instance.addTimingsCallback(onT);
    for (var i = 0; i < 3; i++) {
      await t.fling(find.byType(Scrollable).last, const Offset(0, -900), 2500);
      await wait(t, 900);
    }
    for (var i = 0; i < 3; i++) {
      await t.fling(find.byType(Scrollable).last, const Offset(0, 900), 2500);
      await wait(t, 900);
    }
    await wait(t, 500);
    SchedulerBinding.instance.removeTimingsCallback(onT);
    if (timings.isNotEmpty) {
      final total =
          timings.map((f) => f.totalSpan.inMicroseconds / 1000).toList()
            ..sort();
      final build =
          timings.map((f) => f.buildDuration.inMicroseconds / 1000).toList()
            ..sort();
      final raster =
          timings.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()
            ..sort();
      String p(List<double> l, double q) =>
          l[(l.length * q).floor().clamp(0, l.length - 1)].toStringAsFixed(1);
      log(
        'scroll frames ${timings.length}: build p50 ${p(build, .5)} p90 ${p(build, .9)} max ${p(build, 1)}ms; '
        'raster p50 ${p(raster, .5)} p90 ${p(raster, .9)} max ${p(raster, 1)}ms; '
        'total>16.7ms: ${total.where((x) => x > 16.7).length}',
      );
    } else {
      log('scroll frames: no FrameTiming reported');
    }

    // ---- edit mode at 1x.
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await snap(t, 's02_edit_1x_top');
    logTapTargets(t, doc);
    final a1 = checkAlignment(t, doc, '1x');

    PdfField named(String n) => doc.fields.firstWhere((f) => f.fullName == n);

    // ---- fill the representative set.
    final fillSw = Stopwatch()..start();
    for (final e in values.entries) {
      final f = named(e.key);
      final box = find.byKey(ValueKey('text:${f.id}'));
      await reveal(t, box);
      await t.enterText(
        find.descendant(of: box, matching: find.byType(TextField)),
        e.value,
      );
      await t.pump(const Duration(milliseconds: 50));
    }
    log('typed ${values.length} fields in ${fillSw.elapsedMilliseconds}ms');
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 800);
    // Proficiency dots: tap the overlay at the dot's centre.
    for (final n in checks) {
      final f = named(n);
      await scrollToPagePoint(t, doc, 0, f.rect.top - 60);
      final r = fieldOnScreen(t, doc, f)!;
      await t.tapAt(r.center);
      await wait(t, 300);
    }
    // Overflow in a tiny skill box.
    final acro = named('Acrobatics');
    await reveal(t, find.byKey(ValueKey('text:${acro.id}')));
    await t.enterText(
      find.descendant(
        of: find.byKey(ValueKey('text:${acro.id}')),
        matching: find.byType(TextField),
      ),
      '+1 (expertise)',
    );
    await wait(t, 300);
    FocusManager.instance.primaryFocus?.unfocus();
    await scrollToPagePoint(t, doc, 0, 0);
    await snap(t, 's03_filled_top');
    await scrollToPagePoint(t, doc, 0, 300);
    await snap(t, 's04_filled_skills');
    await scrollToPagePoint(t, doc, 0, 560);
    await snap(t, 's05_filled_bottom');
    final overflowNotes = find.text(FillOverlay.overflowNote).evaluate().length;
    log('overflow notes shown: $overflowNotes');
    final a2 = checkAlignment(t, doc, 'filled');

    // ---- zoom in on the skills and edit there.
    await scrollToPagePoint(t, doc, 0, 300);
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    final c = Offset(size.width * 0.3, size.height * 0.45);
    final p1 = await t.startGesture(c - const Offset(40, 0), pointer: 11);
    final p2 = await t.startGesture(c + const Offset(40, 0), pointer: 12);
    for (var i = 0; i < 25; i++) {
      await p1.moveBy(const Offset(-5, 0));
      await p2.moveBy(const Offset(5, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await p1.up();
    await p2.up();
    await wait(t, 1500);
    final a3 = checkAlignment(t, doc, 'zoomed');
    final pr = pageRects(t)[0]!;
    log(
      'zoomed scale ${(pr.width / doc.pages[0].width).toStringAsFixed(3)} dp/pt',
    );
    final stealth = named('Stealth ');
    final sb = find.byKey(ValueKey('text:${stealth.id}'));
    if (sb.evaluate().isNotEmpty) {
      await t.enterText(
        find.descendant(of: sb, matching: find.byType(TextField)),
        '+1',
      );
    }
    await wait(t, 300);
    await snap(t, 's06_zoomed_edit');
    FocusManager.instance.primaryFocus?.unfocus();

    // ---- ✓ apply.
    final applySw = Stopwatch()..start();
    await t.tap(find.byKey(const ValueKey('done-button')));
    while (find.byType(FieldTextBox).evaluate().isNotEmpty &&
        applySw.elapsedMilliseconds < 15000) {
      await t.pump(const Duration(milliseconds: 16));
    }
    log('apply (✓) ${applySw.elapsedMilliseconds}ms');
    await wait(t, 2500);
    await snap(t, 's07_applied_zoomed');
    // back to 1x
    final q1 = await t.startGesture(c - const Offset(150, 0), pointer: 13);
    final q2 = await t.startGesture(c + const Offset(150, 0), pointer: 14);
    for (var i = 0; i < 30; i++) {
      await q1.moveBy(const Offset(5, 0));
      await q2.moveBy(const Offset(-5, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await q1.up();
    await q2.up();
    await wait(t, 1500);
    await scrollToPagePoint(t, doc, 0, 0);
    await snap(t, 's08_applied_top');
    await scrollToPagePoint(t, doc, 0, 300);
    await snap(t, 's09_applied_skills');
    await scrollToPagePoint(t, doc, 0, 560);
    await snap(t, 's10_applied_bottom');
    final applied = s.editDoc!;
    for (final e in values.entries) {
      final v = applied.fields.firstWhere((f) => f.fullName == e.key).value;
      if (v != e.value) log('MISMATCH after apply ${e.key}');
    }
    for (final n in checks) {
      log(
        'check $n = ${applied.fields.firstWhere((f) => f.fullName == n).value}',
      );
    }
    final bytes = s.bytes!;
    var prefix = bytes.length > original.length;
    for (var i = 0; prefix && i < original.length; i++) {
      if (bytes[i] != original[i]) prefix = false;
    }
    log(
      'original is prefix of new bytes: $prefix (${original.length} → ${bytes.length})',
    );

    // ---- Save As.
    await menu(t, 'Save As');
    if (Platform.isAndroid) {
      await t.pump();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3500)),
      );
      log('TAP $_androidSaveTap');
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3500)),
      );
      await wait(t, 1500);
    } else {
      await until(t, find.text('Save As'));
      await t.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'sheet_qa',
      );
      await wait(t, 400);
      await t.tap(find.widgetWithText(FilledButton, 'Save'));
      await wait(t, 1500);
    }
    final savedName = s.title;
    log('saved as "$savedName" loc=${s.location?.ref} dirty=${s.dirty}');
    expect(s.dirty, isFalse);

    // ---- close, reopen from Recent.
    if (Platform.isAndroid) {
      await t.binding.handlePopRoute();
    } else {
      await t.tap(find.byTooltip('Close'));
    }
    await wait(t, 1500);
    final reSw = Stopwatch()..start();
    await t.tap(find.text(savedName).first);
    await until(t, find.byKey(const ValueKey('edit-button')));
    log('reopen ${reSw.elapsedMilliseconds}ms');
    await wait(t, 2500);
    final re = s.editDoc!;
    var ok = 0;
    for (final e in values.entries) {
      final v = re.fields.firstWhere((f) => f.fullName == e.key).value;
      if (v == e.value) {
        ok++;
      } else {
        log('MISMATCH after reopen ${e.key}');
      }
    }
    log(
      'reopened: $ok/${values.length} values persisted; checks '
      '${checks.map((n) => re.fields.firstWhere((f) => f.fullName == n).value).toList()}',
    );
    await snap(t, 's11_reopened_top');
    if (Platform.isAndroid) {
      final saved = await File('/sdcard/Documents/$savedName').exists();
      log('PULL /sdcard/Documents/$savedName');
      log('saved file visible in Documents: $saved');
      await wait(t, 1500);
    }
    expect(ok, values.length);
    expect(a1, lessThan(1.5));
    expect(a2, lessThan(1.5));
    expect(a3, lessThan(1.5));
  });
}
