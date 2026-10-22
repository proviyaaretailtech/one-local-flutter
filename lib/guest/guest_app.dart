import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/theme.dart' show typeSize;
import 'guest_api.dart';

/// The guest's own screens, laid out after the founder's design boards (specs/guest-experience-v2, "Vinii Bistro"): a welcome, an optional
/// table budget, "What are you in the mood for?", the swipe deck with the budget ring (right adds, left skips, up opens the details) or a
/// list, dish details, "Added to your order", the order, review and notes, and "Order sent" with what the staff did with it.
/// One set of screens for every way in ([GuestGateway]): the QR web page on the customer's phone, "Hand to guest" on the staff phone, and
/// the public menu link (read-only: straight to the menu, nothing to order).
/// Neon green on black for every restaurant to start (founder, 2026-10-22); the restaurant's own theme comes later.
/// The screens hold no business rule: what may be ordered, the prices and every limit come from the database. The budget is a helper kept on
/// this phone only; the total shown is the restaurant's estimate and the bill is made by the restaurant.
class GuestApp extends StatefulWidget {
  const GuestApp({super.key, required this.gateway, this.onExit, this.pollEvery = const Duration(seconds: 10)});
  final GuestGateway gateway;

  /// Hand to guest: give the phone back to the staff screens. Null on the web page.
  final VoidCallback? onExit;
  final Duration pollEvery;

  @override
  State<GuestApp> createState() => _GuestAppState();
}

enum _Phase { loading, failed, ended, welcome, budget, moods, menu, added, order, review, sent, bill }

class _GuestAppState extends State<GuestApp> {
  GuestGateway get g => widget.gateway;

  /// The public menu link: read the menu, nothing to order (no table, no cart, straight to the menu).
  bool get browse => g is MenuCardGateway;

  _Phase _phase = _Phase.loading;
  GuestVisit? _visit;
  GuestMenu? _menu;
  String? _error;
  final _cart = <GuestLine>[];
  Facts? _last;
  List<Facts> _requests = const [];
  Timer? _poll;

  /// The table's budget (a helper on this phone only; never sent anywhere). Null = no budget set.
  num? budget;
  int people = 2;

  /// The category the deck starts from ("What are you in the mood for?"); null = all dishes.
  String? mood;
  int _moodPick = 0; // a new pick starts a fresh deck; visiting the order and coming back keeps the deck where it was
  GuestItem? _justAdded;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void go(_Phase p) => setState(() => _phase = p);

  Future<void> _open() async {
    setState(() => _phase = _Phase.loading);
    try {
      final v = await g.open();
      if (!mounted) return;
      setState(() {
        _visit = v;
        _menu = v.menu;
        _phase = browse ? _Phase.menu : _Phase.welcome;
      });
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      if (e is GuestApiException && e.sessionEnded) {
        _phase = _Phase.ended;
      } else {
        _phase = _Phase.failed;
        _error = e is GuestApiException ? e.message : 'Something went wrong. Please try again.';
      }
    });
  }

  int get _count => _cart.fold(0, (a, l) => a + l.qty);
  num get _total => _cart.fold<num>(0, (a, l) => a + l.item.price * l.qty);
  int qtyOf(GuestItem i) => _cart.where((l) => l.item.id == i.id).firstOrNull?.qty ?? 0;

  /// Adds one of [item] (up to 20 of a dish: the database's limit, said here so the button stops in time).
  void add(GuestItem item, [int n = 1]) {
    if (browse) return;
    setState(() {
      final line = _cart.where((l) => l.item.id == item.id).firstOrNull;
      if (line == null) {
        _cart.add(GuestLine(item, n.clamp(1, 20)));
      } else {
        line.qty = (line.qty + n).clamp(1, 20);
      }
    });
  }

  void remove(GuestItem item) {
    setState(() {
      final line = _cart.where((l) => l.item.id == item.id).firstOrNull;
      if (line == null) return;
      if (line.qty <= 1) {
        _cart.remove(line);
      } else {
        line.qty--;
      }
    });
  }

  Future<void> _refreshStatus() async {
    if (!g.waitsForStaff) return;
    try {
      final r = await g.status();
      if (mounted) setState(() => _requests = r);
    } catch (e) {
      if (e is GuestApiException && e.sessionEnded) {
        _poll?.cancel();
        _fail(e);
      }
    }
  }

  void _sent(Facts result) {
    setState(() {
      _last = result;
      _cart.clear();
      _phase = _Phase.sent;
    });
    if (g.waitsForStaff) {
      _refreshStatus();
      _poll?.cancel();
      _poll = Timer.periodic(widget.pollEvery, (_) => _refreshStatus());
    }
  }

  Future<void> _openItem(GuestItem item) async {
    final n = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _ItemSheet(item: item, inCart: qtyOf(item), browse: browse),
    );
    if (n == null || !mounted) return;
    add(item, n);
    setState(() {
      _justAdded = item;
      _phase = _Phase.added;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: _neon, brightness: Brightness.dark, surface: _bg),
        scaffoldBackgroundColor: _bg,
        textSelectionTheme: const TextSelectionThemeData(cursorColor: _neon),
      ),
      child: Scaffold(
        key: const ValueKey('guest-app'),
        backgroundColor: _bg,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // the menu stays mounted (hidden) while the guest looks at their order, so the deck keeps its place
              if (_menu != null && const {_Phase.menu, _Phase.added, _Phase.order, _Phase.review, _Phase.sent, _Phase.bill}.contains(_phase))
                Offstage(
                  offstage: _phase != _Phase.menu,
                  child: TickerMode(
                    enabled: _phase == _Phase.menu,
                    child: _MenuView(key: ValueKey('menu-$_moodPick'), app: this),
                  ),
                ),
              if (_phase != _Phase.menu) _screen(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _screen() => switch (_phase) {
    _Phase.loading => const Center(
      child: CircularProgressIndicator(key: ValueKey('guest-loading'), color: _neon),
    ),
    _Phase.failed => _Message(
      key: const ValueKey('guest-failed'),
      icon: Icons.storefront_outlined,
      title: 'Not available right now',
      body: _error ?? '',
      action: 'Try again',
      onAction: _open,
      exit: widget.onExit,
    ),
    _Phase.ended => _Message(
      key: const ValueKey('guest-ended'),
      icon: Icons.qr_code_2_rounded,
      title: 'Please scan the table code again',
      body: 'This visit has ended or the table code was changed. Scan the code on your table to order.',
      exit: widget.onExit,
    ),
    _Phase.welcome => _Welcome(app: this),
    _Phase.budget => _BudgetSetup(app: this),
    _Phase.moods => _Moods(app: this),
    _Phase.menu => const SizedBox(),
    _Phase.added => _Added(app: this),
    _Phase.order => _OrderView(app: this),
    _Phase.review => _Review(app: this),
    _Phase.sent => _SentView(app: this),
    _Phase.bill => _BillView(app: this),
  };
}

// ---- the look: neon green on black (founder's "Vinii Bistro" board)
const _bg = Color(0xFF0A0A0A);
const _card = Color(0xFF161616);
const _card2 = Color(0xFF1F1F1F);
const _line = Color(0xFF2A2A2A);
const _ink = Colors.white;
const _muted = Color(0xFF9CA3AF);
const _neon = Color(0xFF8CFF2E);
const _onNeon = Color(0xFF0A0A0A);
const _veg = Color(0xFF22C55E);
const _nonVeg = Color(0xFFEF4444);
const _amber = Color(0xFFF59E0B);

TextStyle _t(double size, FontWeight w, {Color color = _ink, double? height}) => TextStyle(fontFamily: 'Inter', fontSize: typeSize(size), fontWeight: w, color: color, height: height);

/// "₹120" or "₹120.50".
String guestMoney(num v) {
  final whole = v == v.roundToDouble();
  final s = whole ? v.round().toString() : v.toStringAsFixed(2);
  final parts = s.split('.');
  final digits = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  return '₹$digits${parts.length > 1 ? '.${parts[1]}' : ''}';
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {super.key, required this.onTap, this.filled = true, this.busy = false, this.trailing});
  final String label;
  final VoidCallback? onTap;
  final IconData? trailing;
  final bool filled;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final bg = filled ? _neon : Colors.transparent;
    final fg = filled ? _onNeon : _ink;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: onTap == null && filled ? bg.withValues(alpha: 0.4) : bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: busy ? null : onTap,
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: filled
                ? null
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: _ink.withValues(alpha: 0.7), width: 1.4),
                  ),
            alignment: Alignment.center,
            child: busy
                ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: Text(label, style: _t(16, FontWeight.w700, color: fg)),
                      ),
                      if (trailing != null) ...[const SizedBox(width: 8), Icon(trailing, size: 20, color: fg)],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _BackBar extends StatelessWidget {
  const _BackBar({this.onBack, this.title, this.action});
  final VoidCallback? onBack;
  final String? title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
    child: Row(
      children: [
        if (onBack != null)
          IconButton(
            key: const ValueKey('back'),
            tooltip: 'Back',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded, color: _ink),
          )
        else
          const SizedBox(width: 12),
        if (title != null) Expanded(child: Text(title!, style: _t(19, FontWeight.w800))) else const Spacer(),
        ?action,
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({super.key, required this.icon, required this.title, required this.body, this.action, this.onAction, this.exit});
  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback? exit;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: _muted),
          const SizedBox(height: 18),
          Text(title, textAlign: TextAlign.center, style: _t(22, FontWeight.w800)),
          const SizedBox(height: 10),
          Text(
            body,
            textAlign: TextAlign.center,
            style: _t(15, FontWeight.w400, color: _muted, height: 1.4),
          ),
          const SizedBox(height: 24),
          if (action != null) _Pill(action!, key: const ValueKey('guest-retry'), onTap: onAction),
          if (exit != null) ...[const SizedBox(height: 12), _Pill('Back to staff', key: const ValueKey('guest-exit'), filled: false, onTap: exit)],
        ],
      ),
    ),
  );
}

/// Board 1, "Welcome / Landing": the restaurant, its outlet and table, a dish photo behind, "Start exploring".
class _Welcome extends StatelessWidget {
  const _Welcome({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final visit = app._visit!;
    final m = visit.menu;
    final table = '${m.tableWord} ${visit.tableLabel}';
    final hero = m.items.where((i) => i.imageUrl != null).firstOrNull;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (hero != null) Image.network(hero.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Color(0x99000000), Color(0xF20A0A0A)],
              stops: [0, 0.45, 0.8],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: _neon, borderRadius: BorderRadius.circular(12)),
                    alignment: Alignment.center,
                    child: Text(
                      (m.brandName.isEmpty ? visit.business : m.brandName).characters.first.toUpperCase(),
                      style: _t(22, FontWeight.w900, color: _onNeon),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.brandName.isEmpty ? visit.business : m.brandName,
                          key: const ValueKey('guest-brand'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _t(17, FontWeight.w800),
                        ),
                        Row(
                          children: [
                            const Icon(Icons.location_on_rounded, size: 14, color: _neon),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                visit.outlet,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _t(13, FontWeight.w500, color: _muted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (app.widget.onExit != null)
                    TextButton(
                      key: const ValueKey('guest-exit'),
                      onPressed: app.widget.onExit,
                      child: Text('Back to staff', style: _t(14, FontWeight.w600, color: _neon)),
                    ),
                ],
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _neon.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _neon.withValues(alpha: 0.5)),
                ),
                child: Text(
                  visit.areaName == null || visit.areaName!.isEmpty ? table : '$table · ${visit.areaName}',
                  key: const ValueKey('guest-table'),
                  style: _t(14, FontWeight.w700, color: _neon),
                ),
              ),
              const SizedBox(height: 16),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'Food looks better\nwhen you ', style: _t(38, FontWeight.w800, height: 1.12)),
                    TextSpan(
                      text: 'explore it.',
                      style: _t(38, FontWeight.w800, color: _neon, height: 1.12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                m.items.isEmpty
                    ? 'Nothing can be ordered right now. Please ask the staff.'
                    : (m.tagline ?? 'Swipe through dishes, set a budget, and order together. Pay at the table when you are done.'),
                style: _t(15, FontWeight.w400, color: _muted, height: 1.4),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: _Pill(
                  'Start exploring',
                  key: const ValueKey('guest-start'),
                  trailing: Icons.arrow_forward_rounded,
                  onTap: m.items.isEmpty ? null : () => app.go(_Phase.budget),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Board 2, "Party & Budget Setup": a total budget and how many people share it. Kept on this phone only; "Skip" orders without one.
class _BudgetSetup extends StatefulWidget {
  const _BudgetSetup({required this.app});
  final _GuestAppState app;
  @override
  State<_BudgetSetup> createState() => _BudgetSetupState();
}

class _BudgetSetupState extends State<_BudgetSetup> {
  static const _min = 500.0, _max = 20000.0;
  late double _budget = (widget.app.budget ?? 3000).toDouble().clamp(_min, _max);
  late int _people = widget.app.people;

  void _done(bool keep) {
    final app = widget.app;
    app.budget = keep ? _budget : null;
    app.people = _people;
    app.go(_Phase.moods);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(
          onBack: () => widget.app.go(_Phase.welcome),
          action: TextButton(
            key: const ValueKey('budget-skip'),
            onPressed: () => _done(false),
            child: Text('Skip', style: _t(15, FontWeight.w600, color: _muted)),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
            children: [
              Text('Dining with friends?', style: _t(30, FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'Set a budget to stay on track. We will show your progress as you order. Only you see it.',
                style: _t(15, FontWeight.w400, color: _muted, height: 1.4),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: _line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total budget', style: _t(14, FontWeight.w500, color: _muted)),
                    const SizedBox(height: 6),
                    Text(guestMoney(_budget.round()), key: const ValueKey('budget-amount'), style: _t(36, FontWeight.w800)),
                    SliderTheme(
                      data: SliderTheme.of(context)
                          .copyWith(activeTrackColor: _neon, inactiveTrackColor: _line, thumbColor: _neon, overlayColor: _neon.withValues(alpha: 0.15)),
                      child: Slider(
                        key: const ValueKey('budget-slider'),
                        min: _min,
                        max: _max,
                        divisions: 39,
                        value: _budget,
                        onChanged: (v) => setState(() => _budget = v),
                      ),
                    ),
                    Row(
                      children: [
                        Text(guestMoney(_min), style: _t(13, FontWeight.w500, color: _muted)),
                        const Spacer(),
                        Text(guestMoney(_max), style: _t(13, FontWeight.w500, color: _muted)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: _line),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Split between', style: _t(14, FontWeight.w500, color: _muted)),
                          const SizedBox(height: 6),
                          Text('$_people ${_people == 1 ? 'person' : 'people'}', style: _t(18, FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text(
                            '${guestMoney((_budget / _people).round())} per person',
                            key: const ValueKey('budget-per-person'),
                            style: _t(14, FontWeight.w500, color: _neon),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(color: _card2, borderRadius: BorderRadius.circular(14)),
                      child: Row(
                        children: [
                          IconButton(
                            key: const ValueKey('budget-people-minus'),
                            tooltip: 'One person fewer',
                            onPressed: _people > 1 ? () => setState(() => _people--) : null,
                            icon: const Icon(Icons.remove_rounded, color: _ink),
                          ),
                          Text('$_people', style: _t(18, FontWeight.w800)),
                          IconButton(
                            key: const ValueKey('budget-people-plus'),
                            tooltip: 'One more person',
                            onPressed: _people < 30 ? () => setState(() => _people++) : null,
                            icon: const Icon(Icons.add_rounded, color: _ink),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
          child: _Pill('Save & continue', key: const ValueKey('budget-save'), trailing: Icons.arrow_forward_rounded, onTap: () => _done(true)),
        ),
      ],
    );
  }
}

/// Board 3, "Category Selection": "What are you in the mood for?" — every category with a dish photo, and All dishes.
class _Moods extends StatelessWidget {
  const _Moods({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final menu = app._menu!;
    GuestItem? cover(String? cat) =>
        menu.items.where((i) => (cat == null || i.categoryId == cat) && i.imageUrl != null).firstOrNull ??
        menu.items.where((i) => cat == null || i.categoryId == cat).firstOrNull;
    final tiles = <(String?, String)>[(null, 'All dishes'), for (final c in menu.categories) (c.id, c.name)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: () => app.go(_Phase.budget)),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
          child: Text('What are you in the mood for?', style: _t(28, FontWeight.w800, height: 1.15)),
        ),
        Expanded(
          child: GridView.count(
            crossAxisCount: 2,
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.95,
            children: [
              for (final (id, name) in tiles)
                Semantics(
                  button: true,
                  label: name,
                  child: InkWell(
                    key: ValueKey(id == null ? 'mood-all' : 'mood-$id'),
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      app.mood = id;
                      app._moodPick++;
                      app.go(_Phase.menu);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: id == null ? _neon : _line, width: id == null ? 1.6 : 1),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (cover(id) != null) _Art(item: cover(id)!, radius: 0, label: name.characters.first.toUpperCase()),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xCC000000)]),
                            ),
                          ),
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 12,
                            child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: _t(16, FontWeight.w800)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The budget ring of boards 4-8: spent of budget, the share used, red past the budget.
class _BudgetRing extends StatelessWidget {
  const _BudgetRing({required this.spent, required this.budget});
  static const size = 46.0;
  final num spent;
  final num budget;
  @override
  Widget build(BuildContext context) {
    final share = budget <= 0 ? 0.0 : (spent / budget).toDouble();
    final over = share > 1;
    return Row(
      key: const ValueKey('budget-ring'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _RingPainter(share.clamp(0, 1), over ? _nonVeg : _neon)),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${guestMoney(spent)} / ${guestMoney(budget)}', style: _t(15, FontWeight.w800)),
            Text(
              over ? 'Over budget by ${guestMoney(spent - budget)}' : '${(share * 100).round()}% used',
              style: _t(12.5, FontWeight.w500, color: over ? _nonVeg : _muted),
            ),
          ],
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.share, this.color);
  final double share;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(3, 3, size.width - 6, size.height - 6);
    final base = Paint()
      ..color = _line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    canvas.drawArc(r, 0, math.pi * 2, false, base);
    canvas.drawArc(
      r,
      -math.pi / 2,
      math.pi * 2 * share,
      false,
      base
        ..color = color
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.share != share || old.color != color;
}

/// Board 4, "Swipe Browse": the deck (or the list), the budget ring, categories underneath, and the order bar.
class _MenuView extends StatefulWidget {
  const _MenuView({super.key, required this.app});
  final _GuestAppState app;
  @override
  State<_MenuView> createState() => _MenuViewState();
}

class _MenuViewState extends State<_MenuView> {
  bool _swipe = true;
  bool _vegOnly = false;
  late String? _category = widget.app.mood;
  String _q = '';
  int _deckStart = 0;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final menu = app._menu!;
    final items = menu.items.where((i) => !_vegOnly || i.veg).toList();
    final shown = items
        .where((i) => _category == null || i.categoryId == _category)
        .where((i) => _swipe || _q.isEmpty || i.name.toLowerCase().contains(_q.toLowerCase()) || (i.description ?? '').toLowerCase().contains(_q.toLowerCase()))
        .toList();
    Widget chip(String label, bool on, VoidCallback tap, Key key) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: on,
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(999),
          onTap: tap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: on ? _neon : _card,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: on ? _neon : _line),
            ),
            child: Text(label, style: _t(14, FontWeight.w700, color: on ? _onNeon : _ink)),
          ),
        ),
      ),
    );
    final cats = SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          chip(
            'Veg only',
            _vegOnly,
            () => setState(() {
              _vegOnly = !_vegOnly;
              _deckStart++;
            }),
            const ValueKey('veg-only'),
          ),
          chip(
            'All',
            _category == null,
            () => setState(() {
              _category = null;
              _deckStart++;
            }),
            const ValueKey('cat-all'),
          ),
          for (final c in menu.categories)
            chip(
              c.name,
              _category == c.id,
              () => setState(() {
                _category = c.id;
                _deckStart++;
              }),
              ValueKey('cat-${c.id}'),
            ),
        ],
      ),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
          child: Row(
            children: [
              if (app.browse)
                const SizedBox(width: 10)
              else
                IconButton(
                  key: const ValueKey('menu-back'),
                  tooltip: 'Back',
                  onPressed: () => app.go(_Phase.moods),
                  icon: const Icon(Icons.arrow_back_rounded, color: _ink),
                ),
              Expanded(
                child: app.budget != null && !app.browse
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: _BudgetRing(spent: app._total, budget: app.budget!),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            menu.brandName.isEmpty ? app._visit!.business : menu.brandName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _t(18, FontWeight.w800),
                          ),
                          Text(
                            app.browse ? app._visit!.outlet : '${menu.tableWord} ${app._visit!.tableLabel}',
                            key: const ValueKey('menu-subtitle'),
                            style: _t(13, FontWeight.w500, color: _muted),
                          ),
                        ],
                      ),
              ),
              if (app._requests.isNotEmpty)
                IconButton(
                  key: const ValueKey('menu-orders'),
                  tooltip: 'Your orders',
                  onPressed: () => app.go(_Phase.sent),
                  icon: const Icon(Icons.receipt_long_rounded, color: _neon),
                ),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _line),
                ),
                child: Row(
                  children: [
                    for (final (key, label, on) in [('mode-swipe', 'Swipe', _swipe), ('mode-list', 'List', !_swipe)])
                      Semantics(
                        button: true,
                        selected: on,
                        child: InkWell(
                          key: ValueKey(key),
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => setState(() => _swipe = key == 'mode-swipe'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(color: on ? _neon : null, borderRadius: BorderRadius.circular(999)),
                            child: Text(label, style: _t(13, FontWeight.w700, color: on ? _onNeon : _muted)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!_swipe) ...[
          cats,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              key: const ValueKey('menu-search'),
              style: _t(15, FontWeight.w500),
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: InputDecoration(
                hintText: 'Search the menu',
                hintStyle: _t(15, FontWeight.w400, color: _muted),
                prefixIcon: const Icon(Icons.search_rounded, color: _muted),
                filled: true,
                fillColor: _card,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: _line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: _line),
                ),
              ),
            ),
          ),
        ],
        Expanded(
          child: _swipe
              ? _Deck(
                  key: ValueKey('deck-$_vegOnly-$_category-$_deckStart'),
                  items: shown,
                  onAdd: (i) => app.add(i),
                  onDetails: app._openItem,
                  onList: () => setState(() => _swipe = false),
                  onRestart: () => setState(() => _deckStart++),
                  browse: app.browse,
                )
              : shown.isEmpty
              ? Center(
                  child: Text('No dishes match.', style: _t(15, FontWeight.w400, color: _muted)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, n) => _ListRow(
                    item: shown[n],
                    qty: app.qtyOf(shown[n]),
                    onAdd: () => app.add(shown[n]),
                    onRemove: () => app.remove(shown[n]),
                    onOpen: () => app._openItem(shown[n]),
                    browse: app.browse,
                  ),
                ),
        ),
        if (_swipe) cats,
        if (app._count > 0) _OrderBar(app: app) else const SizedBox(height: 10),
      ],
    );
  }
}

/// "View order" at the foot of the menu: how many dishes and the estimated total.
class _OrderBar extends StatelessWidget {
  const _OrderBar({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
    child: Semantics(
      button: true,
      label: 'View order',
      child: Material(
        color: _neon,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: const ValueKey('cart-bar'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => app.go(_Phase.order),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: _onNeon, borderRadius: BorderRadius.circular(999)),
                  child: Text('${app._count}', style: _t(14, FontWeight.w800, color: _neon)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    app._count == 1 ? '1 dish · ${guestMoney(app._total)}' : '${app._count} dishes · ${guestMoney(app._total)}',
                    style: _t(15, FontWeight.w700, color: _onNeon),
                  ),
                ),
                Text('View order', style: _t(15, FontWeight.w800, color: _onNeon)),
                const Icon(Icons.arrow_forward_rounded, color: _onNeon, size: 20),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _VegMark extends StatelessWidget {
  const _VegMark(this.veg);
  final bool veg;
  @override
  Widget build(BuildContext context) => Semantics(
    label: veg ? 'Vegetarian' : 'Non-vegetarian',
    child: Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: veg ? _veg : _nonVeg, width: 1.6),
        borderRadius: BorderRadius.circular(3),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: veg ? _veg : _nonVeg, shape: BoxShape.circle),
      ),
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.icon, this.color = _ink, this.fill = _card2});
  final String text;
  final IconData? icon;
  final Color color;
  final Color fill;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
        Text(text, style: _t(12.5, FontWeight.w700, color: color)),
      ],
    ),
  );
}

List<Widget> _tagsOf(GuestItem i) => [
  if (i.recommended) const _Tag('Bestseller', icon: Icons.star_rounded, color: _onNeon, fill: _amber),
  _Tag(i.veg ? 'Veg' : 'Non-veg', color: i.veg ? _veg : _nonVeg),
  for (final t in i.tags) _Tag(t),
];

/// The dish's photo, or its initial on a dark-green gradient when it has none (never stock art).
class _Art extends StatelessWidget {
  const _Art({required this.item, this.radius = 18, this.label});
  final GuestItem item;
  final double radius;

  /// What the tile says when there is no photo (a category tile shows the category's letter, not its first dish's).
  final String? label;
  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF2B4A12), Color(0xFF101A08)]),
      ),
      alignment: Alignment.center,
      child: FractionallySizedBox(
        widthFactor: 0.4,
        heightFactor: 0.4,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 88, maxHeight: 88),
          child: FittedBox(
            child: Text(label ?? (item.name.isEmpty ? '?' : item.name.characters.first.toUpperCase()), style: _t(56, FontWeight.w900, color: _neon)),
          ),
        ),
      ),
    );
    if (item.imageUrl == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(item.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.item, required this.qty, required this.onAdd, required this.onRemove});
  final GuestItem item;
  final int qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    if (qty == 0) {
      return Semantics(
        button: true,
        label: 'Add ${item.name}',
        child: Material(
          color: _neon,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: ValueKey('add-${item.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: onAdd,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Text('ADD', style: _t(14, FontWeight.w800, color: _onNeon)),
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: _card2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _neon, width: 1.4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('minus-${item.id}'),
            tooltip: 'One less ${item.name}',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: const Icon(Icons.remove_rounded, size: 18, color: _ink),
          ),
          Text('$qty', key: ValueKey('qty-${item.id}'), style: _t(15, FontWeight.w800)),
          IconButton(
            key: ValueKey('plus-${item.id}'),
            tooltip: 'One more ${item.name}',
            visualDensity: VisualDensity.compact,
            onPressed: qty >= 20 ? null : onAdd,
            icon: const Icon(Icons.add_rounded, size: 18, color: _ink),
          ),
        ],
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({required this.item, required this.qty, required this.onAdd, required this.onRemove, required this.onOpen, this.browse = false});
  final GuestItem item;
  final int qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final VoidCallback onOpen;
  final bool browse;
  @override
  Widget build(BuildContext context) => Material(
    color: _card,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      key: ValueKey('row-${item.id}'),
      borderRadius: BorderRadius.circular(18),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            SizedBox(width: 76, height: 76, child: _Art(item: item, radius: 14)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _VegMark(item.veg),
                      const SizedBox(width: 6),
                      if (item.recommended) Text('Bestseller', style: _t(12, FontWeight.w700, color: _amber)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(item.name, style: _t(16, FontWeight.w700)),
                  if (item.description != null)
                    Text(
                      item.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _t(13, FontWeight.w400, color: _muted),
                    ),
                  const SizedBox(height: 4),
                  Text(guestMoney(item.price), style: _t(15, FontWeight.w800, color: _neon)),
                ],
              ),
            ),
            if (!browse) ...[const SizedBox(width: 8), _Stepper(item: item, qty: qty, onAdd: onAdd, onRemove: onRemove)],
          ],
        ),
      ),
    ),
  );
}

/// Boards 4-5: one dish at a time. Right adds it, left skips it, up opens its details; the buttons underneath do the same, so the deck also
/// works without swiping (screen readers, a mouse). On the public menu link both directions just show the next dish.
class _Deck extends StatefulWidget {
  const _Deck({
    super.key,
    required this.items,
    required this.onAdd,
    required this.onDetails,
    required this.onList,
    required this.onRestart,
    this.browse = false,
  });
  final List<GuestItem> items;
  final ValueChanged<GuestItem> onAdd;
  final ValueChanged<GuestItem> onDetails;
  final VoidCallback onList;
  final VoidCallback onRestart;
  final bool browse;
  @override
  State<_Deck> createState() => _DeckState();
}

class _DeckState extends State<_Deck> {
  int _i = 0;
  Offset _drag = Offset.zero;
  static const _throw = 110.0;

  GuestItem? get _top => _i < widget.items.length ? widget.items[_i] : null;

  void _next({required bool added}) {
    final top = _top;
    if (top == null) return;
    if (added) widget.onAdd(top);
    setState(() {
      _i++;
      _drag = Offset.zero;
    });
  }

  void _end(DragEndDetails d) {
    final top = _top;
    if (top == null) return;
    if (_drag.dx > _throw) {
      _next(added: true);
    } else if (_drag.dx < -_throw) {
      _next(added: false);
    } else if (_drag.dy < -_throw) {
      setState(() => _drag = Offset.zero);
      widget.onDetails(top);
    } else {
      setState(() => _drag = Offset.zero);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = _top;
    if (top == null) {
      return Center(
        key: const ValueKey('deck-done'),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.items.isEmpty ? 'No dishes to show.' : "You've seen every dish", style: _t(20, FontWeight.w800)),
              const SizedBox(height: 18),
              if (widget.items.isNotEmpty) _Pill('Start again', key: const ValueKey('deck-restart'), filled: false, onTap: widget.onRestart),
              const SizedBox(height: 10),
              _Pill('See the list', key: const ValueKey('deck-list'), onTap: widget.onList),
            ],
          ),
        ),
      );
    }
    final next = _i + 1 < widget.items.length ? widget.items[_i + 1] : null;
    final b = widget.browse;
    final hint = _drag.dx > 40
        ? (b ? 'NEXT' : 'ADD')
        : _drag.dx < -40
        ? (b ? 'NEXT' : 'SKIP')
        : _drag.dy < -40
        ? 'DETAILS'
        : null;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (next != null)
                  Transform.translate(
                    offset: const Offset(16, -10),
                    child: Transform.rotate(
                      angle: 0.05,
                      child: Opacity(opacity: 0.55, child: _DeckCard(item: next)),
                    ),
                  ),
                GestureDetector(
                  key: const ValueKey('deck-card'),
                  onPanUpdate: (d) => setState(() => _drag += d.delta),
                  onPanEnd: _end,
                  onTap: () => widget.onDetails(top),
                  child: Transform.translate(
                    offset: _drag,
                    child: Transform.rotate(
                      angle: _drag.dx / 900,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _DeckCard(item: top, top: true),
                          if (hint != null)
                            Positioned(
                              top: 24,
                              left: _drag.dx > 40 ? 24 : null,
                              right: _drag.dx < -40 ? 24 : null,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _bg.withValues(alpha: 0.8),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: hint == 'SKIP' ? _nonVeg : _neon, width: 2),
                                ),
                                child: Text(hint, style: _t(18, FontWeight.w900, color: hint == 'SKIP' ? _nonVeg : _neon)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
          child: Row(
            children: [
              if (!b)
                _Round(key: const ValueKey('deck-skip'), icon: Icons.close_rounded, label: 'Skip ${top.name}', color: _nonVeg, onTap: () => _next(added: false))
              else
                const SizedBox(width: 62),
              Expanded(
                child: Column(
                  children: [
                    IconButton(
                      key: const ValueKey('deck-info'),
                      tooltip: 'Details of ${top.name}',
                      onPressed: () => widget.onDetails(top),
                      icon: const Icon(Icons.keyboard_arrow_up_rounded, color: _muted, size: 28),
                    ),
                    Text(
                      b ? 'Swipe for the next dish' : 'Swipe right to add',
                      textAlign: TextAlign.center,
                      style: _t(12.5, FontWeight.w600, color: _muted),
                    ),
                  ],
                ),
              ),
              _Round(
                key: const ValueKey('deck-add'),
                icon: b ? Icons.arrow_forward_rounded : Icons.favorite_rounded,
                label: b ? 'Next dish' : 'Add ${top.name}',
                color: _neon,
                filled: true,
                onTap: () => _next(added: !b),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({super.key, required this.icon, required this.label, required this.color, required this.onTap, this.filled = false});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool filled;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Material(
      color: filled ? color : color.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 62, height: 62, child: Icon(icon, size: 30, color: filled ? _onNeon : Colors.white)),
      ),
    ),
  );
}

class _DeckCard extends StatelessWidget {
  const _DeckCard({required this.item, this.top = false});
  final GuestItem item;
  final bool top;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: top ? _neon.withValues(alpha: 0.55) : _line, width: top ? 1.4 : 1),
      boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 10))],
    ),
    clipBehavior: Clip.antiAlias,
    child: Stack(
      fit: StackFit.expand,
      children: [
        _Art(item: item, radius: 0),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0x00000000), Color(0xE6000000)],
              stops: [0, 0.45, 1],
            ),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name, key: top ? const ValueKey('deck-name') : null, style: _t(26, FontWeight.w800)),
              const SizedBox(height: 4),
              Text(guestMoney(item.price), style: _t(22, FontWeight.w800, color: _neon)),
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: _tagsOf(item)),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Board 6, dish details: photo, tags, description, time to prepare, quantity and Add. Pops with the quantity to add (null = closed).
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({required this.item, required this.inCart, this.browse = false});
  final GuestItem item;
  final int inCart;
  final bool browse;
  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  int _n = 1;
  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final room = 20 - widget.inCart;
    return SafeArea(
      child: Padding(
        key: const ValueKey('item-detail'),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: _line, borderRadius: BorderRadius.circular(4)),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(height: 220, child: _Art(item: i, radius: 22)),
            const SizedBox(height: 16),
            Row(
              children: [
                _VegMark(i.veg),
                const SizedBox(width: 8),
                Expanded(child: Text(i.name, style: _t(24, FontWeight.w800))),
                Text(guestMoney(i.price), style: _t(22, FontWeight.w800, color: _neon)),
              ],
            ),
            if (i.description != null) ...[const SizedBox(height: 8), Text(i.description!, style: _t(15, FontWeight.w400, color: _muted, height: 1.45))],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ..._tagsOf(i),
                if (i.prepMinutes > 0) _Tag('About ${i.prepMinutes} min', icon: Icons.schedule_rounded),
              ],
            ),
            const SizedBox(height: 18),
            if (!widget.browse)
              Row(
                children: [
                  Container(
                    decoration: BoxDecoration(color: _card2, borderRadius: BorderRadius.circular(999)),
                    child: Row(
                      children: [
                        IconButton(
                          key: const ValueKey('detail-minus'),
                          tooltip: 'One less',
                          onPressed: _n > 1 ? () => setState(() => _n--) : null,
                          icon: const Icon(Icons.remove_rounded, color: _ink),
                        ),
                        Text('$_n', key: const ValueKey('detail-qty'), style: _t(18, FontWeight.w800)),
                        IconButton(
                          key: const ValueKey('detail-plus'),
                          tooltip: 'One more',
                          onPressed: _n < room ? () => setState(() => _n++) : null,
                          icon: const Icon(Icons.add_rounded, color: _ink),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Pill(
                      room <= 0 ? '20 is the most' : 'Add · ${guestMoney(i.price * _n)}',
                      key: const ValueKey('detail-add'),
                      onTap: room <= 0 ? null : () => Navigator.of(context).pop(_n),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Board 7, "Added to your order!": the dish, then View order or Keep exploring.
class _Added extends StatelessWidget {
  const _Added({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final item = app._justAdded!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (app.budget != null)
            Center(
              child: _BudgetRing(spent: app._total, budget: app.budget!),
            ),
          const Spacer(),
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: _neon,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: _neon.withValues(alpha: 0.4), blurRadius: 30)],
              ),
              child: const Icon(Icons.check_rounded, size: 48, color: _onNeon),
            ),
          ),
          const SizedBox(height: 18),
          Text('Added to your order!', key: const ValueKey('added-title'), textAlign: TextAlign.center, style: _t(26, FontWeight.w800)),
          const SizedBox(height: 18),
          Center(
            child: Container(
              width: 220,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: _line),
              ),
              child: Column(
                children: [
                  SizedBox(height: 140, child: _Art(item: item, radius: 16)),
                  const SizedBox(height: 10),
                  Text(item.name, textAlign: TextAlign.center, style: _t(17, FontWeight.w800)),
                  Text('${app.qtyOf(item)} × ${guestMoney(item.price)}', style: _t(15, FontWeight.w700, color: _neon)),
                ],
              ),
            ),
          ),
          const Spacer(),
          _Pill('View order (${app._count})', key: const ValueKey('added-view-order'), onTap: () => app.go(_Phase.order)),
          const SizedBox(height: 10),
          _Pill('Keep exploring', key: const ValueKey('added-keep'), filled: false, onTap: () => app.go(_Phase.menu)),
        ],
      ),
    );
  }
}

/// Board 9, "View Order Anytime": every line with its quantity, the estimated total and the budget bar.
class _OrderView extends StatelessWidget {
  const _OrderView({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final budget = app.budget;
    final total = app._total;
    final share = budget == null || budget <= 0 ? 0.0 : (total / budget).toDouble();
    return Column(
      key: const ValueKey('order-screen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(
          onBack: () => app.go(_Phase.menu),
          title: 'Your order (${app._count} ${app._count == 1 ? 'dish' : 'dishes'})',
          action: app._cart.isEmpty
              ? null
              : TextButton(
                  key: const ValueKey('order-clear'),
                  onPressed: () {
                    app._cart.clear();
                    app.go(_Phase.menu);
                  },
                  child: Text('Clear all', style: _t(14, FontWeight.w700, color: _nonVeg)),
                ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            children: [
              for (final l in app._cart)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
                  child: Row(
                    children: [
                      SizedBox(width: 54, height: 54, child: _Art(item: l.item, radius: 12)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.item.name, style: _t(15, FontWeight.w700)),
                            Text(guestMoney(l.item.price), style: _t(13, FontWeight.w500, color: _muted)),
                          ],
                        ),
                      ),
                      _Stepper(item: l.item, qty: l.qty, onAdd: () => app.add(l.item), onRemove: () => app.remove(l.item)),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 64,
                        child: Text(guestMoney(l.item.price * l.qty), textAlign: TextAlign.right, style: _t(15, FontWeight.w800)),
                      ),
                    ],
                  ),
                ),
              if (app._cart.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text('Nothing added yet.', style: _t(15, FontWeight.w400, color: _muted)),
                  ),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          decoration: const BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Estimated total', style: _t(15, FontWeight.w600, color: _muted)),
                  ),
                  Text(guestMoney(total), key: const ValueKey('order-total'), style: _t(22, FontWeight.w800)),
                ],
              ),
              if (budget != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('${guestMoney(total)} / ${guestMoney(budget)}', style: _t(14, FontWeight.w700)),
                    const Spacer(),
                    Text('${(share * 100).round()}% used', style: _t(13, FontWeight.w600, color: share > 1 ? _nonVeg : _muted)),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(value: share.clamp(0, 1), minHeight: 8, backgroundColor: _line, color: share > 1 ? _nonVeg : _neon),
                ),
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('budget-note'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: (share > 1 ? _nonVeg : _neon).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                  child: Row(
                    children: [
                      Icon(share > 1 ? Icons.warning_amber_rounded : Icons.check_circle_rounded, color: share > 1 ? _nonVeg : _neon, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          share > 1
                              ? 'Over your budget by ${guestMoney(total - budget)}'
                              : "You're well within your budget! ${guestMoney(budget - total)} remaining",
                          style: _t(13.5, FontWeight.w600, color: share > 1 ? _nonVeg : _neon),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text('Taxes and charges are added on the bill.', style: _t(12.5, FontWeight.w400, color: _muted)),
              const SizedBox(height: 14),
              _Pill(
                'Continue to review',
                key: const ValueKey('order-continue'),
                trailing: Icons.arrow_forward_rounded,
                onTap: app._cart.isEmpty ? null : () => app.go(_Phase.review),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Boards 10-11, "Review & Add Notes" and the table: a name for the staff, a note for the kitchen, then send.
class _Review extends StatefulWidget {
  const _Review({required this.app});
  final _GuestAppState app;
  @override
  State<_Review> createState() => _ReviewState();
}

class _ReviewState extends State<_Review> {
  final _note = TextEditingController();
  final _name = TextEditingController();
  String _key = GuestGateway.newKey(); // one tap = one key; a retry after a failure sends the same key
  String? _sig;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final app = widget.app;
    // a changed order is a new tap with a new key; the same order retried keeps its key
    final sig = '${app._cart.map((l) => '${l.item.id}x${l.qty}').join(',')}|${_note.text.trim()}|${_name.text.trim()}';
    if (_sig != null && _sig != sig) _key = GuestGateway.newKey();
    _sig = sig;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await app.g.send(List.of(app._cart), guestName: _name.text, note: _note.text, key: _key);
      if (mounted) app._sent(r);
    } catch (e) {
      if (!mounted) return;
      if (e is GuestApiException && e.sessionEnded) {
        app._fail(e);
        return;
      }
      setState(() {
        _busy = false;
        _error = e is GuestApiException ? e.message : 'Something went wrong. Please try again.';
      });
    }
  }

  InputDecoration _field(String label) => InputDecoration(
    labelText: label,
    labelStyle: _t(14, FontWeight.w500, color: _muted),
    counterText: '',
    filled: true,
    fillColor: _card,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: _line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: _line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: _neon),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Column(
      key: const ValueKey('order-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: () => app.go(_Phase.order), title: 'Review your order'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
            children: [
              for (final l in app._cart)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      SizedBox(width: 44, height: 44, child: _Art(item: l.item, radius: 10)),
                      const SizedBox(width: 12),
                      Expanded(child: Text('${l.item.name}  × ${l.qty}', style: _t(15, FontWeight.w600))),
                      Text(guestMoney(l.item.price * l.qty), style: _t(15, FontWeight.w700)),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
                child: Row(
                  children: [
                    const Icon(Icons.table_restaurant_rounded, color: _neon),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Dine in · ${app._menu!.tableWord} ${app._visit!.tableLabel}', style: _t(15, FontWeight.w700))),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (app.g.waitsForStaff) ...[
                TextField(
                  key: const ValueKey('order-name'),
                  controller: _name,
                  maxLength: 40,
                  style: _t(15, FontWeight.w500),
                  decoration: _field('Your first name (optional)'),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                key: const ValueKey('order-note'),
                controller: _note,
                maxLength: 300,
                maxLines: 3,
                minLines: 2,
                style: _t(15, FontWeight.w500),
                decoration: _field('Special instructions (optional), e.g. less spicy'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Total', style: _t(16, FontWeight.w600, color: _muted)),
                  ),
                  Text(guestMoney(app._total), style: _t(22, FontWeight.w800)),
                ],
              ),
              Text('Pay at the table when you are done.', style: _t(12.5, FontWeight.w400, color: _muted)),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    key: const ValueKey('order-error'),
                    style: _t(14, FontWeight.w600, color: _nonVeg),
                  ),
                ),
              const SizedBox(height: 14),
              _Pill(
                app.g.waitsForStaff ? 'Send to the restaurant' : 'Send to the kitchen',
                key: const ValueKey('send-order'),
                busy: _busy,
                trailing: Icons.arrow_forward_rounded,
                onTap: app._cart.isEmpty ? null : _send,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Board 12-13, "Order Placed" and tracking: on the web page, each order of this visit and what the staff did with it (checked every few
/// seconds); with Hand to guest, the order number and "Back to staff".
class _SentView extends StatefulWidget {
  const _SentView({required this.app});
  final _GuestAppState app;
  @override
  State<_SentView> createState() => _SentViewState();
}

class _SentViewState extends State<_SentView> {
  _GuestAppState get app => widget.app;
  bool _ready = false; // the tap that sent the order must not also press "Order more", which sits in the same place
  Timer? _wake;

  @override
  void initState() {
    super.initState();
    app._refreshStatus(); // coming back to this page shows where the orders are now
    _wake = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _wake?.cancel();
    super.dispose();
  }

  (String, Color, IconData) _look(Facts r) => switch (r.s('status')) {
    'waiting' => ('Waiting for the staff to confirm', _amber, Icons.hourglass_top_rounded),
    'accepted' => (
      '${r.m('order').s('display_no')} · ${switch (GuestTrack.of(r)?.stage) {
        'confirmed' => 'Confirmed',
        'in_kitchen' => 'Being prepared',
        'ready' => 'Ready to serve',
        'served' => 'Served',
        _ => r.m('order').s('status_label'),
      }}',
      _neon,
      Icons.restaurant_rounded,
    ),
    'declined' => ('Not accepted${r.so('decline_reason') == null ? '' : ': ${r.s('decline_reason')}'}', _nonVeg, Icons.cancel_rounded),
    _ => (r.s('status'), _muted, Icons.info_outline_rounded),
  };

  @override
  Widget build(BuildContext context) {
    final last = app._last;
    final staff = !app.g.waitsForStaff;
    final displayNo = last?.m('order').so('display_no');
    final accepted = app._requests.where((r) => r.s('status') == 'accepted').toList();
    final served = accepted.isNotEmpty && !app._requests.any((r) => r.s('status') == 'waiting') && accepted.every((r) => GuestTrack.of(r)?.stage == 'served');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: _neon,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: _neon.withValues(alpha: 0.45), blurRadius: 34)],
              ),
              child: const Icon(Icons.check_rounded, size: 52, color: _onNeon),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            served ? 'Your order is served!' : (staff ? 'Sent to the kitchen' : 'Sent to the restaurant'),
            key: const ValueKey('sent-title'),
            textAlign: TextAlign.center,
            style: _t(28, FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            served
                ? 'Hope you enjoy your meal.'
                : staff
                ? (displayNo == null ? 'The kitchen has your order.' : 'Order $displayNo is with the kitchen.')
                : accepted.isEmpty
                ? '${app._menu!.tableWord} ${app._visit!.tableLabel} · A member of staff will confirm it in a moment.'
                : '${app._menu!.tableWord} ${app._visit!.tableLabel} · We will keep this page up to date.',
            textAlign: TextAlign.center,
            style: _t(15, FontWeight.w400, color: _muted, height: 1.4),
          ),
          const SizedBox(height: 18),
          if (!staff)
            Expanded(
              child: ListView(
                children: [
                  for (final r in app._requests)
                    Container(
                      key: ValueKey('request-${r.s('id')}'),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _card,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _line),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(_look(r).$3, color: _look(r).$2, size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_look(r).$1, style: _t(15, FontWeight.w700, color: _look(r).$2)),
                                const SizedBox(height: 4),
                                Text(
                                  r.l('lines').map((l) => '${l.n('qty').toInt()} × ${l.s('name')}').join(', '),
                                  style: _t(13.5, FontWeight.w400, color: _muted),
                                ),
                                if (GuestTrack.of(r) case final track?) _Timeline(track: track),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            )
          else
            const Spacer(),
          if (!staff && accepted.isNotEmpty) ...[
            _Pill('View bill', key: const ValueKey('view-bill'), filled: !served ? false : true, onTap: _ready ? () => app.go(_Phase.bill) : null),
            const SizedBox(height: 10),
          ],
          _Pill('Order more', key: const ValueKey('order-more'), filled: !served, onTap: _ready ? () => app.go(_Phase.menu) : null),
          if (app.widget.onExit != null) ...[
            const SizedBox(height: 10),
            _Pill('Back to staff', key: const ValueKey('guest-exit'), filled: false, onTap: app.widget.onExit),
          ],
        ],
      ),
    );
  }
}

/// Board 13, live tracking: Order confirmed, In the kitchen, Ready, Served, with the time each happened and the minutes left while cooking.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.track});
  final GuestTrack track;
  static const _labels = {'confirmed': 'Order confirmed', 'in_kitchen': 'In the kitchen', 'ready': 'Ready', 'served': 'Served'};
  static const _icons = {
    'confirmed': Icons.check_rounded,
    'in_kitchen': Icons.soup_kitchen_rounded,
    'ready': Icons.room_service_rounded,
    'served': Icons.restaurant_rounded,
  };
  String _hm(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  @override
  Widget build(BuildContext context) {
    if (track.stage == 'cancelled') {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('This order was cancelled.', style: _t(13.5, FontWeight.w600, color: _nonVeg)),
      );
    }
    final current = track.steps.lastIndexWhere((x) => x.done);
    return Padding(
      key: const ValueKey('track'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (track.minutesLeft != null)
            Container(
              key: const ValueKey('track-eta'),
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: _neon.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.timer_outlined, size: 18, color: _neon),
                  const SizedBox(width: 6),
                  Text(
                    track.minutesLeft == 0 ? 'Almost ready' : 'Estimated serving time: about ${track.minutesLeft} min',
                    style: _t(13.5, FontWeight.w700, color: _neon),
                  ),
                ],
              ),
            ),
          for (final (n, step) in track.steps.indexed)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(color: step.done ? (n == current ? _neon : _neon.withValues(alpha: 0.25)) : _card2, shape: BoxShape.circle),
                      child: Icon(_icons[step.key] ?? Icons.circle, size: 15, color: step.done ? (n == current ? _onNeon : _neon) : _muted),
                    ),
                    if (n < track.steps.length - 1) Container(width: 2, height: 18, color: step.done ? _neon.withValues(alpha: 0.4) : _line),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _labels[step.key] ?? step.key,
                            style: _t(14, n == current ? FontWeight.w800 : FontWeight.w500, color: step.done ? _ink : _muted),
                          ),
                        ),
                        if (step.done && step.at != null) Text(_hm(step.at!), style: _t(12.5, FontWeight.w500, color: _muted)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Board 16, "Final Bill (with Budget)" and feedback: the table's dishes and money, how it compares with the budget, "pay at the table",
/// and how the visit was (one feedback per visit; choosing again changes it).
class _BillView extends StatefulWidget {
  const _BillView({required this.app});
  final _GuestAppState app;
  @override
  State<_BillView> createState() => _BillViewState();
}

class _BillViewState extends State<_BillView> {
  GuestBill? _bill;
  String? _error;
  int? _rating;
  final _comment = TextEditingController();
  bool _sending = false;
  bool _thanked = false;
  bool _askedForBill = false;
  static const _faces = [
    (5, Icons.sentiment_very_satisfied_rounded, 'Loved it'),
    (4, Icons.sentiment_satisfied_rounded, 'Good'),
    (3, Icons.sentiment_neutral_rounded, 'Okay'),
    (2, Icons.sentiment_dissatisfied_rounded, 'Could be better'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final b = await widget.app.g.bill();
      if (mounted) {
        setState(() {
          _bill = b;
          _rating ??= b?.rating;
          _thanked = b?.rating != null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is GuestApiException ? e.message : 'Could not load the bill. Please try again.');
    }
  }

  Future<void> _send() async {
    final r = _rating;
    if (r == null || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.app.g.feedback(r, comment: _comment.text);
      if (mounted) {
        setState(() {
          _sending = false;
          _thanked = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e is GuestApiException ? e.message : 'Could not send. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final b = _bill;
    final budget = app.budget;
    Widget money(String label, num v, {bool big = false, Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: _t(big ? 17 : 14.5, big ? FontWeight.w800 : FontWeight.w500, color: big ? _ink : _muted)),
          ),
          Text(v < 0 ? '−${guestMoney(-v)}' : guestMoney(v), key: key, style: _t(big ? 22 : 14.5, FontWeight.w800)),
        ],
      ),
    );
    return Column(
      key: const ValueKey('bill-screen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: () => app.go(_Phase.sent), title: 'Your bill'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            children: [
              Text('${app._menu!.tableWord} ${app._visit!.tableLabel}', style: _t(14, FontWeight.w600, color: _muted)),
              const SizedBox(height: 10),
              if (b == null && _error == null)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator(color: _neon)),
                ),
              if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey('bill-error'),
                  style: _t(14, FontWeight.w600, color: _nonVeg),
                ),
              if (b != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(20)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (b.lines.isEmpty) Text('Nothing on the bill yet.', style: _t(14.5, FontWeight.w500, color: _muted)),
                      for (final l in b.lines)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: [
                              Expanded(child: Text(l.name, style: _t(15, FontWeight.w600))),
                              SizedBox(
                                width: 32,
                                child: Text(
                                  '${l.qty}',
                                  textAlign: TextAlign.center,
                                  style: _t(14.5, FontWeight.w600, color: _muted),
                                ),
                              ),
                              SizedBox(
                                width: 80,
                                child: Text(guestMoney(l.total), textAlign: TextAlign.right, style: _t(15, FontWeight.w700)),
                              ),
                            ],
                          ),
                        ),
                      const Divider(color: _line, height: 24),
                      money('Subtotal', b.subtotal),
                      if (b.discount > 0) money('Discount', -b.discount),
                if (b.gst > 0) money('GST', b.gst),
                if (b.serviceCharge > 0) money('Service charge', b.serviceCharge),
                if (b.roundOff != 0) money('Round off', b.roundOff),
                      const SizedBox(height: 4),
                      money('Total', b.total, big: true, key: const ValueKey('bill-total')),
                      if (b.paid > 0) money('Paid', b.paid),
                      if (b.paid > 0) money('Still to pay', b.due),
                    ],
                  ),
                ),
                if (budget != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('bill-budget'),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: (b.total > budget ? _nonVeg : _neon).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                    child: Row(
                      children: [
                        Icon(b.total > budget ? Icons.warning_amber_rounded : Icons.check_circle_rounded, color: b.total > budget ? _nonVeg : _neon),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            b.total > budget
                                ? '${guestMoney(b.total)} of ${guestMoney(budget)}: ${guestMoney(b.total - budget)} over your budget.'
                                : 'Great! You stayed within your budget: ${guestMoney(b.total)} of ${guestMoney(budget)}.',
                            style: _t(14, FontWeight.w600, color: b.total > budget ? _nonVeg : _neon),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                _Pill(
                  _askedForBill ? 'The staff will bring your bill' : 'Pay at the table',
                  key: const ValueKey('bill-pay'),
                  filled: !_askedForBill,
                  onTap: _askedForBill ? null : () => setState(() => _askedForBill = true),
                ),
                const SizedBox(height: 6),
                Text(
                  'Paying from your phone is coming soon. For now a member of staff takes the payment at your table.',
                  textAlign: TextAlign.center,
                  style: _t(12.5, FontWeight.w400, color: _muted),
                ),
                const SizedBox(height: 22),
                Text('How was your experience?', style: _t(18, FontWeight.w800)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final (v, face, label) in _faces)
                      Semantics(
                        button: true,
                        selected: _rating == v,
                        label: label,
                        child: InkWell(
                          key: ValueKey('rate-$v'),
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => setState(() {
                            _rating = v;
                            _thanked = false;
                          }),
                          child: Container(
                            width: 76,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: _rating == v ? _neon.withValues(alpha: 0.18) : _card,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _rating == v ? _neon : _line),
                            ),
                            child: Column(
                              children: [
                                Icon(face, size: 32, color: _rating == v ? _neon : _amber),
                                const SizedBox(height: 4),
                                Text(
                                  label,
                                  textAlign: TextAlign.center,
                                  style: _t(11.5, FontWeight.w600, color: _rating == v ? _neon : _muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_thanked)
                  Container(
                    key: const ValueKey('feedback-thanks'),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: _neon.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                    child: Text('Thank you! The restaurant reads every message.', style: _t(14, FontWeight.w700, color: _neon)),
                  )
                else if (_rating != null) ...[
                  TextField(
                    key: const ValueKey('feedback-comment'),
                    controller: _comment,
                    maxLength: 500,
                    maxLines: 3,
                    minLines: 1,
                    style: _t(15, FontWeight.w500),
                    decoration: InputDecoration(
                      hintText: 'Anything to tell the restaurant? (optional)',
                      hintStyle: _t(14, FontWeight.w400, color: _muted),
                      counterText: '',
                      filled: true,
                      fillColor: _card,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: _line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: _line),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _Pill('Send feedback', key: const ValueKey('feedback-send'), busy: _sending, onTap: _send),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}
