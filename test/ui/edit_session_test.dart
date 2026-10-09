import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/ui/edit/edit_session.dart';

import 'fakes.dart';

void main() {
  final fields = [
    const PdfField(
      id: '1 0',
      fullName: 'Name',
      kind: PdfFieldKind.text,
      pageIndex: 0,
      rect: PdfRect(10, 10, 100, 20),
      value: 'Old',
    ),
    const PdfField(
      id: '2 0',
      fullName: 'Agree',
      kind: PdfFieldKind.checkbox,
      pageIndex: 0,
      rect: PdfRect(10, 40, 12, 12),
      value: 'Off',
      onValue: 'Yes',
    ),
    const PdfField(
      id: '3 0',
      fullName: 'Size',
      kind: PdfFieldKind.radio,
      pageIndex: 0,
      rect: PdfRect(10, 60, 12, 12),
      value: 'S',
      onValue: 'S',
    ),
    const PdfField(
      id: '4 0',
      fullName: 'Size',
      kind: PdfFieldKind.radio,
      pageIndex: 0,
      rect: PdfRect(30, 60, 12, 12),
      value: 'S',
      onValue: 'L',
    ),
  ];

  test('no edits → no changes', () {
    expect(EditSession(FakeEditDoc(fields)).buildChanges(), isEmpty);
  });

  test('fill values become SetFieldValue', () {
    final s = EditSession(FakeEditDoc(fields));
    s.setValue(fields[0], 'New');
    s.toggleCheck(fields[1]);
    s.setValue(fields[3], 'L');
    final c = s.buildChanges().cast<SetFieldValue>();
    expect(
      {for (final x in c) x.fieldId: x.value},
      {'1 0': 'New', '2 0': 'Yes', '4 0': 'L'},
    );
    expect(s.isChecked(fields[1]), isTrue);
    // Setting back to the original value drops the change.
    s.setValue(fields[0], 'Old');
    expect(
      s.buildChanges().whereType<SetFieldValue>().map((e) => e.fieldId),
      isNot(contains('1 0')),
    );
  });

  test('layout edits become Add/Move/SetMultiline/Delete', () {
    final s = EditSession(FakeEditDoc(fields))..layoutMode = true;
    final name = s.items.firstWhere((i) => i.id == '1 0');
    s.setRect(name, const PdfRect(20, 20, 100, 20));
    s.toggleMultiline(name);
    s.delete(s.items.firstWhere((i) => i.id == '2 0'));
    final added = s.addItem(
      0,
      const PdfRect(50, 300, 144, 18),
      PdfFieldKind.text,
    );
    final removedNew = s.addItem(
      0,
      const PdfRect(0, 0, 14, 14),
      PdfFieldKind.checkbox,
    );
    s.delete(removedNew);
    expect(s.selectedId, isNull);
    expect(added.isNew, isTrue);

    final c = s.buildChanges();
    expect(c.whereType<MoveField>().single.fieldId, '1 0');
    expect(c.whereType<SetMultiline>().single.multiline, isTrue);
    expect(c.whereType<DeleteField>().single.fieldId, '2 0');
    final add = c.whereType<AddField>().single;
    expect(add.kind, PdfFieldKind.text);
    expect(add.rect.top, 300);
  });
}
