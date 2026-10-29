import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'i18n.dart';
import 'ol_mascot.dart' show OlFace;
import 'theme.dart';

// Ol shows the way (founder, 28 Oct 2026): pick a job and Ol walks the person through it on the real screens — the screen dims, a
// spotlight sits on what to tap, Ol's bubble says what to do, and tapping the lit thing moves on (across screens). Skip at any time.
// Targets are found by the keys and words the screens already have, so screens need nothing extra.

/// What to light up: a widget's key, the first widget whose key starts with a prefix (the first product), or a visible word.
class OlTarget {
  const OlTarget.key(this.value) : kind = 'key';
  const OlTarget.keyPrefix(this.value) : kind = 'prefix';
  const OlTarget.text(this.value) : kind = 'text';
  final String kind, value;
}

/// One step: what Ol says, and what to light up. With a [target] the step moves on when the person taps it; [next] adds a Next button
/// (for a step that only explains, or a target that is good to see but not needed).
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

/// The jobs Ol can show, for a store (the bottom bar is Home · Item · Bill · Online order; Money is in the ☰ menu).
const olTours = [
  OlTour('Make a bill', [
    OlStep('Tap Bill at the bottom. It opens the till.', target: OlTarget.text('Bill')),
    OlStep('Find an item by its name here, or tap the scanner to scan its barcode.', target: OlTarget.key('sell-scan'), next: true),
    OlStep('Tap an item to add it to the cart. Tap it again to add one more.', target: OlTarget.keyPrefix('product-')),
    OlStep('When the cart is ready, tap PAY and choose cash, UPI or card. That is the bill done!', target: OlTarget.text('PAY'), next: true),
  ]),
  OlTour('Add a product', [
    OlStep('Tap Item at the bottom.', target: OlTarget.text('Item')),
    OlStep('Make sure Products is chosen.', target: OlTarget.key('item-part-products')),
    OlStep('Tap Quick add.', target: OlTarget.key('cat-add')),
    OlStep('Type the name and price, or scan the barcode, then save. The product shows on the till at once.', next: true),
  ]),
  OlTour('Receive goods', [
    OlStep('Tap Item at the bottom.', target: OlTarget.text('Item')),
    OlStep('Tap Purchase.', target: OlTarget.key('item-part-purchase')),
    OlStep('Orders you sent to suppliers are listed here: tap Received on one when its goods arrive. Goods came without an order? Tap Add Purchase.',
        target: OlTarget.text('Add Purchase')),
    OlStep('Check the quantities, enter the MRP for each item and tap Mark received. Stock goes up by itself.', next: true),
  ]),
  OlTour('Check stock', [
    OlStep('Tap Item at the bottom.', target: OlTarget.text('Item')),
    OlStep('Tap Stock.', target: OlTarget.key('item-part-stock')),
    OlStep('Every item shows how many are left. Low ones are marked, so you know what to reorder.', next: true),
  ]),
  OlTour('Online orders', [
    OlStep('Tap Online order at the bottom.', target: OlTarget.text('Online order')),
    OlStep('New orders wait for you to accept them. Tap the pile to open them.', target: OlTarget.key('orders-pile-new')),
    OlStep('Open an order, accept it, pack it, and hand it to the rider. Each pile shows where orders are.', next: true),
  ]),
  OlTour('Add money', [
    OlStep('Open the menu.', target: OlTarget.key('app-header-menu')),
    OlStep('Tap Money.', target: OlTarget.text('Money')),
    OlStep('Tap Money in.', target: OlTarget.key('money-in')),
    OlStep('Tap Add money, enter the amount and how it was paid, then Save entry. You can send a receipt on WhatsApp too.', target: OlTarget.key('flow-add'), next: true),
  ]),
  OlTour('Start an ad', [
    OlStep('Open the menu.', target: OlTarget.key('app-header-menu')),
    OlStep('Tap Page Manager. Everything about your OneLocal page is there.', target: OlTarget.text('Page Manager')),
    OlStep('Tap Ads.', target: OlTarget.key('pm-ads')),
    OlStep('Ads are paid in coins (1 coin = ₹10). Tap Top up to add coins.', target: OlTarget.key('ads-topup'), next: true),
    OlStep('Tap Create campaign.', target: OlTarget.key('ads-create')),
    OlStep('Pick what the ad is for and where it shows, add a 9:16 photo or video and the dates. Where OneLocal has a price you see the coins it holds; otherwise OneLocal sends you a price. OneLocal checks every ad before it runs.', next: true),
  ]),
  OlTour('Pay someone', [
    OlStep('Open the menu.', target: OlTarget.key('app-header-menu')),
    OlStep('Tap Money.', target: OlTarget.text('Money')),
    OlStep('Tap Transfer.', target: OlTarget.key('money-transfer')),
    OlStep('Pick the contact, type the amount and tap GPay or PhonePe. Come back after paying and it is saved in Money out.', next: true),
  ]),
];

OlTour? olTourFor(String name) => olTours.where((t) => t.name.toLowerCase() == name.toLowerCase()).firstOrNull;

/// Runs walkthroughs on the app's top overlay. One at a time.
class OlGuide {
  OlGuide._(this._overlay, this._tour);
  final OverlayState _overlay;
  final OlTour _tour;
  OverlayEntry? _entry;
  Timer? _poll;
  int _step = 0;
  Rect? _rect; // where the lit target is, on screen
  bool _lost = false; // the target is not on this screen
  int _misses = 0;
  bool _advancing = false;

  static OlGuide? _current;

  /// The guide running now (tests read it).
  static OlGuide? get current => _current;
  int get step => _step;

  /// Tests make the wait for a target short.
  static Duration pollEvery = const Duration(milliseconds: 150);
  static int missesBeforeLost = 26; // about 4 s

  static void start(OverlayState overlay, OlTour tour) {
    _current?.stop();
    final g = OlGuide._(overlay, tour);
    _current = g;
    g._entry = OverlayEntry(builder: g._build);
    overlay.insert(g._entry!);
    g._poll = Timer.periodic(pollEvery, (_) => g._locate());
    g._locate();
  }

  void stop() {
    _poll?.cancel();
    _entry?.remove();
    _entry = null;
    if (_current == this) _current = null;
  }

  void next() {
    if (_step >= _tour.steps.length - 1) return stop();
    _step++;
    _rect = null;
    _lost = false;
    _misses = 0;
    _advancing = false;
    _entry?.markNeedsBuild();
    _locate();
  }

  void _locate() {
    final s = _tour.steps[_step];
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

  /// The target on screen now: attached, laid out, on the page in front (not a page underneath, not a hidden tab), inside the screen.
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
        'prefix' => key is ValueKey && key.value is String && (key.value as String).startsWith(t.value) && !(key.value as String).contains('-count-') && !(key.value as String).contains('-less-'),
        _ => w is Text && (w.data == t.value || w.data == tr(t.value)),
      };
      if (hit) {
        // a word lights up the button it sits in (the whole Bill tab, not just "Bill")
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

  /// The nearest button around a word (an InkWell, a GestureDetector, a Material button), when it is not most of the screen.
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
    if (!TickerMode.valuesOf(e).enabled) return null; // a hidden tab or a page underneath
    final route = ModalRoute.of(e);
    if (route != null && !route.isCurrent) return null;
    final rect = ro.localToGlobal(Offset.zero) & ro.size;
    if (!screen.overlaps(rect)) return null;
    return rect;
  }

  void _tappedLit() {
    if (_advancing || _tour.steps[_step].target == null) return;
    _advancing = true;
    // the tap goes through to the screen; the next step starts once it has done its work
    Timer(const Duration(milliseconds: 450), () {
      if (_current == this) next();
    });
  }

  Widget _build(BuildContext context) => _OlLayer(guide: this);
}

class _OlLayer extends StatelessWidget {
  const _OlLayer({required this.guide});
  final OlGuide guide;

  @override
  Widget build(BuildContext context) {
    final g = guide;
    final step = g._tour.steps[g._step];
    final size = MediaQuery.sizeOf(context);
    final hole = g._rect?.inflate(6);
    final waiting = step.target != null && hole == null && !g._lost;
    final bubble = _Bubble(
      key: const ValueKey('ol-guide-bubble'),
      tour: g._tour,
      index: g._step,
      text: g._lost ? '${tr(step.say)}\n\n${tr("I can't see it on this screen. Go to the right screen, or tap Next.")}' : tr(step.say),
      showNext: step.next || step.target == null || g._lost,
      last: g._step == g._tour.steps.length - 1,
      onNext: g.next,
      onSkip: g.stop,
    );
    // the bubble goes below the lit thing when it is in the top half, above it otherwise; in the middle when nothing is lit
    final below = hole == null || hole.center.dy < size.height / 2;
    final top = hole == null ? null : (below ? min(hole.bottom + 14, size.height - 220) : null);
    final bottom = hole == null ? null : (below ? null : max(size.height - hole.top + 14, 16.0));
    return Stack(children: [
      // the dim screen with the hole; taps outside the hole stop here, taps inside go through to the screen
      Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerUp: (ev) {
            if (hole != null && hole.contains(ev.position)) g._tappedLit();
          },
          child: _HoleBarrier(
            hole: hole,
            child: IgnorePointer(child: CustomPaint(painter: _DimPainter(hole: hole, dim: !waiting), size: Size.infinite)),
          ),
        ),
      ),
      if (hole != null) Positioned.fromRect(rect: hole.inflate(4), child: const IgnorePointer(child: _Pulse())),
      if (!waiting)
        if (hole == null)
          Center(child: Padding(padding: const EdgeInsets.all(18), child: bubble))
        else
          Positioned(left: 14, right: 14, top: top, bottom: bottom, child: Align(alignment: Alignment.center, child: bubble)),
    ]);
  }
}

/// Lets taps through inside [hole] and stops them everywhere else.
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
    final global = localToGlobal(position);
    if (hole != null && hole!.contains(global)) return false; // through to the screen
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

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

/// A lime ring that breathes around the lit thing.
class _Pulse extends StatefulWidget {
  const _Pulse();
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        // two rings, the outer one fading as it grows: a glow round the edge that leaves the lit thing itself clear
        builder: (_, _) => Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
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
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFD2F64B), width: 3)),
            ),
          ),
        ]),
      );
}

class _Bubble extends StatelessWidget {
  const _Bubble({super.key, required this.tour, required this.index, required this.text, required this.showNext, required this.last, required this.onNext, required this.onSkip});
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
                const OlFace(size: 40, t: 0.5),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${tr(tour.name)} · ${tr('Step')} ${index + 1} ${tr('of')} ${tour.steps.length}', style: inter(11.5, 700, color: const Color(0xFF3DB800))),
                    const SizedBox(height: 3),
                    Text(text, key: const ValueKey('ol-guide-text'), style: inter(14.5, 600, height: 1.3)),
                  ]),
                ),
              ]),
              const SizedBox(height: 8),
              // step dots
              Row(children: [
                for (var i = 0; i < tour.steps.length; i++)
                  Container(
                    width: i == index ? 16 : 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(color: i <= index ? const Color(0xFF3DB800) : const Color(0xFFDDE3D7), borderRadius: BorderRadius.circular(3)),
                  ),
                const Spacer(),
                TextButton(key: const ValueKey('ol-guide-skip'), onPressed: onSkip, child: Text(tr(last ? 'Close' : 'Skip'), style: inter(13.5, 600, color: kMuted))),
                if (showNext)
                  FilledButton(
                    key: const ValueKey('ol-guide-next'),
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
