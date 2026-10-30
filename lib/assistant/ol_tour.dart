import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'ol_bot.dart' show OlFace;

// "Show me how" (founder, 31 Oct 2026): Ol walks the person through a job on the real restaurant screens. The screen dims, a ring lights
// what to tap, Ol's bubble says what to do, and tapping the lit thing moves on, across screens. Targets are found by the keys and words the
// screens already have, so screens need nothing extra. The tours themselves are in ol_ask.dart, with the rest of Ol's guide.

/// What to light up: a widget whose key is [value], the first widget whose key starts with [value] (the first dish), or a visible word.
class OlTarget {
  const OlTarget.key(this.value) : kind = 'key';
  const OlTarget.keyPrefix(this.value) : kind = 'prefix';
  const OlTarget.text(this.value) : kind = 'text';
  final String kind, value;
}

/// One step: what Ol says and what to light up. With a [target] the step moves on when the person taps it; [next] (or no target) shows
/// a Next button instead.
class OlStep {
  const OlStep(this.say, {this.target, this.next = false});
  final String say;
  final OlTarget? target;
  final bool next;
}

class OlTour {
  const OlTour(this.name, this.steps);
  final String name;
  final List<OlStep> steps;
}

/// Runs one walkthrough at a time on the root overlay.
class OlWalk {
  OlWalk._(this._overlay, this.tour);
  final OverlayState _overlay;
  final OlTour tour;
  OverlayEntry? _entry;
  Timer? _poll;
  int _step = 0;
  Rect? _rect; // where the lit target is on screen
  bool _lost = false; // the target is not on this screen
  int _misses = 0;
  bool _advancing = false;

  static OlWalk? _current;

  /// The walkthrough running now (tests read it).
  static OlWalk? get current => _current;
  int get step => _step;

  /// How often Ol looks for the target, and after how many misses it says it can't see it (about 4 s). Tests make the wait short.
  static Duration pollEvery = const Duration(milliseconds: 150);
  static int missesBeforeLost = 26;

  /// Starts [tour]; a walkthrough already running stops first.
  static OlWalk start(OverlayState overlay, OlTour tour) {
    _current?.stop();
    final w = OlWalk._(overlay, tour);
    _current = w;
    w._entry = OverlayEntry(builder: (_) => _OlLayer(walk: w));
    overlay.insert(w._entry!);
    w._poll = Timer.periodic(pollEvery, (_) => w._locate());
    w._locate();
    return w;
  }

  void stop() {
    _poll?.cancel();
    _entry?.remove();
    _entry = null;
    if (_current == this) _current = null;
  }

  void next() {
    if (_step >= tour.steps.length - 1) return stop();
    _step++;
    _rect = null;
    _lost = false;
    _misses = 0;
    _advancing = false;
    _entry?.markNeedsBuild();
    _locate();
  }

  void _locate() {
    final s = tour.steps[_step];
    if (s.target == null) {
      if (_rect != null || _lost) {
        _rect = null;
        _lost = false;
        _entry?.markNeedsBuild();
      }
      return;
    }
    final r = _find(s.target!);
    if (r == null) {
      _misses++;
      if (_misses >= missesBeforeLost && !_lost) {
        _lost = true;
        _entry?.markNeedsBuild();
      }
      return;
    }
    _misses = 0;
    if (r != _rect || _lost) {
      _rect = r;
      _lost = false;
      _entry?.markNeedsBuild();
    }
  }

  /// The target on screen now: attached, laid out and not empty, on the page in front (not one underneath, not a hidden tab), on screen.
  Rect? _find(OlTarget t) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    final screen = Offset.zero & (_overlay.context.size ?? Size.zero);
    Rect? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget is _OlLayer) return; // not Ol's own bubble
      final w = e.widget;
      final key = w.key;
      final hit = switch (t.kind) {
        'key' => key is ValueKey && key.value == t.value,
        'prefix' => key is ValueKey && key.value is String && (key.value as String).startsWith(t.value),
        _ => w is Text && (w.data == t.value || w.data == tr(t.value)),
      };
      if (hit) {
        // a word lights up the button it sits in (the whole tab, not just "Bill")
        final r = _visibleRect(t.kind == 'text' ? _tappable(e, screen) : e, screen);
        if (r != null) {
          found = r;
          return;
        }
      }
      e.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found;
  }

  /// The nearest tappable thing around a word (InkWell, GestureDetector, button, ListTile, chip), unless it covers over 25 % of the screen.
  static Element _tappable(Element e, Rect screen) {
    Element found = e;
    e.visitAncestorElements((a) {
      final w = a.widget;
      if (w is InkResponse || w is GestureDetector || w is ButtonStyleButton || w is ListTile || w is RawChip) {
        final ro = a.renderObject;
        if (ro is RenderBox && ro.hasSize && ro.size.width * ro.size.height < screen.width * screen.height * 0.25) found = a;
        return false;
      }
      return true;
    });
    return found;
  }

  static Rect? _visibleRect(Element e, Rect screen) {
    final ro = e.renderObject;
    if (ro is! RenderBox || !ro.attached || !ro.hasSize || ro.size.isEmpty) return null;
    if (!TickerMode.valuesOf(e).enabled) return null; // a hidden tab
    final route = ModalRoute.of(e);
    if (route != null && !route.isCurrent) return null; // a page underneath
    final rect = ro.localToGlobal(Offset.zero) & ro.size;
    if (!screen.overlaps(rect)) return null;
    return rect;
  }

  void _tappedLit() {
    if (_advancing || tour.steps[_step].target == null) return;
    _advancing = true;
    // the tap goes through to the screen; the next step starts once the screen has reacted (it may open another page)
    Timer(const Duration(milliseconds: 450), () {
      if (_current == this) next();
    });
  }
}

class _OlLayer extends StatelessWidget {
  const _OlLayer({required this.walk});
  final OlWalk walk;

  @override
  Widget build(BuildContext context) {
    final w = walk;
    final step = w.tour.steps[w._step];
    final size = MediaQuery.sizeOf(context);
    final hole = w._rect?.inflate(6);
    // while Ol is still looking for the target: no dimming and no bubble
    final waiting = step.target != null && hole == null && !w._lost;
    final bubble = _StepBubble(
      key: const ValueKey('ol-tour-bubble'),
      tour: w.tour,
      index: w._step,
      text: w._lost ? '${tr(step.say)}\n\n${tr("I can't see it on this screen. Go to the right screen, or tap Next.")}' : tr(step.say),
      showNext: step.next || step.target == null || w._lost,
      last: w._step == w.tour.steps.length - 1,
      onNext: w.next,
      onSkip: w.stop,
    );
    // below the lit thing when it is in the top half of the screen, above it otherwise; in the middle when nothing is lit
    final below = hole == null || hole.center.dy < size.height / 2;
    final top = hole == null ? null : (below ? min(hole.bottom + 14, size.height - 230) : null);
    final bottom = hole == null ? null : (below ? null : max(size.height - hole.top + 14, 16.0));
    return Stack(children: [
      Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerUp: (ev) {
            if (hole != null && hole.contains(ev.position)) w._tappedLit();
          },
          child: _HoleBarrier(
            hole: hole,
            child: IgnorePointer(child: CustomPaint(painter: _DimPainter(hole: hole, dim: !waiting), size: Size.infinite)),
          ),
        ),
      ),
      if (hole != null) Positioned.fromRect(rect: hole.inflate(4), child: const IgnorePointer(child: _Ring())),
      if (!waiting)
        if (hole == null)
          Center(child: Padding(padding: const EdgeInsets.all(18), child: bubble))
        else
          Positioned(left: 14, right: 14, top: top, bottom: bottom, child: Align(alignment: Alignment.center, child: bubble)),
    ]);
  }
}

/// Taps inside [hole] go through to the screen; everywhere else they stop here.
class _HoleBarrier extends SingleChildRenderObjectWidget {
  const _HoleBarrier({required this.hole, super.child});
  final Rect? hole;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHoleBarrier(hole);
  @override
  void updateRenderObject(BuildContext context, _RenderHoleBarrier r) => r.hole = hole;
}

class _RenderHoleBarrier extends RenderProxyBox {
  _RenderHoleBarrier(this.hole);
  Rect? hole;
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hole != null && hole!.contains(localToGlobal(position))) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

/// The screen dimmed (#101418 at 70 %) except a rounded hole round the target.
class _DimPainter extends CustomPainter {
  _DimPainter({required this.hole, required this.dim});
  final Rect? hole;
  final bool dim;
  @override
  void paint(Canvas canvas, Size size) {
    if (!dim) return;
    final all = Path()..addRect(Offset.zero & size);
    final paint = Paint()..color = const Color(0xB3101418);
    if (hole == null) return canvas.drawPath(all, paint);
    final cut = Path()..addRRect(RRect.fromRectAndRadius(hole!, const Radius.circular(16)));
    canvas.drawPath(Path.combine(PathOperation.difference, all, cut), paint);
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.hole != hole || old.dim != dim;
}

/// A lime ring (#D2F64B, 3 px) that breathes round the hole, and a second one that grows and fades.
class _Ring extends StatefulWidget {
  const _Ring();
  @override
  State<_Ring> createState() => _RingState();
}

class _RingState extends State<_Ring> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    if (OlFace.animate) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: -6 * _c.value,
            top: -6 * _c.value,
            right: -6 * _c.value,
            bottom: -6 * _c.value,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFD2F64B).withValues(alpha: 0.55 * (1 - _c.value)), width: 3),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFD2F64B).withValues(alpha: 0.75 + 0.25 * _c.value), width: 3),
              ),
            ),
          ),
        ]),
      );
}

class _StepBubble extends StatelessWidget {
  const _StepBubble({super.key, required this.tour, required this.index, required this.text, required this.showNext, required this.last, required this.onNext, required this.onSkip});
  final OlTour tour;
  final int index;
  final String text;
  final bool showNext, last;
  final VoidCallback onNext, onSkip;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          elevation: 8,
          shadowColor: Colors.black38,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const OlFace(height: 40, still: true),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${tr(tour.name)} · ${tr('Step')} ${index + 1} ${tr('of')} ${tour.steps.length}',
                        key: const ValueKey('ol-tour-head'), style: inter(11.5, 700, color: const Color(0xFF3DB800))),
                    const SizedBox(height: 3),
                    Text(text, key: const ValueKey('ol-tour-text'), style: inter(14.5, 600, height: 1.3)),
                  ]),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                // step dots: this one wider, the done ones green
                for (var i = 0; i < tour.steps.length; i++)
                  Container(
                    width: i == index ? 16 : 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(color: i <= index ? const Color(0xFF3DB800) : const Color(0xFFDDE3D7), borderRadius: BorderRadius.circular(3)),
                  ),
                const Spacer(),
                TextButton(key: const ValueKey('ol-tour-skip'), onPressed: onSkip, child: Text(tr(last ? 'Close' : 'Skip'), style: inter(13.5, 600, color: kMuted))),
                if (showNext)
                  FilledButton(
                    key: const ValueKey('ol-tour-next'),
                    onPressed: onNext,
                    style: FilledButton.styleFrom(backgroundColor: kPrimary, shape: const StadiumBorder(), padding: const EdgeInsets.symmetric(horizontal: 18)),
                    child: Text(tr(last ? 'Done' : 'Next'), style: inter(13.5, 700, color: Colors.white)),
                  ),
              ]),
            ]),
          ),
        ),
      );
}
