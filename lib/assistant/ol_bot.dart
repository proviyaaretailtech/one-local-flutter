import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'ol_ask.dart';
import 'ol_tour.dart';

export 'ol_ask.dart' show OlGuide, OlAnswer, showOlSheet;

/// Ol, the OneLocal helper of the restaurant app (founder, 31 Oct 2026): the little lime shop in the last slot of the bottom bar.
/// It greets a new person once, says one tip the first time each tab is opened, and, tapped, opens "Ask Ol": answers with steps and
/// "Take me there", the app's own search, and "Show me how" walkthroughs on the real screens. Everything is on the phone: no AI, no
/// network, so it works offline and costs nothing per question. There is one Ol; what it has said is shared by every page.
class OlBot extends StatefulWidget {
  const OlBot({super.key, required this.current, required this.onNavigate, this.guide = const OlGuide()});

  /// The tab on screen ('Home', 'Menu', 'Bill', 'Orders'): the tip and the quick chips follow it.
  final String current;
  final ValueChanged<String> onNavigate;
  final OlGuide guide;

  /// Off in widget tests: no idle loop, hops or timed bubbles (an animation that never ends keeps a test from settling).
  static bool animate = true;

  /// Said already on this device: the hello and each tab's tip (shared_preferences keys ol_hello_seen and ol_tips_said).
  static bool _helloSeen = false;
  static final _tipped = <String>{};
  static bool _loaded = false;
  static void reset() {
    _helloSeen = false;
    _tipped.clear();
    _loaded = false;
  }

  static const _helloKey = 'ol_hello_seen', _tipsKey = 'ol_tips_said';

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      _helloSeen = _helloSeen || (p.getBool(_helloKey) ?? false);
      _tipped.addAll(p.getStringList(_tipsKey) ?? const []);
    } catch (_) {/* no storage: once per session */}
  }

  static Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_helloKey, _helloSeen);
      await p.setStringList(_tipsKey, _tipped.toList());
    } catch (_) {}
  }

  @override
  State<OlBot> createState() => _OlBotState();
}

class _OlBotState extends State<OlBot> with TickerProviderStateMixin {
  final _link = LayerLink();
  final _bubble = OverlayPortalController();
  late final AnimationController _hop = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  Timer? _say, _hide;
  String? _text;

  @override
  void initState() {
    super.initState();
    _speak();
  }

  @override
  void didUpdateWidget(OlBot old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) {
      // the old tab's bubble goes at once (after this build), then the new tab may have its first tip
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hide?.cancel();
        if (_bubble.isShowing) _bubble.hide();
        _speak();
      });
    }
  }

  @override
  void dispose() {
    _say?.cancel();
    _hide?.cancel();
    _hop.dispose();
    super.dispose();
  }

  /// The hello the first time the app is ever opened; otherwise the tab's tip the first time that tab is ever opened. After about 0.9 s,
  /// so the page draws first; the hello stays about 9 s, a tip about 7 s.
  Future<void> _speak() async {
    _say?.cancel();
    final tab = widget.current;
    await OlBot._load();
    if (!mounted || widget.current != tab) return;
    final hello = !OlBot._helloSeen;
    final tip = hello ? null : widget.guide.tipFor(tab);
    if (!hello && (tip == null || OlBot._tipped.contains(tab))) return;
    void say() {
      if (!mounted || widget.current != tab) return;
      if (hello) {
        OlBot._helloSeen = true;
      } else {
        OlBot._tipped.add(tab);
      }
      if (OlBot.animate) OlBot._save();
      setState(() => _text = tr(hello ? "Hi, I'm Ol! Tell me what you want to do, and I'll help you get it done." : tip!));
      _bubble.show();
      if (OlBot.animate) {
        _hop.forward(from: 0);
        _hide?.cancel();
        _hide = Timer(Duration(seconds: hello ? 9 : 7), () => mounted ? _bubble.hide() : null);
      }
    }

    if (OlBot.animate) {
      _say = Timer(const Duration(milliseconds: 900), say);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => say());
    }
  }

  Future<void> _open() async {
    _hide?.cancel();
    if (_bubble.isShowing) _bubble.hide();
    if (OlBot.animate) _hop.forward(from: 0);
    // the walkthrough runs on the app's top overlay, read now while this page is on screen
    final overlay = Overlay.of(context, rootOverlay: true);
    final pick = await showOlSheet(context, current: widget.current, guide: widget.guide);
    if (pick == null || !mounted) return;
    if (pick.tab != null) widget.onNavigate(pick.tab!);
    if (pick.tour != null) OlWalk.start(overlay, pick.tour!);
    pick.action?.call();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
        controller: _bubble,
        overlayChildBuilder: (_) => CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(-2, -8),
          child: Align(
            alignment: Alignment.bottomRight,
            child: OlSpeech(text: _text ?? '', onTap: _open, onClose: () {
              _hide?.cancel();
              _bubble.hide();
            }),
          ),
        ),
        child: CompositedTransformTarget(
          link: _link,
          child: Semantics(
            button: true,
            label: tr('Ol, your helper. Ask Ol.'),
            excludeSemantics: true,
            child: GestureDetector(
              key: const ValueKey('ol-bot'),
              behavior: HitTestBehavior.opaque,
              onTap: _open,
              child: LayoutBuilder(builder: (context, box) {
                // 44–52 px tall, drawn about 12 % wider than its slot so the awning can overhang it
                final h = (box.maxWidth * 1.12 / OlFace.aspect).clamp(44.0, 52.0);
                return OverflowBox(
                  maxWidth: double.infinity,
                  maxHeight: double.infinity,
                  child: AnimatedBuilder(
                    animation: _hop,
                    builder: (_, child) {
                      // the tap hop: up about 10 px with a 6 % squash
                      final v = _hop.value, up = sin(v * pi);
                      return Transform.translate(
                        offset: Offset(0, -10 * up),
                        child: Transform.scale(alignment: Alignment.bottomCenter, scaleX: 1 + 0.06 * up * (1 - v), scaleY: 1 - 0.06 * up * (1 - v), child: child),
                      );
                    },
                    child: OlFace(height: h),
                  ),
                );
              }),
            ),
          ),
        ),
      );
}

/// Ol's picture (assets/ol/ol_shop.png, 204 × 160: a lime shop under a dark four-panel awning) with its eyes drawn live on top.
/// Alive: one 5.2 s loop — the eyes look left, right and up, two quick blinks, a gentle bob with a soft squash and stretch, and a lime glow
/// that breathes behind it. [still] (and widget tests) holds it at rest.
class OlFace extends StatefulWidget {
  const OlFace({super.key, this.height = 48, this.still = false});
  final double height;
  final bool still;

  static const aspect = 204 / 160;
  static const lime = Color(0xFF8BEA2A), neon = Color(0xFFA6FF3A), deep = Color(0xFF3FA80C), ink = Color(0xFF0E1116);

  /// The one switch for every Ol animation (OlBot.animate; off in widget tests).
  static bool get animate => OlBot.animate;

  @override
  State<OlFace> createState() => _OlFaceState();
}

class _OlFaceState extends State<OlFace> with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 5200));

  @override
  void initState() {
    super.initState();
    if (OlFace.animate && !widget.still) _loop.repeat();
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  /// A smooth sine bump: 0 outside [a, b], rising to 1 in its middle.
  static double _bump(double t, double a, double b) => t <= a || t >= b ? 0 : sin(pi * (t - a) / (b - a));

  @override
  Widget build(BuildContext context) {
    final h = widget.height, w = h * OlFace.aspect;
    return SizedBox(
      width: w,
      height: h,
      child: AnimatedBuilder(
        animation: _loop,
        builder: (_, _) {
          final t = _loop.value;
          final look = Offset(-_bump(t, 0.08, 0.32) + _bump(t, 0.42, 0.66), -_bump(t, 0.72, 0.84));
          final open = 1 - 0.9 * max(_bump(t, 0.88, 0.91), _bump(t, 0.93, 0.96));
          final bob = sin(2 * pi * t), squash = 0.025 * sin(4 * pi * t);
          final glow = 0.29 + 0.11 * sin(2 * pi * t); // 0.18 … 0.40
          return Stack(clipBehavior: Clip.none, alignment: Alignment.bottomCenter, children: [
            // the glow that breathes behind the picture
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [const Color(0xFF8BF22F).withValues(alpha: glow), const Color(0x008BF22F)], stops: const [0.25, 1]),
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(0, -0.04 * h * bob),
              child: Transform.scale(
                alignment: Alignment.bottomCenter,
                scaleX: 1 - squash,
                scaleY: 1 + squash,
                child: CustomPaint(
                  foregroundPainter: _EyesPainter(look: look, open: open),
                  child: Image.asset('assets/ol/ol_shop.png', width: w, height: h, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

/// The two eyes: dark (#0E1116) rounded ovals 11 × 19 picture units at x 81.5 and 124.5, y 106 of the 204 × 160 picture, each with a small
/// white highlight near its top left (hidden while the eye is mostly shut). [look] moves them (-1 … 1); [open] 1 open … 0.1 nearly shut.
class _EyesPainter extends CustomPainter {
  _EyesPainter({required this.look, required this.open});
  final Offset look;
  final double open;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 204;
    final ew = 11 * k, eh = 19 * k * open;
    for (final cx in const [81.5, 124.5]) {
      final c = Offset((cx + 3.2 * look.dx) * k, (106 + 2.6 * look.dy) * k);
      final eye = Rect.fromCenter(center: c, width: ew, height: eh);
      canvas.drawRRect(RRect.fromRectAndRadius(eye, Radius.circular(ew / 2)), Paint()..color = OlFace.ink);
      if (open > 0.5) {
        final d = ew * 0.32;
        canvas.drawCircle(Offset(eye.left + ew * 0.32, eye.top + eh * 0.24), d / 2, Paint()..color = Colors.white.withValues(alpha: 0.8));
      }
    }
  }

  @override
  bool shouldRepaint(_EyesPainter old) => old.look != look || old.open != open;
}

/// Ol's speech bubble: white, 18 px corners, a soft shadow, at most 260 px wide, 14 px dark text, a round dark × at its top right.
/// Not a dialog: the screen stays usable. Tapping it opens Ask Ol.
class OlSpeech extends StatelessWidget {
  const OlSpeech({super.key, required this.text, required this.onTap, required this.onClose});
  final String text;
  final VoidCallback onTap, onClose;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Padding(
          padding: const EdgeInsets.only(top: 8, right: 8),
          child: Stack(clipBehavior: Clip.none, children: [
            Material(
              color: Colors.white,
              elevation: 6,
              shadowColor: const Color(0x33000000),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                key: const ValueKey('ol-bubble'),
                borderRadius: BorderRadius.circular(18),
                onTap: onTap,
                child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 20, 12), child: Text(text, style: inter(14, 500, color: OlFace.ink, height: 1.35))),
              ),
            ),
            Positioned(
              right: -8,
              top: -8,
              child: Material(
                color: OlFace.ink,
                shape: const CircleBorder(),
                child: InkWell(
                  key: const ValueKey('ol-bubble-close'),
                  customBorder: const CircleBorder(),
                  onTap: onClose,
                  child: const Padding(padding: EdgeInsets.all(5), child: Icon(LucideIcons.x, size: 13, color: Colors.white)),
                ),
              ),
            ),
          ]),
        ),
      );
}
