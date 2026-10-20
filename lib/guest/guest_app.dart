import 'dart:async';

import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/theme.dart' show typeSize;
import 'guest_api.dart';

/// The guest's own screens (ported in spirit from the VINII partner app's guest runtime, `lib/presentation/guest/*`): welcome, the menu as a
/// swipe deck (right adds, left skips, up opens the details) or a list, dish details, the order, and what happened to it.
/// One set of screens for both ways in ([GuestGateway]): the QR web page on the customer's phone and "Hand to guest" on the staff phone.
/// The screens hold no business rule: what may be ordered, the prices and every limit come from the database; the total shown here is the
/// restaurant's estimate and the bill is made by the restaurant.
class GuestApp extends StatefulWidget {
  const GuestApp({super.key, required this.gateway, this.onExit, this.pollEvery = const Duration(seconds: 10)});
  final GuestGateway gateway;

  /// Hand to guest: give the phone back to the staff screens. Null on the web page.
  final VoidCallback? onExit;
  final Duration pollEvery;

  @override
  State<GuestApp> createState() => _GuestAppState();
}

enum _Phase { loading, failed, ended, welcome, menu, sent }

class _GuestAppState extends State<GuestApp> {
  GuestGateway get g => widget.gateway;
  _Phase _phase = _Phase.loading;
  GuestVisit? _visit;
  GuestMenu? _menu;
  String? _error;
  final _cart = <GuestLine>[];
  Facts? _last;
  List<Facts> _requests = const [];
  Timer? _poll;

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

  Future<void> _open() async {
    setState(() => _phase = _Phase.loading);
    try {
      final v = await g.open();
      if (!mounted) return;
      setState(() {
        _visit = v;
        _menu = v.menu;
        _phase = _Phase.welcome;
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

  void _orderMore() => setState(() => _phase = _Phase.menu);

  Future<void> _openOrder() async {
    final result = await showModalBottomSheet<Facts>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _OrderSheet(app: this),
    );
    if (result != null && mounted) _sent(result);
    if (mounted) setState(() {});
  }

  Future<void> _openItem(GuestItem item) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => _ItemSheet(item: item, accent: _menu!.accent, inCart: qtyOf(item), onAdd: (n) => add(item, n)),
      );

  @override
  Widget build(BuildContext context) {
    final accent = _menu?.accent ?? const Color(0xFF76EC00);
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.light),
        scaffoldBackgroundColor: _paper,
      ),
      child: Scaffold(
        key: const ValueKey('guest-app'),
        backgroundColor: _paper,
        body: SafeArea(
          child: switch (_phase) {
            _Phase.loading => const Center(child: CircularProgressIndicator(key: ValueKey('guest-loading'), color: _ink)),
            _Phase.failed => _Message(
                key: const ValueKey('guest-failed'),
                icon: Icons.storefront_outlined,
                title: 'Not available right now',
                body: _error ?? '',
                action: 'Try again',
                onAction: _open,
                exit: widget.onExit),
            _Phase.ended => _Message(
                key: const ValueKey('guest-ended'),
                icon: Icons.qr_code_2_rounded,
                title: 'Please scan the table code again',
                body: 'This visit has ended or the table code was changed. Scan the code on your table to order.',
                exit: widget.onExit),
            _Phase.welcome => _Welcome(visit: _visit!, accent: accent, onStart: () => setState(() => _phase = _Phase.menu), onExit: widget.onExit),
            _Phase.menu => _MenuView(app: this, onBack: () => setState(() => _phase = _Phase.welcome)),
            _Phase.sent => _SentView(app: this),
          },
        ),
      ),
    );
  }
}

const _paper = Color(0xFFFAFAF7);
const _ink = Color(0xFF111827);
const _muted = Color(0xFF6B7280);
const _line = Color(0xFFE5E7EB);
const _veg = Color(0xFF16A34A);
const _nonVeg = Color(0xFFB91C1C);

TextStyle _t(double size, FontWeight w, {Color color = _ink, double? height}) => TextStyle(fontFamily: 'Inter', fontSize: typeSize(size), fontWeight: w, color: color, height: height);

/// "₹120" or "₹120.50".
String guestMoney(num v) {
  final whole = v == v.roundToDouble();
  final s = whole ? v.round().toString() : v.toStringAsFixed(2);
  final parts = s.split('.');
  final digits = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  return '₹$digits${parts.length > 1 ? '.${parts[1]}' : ''}';
}

Color _onAccent(Color c) => c.computeLuminance() > 0.45 ? _ink : Colors.white;

class _Pill extends StatelessWidget {
  const _Pill(this.label, {super.key, required this.onTap, this.accent, this.icon, this.filled = true, this.busy = false});
  final String label;
  final VoidCallback? onTap;
  final Color? accent;
  final IconData? icon;
  final bool filled;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final bg = filled ? (accent ?? _ink) : Colors.white;
    final fg = filled ? _onAccent(bg) : _ink;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: onTap == null ? bg.withValues(alpha: 0.45) : bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: busy ? null : onTap,
          child: Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: filled ? null : BoxDecoration(borderRadius: BorderRadius.circular(999), border: Border.all(color: _line, width: 1.4)),
            alignment: Alignment.center,
            child: busy
                ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
                    ExcludeSemantics(child: Text(label, style: _t(16, FontWeight.w700, color: fg))),
                  ]),
          ),
        ),
      ),
    );
  }
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: _muted),
            const SizedBox(height: 18),
            Text(title, textAlign: TextAlign.center, style: _t(22, FontWeight.w800)),
            const SizedBox(height: 10),
            Text(body, textAlign: TextAlign.center, style: _t(15, FontWeight.w400, color: _muted, height: 1.4)),
            const SizedBox(height: 24),
            if (action != null) _Pill(action!, key: const ValueKey('guest-retry'), onTap: onAction),
            if (exit != null) ...[const SizedBox(height: 12), _Pill('Back to staff', key: const ValueKey('guest-exit'), filled: false, onTap: exit)],
          ]),
        ),
      );
}

/// Welcome: the restaurant, the table, "Start ordering". No sign-in.
class _Welcome extends StatelessWidget {
  const _Welcome({required this.visit, required this.accent, required this.onStart, this.onExit});
  final GuestVisit visit;
  final Color accent;
  final VoidCallback onStart;
  final VoidCallback? onExit;
  @override
  Widget build(BuildContext context) {
    final m = visit.menu;
    final table = '${m.tableWord} ${visit.tableLabel}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(26),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [accent, Color.lerp(accent, _ink, 0.55)!]),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (onExit != null)
              Align(
                alignment: Alignment.topRight,
                child: TextButton(key: const ValueKey('guest-exit'), onPressed: onExit, child: Text('Back to staff', style: _t(14, FontWeight.w600, color: _onAccent(accent)))),
              ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(999)),
              child: Text(visit.areaName == null || visit.areaName!.isEmpty ? table : '$table · ${visit.areaName}', key: const ValueKey('guest-table'), style: _t(14, FontWeight.w700)),
            ),
            const SizedBox(height: 18),
            Text(m.brandName.isEmpty ? visit.business : m.brandName, key: const ValueKey('guest-brand'), style: _t(36, FontWeight.w800, color: _onAccent(accent), height: 1.1)),
            if (m.tagline != null) ...[const SizedBox(height: 8), Text(m.tagline!, style: _t(16, FontWeight.w500, color: _onAccent(accent).withValues(alpha: 0.85)))],
            const SizedBox(height: 6),
            Text(visit.outlet, style: _t(15, FontWeight.w500, color: _onAccent(accent).withValues(alpha: 0.75))),
          ]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(
          m.items.isEmpty ? 'Nothing can be ordered right now. Please ask the staff.' : 'Swipe through the menu, add what you like and send it to the restaurant. Pay at the table when you are done.',
          textAlign: TextAlign.center,
          style: _t(14, FontWeight.w400, color: _muted, height: 1.4),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: _Pill('Start ordering', key: const ValueKey('guest-start'), accent: accent, icon: Icons.restaurant_menu_rounded, onTap: m.items.isEmpty ? null : onStart),
      ),
    ]);
  }
}

/// The menu: swipe deck or list, a veg-only filter, categories and search in the list, and the order bar.
class _MenuView extends StatefulWidget {
  const _MenuView({required this.app, required this.onBack});
  final _GuestAppState app;
  final VoidCallback onBack;
  @override
  State<_MenuView> createState() => _MenuViewState();
}

class _MenuViewState extends State<_MenuView> {
  bool _swipe = true;
  bool _vegOnly = false;
  String? _category;
  String _q = '';
  int _deckStart = 0;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final menu = app._menu!;
    final accent = menu.accent;
    var items = menu.items.where((i) => !_vegOnly || i.veg).toList();
    final listItems = items
        .where((i) => _category == null || i.categoryId == _category)
        .where((i) => _q.isEmpty || i.name.toLowerCase().contains(_q.toLowerCase()) || (i.description ?? '').toLowerCase().contains(_q.toLowerCase()))
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: on ? _ink : Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: on ? _ink : _line)),
                child: Text(label, style: _t(14, FontWeight.w600, color: on ? Colors.white : _ink)),
              ),
            ),
          ),
        );
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
        child: Row(children: [
          IconButton(key: const ValueKey('menu-back'), tooltip: 'Back', onPressed: widget.onBack, icon: const Icon(Icons.arrow_back_rounded, color: _ink)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(menu.brandName, maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(18, FontWeight.w800)),
              Text('${menu.tableWord} ${app._visit!.tableLabel}', style: _t(13, FontWeight.w500, color: _muted)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: _line)),
            child: Row(children: [
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
                      decoration: BoxDecoration(color: on ? accent : null, borderRadius: BorderRadius.circular(999)),
                      child: Text(label, style: _t(13, FontWeight.w700, color: on ? _onAccent(accent) : _muted)),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      ),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          chip('Veg only', _vegOnly, () => setState(() {
                _vegOnly = !_vegOnly;
                _deckStart = 0;
              }), const ValueKey('veg-only')),
          if (!_swipe) ...[
            chip('All', _category == null, () => setState(() => _category = null), const ValueKey('cat-all')),
            for (final c in menu.categories) chip(c.name, _category == c.id, () => setState(() => _category = c.id), ValueKey('cat-${c.id}')),
          ],
        ]),
      ),
      if (!_swipe)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            key: const ValueKey('menu-search'),
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: InputDecoration(
              hintText: 'Search the menu',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _line)),
            ),
          ),
        ),
      Expanded(
        child: _swipe
            ? _Deck(
                key: ValueKey('deck-$_vegOnly-$_deckStart'),
                items: items,
                accent: accent,
                onAdd: (i) => app.add(i),
                onDetails: app._openItem,
                onList: () => setState(() => _swipe = false),
                onRestart: () => setState(() => _deckStart++),
              )
            : listItems.isEmpty
                ? Center(child: Text('No dishes match.', style: _t(15, FontWeight.w400, color: _muted)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: listItems.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, n) => _ListRow(item: listItems[n], accent: accent, qty: app.qtyOf(listItems[n]), onAdd: () => app.add(listItems[n]), onRemove: () => app.remove(listItems[n]), onOpen: () => app._openItem(listItems[n])),
                  ),
      ),
      if (app._count > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Semantics(
            button: true,
            label: 'View order',
            child: Material(
              color: _ink,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                key: const ValueKey('cart-bar'),
                borderRadius: BorderRadius.circular(18),
                onTap: app._openOrder,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(999)),
                      child: Text('${app._count}', style: _t(14, FontWeight.w800, color: _onAccent(accent))),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(app._count == 1 ? '1 dish · ${guestMoney(app._total)}' : '${app._count} dishes · ${guestMoney(app._total)}', style: _t(15, FontWeight.w600, color: Colors.white))),
                    Text('View order', style: _t(15, FontWeight.w800, color: accent)),
                  ]),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
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
          decoration: BoxDecoration(border: Border.all(color: veg ? _veg : _nonVeg, width: 1.6), borderRadius: BorderRadius.circular(3)),
          alignment: Alignment.center,
          child: Container(width: 7, height: 7, decoration: BoxDecoration(color: veg ? _veg : _nonVeg, shape: BoxShape.circle)),
        ),
      );
}

/// The dish's photo, or its initial on the restaurant's colour when it has none (never stock art).
class _Art extends StatelessWidget {
  const _Art({required this.item, required this.accent, this.radius = 18});
  final GuestItem item;
  final Color accent;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color.lerp(accent, Colors.white, 0.35)!, Color.lerp(accent, _ink, 0.25)!]),
      ),
      alignment: Alignment.center,
      child: Text(item.name.isEmpty ? '?' : item.name.characters.first.toUpperCase(), style: _t(44, FontWeight.w800, color: _onAccent(accent))),
    );
    if (item.imageUrl == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(item.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.item, required this.qty, required this.accent, required this.onAdd, required this.onRemove});
  final GuestItem item;
  final int qty;
  final Color accent;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    if (qty == 0) {
      return Semantics(
        button: true,
        label: 'Add ${item.name}',
        child: Material(
          color: accent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: ValueKey('add-${item.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: onAdd,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10), child: Text('ADD', style: _t(14, FontWeight.w800, color: _onAccent(accent)))),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: accent, width: 1.6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(key: ValueKey('minus-${item.id}'), tooltip: 'One less ${item.name}', visualDensity: VisualDensity.compact, onPressed: onRemove, icon: const Icon(Icons.remove_rounded, size: 18)),
        Text('$qty', key: ValueKey('qty-${item.id}'), style: _t(15, FontWeight.w800)),
        IconButton(key: ValueKey('plus-${item.id}'), tooltip: 'One more ${item.name}', visualDensity: VisualDensity.compact, onPressed: qty >= 20 ? null : onAdd, icon: const Icon(Icons.add_rounded, size: 18)),
      ]),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({required this.item, required this.accent, required this.qty, required this.onAdd, required this.onRemove, required this.onOpen});
  final GuestItem item;
  final Color accent;
  final int qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: ValueKey('row-${item.id}'),
          borderRadius: BorderRadius.circular(18),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              SizedBox(width: 72, height: 72, child: _Art(item: item, accent: accent, radius: 14)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [_VegMark(item.veg), const SizedBox(width: 6), if (item.recommended) Text("Chef's pick", style: _t(12, FontWeight.w700, color: _muted))]),
                  const SizedBox(height: 4),
                  Text(item.name, style: _t(16, FontWeight.w700)),
                  if (item.description != null) Text(item.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: _t(13, FontWeight.w400, color: _muted)),
                  const SizedBox(height: 4),
                  Text(guestMoney(item.price), style: _t(15, FontWeight.w700)),
                ]),
              ),
              const SizedBox(width: 8),
              _Stepper(item: item, qty: qty, accent: accent, onAdd: onAdd, onRemove: onRemove),
            ]),
          ),
        ),
      );
}

/// The swipe deck: one dish at a time. Right adds it, left skips it, up opens its details. The buttons underneath do the same, so the deck
/// also works without swiping (screen readers, a mouse).
class _Deck extends StatefulWidget {
  const _Deck({super.key, required this.items, required this.accent, required this.onAdd, required this.onDetails, required this.onList, required this.onRestart});
  final List<GuestItem> items;
  final Color accent;
  final ValueChanged<GuestItem> onAdd;
  final ValueChanged<GuestItem> onDetails;
  final VoidCallback onList;
  final VoidCallback onRestart;
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(widget.items.isEmpty ? 'No dishes to show.' : "You've seen every dish", style: _t(20, FontWeight.w800)),
            const SizedBox(height: 18),
            if (widget.items.isNotEmpty) _Pill('Start again', key: const ValueKey('deck-restart'), filled: false, onTap: widget.onRestart),
            const SizedBox(height: 10),
            _Pill('See the list', key: const ValueKey('deck-list'), accent: widget.accent, onTap: widget.onList),
          ]),
        ),
      );
    }
    final next = _i + 1 < widget.items.length ? widget.items[_i + 1] : null;
    final hint = _drag.dx > 40 ? 'ADD' : _drag.dx < -40 ? 'SKIP' : _drag.dy < -40 ? 'DETAILS' : null;
    return Column(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
          child: Stack(fit: StackFit.expand, children: [
            if (next != null) Transform.scale(scale: 0.94, child: Opacity(opacity: 0.6, child: _DeckCard(item: next, accent: widget.accent))),
            GestureDetector(
              key: const ValueKey('deck-card'),
              onPanUpdate: (d) => setState(() => _drag += d.delta),
              onPanEnd: _end,
              onTap: () => widget.onDetails(top),
              child: Transform.translate(
                offset: _drag,
                child: Transform.rotate(
                  angle: _drag.dx / 900,
                  child: Stack(fit: StackFit.expand, children: [
                    _DeckCard(item: top, accent: widget.accent, top: true),
                    if (hint != null)
                      Positioned(
                        top: 24,
                        left: hint == 'ADD' ? 24 : null,
                        right: hint == 'SKIP' ? 24 : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: hint == 'SKIP' ? _nonVeg : _veg, width: 2)),
                          child: Text(hint, style: _t(18, FontWeight.w900, color: hint == 'SKIP' ? _nonVeg : _veg)),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
      Text('Swipe right to add · left to skip · up for details', style: _t(12.5, FontWeight.w500, color: _muted)),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _Round(key: const ValueKey('deck-skip'), icon: Icons.close_rounded, label: 'Skip ${top.name}', color: _nonVeg, onTap: () => _next(added: false)),
          _Round(key: const ValueKey('deck-info'), icon: Icons.info_outline_rounded, label: 'Details of ${top.name}', color: _muted, small: true, onTap: () => widget.onDetails(top)),
          _Round(key: const ValueKey('deck-add'), icon: Icons.add_rounded, label: 'Add ${top.name}', color: _veg, onTap: () => _next(added: true)),
        ]),
      ),
    ]);
  }
}

class _Round extends StatelessWidget {
  const _Round({super.key, required this.icon, required this.label, required this.color, required this.onTap, this.small = false});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool small;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: Material(
          color: Colors.white,
          shape: CircleBorder(side: BorderSide(color: color.withValues(alpha: 0.35), width: 2)),
          child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: small ? 52 : 66, height: small ? 52 : 66, child: Icon(icon, size: small ? 24 : 32, color: color))),
        ),
      );
}

class _DeckCard extends StatelessWidget {
  const _DeckCard({required this.item, required this.accent, this.top = false});
  final GuestItem item;
  final Color accent;
  final bool top;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26), boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 24, offset: Offset(0, 10))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: Padding(padding: const EdgeInsets.all(10), child: _Art(item: item, accent: accent))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _VegMark(item.veg),
                const SizedBox(width: 8),
                if (item.recommended) Text("Chef's pick", style: _t(13, FontWeight.w700, color: _muted)),
                const Spacer(),
                Text(guestMoney(item.price), style: _t(20, FontWeight.w800)),
              ]),
              const SizedBox(height: 6),
              Text(item.name, key: top ? const ValueKey('deck-name') : null, style: _t(24, FontWeight.w800)),
              if (item.description != null) ...[
                const SizedBox(height: 4),
                Text(item.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: _t(14, FontWeight.w400, color: _muted, height: 1.35)),
              ],
            ]),
          ),
        ]),
      );
}

/// Dish details: photo, veg mark, description, tags, time to prepare, quantity, add.
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({required this.item, required this.accent, required this.inCart, required this.onAdd});
  final GuestItem item;
  final Color accent;
  final int inCart;
  final ValueChanged<int> onAdd;
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
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: _line, borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 14),
          SizedBox(height: 200, child: _Art(item: i, accent: widget.accent)),
          const SizedBox(height: 14),
          Row(children: [
            _VegMark(i.veg),
            const SizedBox(width: 8),
            Expanded(child: Text(i.name, style: _t(22, FontWeight.w800))),
            Text(guestMoney(i.price), style: _t(20, FontWeight.w800)),
          ]),
          if (i.description != null) ...[const SizedBox(height: 8), Text(i.description!, style: _t(15, FontWeight.w400, color: _muted, height: 1.4))],
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (i.prepMinutes > 0) _Tag('About ${i.prepMinutes} min'),
            if (i.recommended) const _Tag("Chef's pick"),
            for (final t in i.tags) _Tag(t),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            IconButton(key: const ValueKey('detail-minus'), tooltip: 'One less', onPressed: _n > 1 ? () => setState(() => _n--) : null, icon: const Icon(Icons.remove_circle_outline_rounded)),
            Text('$_n', key: const ValueKey('detail-qty'), style: _t(18, FontWeight.w800)),
            IconButton(key: const ValueKey('detail-plus'), tooltip: 'One more', onPressed: _n < room ? () => setState(() => _n++) : null, icon: const Icon(Icons.add_circle_outline_rounded)),
            const SizedBox(width: 10),
            Expanded(
              child: _Pill(room <= 0 ? '20 is the most' : 'Add · ${guestMoney(i.price * _n)}', key: const ValueKey('detail-add'), accent: widget.accent, onTap: room <= 0 ? null : () {
                widget.onAdd(_n);
                Navigator.of(context).pop();
              }),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: _t(12.5, FontWeight.w600, color: _muted)),
      );
}

/// "Your order": lines with quantities, a note, (on the web page) an optional first name, the estimate, Send.
class _OrderSheet extends StatefulWidget {
  const _OrderSheet({required this.app});
  final _GuestAppState app;
  @override
  State<_OrderSheet> createState() => _OrderSheetState();
}

class _OrderSheetState extends State<_OrderSheet> {
  final _note = TextEditingController();
  final _name = TextEditingController();
  String _key = GuestGateway.newKey();   // one tap = one key; a retry after a failure sends the same key
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
      if (mounted) Navigator.of(context).pop(r);
    } catch (e) {
      if (!mounted) return;
      if (e is GuestApiException && e.sessionEnded) {
        Navigator.of(context).pop();
        app._fail(e);
        return;
      }
      setState(() {
        _busy = false;
        _error = e is GuestApiException ? e.message : 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final accent = app._menu!.accent;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        key: const ValueKey('order-sheet'),
        padding: EdgeInsets.fromLTRB(20, 14, 20, 16 + inset),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: _line, borderRadius: BorderRadius.circular(4)))),
            const SizedBox(height: 14),
            Text('Your order', style: _t(22, FontWeight.w800)),
            Text('${app._menu!.tableWord} ${app._visit!.tableLabel}', style: _t(14, FontWeight.w500, color: _muted)),
            const SizedBox(height: 10),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final l in app._cart)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      _VegMark(l.item.veg),
                      const SizedBox(width: 8),
                      Expanded(child: Text(l.item.name, style: _t(15, FontWeight.w600))),
                      _Stepper(item: l.item, qty: l.qty, accent: accent, onAdd: () => setState(() => app.add(l.item)), onRemove: () => setState(() => app.remove(l.item))),
                      const SizedBox(width: 10),
                      SizedBox(width: 72, child: Text(guestMoney(l.item.price * l.qty), textAlign: TextAlign.right, style: _t(15, FontWeight.w700))),
                    ]),
                  ),
                const SizedBox(height: 8),
                if (app.g.waitsForStaff) ...[
                  TextField(key: const ValueKey('order-name'), controller: _name, maxLength: 40, decoration: const InputDecoration(labelText: 'Your first name (optional)', counterText: '')),
                  const SizedBox(height: 6),
                ],
                TextField(key: const ValueKey('order-note'), controller: _note, maxLength: 300, maxLines: 2, minLines: 1, decoration: const InputDecoration(labelText: 'A note for the kitchen (optional)', counterText: '')),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Text('Estimated total', style: _t(15, FontWeight.w500, color: _muted))),
              Text(guestMoney(app._total), key: const ValueKey('order-total'), style: _t(20, FontWeight.w800)),
            ]),
            Text('Taxes and charges are added on the bill. Pay at the table when you are done.', style: _t(12.5, FontWeight.w400, color: _muted)),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, key: const ValueKey('order-error'), style: _t(14, FontWeight.w600, color: _nonVeg))),
            const SizedBox(height: 14),
            _Pill(app.g.waitsForStaff ? 'Send to the restaurant' : 'Send to the kitchen', key: const ValueKey('send-order'), accent: accent, busy: _busy, onTap: app._cart.isEmpty ? null : _send),
          ]),
        ),
      ),
    );
  }
}

/// After sending: on the web page, each order of this visit and what the staff did with it (checked every few seconds); with Hand to guest,
/// the order number and "Back to staff".
class _SentView extends StatelessWidget {
  const _SentView({required this.app});
  final _GuestAppState app;

  (String, Color) _look(Facts r) => switch (r.s('status')) {
        'waiting' => ('Waiting for the staff to confirm', const Color(0xFFD97706)),
        'accepted' => ('${r.m('order').s('display_no')} · ${r.m('order').s('status_label')}', _veg),
        'declined' => ('Not accepted${r.so('decline_reason') == null ? '' : ': ${r.s('decline_reason')}'}', _nonVeg),
        _ => (r.s('status'), _muted),
      };

  @override
  Widget build(BuildContext context) {
    final accent = app._menu!.accent;
    final last = app._last;
    final staff = !app.g.waitsForStaff;
    final displayNo = last?.m('order').so('display_no');
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 24),
        Icon(Icons.check_circle_rounded, size: 64, color: accent),
        const SizedBox(height: 12),
        Text(staff ? 'Sent to the kitchen' : 'Sent to the restaurant', key: const ValueKey('sent-title'), textAlign: TextAlign.center, style: _t(24, FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          staff
              ? (displayNo == null ? 'The kitchen has your order.' : 'Order $displayNo is with the kitchen.')
              : 'A member of staff will confirm it in a moment. Pay at the table when you are done.',
          textAlign: TextAlign.center,
          style: _t(15, FontWeight.w400, color: _muted, height: 1.4),
        ),
        const SizedBox(height: 18),
        if (!staff)
          Expanded(
            child: ListView(children: [
              for (final r in app._requests)
                Container(
                  key: ValueKey('request-${r.s('id')}'),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _line)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_look(r).$1, style: _t(15, FontWeight.w700, color: _look(r).$2)),
                    const SizedBox(height: 4),
                    Text(r.l('lines').map((l) => '${l.n('qty').toInt()} × ${l.s('name')}').join(', '), style: _t(13.5, FontWeight.w400, color: _muted)),
                  ]),
                ),
            ]),
          )
        else
          const Spacer(),
        _Pill('Order more', key: const ValueKey('order-more'), accent: accent, onTap: app._orderMore),
        if (app.widget.onExit != null) ...[const SizedBox(height: 10), _Pill('Back to staff', key: const ValueKey('guest-exit'), filled: false, onTap: app.widget.onExit)],
      ]),
    );
  }
}
