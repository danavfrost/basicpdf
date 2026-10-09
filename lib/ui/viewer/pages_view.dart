import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:pdfrx/pdfrx.dart' as rx;

/// Builds widgets laid over one page. [scale] converts page points to
/// logical pixels of the page box (overlay origin = page top-left).
typedef PageOverlayBuilder = Widget Function(
  BuildContext context,
  int pageIndex,
  Size pageSize,
  double scale,
);

/// Builds the picture of page [index] at [pixelWidth] device pixels.
/// [viewport] tells it where the visible area is (for sharp detail tiles at
/// high zoom) and when scrolling/zooming has settled.
typedef PageImageBuilder = Widget Function(
  int index,
  int pixelWidth,
  PageViewport viewport,
);

/// The visible area of a [PagesView], in global coordinates. Notifies when
/// the user stops scrolling or zooming.
class PageViewport extends ChangeNotifier {
  final _key = GlobalKey();

  Rect? get globalRect {
    final box = _key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _settled() => notifyListeners();
}

/// Put under a [MetaData] around a control on a page (a form field): taps
/// it accepts belong to the control, so a double tap there doesn't zoom.
/// [accepts] gets the position in the MetaData's own box; null accepts all.
class TapClaim {
  const TapClaim([this.accepts]);
  final bool Function(Offset local)? accepts;
  bool claims(Offset local) => accepts?.call(local) ?? true;
}

/// Drives a [PagesView] from outside: animated zooming and panning.
class PagesController {
  _PagesViewState? _state;

  bool get isAttached => _state != null;

  /// Current zoom (1 = page width fits the view).
  double get zoom => _state?._scale ?? 1;

  /// Size of the view (logical pixels).
  Size get viewSize =>
      _state == null ? Size.zero : Size(_state!._viewW, _state!._viewH);

  /// Logical pixels per page point of page [page] at zoom 1.
  double basePointScale(int page) => _state?._basePointScale(page) ?? 1;

  /// Animates so [rect] (page points) of page [page] is in view, at
  /// [zoom] if given (otherwise the current zoom). With the zoom unchanged
  /// it only pans, and only along an axis where [rect] isn't already
  /// comfortably visible. The rect lands in the upper part of the view so
  /// the keyboard won't cover it.
  Future<void> reveal(int page, Rect rect, {double? zoom}) =>
      _state?._reveal(page, rect, zoom: zoom) ?? Future.value();
}

/// Vertical, lazily built list of pages with pinch zoom. Pages are rendered
/// with PDFium at the current zoom so text stays sharp.
///
/// At 1x the list scrolls natively; pinching is tracked from raw pointers so
/// the list keeps its own drag handling. When zoomed in, one scale gesture
/// recognizer drives both the vertical offset and the horizontal shift, so
/// panning is free in 2D (no axis lock) and pinching continues smoothly.
class PagesView extends StatefulWidget {
  const PagesView({
    super.key,
    required this.pageSizes,
    required this.pageImageBuilder,
    this.topPadding = 0,
    this.overlayBuilder,
    this.onTap,
    this.controller,
  });

  /// Zoom double tapped from fit-width.
  static const doubleTapZoom = 2.5;

  final PagesController? controller;

  /// Displayed page sizes in points.
  final List<Size> pageSizes;

  final PageImageBuilder pageImageBuilder;
  final double topPadding;
  final PageOverlayBuilder? overlayBuilder;
  final VoidCallback? onTap;

  /// Convenience for a pdfrx document. [pageSizes] (e.g. from the PDF core,
  /// which knows every page size up front) lets the layout be final before
  /// pdfrx has measured all pages; otherwise pdfrx's sizes are used and the
  /// layout updates as pages finish loading.
  static Widget forDocument({
    Key? key,
    required rx.PdfDocument document,
    List<Size>? pageSizes,
    double topPadding = 0,
    PageOverlayBuilder? overlayBuilder,
    VoidCallback? onTap,
    PagesController? controller,
  }) {
    final known =
        pageSizes != null && pageSizes.length == document.pages.length;
    Widget builder(int i, int px, PageViewport vp) => PdfPageImage(
      page: document.pages[i],
      pixelWidth: px,
      pageSize: known ? pageSizes[i] : null,
      viewport: vp,
    );
    if (known) {
      return PagesView(
        key: key,
        pageSizes: pageSizes,
        topPadding: topPadding,
        overlayBuilder: overlayBuilder,
        onTap: onTap,
        controller: controller,
        pageImageBuilder: builder,
      );
    }
    return _ProgressivePages(
      key: key,
      document: document,
      topPadding: topPadding,
      overlayBuilder: overlayBuilder,
      onTap: onTap,
      controller: controller,
      pageImageBuilder: builder,
    );
  }

  @override
  State<PagesView> createState() => _PagesViewState();
}

/// Uses pdfrx's page sizes and rebuilds as progressive loading measures more
/// pages (only when the core couldn't provide the sizes).
class _ProgressivePages extends StatefulWidget {
  const _ProgressivePages({
    super.key,
    required this.document,
    required this.topPadding,
    required this.overlayBuilder,
    required this.onTap,
    required this.controller,
    required this.pageImageBuilder,
  });
  final rx.PdfDocument document;
  final double topPadding;
  final PageOverlayBuilder? overlayBuilder;
  final VoidCallback? onTap;
  final PagesController? controller;
  final PageImageBuilder pageImageBuilder;

  @override
  State<_ProgressivePages> createState() => _ProgressivePagesState();
}

class _ProgressivePagesState extends State<_ProgressivePages> {
  StreamSubscription<rx.PdfDocumentEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(_ProgressivePages old) {
    super.didUpdateWidget(old);
    if (old.document != widget.document) {
      _sub?.cancel();
      _listen();
    }
  }

  void _listen() {
    final doc = widget.document;
    if (doc.pages.every((p) => p.isLoaded)) return;
    try {
      _sub = doc.events.listen((e) {
        if (e is rx.PdfDocumentPageStatusChangedEvent ||
            e is rx.PdfDocumentLoadCompleteEvent) {
          if (mounted) setState(() {});
        }
      });
      unawaited(doc.loadPagesProgressively().catchError((_) {}));
    } catch (_) {
      // Fakes in tests have no events.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PagesView(
      pageSizes: [
        for (final p in widget.document.pages) Size(p.width, p.height),
      ],
      topPadding: widget.topPadding,
      overlayBuilder: widget.overlayBuilder,
      onTap: widget.onTap,
      controller: widget.controller,
      pageImageBuilder: (i, px, vp) {
        final p = widget.document.pages[i];
        return PdfPageImage(
          page: p,
          pixelWidth: px,
          pageSize: Size(p.width, p.height),
          viewport: vp,
        );
      },
    );
  }
}

class _PagesViewState extends State<PagesView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _margin = 8.0;
  static const _gap = 8.0;
  static const _bottom = 48.0;
  static const _maxScale = 8.0;

  final _v = ScrollController();

  /// Horizontal shift of the (zoomed, wider than the view) page column.
  final _hx = ValueNotifier<double>(0);
  final _viewport = PageViewport();
  double _scale = 1;
  double _renderScale = 1;

  /// True while zoomed in: the list's own scrolling is off and the scale
  /// recognizer pans both axes. Switched only between gestures.
  bool _zoomed = false;

  double _viewW = 0, _viewH = 0;

  // 1x pinch tracking (raw pointers so the list keeps its own drag handling).
  final _pointers = <int, Offset>{};
  double? _startDist;
  double _startScale = 1;
  Offset _startFocal = Offset.zero;
  double _startV = 0, _startH = 0;

  // Zoomed gesture.
  bool _gestureActive = false;

  // Fling.
  late final Ticker _ticker = createTicker(_onFlingTick);
  Simulation? _flingX, _flingY;
  Duration? _flingStart;

  // Page geometry cache (per view width): item tops in the list, unscaled.
  double _geomW = -1;
  List<Size> _geomSizes = const [];
  List<double> _tops = const [];

  // Animated zoom/pan (double tap, revealing a field).
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..addListener(_onAnimTick);
  void Function(double t)? _animStep;
  Completer<void>? _animDone;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller?._state = this;
  }

  @override
  void didUpdateWidget(PagesView old) {
    super.didUpdateWidget(old);
    _overlays.clear();
    if (old.controller != widget.controller) {
      if (old.controller?._state == this) old.controller!._state = null;
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller!._state = null;
    WidgetsBinding.instance.removeObserver(this);
    _anim.dispose();
    _animDone?.complete();
    _ticker.dispose();
    _v.dispose();
    _hx.dispose();
    _viewport.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- geometry

  double get _maxPageWidth =>
      widget.pageSizes.fold(1.0, (m, s) => math.max(m, s.width));

  (double, double) _pagePx(int i, double viewWidth) {
    final s = widget.pageSizes[i];
    final w = math.max(
      1.0,
      (viewWidth - 2 * _margin) * s.width / _maxPageWidth,
    );
    return (w, w * s.height / math.max(1e-6, s.width));
  }

  /// Unscaled top of each item from the start of the list content, plus
  /// the total at the end.
  List<double> _itemTops(double viewW) {
    if (viewW == _geomW && identical(_geomSizes, widget.pageSizes)) {
      return _tops;
    }
    final n = widget.pageSizes.length;
    final tops = List<double>.filled(n + 1, 0);
    var y = 0.0;
    for (var i = 0; i < n; i++) {
      tops[i] = y;
      y += _pagePx(i, viewW).$2 + _gap;
    }
    tops[n] = y;
    _geomW = viewW;
    _geomSizes = widget.pageSizes;
    return _tops = tops;
  }

  double get _listTop => widget.topPadding + _margin;

  /// (page index, fraction into it) at the line just under the top bar.
  (int, double) _anchorFor(double viewW, double scale, double offset) {
    final tops = _itemTops(viewW);
    final n = widget.pageSizes.length;
    if (n == 0) return (0, 0);
    final y = (offset + widget.topPadding - _listTop) / scale;
    var lo = 0, hi = n - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final ext = tops[lo + 1] - tops[lo];
    return (lo, ext <= 0 ? 0 : ((y - tops[lo]) / ext).clamp(0.0, 1.0));
  }

  double _offsetFor(double viewW, double scale, int page, double fraction) {
    final tops = _itemTops(viewW);
    if (page >= widget.pageSizes.length) return 0;
    final y = tops[page] + fraction * (tops[page + 1] - tops[page]);
    return y * scale + _listTop - widget.topPadding;
  }

  double get _maxH => math.max(0.0, _viewW * _scale - _viewW);

  /// Largest scroll offset at zoom [s].
  double _maxVAt(double s) {
    final tops = _itemTops(_viewW);
    return math.max(0.0, _listTop + tops.last * s + _bottom - _viewH);
  }

  double _basePointScale(int page) {
    if (page < 0 || page >= widget.pageSizes.length || _viewW <= 0) return 1;
    return _pagePx(page, _viewW).$1 / widget.pageSizes[page].width;
  }

  /// Sets zoom [s] and offsets [v], [h] for the same frame (no frame with
  /// the new zoom at the old offsets).
  void _setView(double s, double v, double h) {
    s = s.clamp(1.0, _maxScale);
    if (!_v.hasClients) return;
    final p = _v.position;
    // Stop any scroll animation (e.g. a text field revealing its caret).
    if (p.isScrollingNotifier.value) p.jumpTo(p.pixels);
    v = v.clamp(0.0, _maxVAt(s));
    if (s != _scale) {
      setState(() => _scale = s);
      // The list lays out again this frame with the new extents; give it
      // the matching offset before that.
      p.correctPixels(v);
    } else if ((v - p.pixels).abs() > 1e-3) {
      p.jumpTo(v);
    }
    _hx.value = h.clamp(0.0, math.max(0.0, _viewW * s - _viewW));
  }

  /// Unscaled content position (as at zoom 1) of view point [view].
  Offset _contentAt(Offset view) {
    final v = _v.hasClients ? _v.offset : 0.0;
    return Offset(
      (view.dx + _hx.value) / _scale,
      (view.dy + v - _listTop) / _scale,
    );
  }

  /// Animates to zoom [s1] with content point [content] (unscaled) moving
  /// to view point [to].
  Future<void> _animateTo(double s1, Offset content, Offset to) {
    _stopFling();
    _anim.stop();
    s1 = s1.clamp(1.0, _maxScale);
    final s0 = _scale;
    final from = Offset(
      content.dx * s0 - _hx.value,
      _listTop + content.dy * s0 - (_v.hasClients ? _v.offset : 0.0),
    );
    _animStep = (t) {
      final s = s0 * math.pow(s1 / s0, t);
      final f = Offset.lerp(from, to, t)!;
      _setView(s, _listTop + content.dy * s - f.dy, content.dx * s - f.dx);
    };
    final done = _animDone;
    _animDone = Completer<void>();
    done?.complete();
    final mine = _animDone!;
    _anim.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted || !identical(_animDone, mine)) return;
      _animStep = null;
      _animDone = null;
      _gestureEnded();
      mine.complete();
    });
    return mine.future;
  }

  void _onAnimTick() {
    final step = _animStep;
    if (step == null) return;
    step(Curves.easeInOutCubic.transform(_anim.value));
  }

  // ------------------------------------------------------------ reveal

  Future<void> _reveal(int page, Rect rect, {double? zoom}) {
    if (!mounted || _viewW <= 0 || page >= widget.pageSizes.length) {
      return Future.value();
    }
    final s1 = (zoom ?? _scale).clamp(1.0, _maxScale);
    final tops = _itemTops(_viewW);
    final (bw, _) = _pagePx(page, _viewW);
    final k = bw / widget.pageSizes[page].width;
    final r = Rect.fromLTWH(
      (_viewW - bw) / 2 + rect.left * k,
      tops[page] + rect.top * k,
      rect.width * k,
      rect.height * k,
    );
    final v = _v.hasClients ? _v.offset : 0.0;
    // The field's rect on screen now, and the area it should be in.
    final now = Rect.fromLTWH(
      r.left * _scale - _hx.value,
      _listTop + r.top * _scale - v,
      r.width * _scale,
      r.height * _scale,
    );
    const m = 12.0;
    final area = Rect.fromLTRB(
      m,
      widget.topPadding + m,
      _viewW - m,
      _viewH - m,
    );
    final zooming = (s1 - _scale).abs() > 1e-3;
    final w1 = r.width * s1, h1 = r.height * s1;
    // Horizontal: centred if it fits, else its left edge at the margin.
    var tx = now.center.dx;
    if (zooming || now.left < area.left || now.right > area.right) {
      tx = w1 <= area.width ? area.center.dx : area.left + w1 / 2;
    }
    // Vertical: centred at 40 % of the area (clear of a keyboard), or its
    // top at the margin when it's taller than that.
    var ty = now.center.dy;
    if (zooming || now.top < area.top || now.bottom > area.bottom) {
      final anchor = area.top + area.height * 0.4;
      ty = h1 / 2 <= anchor - area.top ? anchor : area.top + h1 / 2;
    }
    if (!zooming &&
        (tx - now.center.dx).abs() < 1 &&
        (ty - now.center.dy).abs() < 1) {
      return Future.value();
    }
    return _animateTo(s1, r.center, Offset(tx, ty));
  }

  // ---------------------------------------------------------- double tap

  // Raw pointer tracking (not a gesture recognizer, so single taps on the
  // page and its fields are never delayed waiting for a second tap).
  int? _tapPointer;
  Offset _tapDownAt = Offset.zero;
  Duration _tapDownTime = Duration.zero;
  bool _tapMoved = false;
  bool _tapClaimed = false;
  Offset? _lastTapAt;
  Duration _lastTapTime = Duration.zero;
  bool _lastTapClaimed = false;

  bool _claimedAt(Offset global) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      global,
      View.of(context).viewId,
    );
    for (final e in result.path) {
      final t = e.target;
      if (t is RenderMetaData && t.metaData is TapClaim) {
        final local = e is BoxHitTestEntry ? e.localPosition : Offset.zero;
        if ((t.metaData as TapClaim).claims(local)) return true;
      }
    }
    return false;
  }

  void _trackTapDown(PointerDownEvent e) {
    if (_tapPointer != null || _pointers.isNotEmpty) {
      // A second finger: not a tap.
      _tapPointer = null;
      _lastTapAt = null;
      return;
    }
    _tapPointer = e.pointer;
    _tapDownAt = e.localPosition;
    _tapDownTime = e.timeStamp;
    _tapMoved = false;
    _tapClaimed = _claimedAt(e.position);
  }

  void _trackTapMove(PointerMoveEvent e) {
    if (e.pointer != _tapPointer) return;
    if ((e.localPosition - _tapDownAt).distance > kTouchSlop) {
      _tapMoved = true;
      if (_anim.isAnimating) _anim.stop();
    }
  }

  void _trackTapUp(PointerUpEvent e) {
    if (e.pointer != _tapPointer) return;
    _tapPointer = null;
    final isTap = !_tapMoved && e.timeStamp - _tapDownTime < kLongPressTimeout;
    if (!isTap) {
      _lastTapAt = null;
      return;
    }
    final last = _lastTapAt;
    if (last != null &&
        _tapDownTime - _lastTapTime < kDoubleTapTimeout &&
        (_tapDownAt - last).distance < kDoubleTapSlop &&
        !_tapClaimed &&
        !_lastTapClaimed) {
      _lastTapAt = null;
      _onDoubleTap(e.localPosition);
      return;
    }
    _lastTapAt = _tapDownAt;
    _lastTapTime = e.timeStamp;
    _lastTapClaimed = _tapClaimed;
  }

  void _onDoubleTap(Offset at) {
    final c = _contentAt(at);
    if (_scale > 1.05) {
      _animateTo(1, c, at);
    } else {
      _animateTo(PagesView.doubleTapZoom, c, at);
    }
  }

  void _jumpTo(double v, double h) {
    if (_v.hasClients) {
      final p = _v.position;
      final target = v.clamp(p.minScrollExtent, p.maxScrollExtent);
      if ((target - p.pixels).abs() > 1e-3) _v.jumpTo(target);
    }
    _hx.value = h.clamp(0.0, _maxH);
  }

  // --------------------------------------------------- width change (rotate)

  void _onWidthChanged(double oldW, double newW) {
    if (!_v.hasClients || oldW <= 0) return;
    final (page, frac) = _anchorFor(oldW, _scale, _v.offset);
    final oldMaxH = math.max(0.0, oldW * _scale - oldW);
    final hFrac = oldMaxH > 0 ? _hx.value / oldMaxH : 0.0;
    // Lay out at the new width first, then restore the reading position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jumpTo(_offsetFor(newW, _scale, page, frac), hFrac * _maxH);
      _revealFocusSoon();
      _viewport._settled();
    });
  }

  // ------------------------------------------------- focus after metrics

  @override
  void didChangeMetrics() {
    // Rotation or the keyboard appearing: keep a focused field in view.
    _revealFocusSoon();
  }

  int _revealGen = 0;

  bool get _hasFocusInside {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null &&
        ctx.mounted &&
        ctx.findAncestorStateOfType<_PagesViewState>() == this;
  }

  void _revealFocusSoon() {
    if (!mounted || !_hasFocusInside) return;
    final gen = ++_revealGen;
    // After the new size is laid out (and again once the keyboard
    // animation has settled), bring the focused field back into view.
    for (final ms in const [0, 350]) {
      Timer(Duration(milliseconds: ms), () {
        if (!mounted || gen != _revealGen) return;
        WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocus());
        WidgetsBinding.instance.scheduleFrame();
      });
    }
  }

  void _revealFocus() {
    if (!mounted) return;
    if (!_hasFocusInside || _anim.isAnimating) return;
    final target = FocusManager.instance.primaryFocus!.context!
        .findRenderObject();
    final me = context.findRenderObject();
    if (target is! RenderBox || me is! RenderBox) return;
    if (!target.attached || !target.hasSize || !me.hasSize) return;
    // The focus sits on the inner editable text; include some room around
    // it so the field's box shows too.
    final r = MatrixUtils.transformRect(
      target.getTransformTo(me),
      Offset.zero & target.size,
    ).inflate(16);
    final top = widget.topPadding + 8;
    final bottom = me.size.height - 8;
    var dv = 0.0;
    if (r.height > bottom - top || r.top < top) {
      dv = r.top - top;
    } else if (r.bottom > bottom) {
      dv = r.bottom - bottom;
    }
    var dh = 0.0;
    const side = 8.0;
    if (r.width > me.size.width - 2 * side || r.left < side) {
      dh = r.left - side;
    } else if (r.right > me.size.width - side) {
      dh = r.right - (me.size.width - side);
    }
    if (dv == 0 && dh == 0) return;
    _jumpTo((_v.hasClients ? _v.offset : 0) + dv, _hx.value + dh);
  }

  // ----------------------------------------------------------- 1x pinch

  void _pointerDown(PointerDownEvent e) {
    _trackTapDown(e);
    _stopFling();
    // A zoom animation keeps going under a tap (e.g. the second tap of a
    // double tap); a drag or a pinch takes over from it.
    if (_zoomed) return; // the scale recognizer handles it
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) _beginPinch();
  }

  void _beginPinch() {
    if (_anim.isAnimating) _anim.stop();
    final p = _pointers.values.toList();
    _startDist = (p[0] - p[1]).distance;
    _startFocal = (p[0] + p[1]) / 2;
    _startScale = _scale;
    _startV = _v.hasClients ? _v.offset : 0;
    _startH = _hx.value;
  }

  void _pointerMove(PointerMoveEvent e) {
    _trackTapMove(e);
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    final startDist = _startDist;
    if (startDist == null || _pointers.length < 2 || startDist < 1) return;
    final p = _pointers.values.take(2).toList();
    _zoomTo(
      (_startScale * (p[0] - p[1]).distance / startDist),
      focal: (p[0] + p[1]) / 2,
    );
  }

  void _pointerUp(PointerEvent e) {
    if (e is PointerUpEvent) {
      _trackTapUp(e);
    } else if (e.pointer == _tapPointer) {
      _tapPointer = null;
    }
    _pointers.remove(e.pointer);
    if (_pointers.length < 2 && _startDist != null) {
      _startDist = null;
      _gestureEnded();
    } else if (_pointers.length == 2) {
      _beginPinch();
    }
  }

  /// Zooms to [s] keeping the content under [focal] (where the gesture
  /// started) under the fingers' current focal point.
  void _zoomTo(double s, {required Offset focal}) {
    s = s.clamp(1.0, _maxScale);
    final r = s / _startScale;
    final top = widget.topPadding;
    final newH = (_startH + _startFocal.dx) * r - focal.dx;
    final newV = (_startV + _startFocal.dy - top) * r + top - focal.dy;
    _setView(s, newV, newH);
  }

  // ------------------------------------------------------ zoomed gesture

  void _scaleStart(ScaleStartDetails d) {
    _stopFling();
    if (_anim.isAnimating) _anim.stop();
    _gestureActive = true;
    _startScale = _scale;
    _startFocal = d.localFocalPoint;
    _startV = _v.hasClients ? _v.offset : 0;
    _startH = _hx.value;
  }

  void _scaleUpdate(ScaleUpdateDetails d) {
    _zoomTo(_startScale * d.scale, focal: d.localFocalPoint);
  }

  void _scaleEnd(ScaleEndDetails d) {
    // Pointer count changes end and restart the gesture; only the last
    // finger lifting really ends it.
    if (d.pointerCount > 0) return;
    _gestureActive = false;
    final vel = d.velocity.pixelsPerSecond;
    if (_scale > 1.001 && vel.distance > 50 && _v.hasClients) {
      _startFling(-vel);
    } else {
      _gestureEnded();
    }
  }

  void _startFling(Offset velocity) {
    final p = _v.position;
    _flingY = ClampingScrollSimulation(
      position: p.pixels,
      velocity: velocity.dy,
    );
    _flingX = ClampingScrollSimulation(
      position: _hx.value,
      velocity: velocity.dx,
    );
    _flingStart = null;
    _ticker.start();
  }

  void _onFlingTick(Duration elapsed) {
    _flingStart ??= elapsed;
    final t = (elapsed - _flingStart!).inMicroseconds / 1e6;
    final sx = _flingX, sy = _flingY;
    if (sx == null || sy == null) return;
    _jumpTo(sy.x(t), sx.x(t));
    final p = _v.position;
    final yStuck =
        p.pixels <= p.minScrollExtent || p.pixels >= p.maxScrollExtent;
    final xStuck = _hx.value <= 0 || _hx.value >= _maxH;
    if ((sx.isDone(t) || xStuck) && (sy.isDone(t) || yStuck)) {
      _stopFling();
      _gestureEnded();
    }
  }

  void _stopFling() {
    if (_ticker.isActive) _ticker.stop();
    _flingX = _flingY = null;
  }

  /// A pinch/pan/fling finished: settle the mode, render resolution and
  /// detail tiles.
  void _gestureEnded() {
    final zoomed = _scale > 1.001;
    setState(() {
      if (!zoomed) {
        _scale = 1;
        _hx.value = 0;
      }
      _zoomed = zoomed;
      _renderScale = _scale;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _viewport._settled();
    });
  }

  // ------------------------------------------------------------- overlays

  /// Overlays laid out at the settled zoom ([_renderScale]), by page.
  /// While a pinch or zoom animation runs they are only scaled (the same
  /// widget instance, so nothing under it rebuilds or lays out again);
  /// once it settles they're laid out at the new zoom.
  final _overlays = <int, (double, double, Widget)>{};

  Widget _overlay(BuildContext context, int i, double bw, double bh) {
    final ow = bw * _renderScale, oh = bh * _renderScale;
    var cached = _overlays[i];
    if (cached == null || cached.$1 != ow || cached.$2 != oh) {
      final w = widget.overlayBuilder!(
        context,
        i,
        Size(ow, oh),
        ow / widget.pageSizes[i].width,
      );
      _overlays[i] = cached = (ow, oh, w);
    }
    // Always the same structure, so the overlay's state (focus, text
    // editing) survives the start and end of a zoom.
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox(width: ow, height: oh, child: cached.$3),
    );
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final bg = Theme.of(context).colorScheme.surfaceContainerHighest;
    return LayoutBuilder(
      builder: (context, box) {
        final viewW = box.maxWidth;
        if (_viewW != viewW && _viewW > 0) _onWidthChanged(_viewW, viewW);
        if (_viewH != box.maxHeight && _viewH > 0) _revealFocusSoon();
        _viewW = viewW;
        _viewH = box.maxHeight;
        final contentW = viewW * _scale;
        _itemTops(viewW);

        final list = NotificationListener<ScrollEndNotification>(
          onNotification: (_) {
            if (!_gestureActive && !_ticker.isActive) _viewport._settled();
            return false;
          },
          child: ListView.builder(
            controller: _v,
            physics: _zoomed
                ? const NeverScrollableScrollPhysics()
                : const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(top: _listTop, bottom: _bottom),
            itemCount: widget.pageSizes.length,
            itemExtentBuilder: (i, _) => i >= widget.pageSizes.length
                ? null
                : (_pagePx(i, viewW).$2 + _gap) * _scale,
            itemBuilder: (context, i) {
              final (bw, bh) = _pagePx(i, viewW);
              final w = bw * _scale, h = bh * _scale;
              final px = (bw * _renderScale * dpr).round();
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: w,
                  height: h,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(blurRadius: 2, color: Color(0x33000000)),
                      ],
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        widget.pageImageBuilder(i, px, _viewport),
                        if (widget.overlayBuilder != null)
                          _overlay(context, i, bw, bh),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );

        return Listener(
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          onPointerCancel: _pointerUp,
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: _zoomed
                ? {
                    ScaleGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          ScaleGestureRecognizer
                        >(
                          () => ScaleGestureRecognizer(debugOwner: this),
                          (r) => r
                            ..onStart = _scaleStart
                            ..onUpdate = _scaleUpdate
                            ..onEnd = _scaleEnd,
                        ),
                  }
                : const {},
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.onTap,
              child: ColoredBox(
                key: _viewport._key,
                color: bg,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: contentW,
                    maxWidth: contentW,
                    child: ValueListenableBuilder<double>(
                      valueListenable: _hx,
                      builder: (context, hx, child) => Transform.translate(
                        offset: Offset(-hx, 0),
                        child: child,
                      ),
                      child: list,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Renders one pdfrx page at [pixelWidth] and keeps showing the previous
/// image (stretched) while a new resolution or new bytes are rendering.
///
/// The whole-page bitmap is capped at [maxSide] pixels. When the zoom asks
/// for more, the part of the page inside the viewport is additionally
/// rendered at full resolution as a detail tile (memory stays bounded by
/// the screen size).
class PdfPageImage extends StatefulWidget {
  const PdfPageImage({
    super.key,
    required this.page,
    required this.pixelWidth,
    this.pageSize,
    this.viewport,
  });
  final rx.PdfPage page;
  final int pixelWidth;

  /// Page size in points (aspect ratio); defaults to the pdfrx page's.
  final Size? pageSize;
  final PageViewport? viewport;

  static const maxSide = 3072;

  @override
  State<PdfPageImage> createState() => _PdfPageImageState();
}

class _PdfPageImageState extends State<PdfPageImage> {
  ui.Image? _image;
  rx.PdfPage? _renderedPage;
  int _renderedWidth = 0;
  bool _busy = false;
  Timer? _debounce;

  // Detail tile: the visible part of the page at full resolution.
  ui.Image? _tile;
  Rect _tileFrac = Rect.zero; // part of the page it covers (0..1)
  int _tileFull = 0; // full page pixel width it was rendered for
  rx.PdfPage? _tilePage;
  bool _tileBusy = false;
  Timer? _tileDebounce;

  @override
  void initState() {
    super.initState();
    widget.viewport?.addListener(_scheduleTile);
    _render();
  }

  @override
  void didUpdateWidget(PdfPageImage old) {
    super.didUpdateWidget(old);
    if (old.viewport != widget.viewport) {
      old.viewport?.removeListener(_scheduleTile);
      widget.viewport?.addListener(_scheduleTile);
    }
    if (widget.page != _renderedPage || _targetWidth != _renderedWidth) {
      _debounce?.cancel();
      _debounce = Timer(
        widget.page != _renderedPage
            ? Duration.zero
            : const Duration(milliseconds: 120),
        _render,
      );
    }
    if (widget.page != _tilePage && _tile != null) _dropTile();
  }

  double get _aspect {
    final s = widget.pageSize;
    if (s != null && s.width > 0) return s.height / s.width;
    final p = widget.page;
    return p.width > 0 ? p.height / p.width : 1.4142;
  }

  int get _targetWidth {
    var w = widget.pixelWidth.toDouble();
    final h = w * _aspect;
    final big = math.max(w, h);
    if (big > PdfPageImage.maxSide) w = w * PdfPageImage.maxSide / big;
    return math.max(1, w.round());
  }

  Future<void> _render() async {
    if (_busy || !mounted) return;
    final page = widget.page;
    final w = _targetWidth;
    if (page == _renderedPage && w == _renderedWidth) return;
    _busy = true;
    try {
      final h = math.max(1, (w * _aspect).round());
      final img = await page.render(
        width: w,
        height: h,
        fullWidth: w.toDouble(),
        fullHeight: h.toDouble(),
        backgroundColor: 0xffffffff,
      );
      if (img == null) {
        _renderedPage = page;
        _renderedWidth = w;
        return;
      }
      final uiImage = await img.createImage();
      img.dispose();
      if (!mounted) {
        uiImage.dispose();
        return;
      }
      final old = _image;
      setState(() {
        _image = uiImage;
        _renderedPage = page;
        _renderedWidth = w;
      });
      old?.dispose();
    } catch (_) {
      // Document disposed mid-render or out of memory: don't retry in a loop.
      _renderedPage = page;
      _renderedWidth = w;
    } finally {
      _busy = false;
      if (mounted &&
          (widget.page != _renderedPage || _targetWidth != _renderedWidth)) {
        scheduleMicrotask(_render);
      } else if (mounted) {
        _scheduleTile();
      }
    }
  }

  // ------------------------------------------------------------ tiles

  void _scheduleTile() {
    _tileDebounce?.cancel();
    _tileDebounce = Timer(const Duration(milliseconds: 150), _renderTile);
  }

  void _dropTile() {
    final t = _tile;
    if (t == null) return;
    setState(() {
      _tile = null;
      _tilePage = null;
      _tileFull = 0;
    });
    t.dispose();
  }

  Future<void> _renderTile() async {
    if (!mounted || _tileBusy) return;
    final full = widget.pixelWidth;
    // The whole-page bitmap is sharp enough: no tile needed.
    if (full <= _targetWidth * 1.05) {
      _dropTile();
      return;
    }
    final box = context.findRenderObject();
    final vp = widget.viewport?.globalRect;
    if (box is! RenderBox || !box.hasSize || !box.attached || vp == null) {
      return;
    }
    final g = box.localToGlobal(Offset.zero) & box.size;
    final vis = g.intersect(vp);
    if (vis.width <= 0 || vis.height <= 0) {
      _dropTile();
      return;
    }
    final sz = box.size;
    if (sz.width <= 0 || sz.height <= 0) return;
    var frac = Rect.fromLTRB(
      (vis.left - g.left) / sz.width,
      (vis.top - g.top) / sz.height,
      (vis.right - g.left) / sz.width,
      (vis.bottom - g.top) / sz.height,
    );
    // A transform mid-change can give non-finite positions: skip; the
    // next settle renders the tile.
    if (!frac.left.isFinite ||
        !frac.top.isFinite ||
        !frac.right.isFinite ||
        !frac.bottom.isFinite) {
      return;
    }
    final page = widget.page;
    // Already covered at this resolution?
    if (_tile != null &&
        _tilePage == page &&
        _tileFull == full &&
        _tileFrac.left <= frac.left + 1e-4 &&
        _tileFrac.top <= frac.top + 1e-4 &&
        _tileFrac.right >= frac.right - 1e-4 &&
        _tileFrac.bottom >= frac.bottom - 1e-4) {
      return;
    }
    // A margin around the visible part so small pans stay sharp.
    final mx = frac.width * 0.15, my = frac.height * 0.15;
    frac = Rect.fromLTRB(
      math.max(0, frac.left - mx),
      math.max(0, frac.top - my),
      math.min(1, frac.right + mx),
      math.min(1, frac.bottom + my),
    );
    final fullH = (full * _aspect).round();
    final x = (frac.left * full).floor();
    final y = (frac.top * fullH).floor();
    final w = (frac.right * full).ceil() - x;
    final h = (frac.bottom * fullH).ceil() - y;
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) return;
    _tileBusy = true;
    try {
      final img = await page.render(
        x: x,
        y: y,
        width: w,
        height: h,
        fullWidth: full.toDouble(),
        fullHeight: fullH.toDouble(),
        backgroundColor: 0xffffffff,
      );
      if (img == null) return;
      final uiImage = await img.createImage();
      img.dispose();
      if (!mounted || widget.page != page || widget.pixelWidth != full) {
        uiImage.dispose();
        return;
      }
      final old = _tile;
      setState(() {
        _tile = uiImage;
        _tilePage = page;
        _tileFull = full;
        _tileFrac = Rect.fromLTRB(
          x / full,
          y / fullH,
          (x + w) / full,
          (y + h) / fullH,
        );
      });
      old?.dispose();
    } catch (_) {
      // Disposed mid-render: the whole-page bitmap still shows.
    } finally {
      _tileBusy = false;
    }
  }

  @override
  void dispose() {
    widget.viewport?.removeListener(_scheduleTile);
    _debounce?.cancel();
    _tileDebounce?.cancel();
    _image?.dispose();
    _tile?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final tile = _tile;
    if (img == null && tile == null) return const SizedBox.expand();
    final base = img == null
        ? const SizedBox.expand()
        : RawImage(
            image: img,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.medium,
          );
    if (tile == null) return base;
    return LayoutBuilder(
      builder: (context, c) {
        final f = _tileFrac;
        return Stack(
          fit: StackFit.expand,
          children: [
            base,
            Positioned(
              left: f.left * c.maxWidth,
              top: f.top * c.maxHeight,
              width: f.width * c.maxWidth,
              height: f.height * c.maxHeight,
              child: RawImage(
                image: tile,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ],
        );
      },
    );
  }
}
