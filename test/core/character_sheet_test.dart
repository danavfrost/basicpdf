// The blank 5e character sheet (fixtures/character_sheet.pdf, an Adobe
// InDesign export with 336 widgets, all auto-size text, no /AP on text
// fields, checkboxes whose /AP has only an /Yes state, two image push
// buttons with JavaScript).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';

import 'helpers.dart';

/// A representative fill, the way a player fills the sheet.
const sheetValues = <String, String>{
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
  'Acrobatics': '+1',
  'Athletics': '+6',
  'Perception ': '+4',
  'ProfBonus': '+3',
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
  'PersonalityTraits ':
      'I face problems head-on. A simple, direct solution is the best '
      'path to success.',
  'ProficienciesLang':
      'Languages: Common, Dwarvish.\nAll armor, shields, simple and '
      "martial weapons. Smith's tools, dice set.",
  'Backstory':
      'Born under the mountain, Brannoc served twenty years in the '
      'Ironguard before a cave-in buried his company.\n\n'
      'He alone dug his way out — and has been looking for the one who '
      'set the charges ever since.',
  'Spells 1014': 'Fire Bolt',
};

PdfField named(PdfEditDoc d, String n) => d.fields.firstWhere(
  (f) => f.fullName == n,
  orElse: () => throw StateError('no field "$n"'),
);

void main() {
  // The official sheet is Wizards of the Coast's copyrighted document, so it
  // isn't in the repo. Drop a blank copy at test/fixtures/character_sheet.pdf
  // to run these tests.
  if (!File('test/fixtures/character_sheet.pdf').existsSync()) {
    test(
      'character sheet',
      () {},
      skip: 'test/fixtures/character_sheet.pdf not present',
    );
    return;
  }
  late Uint8List original;
  late PdfEditDoc d;
  setUpAll(() {
    original = fixture('character_sheet.pdf');
    d = PdfEditDoc.open(original);
  });

  test('structure: pages, field kinds, flags', () {
    expect(d.pages.length, 3);
    for (final p in d.pages) {
      expect([p.width, p.height], [612, 792]);
    }
    int count(PdfFieldKind k) => d.fields.where((f) => f.kind == k).length;
    expect(d.fields.length, 336);
    expect(count(PdfFieldKind.text), 198);
    expect(count(PdfFieldKind.multilineText), 12);
    expect(count(PdfFieldKind.checkbox), 122);
    // CHARACTER IMAGE (3 widgets) and Faction Symbol Image: push buttons.
    expect(count(PdfFieldKind.unknown), 4);
    expect(d.fields.where((f) => f.readOnly), isEmpty);
    expect(d.fields.every((f) => f.rotation == 0 && f.maxLength == 0), isTrue);
    // Every text field auto-sizes (DA "/Helv 0 Tf").
    expect(
      d.fields
          .where(
            (f) =>
                f.kind == PdfFieldKind.text ||
                f.kind == PdfFieldKind.multilineText,
          )
          .every((f) => f.fontSize == 0),
      isTrue,
    );
    final check = named(d, 'Check Box 11');
    expect(check.onValue, 'Yes');
    expect(check.value, 'Off');
    // On open the display only adds empty /Off appearances to the
    // checkboxes (PDFium frames a box that has none); values unchanged.
    final shown = PdfEditDoc.open(d.displayBytes);
    expect(shown.fields.length, d.fields.length);
    expect(named(shown, 'Check Box 11').value, 'Off');
    expect(
      String.fromCharCodes(d.displayBytes.sublist(d.bytes.length)),
      allOf(contains('/Off'), isNot(contains('/AS /Yes'))),
    );
  });

  test('auto size: the tiny skill boxes and modifier boxes', () {
    final skill = named(d, 'Acrobatics'); // 14.4 x 8.6 pt
    final fit = d.textFit(skill, '+5');
    expect(fit.fits, isTrue);
    expect(fit.fontSize, greaterThanOrEqualTo(4));
    // A two-digit bonus still fits.
    expect(d.textFits(skill, '+10'), isTrue);
    // Big boxes start at 12 pt and shrink as text grows.
    final feats = named(d, 'Features and Traits');
    expect(d.textFit(feats, 'Darkvision').fontSize, 12);
    final long = List.filled(80, 'Second Wind, Action Surge.').join(' ');
    final f2 = d.textFit(feats, long);
    expect(f2.fontSize, lessThan(12));
    expect(f2.fits, isTrue);
  });

  test('auto size: readable text in small single-line boxes', () {
    // Inner height / 1.35 (pdf.js's line factor without its 1 pt padding),
    // at most 12 pt, then shrunk to the width.
    final skill = named(d, 'Acrobatics'); // 14.4 x 8.6 pt, no border
    expect(
      d.textFit(skill, '+5').fontSize,
      closeTo(skill.rect.height / 1.35, 0.01),
    );
    expect(d.textFit(skill, '+5').fontSize, greaterThan(6.3));
    final mod = named(d, 'STRmod'); // 12.8 pt tall
    expect(
      d.textFit(mod, '+3').fontSize,
      closeTo(mod.rect.height / 1.35, 0.01),
    );
    expect(d.textFit(named(d, 'CharacterName'), 'Bo').fontSize, 12);
    // Text stays vertically centred: the baseline sits so the
    // ascent..descent band is centred in the box.
    final fit = d.textFit(skill, '+5');
    final fs = fit.fontSize;
    final above = fit.firstBaseline! - 0.718 * fs;
    final below = skill.rect.height - fit.firstBaseline! - 0.207 * fs;
    expect(above, closeTo(below, 0.01));
    expect(above, greaterThan(1));
    // Multi-line boxes: 1 pt above the first line, 2 pt at the sides.
    final feats = d.textFit(named(d, 'Features and Traits'), 'x');
    expect(feats.inset, 2);
    expect(feats.insetY, 1);
    expect(feats.firstBaseline, closeTo(1 + 0.9 * 12, 1e-9));
  });

  test('fill, save, reopen: values persist, original bytes are a prefix', () {
    final changes = <PdfChange>[
      for (final e in sheetValues.entries)
        SetFieldValue(named(d, e.key).id, e.value),
      // Proficiency dots: STR save (11), Athletics (26), Investigation (31).
      SetFieldValue(named(d, 'Check Box 11').id, 'Yes'),
      SetFieldValue(named(d, 'Check Box 26').id, 'Yes'),
      SetFieldValue(named(d, 'Check Box 31').id, 'Yes'),
    ];
    final saved = d.applyChanges(changes);
    final out = saved.bytes;
    expect(out.length, greaterThan(original.length));
    expect(out.sublist(0, original.length), original);
    final tail = str(out.sublist(original.length));
    // Every new value gets its own appearance stream, so viewers that
    // ignore /NeedAppearances still show it.
    expect(
      RegExp(r'/Subtype\s*/Form').allMatches(tail).length,
      greaterThanOrEqualTo(sheetValues.length),
    );
    expect(tail, isNot(contains('NeedAppearances')));

    final re = PdfEditDoc.open(out);
    expect(re.fields.length, 336);
    for (final e in sheetValues.entries) {
      expect(named(re, e.key).value, e.value, reason: e.key);
    }
    expect(named(re, 'Check Box 11').value, 'Yes');
    expect(named(re, 'Check Box 26').value, 'Yes');
    expect(named(re, 'Check Box 12').value, 'Off');
    expect(
      named(PdfEditDoc.open(re.displayBytes), 'Check Box 11').value,
      'Yes',
    );
    // The typical values fit their boxes.
    for (final e in sheetValues.entries) {
      expect(re.textFits(named(re, e.key), e.value), isTrue, reason: e.key);
    }
    final dump = Platform.environment['SHEET_OUT'];
    if (dump != null) File(dump).writeAsBytesSync(out);

    // A second round (edit again, clear one, uncheck one) keeps the rest.
    final again = re.applyChanges([
      SetFieldValue(named(re, 'HPCurrent').id, '31'),
      SetFieldValue(named(re, 'XP').id, ''),
      SetFieldValue(named(re, 'Check Box 26').id, 'Off'),
    ]);
    expect(again.bytes.sublist(0, out.length), out);
    final re2 = PdfEditDoc.open(again.bytes);
    expect(named(re2, 'HPCurrent').value, '31');
    expect(named(re2, 'XP').value, '');
    expect(named(re2, 'Check Box 26').value, 'Off');
    expect(named(re2, 'Check Box 11').value, 'Yes');
    expect(named(re2, 'CharacterName').value, 'Brannoc Ironvein');
  });

  test("check marks: the sheet's own dot (/MK /CA 'l', its /Yes stream)", () {
    final dot = named(d, 'Check Box 12'); // 9.3 x 12.2 pt
    final m = dot.checkMark!;
    expect(m.glyph, 'l');
    expect(m.size, closeTo(6.5988, 1e-4));
    expect(m.x, closeTo(2.0312, 1e-4));
    // "2.0312 3.8798 Td" in a 12.2 pt tall box, measured from the top.
    expect(m.y, closeTo(dot.rect.height - 3.8798, 0.01));
    expect(m.color, 0xFF000000);
    // Text fields have none.
    expect(named(d, 'CharacterName').checkMark, isNull);
  });

  test('check marks: generated layout for a widget without an on stream', () {
    final d0 = PdfEditDoc.open(PdfEditDoc.createTextDocument(''));
    final d1 = d0.applyChanges(const [
      AddField(0, PdfRect(100, 100, 12, 12), PdfFieldKind.checkbox),
    ]);
    final cb = d1.fields.firstWhere((f) => f.kind == PdfFieldKind.checkbox);
    final m = cb.checkMark!;
    expect(m.glyph, '4');
    // Centred: glyph advance 0.76 em.
    expect(m.x + 0.76 * m.size / 2, closeTo(6, 0.01));
    expect(m.size, greaterThan(4));
  });

  test('editDisplayBytes: checkboxes off and text empty; values kept', () {
    expect(identical(d.editDisplayBytes, d.displayBytes), isTrue);
    final filled = d.applyChanges([
      SetFieldValue(named(d, 'Check Box 11').id, 'Yes'),
      SetFieldValue(named(d, 'CharacterName').id, 'Brannoc'),
    ]);
    final e = filled.editDisplayBytes;
    expect(identical(e, filled.displayBytes), isFalse);
    final shown = PdfEditDoc.open(e);
    // Values (/V) are unchanged; only the drawing differs.
    expect(named(shown, 'Check Box 11').value, 'Yes');
    expect(named(shown, 'CharacterName').value, 'Brannoc');
    final text = String.fromCharCodes(e.sublist(filled.bytes.length));
    expect(text, contains('/AS /Off'));
    // Saved bytes are untouched by it.
    expect(identical(filled.bytes, e), isFalse);
    expect(filled.bytes.length, lessThan(e.length));
  });

  test('saving gives checkboxes an empty off appearance (no grey frames in '
      'PDFium viewers)', () {
    final out = d.applyChanges([
      SetFieldValue(named(d, 'Check Box 26').id, 'Yes'),
    ]);
    final update = String.fromCharCodes(out.bytes.sublist(d.bytes.length));
    // Every checkbox widget on the sheet is rewritten with an /Off state.
    expect(
      RegExp(r'/Off \d+ 0 R').allMatches(update).length,
      greaterThanOrEqualTo(100),
    );
    expect(named(PdfEditDoc.open(out.bytes), 'Check Box 26').value, 'Yes');
    expect(named(PdfEditDoc.open(out.bytes), 'Check Box 12').value, 'Off');
  });
}
