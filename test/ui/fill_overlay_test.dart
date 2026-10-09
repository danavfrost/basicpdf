import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/ui/edit/edit_session.dart';
import 'package:pdfedit/ui/edit/fill_overlay.dart';

import 'fakes.dart';

void main() {
  testWidgets('an overflow note does not block taps on the fields below it', (
    t,
  ) async {
    // A tiny skill box like the character sheet's, a proficiency dot just
    // below it: the note under the skill box lies over the dot.
    const skill = PdfField(
      id: '1 0',
      fullName: 'Acrobatics',
      kind: PdfFieldKind.text,
      pageIndex: 0,
      rect: PdfRect(100, 100, 14.4, 8.6),
    );
    const dot = PdfField(
      id: '2 0',
      fullName: 'Check',
      kind: PdfFieldKind.checkbox,
      pageIndex: 0,
      rect: PdfRect(100, 110, 6, 8.7),
      value: 'Off',
      onValue: 'Yes',
    );
    final doc = FakeEditDoc([skill, dot])..overflowing.add('1 0');
    final session = EditSession(doc);
    session.setValue(skill, '+1 (expertise)');
    const scale = 2.0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 612 * scale,
            height: 792 * scale,
            child: FillOverlay(session: session, pageIndex: 0, scale: scale),
          ),
        ),
      ),
    );
    final note = find.text(FillOverlay.overflowNote);
    expect(note, findsOneWidget);
    const dotCenter = Offset(103 * scale, 114.35 * scale);
    expect(t.getRect(note).contains(dotCenter), isTrue);
    await t.tapAt(dotCenter);
    await t.pump();
    expect(session.isChecked(dot), isTrue);
  });
}
