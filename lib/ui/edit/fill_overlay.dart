import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/pdf_core.dart';
import '../viewer/pages_view.dart' show TapClaim;
import 'edit_session.dart';

// Fields to fill: a light blue wash with a fine edge; the field being
// typed in: paper white with a strong blue ring, so it's obvious where the
// text goes.
const _fieldFill = Color(0xFFE3EBFF); // choice boxes
const _fieldBorder = Color(0xFF7F9BE0);
const _textTint = Color(0x1A2F5BD3); // idle text field: a faint wash
const _focusFill = Color(0xFFFFFFFF);
const _focusBorder = Color(0xFF2F5BD3);
const _ink = Color(0xFF111111);

/// Font features that make text advance by plain glyph widths, like the
/// PDF appearance (no kerning, no ligatures).
const noKerning = [FontFeature.disable('kern'), FontFeature.disable('liga')];

/// True when [s] has characters the saved field can't draw (they become ?).
bool hasUndrawable(String s) => s.isNotEmpty && !PdfEditDoc.canDrawText(s);

/// Smallest tap target (logical pixels) of a field on screen: taps this
/// close to a small field still reach it (the nearest field wins).
const minTapTarget = 32.0;

/// Text this tall (logical pixels) is comfortable to edit.
const comfortableTextHeight = 15.0;

/// Below this, tapping a field zooms in on it.
const smallTextHeight = 11.0;

/// The most a field tap zooms in.
const maxFieldZoom = 4.0;

/// Zoom at which a field with [fontPt] text and [fieldWidthPt] width is
/// comfortable to edit, or null to keep the current zoom (already
/// comfortable, or zooming in wouldn't help). [basePointScale] is logical
/// pixels per point at zoom 1, [viewWidth] the view's width.
double? comfortableZoom({
  required double fontPt,
  required double fieldWidthPt,
  required double basePointScale,
  required double currentZoom,
  required double viewWidth,
}) {
  if (fontPt <= 0 || basePointScale <= 0) return null;
  if (fontPt * basePointScale * currentZoom >= smallTextHeight) return null;
  var z = comfortableTextHeight / (fontPt * basePointScale);
  // Keep the whole field across the view if it's wide.
  final fitWidth = (viewWidth - 24) / (fieldWidthPt * basePointScale);
  if (fitWidth < z) z = fitWidth;
  if (z > maxFieldZoom) z = maxFieldZoom;
  return z > currentZoom + 0.05 ? z : null;
}

/// The field whose tap target contains [p] (overlay pixels at [scale]):
/// a field's own box, or the box grown to [minTapTarget]; where grown
/// targets overlap, the field nearest to [p] wins.
PdfField? fieldTargetAt(Iterable<PdfField> fields, Offset p, double scale) {
  PdfField? best;
  var bestD = double.infinity, bestC = double.infinity;
  for (final f in fields) {
    final r = Rect.fromLTWH(
      f.rect.left * scale,
      f.rect.top * scale,
      f.rect.width * scale,
      f.rect.height * scale,
    );
    final target = Rect.fromCenter(
      center: r.center,
      width: math.max(r.width, minTapTarget),
      height: math.max(r.height, minTapTarget),
    );
    if (!target.contains(p)) continue;
    final dx = math.max(0.0, math.max(r.left - p.dx, p.dx - r.right));
    final dy = math.max(0.0, math.max(r.top - p.dy, p.dy - r.bottom));
    final d = math.sqrt(dx * dx + dy * dy);
    final c = (r.center - p).distance;
    if (d < bestD - 1e-6 || ((d - bestD).abs() <= 1e-6 && c < bestC)) {
      best = f;
      bestD = d;
      bestC = c;
    }
  }
  return best;
}

/// Fill controls placed over each field of one page.
class FillOverlay extends StatelessWidget {
  const FillOverlay({
    super.key,
    required this.session,
    required this.pageIndex,
    required this.scale,
    this.quiet = false,
  });

  final EditSession session;
  final int pageIndex;
  final double scale;

  /// Just the values, no highlights, notes or taps: shown for a moment
  /// after ✓ while the pages redraw with the new values (no flicker).
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final fields = session.fields
            .where((f) => f.pageIndex == pageIndex)
            .toList();
        final tappable = fields.where(_tappable).toList();
        final stack = Stack(
          clipBehavior: Clip.none,
          children: [
            // Taps beside a small field still reach it; taps on bare paper
            // put the keyboard away.
            if (!quiet)
              Positioned.fill(
                child: MetaData(
                  metaData: TapClaim(
                    (p) => fieldTargetAt(tappable, p, scale) != null,
                  ),
                  behavior: HitTestBehavior.opaque,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _tapNear(tappable, d.localPosition),
                  ),
                ),
              ),
            for (final f in fields)
              Positioned(
                left: f.rect.left * scale,
                top: f.rect.top * scale,
                width: math.max(8, f.rect.width * scale),
                height: math.max(8, f.rect.height * scale),
                // Turn the control so its text reads the way the field's does.
                child: MetaData(
                  metaData: const TapClaim(),
                  behavior: HitTestBehavior.translucent,
                  child: RotatedBox(
                    quarterTurns: (f.rotation ~/ 90) % 4,
                    child: _control(context, f),
                  ),
                ),
              ),
            for (final f in fields)
              if (!quiet)
                if (_notes(f) case final notes when notes.isNotEmpty)
                  Positioned(
                    left: f.rect.left * scale,
                    top: f.rect.bottom * scale + 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [for (final n in notes) _Note(n)],
                    ),
                  ),
          ],
        );
        return quiet ? IgnorePointer(child: stack) : stack;
      },
    );
  }

  static bool _tappable(PdfField f) =>
      !f.readOnly &&
      switch (f.kind) {
        PdfFieldKind.text ||
        PdfFieldKind.multilineText ||
        PdfFieldKind.checkbox => true,
        PdfFieldKind.radio => f.onValue != null,
        _ => false,
      };

  void _tapNear(List<PdfField> fields, Offset p) {
    final f = fieldTargetAt(fields, p, scale);
    if (f == null) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    switch (f.kind) {
      case PdfFieldKind.checkbox:
        session.toggleCheck(f);
      case PdfFieldKind.radio:
        session.setValue(f, f.onValue!);
      default:
        session.focusField(f);
    }
  }

  static const undrawableNote = 'Some characters will be saved as ?';
  static const overflowNote = "Doesn't fit — extra text won't show";

  List<String> _notes(PdfField f) {
    if (f.readOnly ||
        (f.kind != PdfFieldKind.text && f.kind != PdfFieldKind.multilineText)) {
      return const [];
    }
    final v = session.valueOf(f);
    return [
      if (hasUndrawable(v)) undrawableNote,
      if (v.isNotEmpty && !session.fitOf(f).fits) overflowNote,
    ];
  }

  Widget _control(BuildContext context, PdfField f) {
    final editable = !f.readOnly;
    if (quiet &&
        f.kind != PdfFieldKind.text &&
        f.kind != PdfFieldKind.multilineText &&
        f.kind != PdfFieldKind.checkbox &&
        f.kind != PdfFieldKind.radio) {
      return const SizedBox.shrink();
    }
    switch (f.kind) {
      case PdfFieldKind.text:
      case PdfFieldKind.multilineText:
        if (!editable) {
          return quiet ? const SizedBox.shrink() : _ReadOnlyBox(text: f.value);
        }
        return FieldTextBox(
          key: ValueKey('text:${f.id}'),
          field: f,
          session: session,
          scale: scale,
          quiet: quiet,
        );
      case PdfFieldKind.checkbox:
        return _CheckBox(
          field: f,
          checked: session.isChecked(f),
          scale: scale,
          onTap: editable ? () => session.toggleCheck(f) : null,
        );
      case PdfFieldKind.radio:
        return _CheckBox(
          field: f,
          checked: f.onValue != null && session.valueOf(f) == f.onValue,
          scale: scale,
          onTap: editable && f.onValue != null
              ? () => session.setValue(f, f.onValue!)
              : null,
        );
      case PdfFieldKind.comboBox:
      case PdfFieldKind.listBox:
        return _ChoiceBox(
          field: f,
          value: session.valueOf(f),
          scale: scale,
          onChanged: editable ? (v) => session.setValue(f, v) : null,
        );
      case PdfFieldKind.signature:
        return const _ReadOnlyBox(text: 'Signature', icon: Icons.draw_outlined);
      case PdfFieldKind.unknown:
        return const SizedBox.shrink();
    }
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  // The note can lie over other (small) fields: it must not take their taps.
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
    ),
  );
}

/// The field's height along its own text direction (rotated fields swap).
double textBoxHeight(PdfField f) =>
    f.rotation % 180 == 90 ? f.rect.width : f.rect.height;

double fieldFontSize(PdfField f, double scale) {
  final h = textBoxHeight(f);
  final pt = f.fontSize > 0
      ? f.fontSize
      : f.kind == PdfFieldKind.multilineText
      ? math.min(12.0, math.max(6.0, h * 0.7))
      : math.min(12.0, math.max(5.0, h * 0.65));
  return pt * scale;
}

class FieldTextBox extends StatefulWidget {
  const FieldTextBox({
    super.key,
    required this.field,
    required this.session,
    required this.scale,
    this.quiet = false,
  });
  final PdfField field;
  final EditSession session;
  final double scale;
  final bool quiet;

  @override
  State<FieldTextBox> createState() => _FieldTextBoxState();
}

class _FieldTextBoxState extends State<FieldTextBox> {
  late final _ctl = TextEditingController(
    text: widget.session.valueOf(widget.field),
  );
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    widget.session.registerFocus(widget.field, _focus);
  }

  @override
  void didUpdateWidget(FieldTextBox old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session || old.field.id != widget.field.id) {
      old.session.unregisterFocus(old.field, _focus);
      widget.session.registerFocus(widget.field, _focus);
    }
    // Another widget of the same field changed the value.
    final v = widget.session.valueOf(widget.field);
    if (v != _ctl.text) _ctl.text = v;
  }

  @override
  void dispose() {
    widget.session.unregisterFocus(widget.field, _focus);
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() {}); // focus look
    if (!_focus.hasFocus) return;
    final f = widget.field;
    widget.session.onShowField?.call(f, widget.session.fitOf(f).fontSize);
  }

  void _next() {
    final next = widget.session.nextField(widget.field);
    if (next == null) {
      _focus.unfocus();
    } else {
      widget.session.focusField(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    final multi = f.kind == PdfFieldKind.multilineText;
    // Same font, size, inset, wrap width, line spacing and baseline as the
    // saved appearance, so the text sits and wraps where it will in the PDF
    // (the core's wrapText follows Flutter's line breaking rules).
    // Auto-size fields shrink as you type, like the PDF does.
    final fit = widget.session.fitOf(f);
    final scale = widget.scale;
    // Flutter's text engine rounds every line height to a whole pixel and
    // (on Android) truncates font sizes to 1/64 px; at the page's scale
    // either would make the overlay drift from the PDF. So the editor is
    // laid out at a nearby scale [s] at which one line is a whole number of
    // pixels, then drawn scaled by scale / s to sit on the page.
    final fontPt = fit.fontSize > 0 ? fit.fontSize : 12.0;
    final lineH = fit.lineHeight > 0 ? fit.lineHeight : fontPt * 1.2;
    final linePx = math.max(1, (lineH * scale).round());
    final s = linePx / lineH;
    final size = math.max(1.0, (fontPt * s * 64).floorToDouble() / 64);
    final style = _style(size, linePx / size, fit.monospace);
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    // The wrap width follows the font size actually used, keeping the
    // saved appearance's text-to-width proportions exactly.
    final boxW = f.rotation % 180 == 90 ? f.rect.height : f.rect.width;
    final wrapW = math.max(0.0, boxW - 2 * fit.inset) * size / fontPt;
    final cursorWidth = math.max(1.0, scale) * s / scale;
    // Two more things would narrow the text: a Container border insets its
    // child, and the editor keeps cursorWidth + 1 px free at the right of
    // every line for the caret. So the border is painted on top
    // (foregroundDecoration) and the editor sticks out to the right by the
    // caret margin.
    final caretMargin = cursorWidth + 1;
    // First baseline where the appearance puts it.
    final boxH = f.rotation % 180 == 90 ? f.rect.width : f.rect.height;
    final baselinePt =
        fit.firstBaseline ??
        (multi ? fit.insetY + 0.9 * fontPt : boxH / 2 + 0.2555 * fontPt);
    final top = baselinePt * s - _baselineIn(style, strut);
    // The whole box focuses the field, not just the text line inside it.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!_focus.hasFocus) {
          _focus.requestFocus();
          _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
        }
      },
      child: Container(
        // The same widget structure focused or not (a changing structure
        // would rebuild the editor and drop the keyboard connection).
        color: _focus.hasFocus
            ? _focusFill
            : widget.quiet
            ? const Color(0x00000000)
            : _textTint,
        foregroundDecoration: BoxDecoration(
          border: Border.all(
            color: _focus.hasFocus ? _focusBorder : const Color(0x00000000),
            width: 1.5,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            // Box size in editor pixels (at scale s).
            final w = box.maxWidth * s / scale, h = box.maxHeight * s / scale;
            final inset = fit.inset * s;
            final padding = EdgeInsets.fromLTRB(
              inset,
              0,
              math.max(0.0, w - inset - wrapW),
              multi ? fit.insetY * s : 0,
            );
            return FittedBox(
              fit: BoxFit.fill,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      top: top,
                      bottom: multi ? 0 : null,
                      right: -caretMargin,
                      // Sizes are page points × zoom; the system font-size
                      // setting must not change them.
                      child: MediaQuery.withNoTextScaling(
                        child: TextSelectionTheme(
                          // On paper, in the field's colours (not the
                          // app theme's, which may be dark).
                          data: const TextSelectionThemeData(
                            cursorColor: _focusBorder,
                            selectionColor: Color(0x552F5BD3),
                            selectionHandleColor: _focusBorder,
                          ),
                          child: _textField(
                            f,
                            multi,
                            style,
                            strut,
                            padding,
                            cursorWidth,
                            fit.quadding,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static TextStyle _style(double size, double height, bool monospace) =>
      TextStyle(
        fontSize: size,
        height: height,
        color: _ink,
        // Bundled Liberation fonts share Helvetica's/Courier's glyph
        // widths, so lines wrap here exactly as in the saved PDF.
        fontFamily: monospace ? 'Liberation Mono' : 'Liberation Sans',
        // Material 3 text adds letter spacing; PDF text has none.
        letterSpacing: 0,
        wordSpacing: 0,
        // The saved appearance draws plain glyph advances: no kerning
        // pairs, no ligatures.
        fontFeatures: noKerning,
      );

  static final _baselines = <String, double>{};

  /// Distance from the top of the editor's first line to its baseline.
  static double _baselineIn(TextStyle style, StrutStyle strut) => _baselines
      .putIfAbsent('${style.fontFamily}/${style.fontSize}/${style.height}', () {
        final tp = TextPainter(
          text: TextSpan(text: 'Hg', style: style),
          strutStyle: strut,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
        )..layout();
        final d = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
        tp.dispose();
        return d;
      });

  Widget _textField(
    PdfField f,
    bool multi,
    TextStyle style,
    StrutStyle strut,
    EdgeInsets padding,
    double cursorWidth,
    int quadding,
  ) {
    return TextField(
      controller: _ctl,
      focusNode: _focus,
      scrollPadding: const EdgeInsets.all(40),
      maxLines: multi ? null : 1,
      expands: multi,
      maxLength: f.maxLength > 0 ? f.maxLength : null,
      keyboardType: multi ? TextInputType.multiline : TextInputType.text,
      // A form gets names, numbers and game terms: the keyboard may
      // suggest, but must not silently change what was typed.
      autocorrect: false,
      // Single-line fields: the keyboard's action key moves on to the next
      // field in reading order; on the last one it closes the keyboard.
      textInputAction: multi
          ? TextInputAction.newline
          : widget.session.nextField(f) == null
          ? TextInputAction.done
          : TextInputAction.next,
      onEditingComplete: multi ? null : _next,
      textAlignVertical: TextAlignVertical.top,
      // Same alignment as the saved appearance (/Q).
      textAlign: switch (quadding) {
        1 => TextAlign.center,
        2 => TextAlign.right,
        _ => TextAlign.left,
      },
      style: style,
      strutStyle: strut,
      cursorColor: _focusBorder,
      cursorWidth: cursorWidth,
      decoration: InputDecoration.collapsed(hintText: null)
          .copyWith(isDense: true, counterText: '', contentPadding: padding),
      onChanged: (v) => widget.session.setValue(f, v),
    );
  }
}

/// A checkbox or radio button drawn the way its PDF draws it: nothing of
/// its own when off (the printed artwork shows), the PDF's "on" mark
/// (a ZapfDingbats check, dot, cross, …) when on.
class _CheckBox extends StatelessWidget {
  const _CheckBox({
    required this.field,
    required this.checked,
    required this.scale,
    this.onTap,
  });
  final PdfField field;
  final bool checked;
  final double scale;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mark = field.checkMark;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: !checked || mark == null
          ? const SizedBox.expand()
          : CustomPaint(
              painter: CheckMarkPainter(mark, scale),
              size: Size.infinite,
            ),
    );
  }
}

/// Paints a ZapfDingbats check-style glyph where the PDF's appearance puts
/// it. Coordinates are page points × [scale], in the widget box's own
/// orientation.
class CheckMarkPainter extends CustomPainter {
  CheckMarkPainter(this.mark, this.scale);
  final PdfCheckMark mark;
  final double scale;

  // Glyph boxes (1/1000 em, y up) from the ZapfDingbats metrics.
  static const _boxes = <String, (double, double, double, double)>{
    '4': (35, -14, 721, 705), // ✔
    'l': (35, -14, 757, 708), // ●
    'n': (35, 0, 727, 692), // ■
    'u': (35, -14, 724, 705), // ◆
    '8': (35, 0, 803, 692), // ✖
    'H': (35, 0, 781, 692), // ★
  };

  @override
  void paint(Canvas canvas, Size size) {
    final g = _boxes.containsKey(mark.glyph) ? mark.glyph : '4';
    final (x0, y0, x1, y1) = _boxes[g]!;
    final em = mark.size * scale / 1000;
    final ox = mark.x * scale, oy = mark.y * scale;
    // Glyph box on the canvas.
    final r = Rect.fromLTRB(
      ox + x0 * em,
      oy - y1 * em,
      ox + x1 * em,
      oy - y0 * em,
    );
    Offset at(double u, double v) =>
        Offset(r.left + u * r.width, r.bottom - v * r.height);
    final paint = Paint()
      ..color = Color(mark.color)
      ..isAntiAlias = true;
    switch (g) {
      case 'l':
        canvas.drawOval(r, paint);
      case 'n':
        canvas.drawRect(r, paint);
      case 'u':
        canvas.drawPath(
          Path()
            ..moveTo(r.center.dx, r.top)
            ..lineTo(r.right, r.center.dy)
            ..lineTo(r.center.dx, r.bottom)
            ..lineTo(r.left, r.center.dy)
            ..close(),
          paint,
        );
      case '8':
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = r.shortestSide * 0.22
          ..strokeCap = StrokeCap.round;
        final d = r.deflate(r.shortestSide * 0.12);
        canvas
          ..drawLine(d.topLeft, d.bottomRight, paint)
          ..drawLine(d.topRight, d.bottomLeft, paint);
      case 'H':
        final path = Path();
        final c = r.center;
        final ro = r.shortestSide / 2, ri = ro * 0.4;
        for (var i = 0; i < 10; i++) {
          final a = -math.pi / 2 + i * math.pi / 5;
          final rr = i.isEven ? ro : ri;
          final p = c + Offset(math.cos(a) * rr, math.sin(a) * rr);
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path..close(), paint);
      default: // heavy check mark
        canvas.drawPath(
          Path()
            ..moveTo(at(0, 0.42).dx, at(0, 0.42).dy)
            ..lineTo(at(0.15, 0.56).dx, at(0.15, 0.56).dy)
            ..lineTo(at(0.37, 0.31).dx, at(0.37, 0.31).dy)
            ..lineTo(at(0.86, 1).dx, at(0.86, 1).dy)
            ..lineTo(at(1, 0.9).dx, at(1, 0.9).dy)
            ..lineTo(at(0.39, 0).dx, at(0.39, 0).dy)
            ..close(),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(CheckMarkPainter old) =>
      old.scale != scale || old.mark != mark;
}

class _ChoiceBox extends StatelessWidget {
  const _ChoiceBox({
    required this.field,
    required this.value,
    required this.scale,
    this.onChanged,
  });
  final PdfField field;
  final String value;
  final double scale;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final display =
        field.options
            .where((o) => o.$1 == value)
            .map((o) => o.$2)
            .firstOrNull ??
        value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: onChanged == null || field.options.isEmpty
          ? null
          : (d) async {
              final box = context.findRenderObject() as RenderBox;
              final origin = box.localToGlobal(Offset.zero);
              final picked = await showMenu<String>(
                context: context,
                position: RelativeRect.fromLTRB(
                  origin.dx,
                  origin.dy + box.size.height,
                  origin.dx + box.size.width,
                  origin.dy,
                ),
                items: [
                  for (final (export, label) in field.options)
                    CheckedPopupMenuItem(
                      value: export,
                      checked: export == value,
                      child: Text(label.isEmpty ? export : label),
                    ),
                ],
              );
              if (picked != null) onChanged!(picked);
            },
      child: Container(
        decoration: BoxDecoration(
          color: onChanged == null ? const Color(0xFFEEEEEE) : _fieldFill,
          border: Border.all(color: _fieldBorder, width: 0.6),
        ),
        padding: EdgeInsets.symmetric(horizontal: 2 * scale),
        child: Row(
          children: [
            Expanded(
              child: Text(
                display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fieldFontSize(field, scale),
                  color: _ink,
                ),
              ),
            ),
            if (onChanged != null)
              Icon(
                Icons.arrow_drop_down,
                size: math.min(24, textBoxHeight(field) * scale),
                color: _ink,
              ),
          ],
        ),
      ),
    );
  }
}

class _ReadOnlyBox extends StatelessWidget {
  const _ReadOnlyBox({required this.text, this.icon = Icons.lock_outline});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0x66888888), width: 0.8),
        ),
        alignment: Alignment.topRight,
        child: LayoutBuilder(
          builder: (context, box) => Icon(
            icon,
            size: math.min(14, math.min(box.maxWidth, box.maxHeight)),
            color: const Color(0x99888888),
          ),
        ),
      ),
    );
  }
}
