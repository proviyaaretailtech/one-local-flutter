import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../home/app_actions.dart';
import 'i18n.dart';
import 'theme.dart';

/// Ol moves (looks around, blinks, bobs) and says hello once. Off under `flutter test`, where a forever-running animation would
/// never settle; tests turn them on when they need them.
bool olAnimates = kIsWeb || !Platform.environment.containsKey('FLUTTER_TEST');
bool olGreets = kIsWeb || !Platform.environment.containsKey('FLUTTER_TEST');

const _olInk = Color(0xFF0E1116);
const _seenKey = 'ol_hello_seen';

/// Ol (founder, 27 Oct 2026): OneLocal's helper, in the bottom bar's empty circle. Vendors will tell Ol what they want to do in the app;
/// for now Ol finds the right screen from the same list the side menu searches. The first time the app opens, Ol says hello in a
/// small bubble, once.
class OlMascot extends StatefulWidget {
  const OlMascot({super.key, this.size = 44});
  final double size;
  @override
  State<OlMascot> createState() => _OlMascotState();
}

class _OlMascotState extends State<OlMascot> with SingleTickerProviderStateMixin {
  // the whole app shares one hello: every page has its own bar, and the bubble must not come back on the next page
  static bool _greeted = false;
  static bool _checking = false;

  late final AnimationController _life = AnimationController(vsync: this, duration: const Duration(milliseconds: 5200));
  final _bubble = OverlayPortalController();
  final _link = LayerLink();
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    if (olAnimates) _life.repeat();
    if (olGreets) _maybeGreet();
  }

  Future<void> _maybeGreet() async {
    if (_greeted || _checking) return;
    _checking = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_seenKey) == true) {
        _greeted = true;
        return;
      }
    } catch (_) {
      // no storage here: say hello this time anyway
    } finally {
      _checking = false;
    }
    if (_greeted) return;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted || _greeted) return;
    _greeted = true;
    _bubble.show();
    _hide = Timer(const Duration(seconds: 9), _dismiss);
  }

  Future<void> _dismiss() async {
    _hide?.cancel();
    if (_bubble.isShowing) _bubble.hide();
    try {
      (await SharedPreferences.getInstance()).setBool(_seenKey, true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _hide?.cancel();
    _life.dispose();
    super.dispose();
  }

  void _open() {
    _dismiss();
    showOlSheet(context);
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _bubble,
          overlayChildBuilder: (_) => CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(6, -14),
            child: Align(alignment: Alignment.bottomRight, child: _HelloBubble(onClose: _dismiss, onTap: _open)),
          ),
          child: Semantics(
            button: true,
            label: tr('Ask Ol'),
            child: GestureDetector(
              key: const ValueKey('ol-mascot'),
              onTap: _open,
              child: AnimatedBuilder(animation: _life, builder: (_, _) => OlFace(size: widget.size, t: _life.value)),
            ),
          ),
        ),
      );
}

/// Ol at a moment [t] (0..1) of its loop: the founder's neon shop character (assets/ol/ol_shop.png, 28 Oct 2026), drawn without eyes
/// so the eyes here can move. It bobs with a soft squash, looks left, looks right, glances up and blinks twice; the glow breathes.
class OlFace extends StatelessWidget {
  const OlFace({super.key, required this.size, this.t = 0});
  final double size;
  final double t;

  // the picture is 204 × 160; its eyes sat at x 81.5 and 124.5, y 106 (11 × 19 each)
  static const _aspect = 204 / 160;
  static const _eyes = [81.5 / 204, 124.5 / 204];
  static const _eyeY = 106 / 160, _eyeW = 11 / 204, _eyeH = 19 / 160;

  // a smooth bump between [a] and [b] (0 outside), peaking at 1 in the middle
  static double _bump(double t, double a, double b) {
    if (t <= a || t >= b) return 0;
    return math.sin((t - a) / (b - a) * math.pi);
  }

  @override
  Widget build(BuildContext context) {
    final look = -_bump(t, 0.08, 0.32) + _bump(t, 0.42, 0.66); // left, then right
    final up = _bump(t, 0.72, 0.84);
    final blink = (1 - 0.9 * (_bump(t, 0.88, 0.91) + _bump(t, 0.93, 0.96))).clamp(0.1, 1.0);
    final wave = math.sin(t * math.pi * 4);
    final squash = 1 + wave * 0.025;
    final glow = 0.5 + 0.5 * math.sin(t * math.pi * 2);
    final w = size * 1.12, h = w / _aspect; // a touch wider than the old circle: the awning carries it
    final ew = w * _eyeW, eh = h * _eyeH;
    return SizedBox(
      width: size,
      height: size,
      child: OverflowBox(
        minWidth: w,
        maxWidth: w,
        minHeight: h,
        maxHeight: h,
        child: Transform.translate(
          offset: Offset(0, wave * size * 0.04),
          child: Transform(
            alignment: Alignment.bottomCenter,
            transform: Matrix4.diagonal3Values(squash, 2 - squash, 1),
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(clipBehavior: Clip.none, children: [
                // the glow breathing behind the picture's own glow
                Positioned(
                  left: w * 0.16,
                  right: w * 0.16,
                  top: h * 0.12,
                  bottom: h * 0.08,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(w * 0.18),
                      boxShadow: [BoxShadow(color: const Color(0xFF8BF22F).withValues(alpha: 0.18 + 0.22 * glow), blurRadius: w * 0.16, spreadRadius: w * 0.01)],
                    ),
                  ),
                ),
                Positioned.fill(child: Image.asset('assets/ol/ol_shop.png', fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
                for (final ex in _eyes)
                  Positioned(
                    left: w * ex - ew / 2 + look * w * 0.035,
                    top: h * _eyeY - eh / 2 - up * h * 0.03 + eh * (1 - blink) / 2,
                    child: Container(
                      width: ew,
                      height: eh * blink,
                      decoration: BoxDecoration(color: _olInk, borderRadius: BorderRadius.circular(ew)),
                      alignment: const Alignment(-0.3, -0.5),
                      child: blink > 0.6 ? Container(width: ew * 0.32, height: ew * 0.32, decoration: const BoxDecoration(color: Color(0xCCFFFFFF), shape: BoxShape.circle)) : null,
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _HelloBubble extends StatelessWidget {
  const _HelloBubble({required this.onClose, required this.onTap});
  final VoidCallback onClose, onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Stack(clipBehavior: Clip.none, children: [
          GestureDetector(
            onTap: onTap,
            child: Container(
              key: const ValueKey('ol-hello'),
              constraints: const BoxConstraints(maxWidth: 260),
              padding: const EdgeInsets.fromLTRB(16, 14, 22, 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6))],
              ),
              child: Text(tr("Hi, I'm Ol! Tell me what you want to do, and I'll help you get it done in OneLocal."), style: inter(14, 500, color: _olInk, height: 1.35)),
            ),
          ),
          Positioned(
            right: -8,
            top: -10,
            child: Material(
              color: _olInk,
              shape: const CircleBorder(),
              child: InkWell(
                key: const ValueKey('ol-hello-close'),
                customBorder: const CircleBorder(),
                onTap: onClose,
                child: const Padding(padding: EdgeInsets.all(5), child: Icon(LucideIcons.x, size: 14, color: Colors.white)),
              ),
            ),
          ),
        ]),
      );
}

/// Ol's sheet: say what you want to do, or pick a common job; Ol opens the screen for it.
Future<void> showOlSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => const _OlSheet(),
    );

class _OlSheet extends StatefulWidget {
  const _OlSheet();
  @override
  State<_OlSheet> createState() => _OlSheetState();
}

class _OlSheetState extends State<_OlSheet> {
  final _ask = TextEditingController();
  List<AppAction> _hits = const [];
  bool _asked = false;

  static const _jobs = ['Make a bill', 'Add a product', 'Receive goods', 'Check stock', 'Online orders'];

  @override
  void dispose() {
    _ask.dispose();
    super.dispose();
  }

  void _search(String q) {
    final all = appActions(context);
    setState(() {
      _asked = q.trim().isNotEmpty;
      _hits = q.trim().isEmpty ? const [] : searchActions(all, q).take(4).toList();
    });
  }

  void _go(AppAction a) {
    Navigator.of(context).pop();
    a.open();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 18 + MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          top: false,
          child: Column(key: const ValueKey('ol-sheet'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const OlFace(size: 44, t: 0.5),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Ol'), style: inter(19, 800)),
                  Text(tr('Your OneLocal helper. Tell me what you want to do.'), style: inter(13, 400, color: kMuted)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('ol-ask'),
              controller: _ask,
              autofocus: false,
              textInputAction: TextInputAction.search,
              onChanged: _search,
              onSubmitted: (q) {
                _search(q);
                if (_hits.isNotEmpty) _go(_hits.first);
              },
              decoration: InputDecoration(
                hintText: tr('e.g. receive goods, add a product…'),
                prefixIcon: const Icon(LucideIcons.sparkles, size: 18),
                filled: true,
                fillColor: kBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),
            if (!_asked)
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final j in _jobs)
                  ActionChip(
                    key: ValueKey('ol-job-$j'),
                    label: Text(tr(j), style: inter(13, 600)),
                    backgroundColor: const Color(0xFFF2FDE6),
                    side: const BorderSide(color: Color(0xFFCDEFAA)),
                    onPressed: () {
                      _ask.text = j;
                      _search(j);
                    },
                  ),
              ])
            else if (_hits.isEmpty)
              Text(tr("I can't do that yet. I'm still learning — try other words."), style: inter(13.5, 500, color: kMuted))
            else
              for (final a in _hits)
                ListTile(
                  key: ValueKey('ol-hit-${a.title}'),
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(backgroundColor: const Color(0xFFF2FDE6), child: Icon(a.icon, size: 18, color: kInk)),
                  title: Text(tr(a.title), style: inter(14.5, 700)),
                  subtitle: Text(tr(a.where), style: inter(12.5, 400, color: kMuted)),
                  trailing: const Icon(LucideIcons.chevronRight, size: 18),
                  onTap: () => _go(a),
                ),
            const SizedBox(height: 6),
            Text(tr('Ol is learning. Soon Ol will do these jobs for you.'), style: inter(11.5, 400, color: kMuted)),
          ]),
        ),
      );
}
