import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/pdf_core.dart';
import 'edit_session.dart';

/// A pan recognizer that wins the gesture arena immediately, so dragging a
/// field or drawing a box doesn't scroll the page list underneath.
class EagerPanGestureRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }

  @override
  String get debugDescription => 'eager pan';
}

Widget eagerPan({
  Key? key,
  required Widget child,
  GestureDragStartCallback? onStart,
  GestureDragUpdateCallback? onUpdate,
  GestureDragEndCallback? onEnd,
}) {
  return RawGestureDetector(
    key: key,
    behavior: HitTestBehavior.opaque,
    gestures: {
      EagerPanGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<EagerPanGestureRecognizer>(
            EagerPanGestureRecognizer.new,
            (r) => r
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = onStart
              ..onUpdate = onUpdate
              ..onEnd = onEnd,
          ),
    },
    child: child,
  );
}

const _minSize = 8.0; // points
const _checkSize = 14.0; // points

/// Fields tool for one page: draw text boxes, place checkboxes, select,
/// move, resize, delete, toggle multi-line.
class LayoutOverlay extends StatefulWidget {
  const LayoutOverlay({
    super.key,
    required this.session,
    required this.pageIndex,
    required this.pageSize,
    required this.scale,
  });

  final EditSession session;
  final int pageIndex;

  /// Page box size in logical pixels.
  final Size pageSize;
  final double scale;

  @override
  State<LayoutOverlay> createState() => _LayoutOverlayState();
}

class _LayoutOverlayState extends State<LayoutOverlay> {
  Offset? _drawStart;
  Offset? _drawEnd;

  double get s => widget.scale;
  double get _pageW => widget.pageSize.width / s;
  double get _pageH => widget.pageSize.height / s;

  PdfRect _clamp(PdfRect r) {
    final w = r.width.clamp(_minSize, _pageW);
    final h = r.height.clamp(_minSize, _pageH);
    return PdfRect(
      r.left.clamp(0.0, _pageW - w),
      r.top.clamp(0.0, _pageH - h),
      w,
      h,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final session = widget.session;
        final items = session.itemsOnPage(widget.pageIndex);
        final sel = session.selected;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: _background(session)),
            for (final i in items)
              if (i.id != sel?.id) _box(i, selected: false),
            if (sel != null && sel.pageIndex == widget.pageIndex) ...[
              _box(sel, selected: true),
              ..._handles(sel),
              _toolbar(sel),
            ],
            if (_drawStart != null && _drawEnd != null)
              Positioned.fromRect(
                rect: Rect.fromPoints(_drawStart!, _drawEnd!),
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0x335B7FD6),
                      border: Border.all(color: const Color(0xFF5B7FD6)),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _background(EditSession session) {
    switch (session.tool) {
      case LayoutTool.addText:
        return eagerPan(
          key: const ValueKey('draw'),
          onStart: (d) => setState(() {
            _drawStart = d.localPosition;
            _drawEnd = d.localPosition;
          }),
          onUpdate: (d) => setState(() => _drawEnd = d.localPosition),
          onEnd: (_) {
            final a = _drawStart, b = _drawEnd;
            setState(() => _drawStart = _drawEnd = null);
            if (a == null || b == null) return;
            final r = Rect.fromPoints(a, b);
            final pr = r.width < 12 || r.height < 6
                // A tap or tiny drag: drop a default-size box there.
                ? PdfRect(a.dx / s, a.dy / s, 144, 18)
                : PdfRect(r.left / s, r.top / s, r.width / s, r.height / s);
            session.addItem(widget.pageIndex, _clamp(pr), PdfFieldKind.text);
          },
          child: const SizedBox.expand(),
        );
      case LayoutTool.addCheckbox:
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final p = d.localPosition / s;
            session.addItem(
              widget.pageIndex,
              _clamp(
                PdfRect(
                  p.dx - _checkSize / 2,
                  p.dy - _checkSize / 2,
                  _checkSize,
                  _checkSize,
                ),
              ),
              PdfFieldKind.checkbox,
            );
          },
        );
      case LayoutTool.select:
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: session.selectedId == null ? null : () => session.select(null),
        );
    }
  }

  Rect _px(PdfRect r) =>
      Rect.fromLTWH(r.left * s, r.top * s, r.width * s, r.height * s);

  Widget _box(LayoutItem i, {required bool selected}) {
    final scheme = Theme.of(context).colorScheme;
    final color = i.isNew ? const Color(0xFF2E9E5B) : const Color(0xFF5B7FD6);
    final box = Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: selected ? 0.25 : 0.12),
        border: Border.all(
          color: selected ? scheme.primary : color,
          width: selected ? 2 : 1,
        ),
        shape: i.kind == PdfFieldKind.radio
            ? BoxShape.circle
            : BoxShape.rectangle,
      ),
      child: i.kind == PdfFieldKind.checkbox
          ? const FittedBox(child: Icon(Icons.check, color: Color(0x88000000)))
          : i.kind == PdfFieldKind.multilineText
          ? const Align(
              alignment: Alignment.bottomRight,
              child: Icon(Icons.notes, size: 12, color: Color(0x88000000)),
            )
          : null,
    );
    return Positioned.fromRect(
      key: ValueKey('box:${i.id}'),
      rect: _px(i.rect),
      child: selected
          ? eagerPan(
              onUpdate: (d) {
                final r = i.rect;
                widget.session.setRect(
                  i,
                  _clamp(
                    PdfRect(
                      r.left + d.delta.dx / s,
                      r.top + d.delta.dy / s,
                      r.width,
                      r.height,
                    ),
                  ),
                );
              },
              child: box,
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.session.select(i.id),
              child: box,
            ),
    );
  }

  List<Widget> _handles(LayoutItem i) {
    const hit = 28.0;
    final r = _px(i.rect);
    final scheme = Theme.of(context).colorScheme;
    Widget handle(Offset at, void Function(Offset delta) drag, String name) =>
        Positioned(
          key: ValueKey('handle:$name'),
          left: at.dx - hit / 2,
          top: at.dy - hit / 2,
          width: hit,
          height: hit,
          child: eagerPan(
            onUpdate: (d) => drag(d.delta / s),
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border.all(color: scheme.primary, width: 2),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );

    void resize(double dl, double dt, double dr, double db) {
      final o = i.rect;
      var l = o.left + dl, t = o.top + dt, rr = o.right + dr, b = o.bottom + db;
      if (rr - l < _minSize) {
        if (dl != 0) {
          l = rr - _minSize;
        } else {
          rr = l + _minSize;
        }
      }
      if (b - t < _minSize) {
        if (dt != 0) {
          t = b - _minSize;
        } else {
          b = t + _minSize;
        }
      }
      l = math.max(0, l);
      t = math.max(0, t);
      rr = math.min(_pageW, rr);
      b = math.min(_pageH, b);
      widget.session.setRect(i, PdfRect(l, t, rr - l, b - t));
    }

    return [
      handle(r.topLeft, (d) => resize(d.dx, d.dy, 0, 0), 'tl'),
      handle(r.topRight, (d) => resize(0, d.dy, d.dx, 0), 'tr'),
      handle(r.bottomLeft, (d) => resize(d.dx, 0, 0, d.dy), 'bl'),
      handle(r.bottomRight, (d) => resize(0, 0, d.dx, d.dy), 'br'),
    ];
  }

  Widget _toolbar(LayoutItem i) {
    final r = _px(i.rect);
    const h = 40.0;
    final above = r.top - h - 14 >= 0;
    final top = above ? r.top - h - 14 : r.bottom + 14;
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: math.max(0, math.min(r.left, widget.pageSize.width - 140)),
      top: top,
      height: h,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(20),
        color: scheme.surfaceContainerHigh,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (i.isText)
              IconButton(
                tooltip: i.kind == PdfFieldKind.multilineText
                    ? 'Multi-line (tap for single line)'
                    : 'Single line (tap for multi-line)',
                isSelected: i.kind == PdfFieldKind.multilineText,
                icon: const Icon(Icons.short_text),
                selectedIcon: const Icon(Icons.notes),
                onPressed: () => widget.session.toggleMultiline(i),
              ),
            IconButton(
              tooltip: 'Delete field',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => widget.session.delete(i),
            ),
          ],
        ),
      ),
    );
  }
}
