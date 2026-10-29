import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';

/// Ol, the OneLocal helper (founder, 27 Oct 2026): the lime character in the last slot of the restaurant bar, like the store bar's.
/// It is alive (blinks, glances around, bounces when it has something to say), says a tip for the tab you are on in a speech bubble,
/// and, tapped, opens "Ask Ol": quick actions for this screen and a box to ask where something is ("how do I split a bill?").
/// Ol answers with the steps and "Take me there", which switches tab through [onNavigate].
/// The answers come from [OlGuide], a guide to this app kept on the phone, so Ol works offline and costs nothing per question.
class OlBot extends StatefulWidget {
  const OlBot({super.key, required this.current, required this.onNavigate, this.guide = const OlGuide()});

  /// The tab now on screen ('Home', 'Menu', 'Bill', 'Orders'): the tip and the quick actions follow it.
  final String current;
  final ValueChanged<String> onNavigate;
  final OlGuide guide;

  /// Off in widget tests: no blinking, glancing or timed tips (they would keep the test clock busy).
  static bool animate = true;

  /// Tips already said, per tab: each tab's tip is said once on this device, not every session (founder, 29 Oct 2026: the bubbles
  /// covered the screen on every visit). Kept in the device's storage; tests (no animation) keep it in memory only.
  static final _tipped = <String>{};
  static bool _loaded = false;
  static void reset() {
    _tipped.clear();
    _loaded = false;
  }

  static const _prefsKey = 'ol_tips_said';

  static Future<void> _load() async {
    if (_loaded || !animate) return;
    _loaded = true;
    try {
      _tipped.addAll((await SharedPreferences.getInstance()).getStringList(_prefsKey) ?? const []);
    } catch (_) {/* no storage: tips once per session */}
  }

  static Future<void> _remember(String tab) async {
    _tipped.add(tab);
    if (!animate) return;
    try {
      await (await SharedPreferences.getInstance()).setStringList(_prefsKey, _tipped.toList());
    } catch (_) {}
  }

  @override
  State<OlBot> createState() => _OlBotState();
}

class _OlBotState extends State<OlBot> with TickerProviderStateMixin {
  final _link = LayerLink();
  final _bubble = OverlayPortalController();
  late final AnimationController _bounce = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final AnimationController _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
  Timer? _life, _say, _hide;
  double _look = 0; // where the eyes look: -1 left … 1 right
  String? _tip;
  final _rand = Random();

  @override
  void initState() {
    super.initState();
    if (OlBot.animate) _life = Timer.periodic(const Duration(milliseconds: 2600), (_) => _alive());
    _maybeTip();
  }

  @override
  void didUpdateWidget(OlBot old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) {
      // the old tab's tip goes away; not during this build, but right after it
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _bubble.isShowing) _bubble.hide();
        _maybeTip();
      });
    }
  }

  @override
  void dispose() {
    _life?.cancel();
    _say?.cancel();
    _hide?.cancel();
    _bounce.dispose();
    _blink.dispose();
    super.dispose();
  }

  /// Every few seconds: blink, and now and then glance somewhere else.
  void _alive() {
    if (!mounted) return;
    _blink.forward(from: 0).then((_) => mounted ? _blink.reverse() : null);
    if (_rand.nextDouble() < 0.45) setState(() => _look = [-1.0, 0.0, 0.0, 1.0][_rand.nextInt(4)]);
  }

  /// The first time a tab is ever opened on this device, Ol says its tip (after a moment, so the page draws first).
  Future<void> _maybeTip() async {
    _say?.cancel();
    final tab = widget.current;
    await OlBot._load();
    if (!mounted || widget.current != tab || OlBot._tipped.contains(tab)) return;
    final tip = widget.guide.tipFor(tab);
    if (tip == null) return;
    void say() {
      if (!mounted || widget.current != tab) return;
      OlBot._remember(tab);
      setState(() => _tip = tip);
      _bubble.show();
      if (OlBot.animate) {
        _bounce.forward(from: 0);
        _hide?.cancel();
        _hide = Timer(const Duration(seconds: 7), () => mounted ? _bubble.hide() : null);
      }
    }

    if (OlBot.animate) {
      _say = Timer(const Duration(milliseconds: 900), say);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => say());
    }
  }

  Future<void> _open() async {
    _bubble.hide();
    if (OlBot.animate) _bounce.forward(from: 0);
    final go = await showOlSheet(context, current: widget.current, guide: widget.guide);
    if (go != null && mounted) widget.onNavigate(go);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _bubble,
      overlayChildBuilder: (_) => CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.topRight,
        followerAnchor: Alignment.bottomRight,
        offset: const Offset(-4, -10),
        child: Align(alignment: Alignment.bottomRight, child: _Bubble(text: _tip ?? '', onTap: _open, onClose: _bubble.hide)),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: Semantics(
          button: true,
          label: 'Ol, your OneLocal helper. Ask Ol.',
          child: GestureDetector(
            key: const ValueKey('ol-bot'),
            onTap: _open,
            child: Center(
              child: AnimatedBuilder(
                animation: Listenable.merge([_bounce, _blink]),
                builder: (_, _) {
                  // a little hop and squash when Ol speaks or is tapped
                  final hop = sin(_bounce.value * pi) * (1 - _bounce.value);
                  return Transform.translate(
                    offset: Offset(0, -10 * hop),
                    child: Transform.scale(scaleX: 1 + 0.06 * hop, scaleY: 1 - 0.06 * hop, child: OlFace(look: _look, blink: _blink.value, size: 52)),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ol's face: a glowing lime circle with two dark pill eyes. [look] moves the eyes (-1 left … 1 right); [blink] 0 open … 1 shut.
/// Ol's face (founder, 28 Oct 2026): a little glowing lime shop - a soft green body under a four-panel dark awning with neon lime edges -
/// and two dark oval eyes. The shop is painted ([_ShopPainter]); the eyes are live, so Ol still blinks and glances.
class OlFace extends StatelessWidget {
  const OlFace({super.key, this.look = 0, this.blink = 0, this.size = 52});
  final double look, blink;
  final double size;
  static const lime = Color(0xFF8BEA2A);
  @override
  Widget build(BuildContext context) {
    final eyeW = size * 0.1, eyeH = max(2.0, size * 0.17 * (1 - 0.85 * blink));
    Widget eye() => AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: eyeW,
          height: eyeH,
          alignment: const Alignment(0.3, -0.5),
          decoration: BoxDecoration(color: const Color(0xFF0B1206), borderRadius: BorderRadius.circular(size)),
          // a tiny light in each eye
          child: blink > 0.5 ? null : Container(width: eyeW * 0.32, height: eyeW * 0.32, decoration: const BoxDecoration(color: Color(0x99FFFFFF), shape: BoxShape.circle)),
        );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _ShopPainter())),
        // the eyes sit on the shop's front, below the awning
        AnimatedPositioned(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          left: size * (0.31 + 0.06 * look),
          width: size * 0.38,
          top: size * 0.6,
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [eye(), eye()]),
        ),
      ]),
    );
  }
}

/// The shop body and its awning, drawn to fit any square.
class _ShopPainter extends CustomPainter {
  static const _neon = Color(0xFFA6FF3A), _deep = Color(0xFF3FA80C), _dark = Color(0xFF112409);

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final edge = w * 0.045;
    Paint glow(double width, double blur, double alpha) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = _neon.withValues(alpha: alpha)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = edge
      ..strokeJoin = StrokeJoin.round
      ..color = _neon;

    // the body: a rounded block, lit from the top
    final body = RRect.fromLTRBR(w * 0.12, h * 0.36, w * 0.88, h * 0.94, Radius.circular(w * 0.16));
    canvas.drawRRect(body, glow(edge * 2.2, w * 0.06, 0.55));
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF8EF23A), Color(0xFF55C51A), _deep])
            .createShader(body.outerRect),
    );
    canvas.drawRRect(body, line);

    // the awning: a rounded top, four panels, a scalloped hem
    final left = w * 0.06, right = w * 0.94, top = h * 0.06, hem = h * 0.42, scallop = (right - left) / 8;
    final awning = Path()
      ..moveTo(left, hem)
      ..lineTo(left + w * 0.06, top + h * 0.05)
      ..quadraticBezierTo(left + w * 0.08, top, left + w * 0.16, top)
      ..lineTo(right - w * 0.16, top)
      ..quadraticBezierTo(right - w * 0.08, top, right - w * 0.06, top + h * 0.05)
      ..lineTo(right, hem);
    for (var i = 3; i >= 0; i--) {
      awning.arcToPoint(Offset(left + scallop * 2 * i, hem), radius: Radius.circular(scallop), clockwise: true);
    }
    awning.close();
    canvas.drawPath(awning, glow(edge * 2.2, w * 0.06, 0.6));
    canvas.drawPath(awning, Paint()..color = _dark);
    // the panel seams, fanning down from the top
    for (var i = 1; i < 4; i++) {
      final xb = left + scallop * 2 * i;
      final xt = left + w * 0.16 + (right - left - w * 0.32) * i / 4;
      canvas.drawLine(Offset(xt, top), Offset(xb, hem), line);
    }
    canvas.drawPath(awning, line);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.onTap, required this.onClose});
  final String text;
  final VoidCallback onTap, onClose;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
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
              child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 20, 12), child: Text(text, style: inter(14, 500, color: kInk, height: 1.35))),
            ),
          ),
          Positioned(
            right: -8,
            top: -8,
            child: Material(
              color: kInk,
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
      );
}

/// "Ask Ol": quick actions for this screen, a short chat, and "Take me there". Answers the tab to switch to, or null.
Future<String?> showOlSheet(BuildContext context, {required String current, OlGuide guide = const OlGuide()}) => showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => _OlSheet(current: current, guide: guide),
    );

class _Msg {
  const _Msg(this.text, {this.mine = false, this.answer});
  final String text;
  final bool mine;
  final OlAnswer? answer;
}

class _OlSheet extends StatefulWidget {
  const _OlSheet({required this.current, required this.guide});
  final String current;
  final OlGuide guide;
  @override
  State<_OlSheet> createState() => _OlSheetState();
}

class _OlSheetState extends State<_OlSheet> {
  final _ask = TextEditingController();
  final _scroll = ScrollController();
  late final _msgs = <_Msg>[_Msg(widget.guide.greeting(widget.current, DateTime.now()))];

  @override
  void dispose() {
    _ask.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(String q) {
    final text = q.trim();
    if (text.isEmpty) return;
    final a = widget.guide.answer(text);
    setState(() {
      _msgs.add(_Msg(text, mine: true));
      _msgs.add(_Msg(a.text, answer: a));
      _ask.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final quick = widget.guide.quickFor(widget.current);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 10),
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Row(children: [
                const OlFace(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Ask Ol', style: inter(19, 800)),
                    Text('Your OneLocal helper · finds anything in the app', style: inter(12.5, 400, color: kMuted)),
                  ]),
                ),
              ]),
            ),
            Flexible(
              child: ListView(
                controller: _scroll,
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                children: [
                  for (final m in _msgs) _bubbleFor(m),
                ],
              ),
            ),
            // quick actions for this tab, all in view
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, runSpacing: 4, children: [
                for (final q in quick)
                  ActionChip(
                    key: ValueKey('ol-quick-${q.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}'),
                    label: Text(q, style: inter(13, 600)),
                    backgroundColor: const Color(0xFFF1FBE6),
                    side: const BorderSide(color: Color(0xFFCDEFA8)),
                    shape: const StadiumBorder(),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _send(q),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                key: const ValueKey('ol-ask'),
                controller: _ask,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                style: inter(15, 500),
                decoration: InputDecoration(
                  hintText: 'Ask Ol… e.g. where do I split a bill?',
                  hintStyle: inter(14, 400, color: kMuted),
                  filled: true,
                  fillColor: const Color(0xFFF4F5F1),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                  suffixIcon: IconButton(key: const ValueKey('ol-send'), onPressed: () => _send(_ask.text), icon: const Icon(LucideIcons.sendHorizontal, color: kInk)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _bubbleFor(_Msg m) {
    final a = m.answer;
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: m.mine ? kInk : const Color(0xFFF4F5F1),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(m.mine ? 18 : 4),
            bottomRight: Radius.circular(m.mine ? 4 : 18),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.text, style: inter(14, m.mine ? 600 : 500, color: m.mine ? Colors.white : kInk, height: 1.4)),
          if (a != null && a.steps.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (var i = 0; i < a.steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('${i + 1}. ${a.steps[i]}', style: inter(13.5, 400, color: kInk, height: 1.35)),
              ),
          ],
          if (a?.tab != null) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              key: ValueKey('ol-go-${a!.tab}'),
              style: FilledButton.styleFrom(backgroundColor: kInk, shape: const StadiumBorder(), visualDensity: VisualDensity.compact),
              onPressed: () => Navigator.of(context).pop(a.tab),
              icon: const Icon(LucideIcons.arrowRight, size: 16, color: OlFace.lime),
              label: Text('Take me there · ${a.tab}', style: inter(13.5, 700, color: Colors.white)),
            ),
          ],
        ]),
      ),
    );
  }
}

/// One answer: what Ol says, the steps, and the tab that has it (null when Ol is not sure).
class OlAnswer {
  const OlAnswer(this.text, {this.steps = const [], this.tab});
  final String text;
  final List<String> steps;
  final String? tab;
}

class _Topic {
  const _Topic(this.words, this.answer);
  final List<String> words;
  final OlAnswer answer;
}

/// What Ol knows about the restaurant app: a tip and quick actions per tab, and where everything is.
/// A question is matched to the topic whose words it shares most (any case; "bills" finds "bill").
class OlGuide {
  const OlGuide();

  String greeting(String tab, DateTime now) {
    final h = now.hour;
    final hello = h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
    return "$hello! I'm Ol 👋 I can take you anywhere in the app. You're on $tab. What do you need?";
  }

  String? tipFor(String tab) => switch (tab) {
        'Home' => "Hi, I'm Ol! Today's sales and orders are right here. Tap me any time to find something.",
        'Menu' => 'Tip: tap the three dots on a dish for AI picture, settings or out of stock. Recipe shows each dish\'s food cost.',
        'Bill' => 'Choose a table, then tap dishes to add them. Takeaway and Delivery need no table.',
        'Orders' => 'All your orders live here, newest first. Tap one to see its items and status.',
        _ => null,
      };

  List<String> quickFor(String tab) => switch (tab) {
        'Home' => const ['Take an order', 'Add a dish', 'Split a bill', 'Recipe costs'],
        'Menu' => const ['Add a dish', 'AI picture', 'Recipe costs', 'Mark out of stock'],
        'Bill' => const ['Takeaway on a table', 'Split a bill', 'Ready to serve', 'Add a table'],
        'Orders' => const ['Track an order', 'Take an order', 'Today\'s sales'],
        _ => const ['Take an order', 'Add a dish'],
      };

  static const _topics = <_Topic>[
    _Topic(['take', 'order', 'new', 'bill', 'table', 'dine', 'kot', 'kitchen', 'send', 'cart'], OlAnswer(
      'To take an order:',
      steps: ['Open Bill', 'Keep Dine in and tap Choose table (or pick Takeaway / Delivery)', 'Tap dishes to add them', 'Send to kitchen, or Hold'],
      tab: 'Bill',
    )),
    _Topic(['takeaway', 'parcel', 'pack', 'take', 'away', 'table', 'same'], OlAnswer(
      'Takeaway for guests already at a table goes on the same bill:',
      steps: ['Open Bill and choose their table', 'Tap the Takeaway pill', 'Tap the dishes to pack; they show "Takeaway" on the bill and the kitchen card'],
      tab: 'Bill',
    )),
    _Topic(['delivery', 'deliver', 'address', 'home'], OlAnswer(
      'For a delivery order:',
      steps: ['Open Bill and tap the Delivery pill', 'Tap the dishes', 'Send or Hold, then enter the phone and address'],
      tab: 'Bill',
    )),
    _Topic(['split', 'cash', 'card', 'upi', 'pay', 'payment', 'settle', 'generate', 'bill'], OlAnswer(
      'To split one bill across Cash, Card and UPI:',
      steps: ['Open the table\'s order and tap Generate Bill', 'On Checkout, tap Split the bill', 'Enter each method\'s amount (Rest fills what is left)', 'Take each payment'],
      tab: 'Bill',
    )),
    _Topic(['ready', 'serve', 'served', 'kitchen', 'kds', 'display'], OlAnswer(
      'Dishes the kitchen has made are in Ready to serve:',
      steps: ['Open Bill', 'Tap Ready to serve', 'Mark dishes served as they go out'],
      tab: 'Bill',
    )),
    _Topic(['table', 'tables', 'add', 'rename', 'seats', 'qr', 'manage', 'clean'], OlAnswer(
      'Tables are managed from Bill:',
      steps: ['Open Bill', 'Tap Manage tables to add, rename or change seats', 'Table QR codes lets guests order from their table'],
      tab: 'Bill',
    )),
    _Topic(['dish', 'item', 'menu', 'add', 'new', 'price', 'category', 'quick'], OlAnswer(
      'To add a dish:',
      steps: ['Open Menu', 'Tap Quick add beside the search', 'Give it a name, price and category, then save'],
      tab: 'Menu',
    )),
    _Topic(['photo', 'picture', 'image', 'ai', 'background', 'enhance'], OlAnswer(
      'For an AI picture of a dish:',
      steps: ['Open Menu', 'Tap ⋮ on the dish, then AI picture', 'Choose With background or Without background', 'Tap Use this picture'],
      tab: 'Menu',
    )),
    _Topic(['description', 'describe', 'timing', 'timings', 'available'], OlAnswer(
      'To change a dish\'s description or serving times:',
      steps: ['Open Menu', 'Tap ⋮ on the dish', 'Edit description & timings'],
      tab: 'Menu',
    )),
    _Topic(['stock', 'out', 'finished', 'sold', 'unavailable', 'off'], OlAnswer(
      'To mark a dish out of stock:',
      steps: ['Open Menu', 'Tap ⋮ on the dish', 'Mark out of stock (and back in stock later)'],
      tab: 'Menu',
    )),
    _Topic(['recipe', 'recipes', 'cost', 'costs', 'margin', 'food', 'profit', 'ingredient', 'ingredients', 'made', 'make'], OlAnswer(
      'Recipes, ingredients and food cost are in Menu:',
      steps: ['Open Menu', 'Tap Recipe to see each dish\'s cost and margin (green is healthy)', 'Tap Ingredients for stock and purchase'],
      tab: 'Menu',
    )),
    _Topic(['orders', 'track', 'status', 'online', 'history', 'past'], OlAnswer(
      'Every order, newest first, is in Orders. Tap one for its items and status.',
      tab: 'Orders',
    )),
    _Topic(['sales', 'today', 'revenue', 'report', 'dashboard', 'earnings', 'money'], OlAnswer(
      'Today\'s sales, orders and trends are on Home.',
      tab: 'Home',
    )),
    _Topic(['settings', 'setting', 'hours', 'phone', 'outlet', 'profile', 'gst'], OlAnswer(
      'Settings are in the side menu:',
      steps: ['Open Home', 'Tap ☰ at the top left', 'Choose Settings (outlet timings, phone numbers, outlet info)'],
      tab: 'Home',
    )),
  ];

  OlAnswer answer(String question) {
    final words = question.toLowerCase().replaceAll(RegExp(r"'s\b|'"), '').replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').split(RegExp(r'\s+')).where((w) => w.length > 1).map(_stem).toSet();
    _Topic? best;
    var bestScore = 0;
    for (final t in _topics) {
      final score = t.words.where((w) => words.contains(_stem(w))).length;
      if (score > bestScore) {
        best = t;
        bestScore = score;
      }
    }
    if (best == null) {
      return const OlAnswer("I'm not sure about that one yet. Try asking about orders, tables, takeaway, splitting a bill, dishes, AI pictures, recipes or sales.");
    }
    return best.answer;
  }

  static String _stem(String w) => w.length > 3 && w.endsWith('s') && !w.endsWith('ss') ? w.substring(0, w.length - 1) : w;
}
