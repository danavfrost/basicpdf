// Public contract between the PDF core and the UI. See SPEC.md §5.
//
// Pure Dart: no Flutter imports anywhere under lib/core/.
//
// Coordinates: every PdfRect here is in *page display space* — points,
// origin at the top-left of the page as it is shown (CropBox applied,
// /Rotate applied), y grows downward. The core converts to and from PDF
// user space internally, so the UI can scale rects straight onto a rendered
// page image.

import 'dart:typed_data';

import 'src/edit_doc.dart';
import 'src/new_doc.dart';
import 'src/text.dart' show canEncodeWinAnsi;

/// Thrown by [PdfEditDoc.open] when a user password is needed or was wrong.
class PdfPasswordException implements Exception {
  /// true if a password was supplied but didn't match.
  final bool wrongPassword;
  const PdfPasswordException({this.wrongPassword = false});
  @override
  String toString() =>
      wrongPassword ? 'Incorrect password' : 'Password required';
}

/// Thrown when the file can't be handled (corrupt, unsupported security
/// handler, ...). [message] is short and user-presentable.
class PdfCoreException implements Exception {
  final String message;
  const PdfCoreException(this.message);
  @override
  String toString() => message;
}

class PdfRect {
  final double left, top, width, height;
  const PdfRect(this.left, this.top, this.width, this.height);
  double get right => left + width;
  double get bottom => top + height;
  @override
  String toString() => 'PdfRect($left, $top, $width, $height)';
}

class PdfPageInfo {
  final int index;

  /// Displayed size in points (after CropBox and /Rotate).
  final double width, height;
  const PdfPageInfo(this.index, this.width, this.height);
}

class PdfPermissions {
  final bool canModify;
  final bool canFillForms;
  final bool canAnnotate;
  const PdfPermissions({
    this.canModify = true,
    this.canFillForms = true,
    this.canAnnotate = true,
  });
  static const all = PdfPermissions();

  /// Editing in this app means filling fields; adding/moving/deleting
  /// fields additionally needs [canModify] or [canAnnotate].
  bool get canEditFields => canFillForms || canAnnotate;
  bool get canLayoutFields => canModify || canAnnotate;
}

enum PdfFieldKind {
  text,
  multilineText,
  checkbox,
  radio,
  comboBox,
  listBox,
  signature,
  unknown,
}

/// How a checkbox or radio widget draws its "on" mark: one ZapfDingbats
/// glyph (the PDF's own on-appearance when it is that simple, otherwise
/// the glyph from /MK /CA laid out the way this core generates it).
class PdfCheckMark {
  /// ZapfDingbats character: '4' check, 'l' dot, '8' cross, 'u' diamond,
  /// 'n' square, 'H' star (anything else: draw a check).
  final String glyph;

  /// Font size of the glyph, points.
  final double size;

  /// Left end of the glyph's baseline, from the top-left of the widget box
  /// in the box's own orientation (before [PdfField.rotation]), points,
  /// y growing downward.
  final double x, y;

  /// Colour as 0xAARRGGBB.
  final int color;

  const PdfCheckMark({
    this.glyph = '4',
    required this.size,
    required this.x,
    required this.y,
    this.color = 0xFF000000,
  });
}

/// One widget (on-page box) of a form field. A field with several widgets
/// (e.g. a radio group) yields several PdfField entries sharing
/// [fullName]; for radios each has its own [onValue].
class PdfField {
  /// Stable id for this widget within the current bytes
  /// (e.g. "12 0" = object number + generation of the widget annotation).
  final String id;
  final String fullName;
  final PdfFieldKind kind;
  final int pageIndex;
  final PdfRect rect;

  /// Current value. Text: the text. Checkbox/radio: the export value of the
  /// selected state, or "Off". Choice: selected option's export value.
  final String value;

  /// Checkbox/radio: the "on" export value of this widget.
  final String? onValue;

  /// Choice fields: (exportValue, displayText) pairs.
  final List<(String, String)> options;
  final bool readOnly;
  final bool required;

  /// 0 means auto size.
  final double fontSize;

  /// 0 means no limit.
  final int maxLength;

  /// Clockwise angle (0, 90, 180, 270) at which the field's text reads on
  /// the displayed page (page /Rotate combined with the widget's /MK /R).
  /// 90 means the text runs top-to-bottom; rotate the overlay by this.
  final int rotation;

  /// Checkbox/radio: how its "on" state is drawn (null for other kinds).
  final PdfCheckMark? checkMark;

  const PdfField({
    required this.id,
    required this.fullName,
    required this.kind,
    required this.pageIndex,
    required this.rect,
    this.value = '',
    this.onValue,
    this.options = const [],
    this.readOnly = false,
    this.required = false,
    this.fontSize = 0,
    this.maxLength = 0,
    this.rotation = 0,
    this.checkMark,
  });
}

/// A change to apply. Applied in list order by [PdfEditDoc.applyChanges].
sealed class PdfChange {
  const PdfChange();
}

/// Set a field's value. For radios pass the chosen widget's onValue
/// (or "Off"); for checkboxes the onValue or "Off".
class SetFieldValue extends PdfChange {
  final String fieldId;
  final String value;
  const SetFieldValue(this.fieldId, this.value);
}

/// Add a new field. [kind] must be text, multilineText or checkbox.
/// [name] null → auto-generated (Text1, Text2, Check1, ...).
class AddField extends PdfChange {
  final int pageIndex;
  final PdfRect rect;
  final PdfFieldKind kind;
  final String? name;
  final String value;
  const AddField(
    this.pageIndex,
    this.rect,
    this.kind, {
    this.name,
    this.value = '',
  });
}

/// Move/resize a widget (same page).
class MoveField extends PdfChange {
  final String fieldId;
  final PdfRect rect;
  const MoveField(this.fieldId, this.rect);
}

/// Switch a text field between single and multi-line.
class SetMultiline extends PdfChange {
  final String fieldId;
  final bool multiline;
  const SetMultiline(this.fieldId, this.multiline);
}

/// Delete a widget (and its field if it was the field's last widget).
class DeleteField extends PdfChange {
  final String fieldId;
  const DeleteField(this.fieldId);
}

/// How a text field's saved appearance lays out a value (see
/// [PdfEditDoc.textFit]). Lengths are in points.
class PdfTextFit {
  /// False when part of the text falls outside the box and won't show
  /// (fields don't scroll in a saved/printed PDF).
  final bool fits;

  /// Font size the appearance uses (auto size resolved).
  final double fontSize;

  /// Distance from the box edge to the text (border + padding), left and
  /// right.
  final double inset;

  /// Distance from the top/bottom box edge to the text area of a
  /// multi-line field (border + vertical padding). Defaults to [inset].
  final double insetY;

  /// Baseline-to-baseline distance for multi-line fields.
  final double lineHeight;

  /// True when the appearance uses a fixed-width font (Courier) rather
  /// than Helvetica.
  final bool monospace;

  /// Distance from the top edge of the box (along the text's own up
  /// direction) to the baseline of the first line of text, or null if
  /// unknown.
  final double? firstBaseline;

  /// Horizontal alignment of the text in the box (the field's /Q):
  /// 0 left, 1 centred, 2 right.
  final int quadding;
  const PdfTextFit({
    required this.fits,
    required this.fontSize,
    this.inset = 3,
    double? lineHeight,
    this.monospace = false,
    this.firstBaseline,
    this.quadding = 0,
    double? insetY,
  }) : lineHeight = lineHeight ?? fontSize * 1.2,
       insetY = insetY ?? inset;
}

/// An opened PDF. Immutable: [applyChanges] returns a new document.
abstract class PdfEditDoc {
  /// Opens [bytes]. Throws [PdfPasswordException] if a user password is
  /// needed (or [password] is wrong), [PdfCoreException] if unreadable.
  /// An owner password, if given and correct, lifts permission limits.
  static PdfEditDoc open(Uint8List bytes, {String? password}) =>
      CorePdfEditDoc.open(bytes, password: password);

  /// The current file bytes (original plus any appended updates).
  Uint8List get bytes;

  /// Bytes for rendering only. When some field has a value but no usable
  /// appearance (or /NeedAppearances is true), this is [bytes] plus an
  /// in-memory update with generated appearances; otherwise it is the very
  /// same instance as [bytes]. Computed lazily and cached. Save [bytes],
  /// never this, so merely opening a file never changes it.
  Uint8List get displayBytes => bytes;

  /// Bytes for rendering while fields are being filled: [displayBytes]
  /// with every checkbox and radio button shown in its off state and text
  /// fields drawn without their text (frame only), so fill controls drawn
  /// on top can show the pending values instead. The very same instance as
  /// [displayBytes] when nothing needs hiding. Computed lazily and cached.
  Uint8List get editDisplayBytes => displayBytes;

  bool get isEncrypted;

  /// True when opened with the owner password (or not encrypted).
  bool get isOwner;

  PdfPermissions get permissions;
  List<PdfPageInfo> get pages;
  List<PdfField> get fields;

  /// Returns a new document whose bytes are this document's bytes plus an
  /// incremental update containing [changes]. Field ids in the result may
  /// differ for added fields; existing widgets keep their ids.
  /// Generates appearance streams so every viewer shows the new values.
  PdfEditDoc applyChanges(List<PdfChange> changes);

  /// Creates a new text PDF per SPEC §1.4: letter pages, 72 pt margins,
  /// Helvetica 12, one multi-line field per page (Body1, Body2, ...),
  /// text flowed across pages. Empty text → one page with an empty field.
  static Uint8List createTextDocument(String text) =>
      createTextDocumentBytes(text);

  /// How the saved appearance of text [field] would lay out [value]: its
  /// font size (auto size resolved, same rules as the generated appearance)
  /// and whether all of it is visible. Non-text fields always fit.
  PdfTextFit textFit(PdfField field, String value) => PdfTextFit(
    fits: true,
    fontSize: field.fontSize > 0 ? field.fontSize : 12,
  );

  /// Shorthand for `textFit(field, value).fits`.
  bool textFits(PdfField field, String value) => textFit(field, value).fits;

  /// True if every character of [text] can be drawn in a field's saved
  /// appearance (Helvetica, WinAnsi). Other characters are kept in the
  /// field value but drawn as '?'; the UI can show its inline note when
  /// this is false.
  static bool canDrawText(String text) => canEncodeWinAnsi(text);
}
