// QA (Android + iOS): fill a whole 5e character the way a player would on
// a phone — tap a field at 1x (zooms in on it), type, keyboard Next through
// the sheet, tap proficiency dots at 1x, double-tap zoom in and out, ✓,
// dark mode — with screenshots of each step, then write the bytes out for
// rendering on the host.
//
// Android: tool/qa/android_run.sh integration_test/sheet_fill_test.dart <log>
//          ("[QA] TYPE"/"[QA] KEY" type on the real keyboard with adb;
//          "[QA] PULL" copies the written PDF to the host).
// iOS:     tool/qa/ios_run.sh integration_test/sheet_fill_test.dart
//          with tool/qa/ios_shooter.sh running (no real keyboard: enterText).
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

import 'ios_helpers.dart' as ios;
import 'ios_helpers.dart' show QaApp, log, wait, qaTest, qaDone, startApp, menu;
import 'sheet_qa_test.dart' show sheetFile, pageRects, fieldOnScreen;

Future<void> snap(WidgetTester t, String name) async {
  if (Platform.isIOS) return ios.shot(t, name);
  await wait(t, 700);
  log('SHOT $name');
  await wait(t, 2600);
}

/// A point on screen (below the top bar) away from every field's tap
/// target, for double taps that should zoom.
Offset blankSpot(WidgetTester t, PdfEditDoc doc) {
  final size = t.view.physicalSize / t.view.devicePixelRatio;
  final rects = pageRects(t);
  for (var y = size.height * 0.5; y < size.height - 40; y += 17) {
    for (var x = 20.0; x < size.width - 20; x += 17) {
      final p = Offset(x, y);
      var free = true;
      for (final e in rects.entries) {
        if (!e.value.contains(p)) continue;
        final k = e.value.width / doc.pages[e.key].width;
        final fields = doc.fields.where((f) => f.pageIndex == e.key);
        if (fieldTargetAt(fields, p - e.value.topLeft, k) != null) free = false;
      }
      if (free) return p;
    }
  }
  return Offset(size.width / 2, size.height * 0.6);
}

/// Typed on the real keyboard (Android) in this order, pressing the
/// keyboard's Next after each: the header, then down the ability column.
const typed = <String, String>{
  'CharacterName': 'Brannoc Ironvein',
  'ClassLevel': 'Fighter 5 / Rogue 1',
  'Race ': 'Mountain Dwarf',
  'Background': 'Soldier',
  'Alignment': 'Lawful Neutral',
  'PlayerName': 'Hal',
  'XP': '6500',
  'STR': '16',
  'STRmod': '+3',
};

/// The rest, filled field by field (scrolling/zooming to each like Next).
const rest = <String, String>{
  'DEX': '12',
  'DEXmod ': '+1',
  'CON': '15',
  'CONmod': '+2',
  'INT': '10',
  'INTmod': '+0',
  'WIS': '13',
  'WISmod': '+1',
  'CHA': '8',
  'CHamod': '-1',
  'Inspiration': '1',
  'ProfBonus': '+3',
  'ST Strength': '+6',
  'ST Dexterity': '+1',
  'ST Constitution': '+5',
  'ST Intelligence': '+0',
  'ST Wisdom': '+1',
  'ST Charisma': '-1',
  'Acrobatics': '+1',
  'Animal': '+1',
  'Arcana': '+0',
  'Athletics': '+9',
  'Deception ': '-1',
  'History ': '+0',
  'Insight': '+4',
  'Intimidation': '-1',
  'Investigation ': '+0',
  'Medicine': '+1',
  'Nature': '+0',
  'Perception ': '+4',
  'Performance': '-1',
  'Persuasion': '-1',
  'Religion': '+0',
  'SleightofHand': '+1',
  'Stealth ': '+4',
  'Survival': '+4',
  'Passive': '14',
  'ProficienciesLang':
      'Armor: all armor, shields\n'
      'Weapons: simple, martial\n'
      "Tools: smith's tools, thieves' tools, dice set\n"
      'Languages: Common, Dwarvish, Thieves\' Cant',
  'AC': '18',
  'Initiative': '+1',
  'Speed': '25',
  'HPMax': '52',
  'HPCurrent': '47',
  'HPTemp': '5',
  'HDTotal': '5d10 + 1d8',
  'HD': '4d10',
  'Wpn Name': 'Warhammer',
  'Wpn1 AtkBonus': '+6',
  'Wpn1 Damage': '1d8+3 bludg.',
  'Wpn Name 2': 'Light crossbow',
  'Wpn2 AtkBonus ': '+4',
  'Wpn2 Damage ': '1d8+1 pierc.',
  'Wpn Name 3': 'Handaxe',
  'Wpn3 AtkBonus  ': '+6',
  'Wpn3 Damage ': '1d6+3 slash.',
  'AttacksSpellcasting':
      'Extra Attack is not yet available. Sneak Attack 1d6 once per turn '
      'with a finesse or ranged weapon when you have advantage.',
  'CP': '14',
  'SP': '32',
  'EP': '0',
  'GP': '127',
  'PP': '2',
  'Equipment':
      'Chain mail, shield, warhammer, light crossbow and 20 bolts, '
      "two handaxes, explorer's pack, insignia of rank (Ironguard), "
      'a set of bone dice, a trophy taken from a fallen enemy (a goblin '
      "chieftain's tooth), common clothes, belt pouch.",
  'PersonalityTraits ':
      'I face problems head-on. A simple, direct solution is the best '
      'path to success.',
  'Ideals': 'Responsibility. I do what I must and obey just authority.',
  'Bonds': 'Those who fight beside me are those worth dying for.',
  'Flaws': 'I made a terrible mistake in battle that cost many lives.',
  'Features and Traits':
      'Second Wind: bonus action, regain 1d10 + 5 HP. Once per short '
      'rest.\n\n'
      'Action Surge: one additional action on your turn. Once per short '
      'rest.\n\n'
      'Fighting Style (Defense): +1 AC while wearing armor.\n\n'
      'Martial Archetype (Battle Master): 4 superiority dice (d8); '
      'Riposte, Trip Attack, Precision Attack.\n\n'
      'Sneak Attack 1d6. Thieves’ Cant. Expertise: Athletics, '
      'thieves’ tools.\n\n'
      'Darkvision 60 ft. Dwarven Resilience: advantage on saves against '
      'poison, resistance to poison damage. Stonecunning.\n\n'
      'Military Rank: soldiers loyal to the Ironguard still recognize '
      'my authority.',
  // Page 2
  'CharacterName 2': 'Brannoc Ironvein',
  'Age': '87',
  'Height': "4'6\"",
  'Weight': '190 lb',
  'Eyes': 'Grey',
  'Skin': 'Ruddy',
  'Hair': 'Copper, braided',
  'Allies':
      'The Ironguard of Mithral Hall — old comrades who still owe me a '
      'drink or three.\n\nSergeant Mara Fenwick, quartermaster at the '
      'Neverwinter garrison.',
  'FactionName': 'Lords’ Alliance',
  'Backstory':
      'Brannoc served twenty years in the Ironguard, holding the deep gates '
      'against everything that crawled up from the Underdark. When a '
      'collapse he ordered buried half his company, he left the hall in '
      'disgrace.\n\nHe has since taken work as a caravan guard, card '
      'sharp and, when the coin is right, a quiet breaker of locks — '
      'looking all the while for the one who set the charges.',
  'Feat+Traits':
      'Battle Master maneuvers: Riposte, Trip Attack, Precision Attack. '
      'Student of War: smith\'s tools.',
  'Treasure':
      'A silver signet ring of the Ironguard; 3 small garnets (10 gp '
      'each); a map of the old Delzoun tunnels.',
  // Page 3
  'Spellcasting Class 2': 'Arcane Trickster (later)',
  'SpellcastingAbility 2': 'INT',
  'SpellSaveDC  2': '10',
  'SpellAtkBonus 2': '+3',
  'Spells 1014': 'Mage Hand',
  'Spells 1016': 'Minor Illusion',
  'Spells 1017': 'Light',
  'SlotsTotal 19': '2',
  'SlotsRemaining 19': '1',
  'Spells 1015': 'Disguise Self',
  'Spells 1023': 'Silent Image',
  'Spells 1024': 'Shield',
  'Spells 1025': 'Feather Fall',
};

/// Proficiency dots (by position: saves STR/CON; skills Athletics,
/// Insight, Perception, Stealth, Survival).
const dots = [
  'Check Box 11',
  'Check Box 19',
  'Check Box 26',
  'Check Box 29',
  'Check Box 34',
  'Check Box 39',
  'Check Box 40',
];

String adbText(String s) => s.replaceAll(' ', '%s').replaceAll('/', '/');

double zoomOf(WidgetTester t, PdfEditDoc doc) {
  final pr = pageRects(t).values.first;
  return pr.width / (t.view.physicalSize.width / t.view.devicePixelRatio - 16);
}

Future<void> doubleTap(WidgetTester t, Offset at) async {
  await t.tapAt(at);
  await t.pump(const Duration(milliseconds: 60));
  await t.tapAt(at);
}

/// Frame timings while [body] runs (e.g. a zoom animation).
Future<void> timed(
  WidgetTester t,
  String tag,
  Future<void> Function() body,
) async {
  final timings = <FrameTiming>[];
  void onT(List<FrameTiming> l) => timings.addAll(l);
  SchedulerBinding.instance.addTimingsCallback(onT);
  await body();
  await wait(t, 600);
  SchedulerBinding.instance.removeTimingsCallback(onT);
  if (timings.isEmpty) {
    log('$tag: no frame timings');
    return;
  }
  final b = timings.map((f) => f.buildDuration.inMicroseconds / 1000).toList()
    ..sort();
  final r = timings.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()
    ..sort();
  String p(List<double> l, double q) =>
      l[(l.length * q).floor().clamp(0, l.length - 1)].toStringAsFixed(1);
  log(
    '$tag: ${timings.length} frames, build p50 ${p(b, .5)} p90 ${p(b, .9)} max ${p(b, 1)} ms; '
    'raster p50 ${p(r, .5)} p90 ${p(r, .9)} max ${p(r, 1)} ms; '
    'over 16.7ms: ${timings.where((f) => f.totalSpan.inMicroseconds > 16700).length}',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  qaDone();

  qaTest('character sheet: fill a whole character on a phone', (t) async {
    final file = await sheetFile();
    final QaApp qa = await startApp(t);
    final s = qa.session;
    if (Theme.of(t.element(find.byType(Scaffold).first)).brightness ==
        Brightness.dark) {
      await menu(t, 'Dark mode');
    }
    await qa.history.touch(FileService.pathLocation(file.path));
    await wait(t, 500);
    await t.tap(find.text('Character Sheet.pdf').first);
    await ios.until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 2000);
    final doc = s.editDoc!;
    PdfField named(String n) => doc.fields.firstWhere((f) => f.fullName == n);
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    log(
      'view ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)} dp',
    );

    // ---- view mode: double tap zooms in and back out.
    await timed(t, 'double-tap zoom in (view)', () async {
      await doubleTap(t, Offset(size.width * 0.25, size.height * 0.45));
      await wait(t, 700);
    });
    log('zoom after double tap: ${zoomOf(t, doc).toStringAsFixed(2)}');
    await snap(t, 'v01_view_doubletap_zoomed');
    await timed(t, 'double-tap zoom out (view)', () async {
      await doubleTap(t, Offset(size.width * 0.5, size.height * 0.5));
      await wait(t, 700);
    });
    log('zoom after 2nd double tap: ${zoomOf(t, doc).toStringAsFixed(2)}');

    // ---- edit mode at 1x.
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await snap(t, 'e01_edit_1x');

    // ---- tap the name at 1x on the real keyboard: zooms in on it.
    t.testTextInput.unregister();
    final name = named('CharacterName');
    await timed(t, 'tap field at 1x -> zoom', () async {
      await t.tapAt(fieldOnScreen(t, doc, name)!.center);
      for (final ms in [150, 150, 300, 300]) {
        await wait(t, ms);
        log(
          '  zoom ${zoomOf(t, doc).toStringAsFixed(2)} '
          'name at ${fieldOnScreen(t, doc, name)}',
        );
      }
    });
    log('zoom after tapping the name: ${zoomOf(t, doc).toStringAsFixed(2)}');
    await wait(t, 800);
    await snap(t, 'e02_name_focused_keyboard');
    if (Platform.isAndroid) {
      log('TYPE ${adbText(typed['CharacterName']!)}');
      await wait(t, 2500);
      await snap(t, 'e02b_name_typed_keyboard');
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 1200);
    t.testTextInput.register();
    final session = t
        .widget<FillOverlay>(find.byType(FillOverlay).first)
        .session;

    // ---- keyboard Next through the header and down the ability column.
    session.focusField(name);
    await wait(t, 600);
    var i = 0;
    for (final e in typed.entries) {
      final f = named(e.key);
      final fieldBox = find.byKey(ValueKey('text:${f.id}'));
      final focused = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<FieldTextBox>()
          ?.field
          .id;
      if (focused != f.id) {
        log('Next chain: expected ${e.key} focused, got $focused');
      }
      await t.enterText(
        find.descendant(of: fieldBox, matching: find.byType(TextField)),
        e.value,
      );
      await wait(t, 300);
      if (i == 1 || i == 6 || i == 8) await snap(t, 'e03_typed_$i');
      await t.testTextInput.receiveAction(TextInputAction.next);
      await wait(t, 700);
      i++;
    }
    await snap(t, 'e04_after_next_chain');
    log('zoom after the Next chain: ${zoomOf(t, doc).toStringAsFixed(2)}');

    // A tiny skill box, tapped on the real keyboard: zooms further so its
    // text is comfortable.
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 600);
    t.testTextInput.unregister();
    final athl = named('Athletics');
    final ar = fieldOnScreen(t, doc, athl);
    final visible =
        ar != null &&
        ar.top > 140 &&
        ar.bottom < t.view.physicalSize.height / t.view.devicePixelRatio - 40;
    log('Athletics on screen: $visible');
    if (visible) {
      await t.tapAt(ar.center);
    } else {
      session.focusField(athl);
    }
    await wait(t, 1500);
    log('zoom on a skill box: ${zoomOf(t, doc).toStringAsFixed(2)}');
    await snap(t, 'e05_skill_focused_keyboard');
    if (Platform.isAndroid) {
      log('TYPE +9');
      await wait(t, 2000);
      await snap(t, 'e06_skill_typed');
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 1200);
    t.testTextInput.register();

    // ---- the rest of the character, field by field.
    final sw = Stopwatch()..start();
    for (final e in rest.entries) {
      final f = named(e.key);
      session.focusField(f);
      final box = find.byKey(ValueKey('text:${f.id}'));
      for (var k = 0; k < 40 && box.evaluate().isEmpty; k++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await wait(t, 120);
      await t.enterText(
        find.descendant(of: box, matching: find.byType(TextField)),
        e.value,
      );
      await t.pump(const Duration(milliseconds: 50));
      if (e.key == 'Features and Traits') await snap(t, 'e07_features_focused');
      if (e.key == 'Spells 1024') await snap(t, 'e08_spells_focused');
    }
    log('filled ${rest.length} more fields in ${sw.elapsedMilliseconds} ms');
    // Overflow in a skill box: the note.
    final acro = named('Acrobatics');
    session.focusField(acro);
    await wait(t, 800);
    await t.enterText(
      find.descendant(
        of: find.byKey(ValueKey('text:${acro.id}')),
        matching: find.byType(TextField),
      ),
      '+1 (expertise)',
    );
    await wait(t, 500);
    await snap(t, 'e09_overflow_note');
    await t.enterText(
      find.descendant(
        of: find.byKey(ValueKey('text:${acro.id}')),
        matching: find.byType(TextField),
      ),
      '+1',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 600);

    // ---- back to 1x (double tap), proficiency dots at 1x with imprecise
    // taps (a few dp off).
    await doubleTap(t, blankSpot(t, doc));
    await wait(t, 900);
    log('zoom before dots: ${zoomOf(t, doc).toStringAsFixed(2)}');
    final pr0 = pageRects(t)[0];
    if (pr0 == null || pr0.top < -50) {
      // Page 1 off screen: scroll back to the top.
      for (var k = 0; k < 10 && (pageRects(t)[0]?.top ?? -1e9) < 0; k++) {
        await t.fling(
          find.byType(Scrollable).last,
          const Offset(0, 1500),
          4000,
        );
        await wait(t, 600);
      }
    }
    final rnd = math.Random(7);
    for (final n in dots) {
      final r = fieldOnScreen(t, doc, named(n))!;
      final off = Offset(rnd.nextDouble() * 8 - 4, rnd.nextDouble() * 6 - 3);
      await t.tapAt(r.center + off);
      await wait(t, 250);
    }
    final checked = dots.where((n) => session.isChecked(named(n))).length;
    log('dots checked with imprecise taps at 1x: $checked/${dots.length}');
    await snap(t, 'e10_filled_edit_1x');
    // Zoomed look at the skills while editing.
    final skillsAt = fieldOnScreen(t, doc, named('Insight'))!.center;
    await doubleTap(t, skillsAt);
    await wait(t, 900);
    await snap(t, 'e11_skills_zoomed_edit');
    // A focused field while zoomed (focus ring look).
    session.focusField(named('Perception '));
    await wait(t, 900);
    await snap(t, 'e12_skill_focus_ring');
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 400);

    // ---- ✓
    await t.tap(find.byKey(const ValueKey('done-button')));
    for (
      var k = 0;
      k < 200 && find.byType(FieldTextBox).evaluate().isNotEmpty;
      k++
    ) {
      await t.pump(const Duration(milliseconds: 50));
    }
    await wait(t, 2500);
    await snap(t, 'a01_applied_zoomed');
    await doubleTap(t, Offset(size.width * 0.5, size.height * 0.5));
    await wait(t, 1500);
    await snap(t, 'a02_applied_1x');
    final applied = s.editDoc!;
    var ok = 0;
    for (final e in {...typed, ...rest}.entries) {
      final v = applied.fields.firstWhere((f) => f.fullName == e.key).value;
      if (v == e.value) {
        ok++;
      } else {
        log('MISMATCH ${e.key}: "$v"');
      }
    }
    log('values applied: $ok/${typed.length + rest.length}');
    // Zoom on the header and the skills after ✓.
    await doubleTap(
      t,
      fieldOnScreen(
        t,
        applied,
        applied.fields.firstWhere((f) => f.fullName == 'ClassLevel'),
      )!.center,
    );
    await wait(t, 1500);
    await snap(t, 'a03_applied_header_zoomed');
    await doubleTap(t, Offset(size.width * 0.5, size.height * 0.5));
    await wait(t, 1200);
    await doubleTap(
      t,
      fieldOnScreen(
        t,
        applied,
        applied.fields.firstWhere((f) => f.fullName == 'Insight'),
      )!.center,
    );
    await wait(t, 1500);
    await snap(t, 'a04_applied_skills_zoomed');
    await doubleTap(t, Offset(size.width * 0.5, size.height * 0.5));
    await wait(t, 1200);

    // ---- dark mode: edit + view.
    await menu(t, 'Dark mode');
    await wait(t, 800);
    await snap(t, 'd01_dark_view_1x');
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1200);
    final s2 = t.widget<FillOverlay>(find.byType(FillOverlay).first).session;
    s2.focusField(applied.fields.firstWhere((f) => f.fullName == 'HPCurrent'));
    await wait(t, 1200);
    await snap(t, 'd02_dark_edit_focused');
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 300);
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 1500);
    await menu(t, 'Dark mode');
    await wait(t, 600);

    // ---- write the bytes out for the host.
    final bytes = s.bytes!;
    if (Platform.isAndroid) {
      final dir = await getExternalStorageDirectory();
      final out = File('${dir!.path}/filled_sheet.pdf');
      await out.writeAsBytes(bytes, flush: true);
      log('PULL ${out.path}');
      await wait(t, 2500);
    } else {
      final out = File('${await ios.docsDir()}/qa/filled_sheet.pdf');
      await out.writeAsBytes(bytes, flush: true);
      log('WROTE ${out.path}');
    }
    expect(ok, typed.length + rest.length);
    expect(checked, dots.length);
  });
}
