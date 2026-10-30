import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../menu/menu_widgets.dart' show CanMakeLabel, FoodTypeMark;
import '../ui/mobile_input.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'dish_options_sheet.dart';
import 'guest_orders.dart';
import 'reserve_screen.dart';
import 'manage_tables_screen.dart';
import 'table_deck.dart';
import 'table_qr_screen.dart';
import 'table_order_screen.dart';
import 'table_widgets.dart';
import 'tables_api.dart' show TablesApi;
import 'take_order_screens.dart';

/// Figma "Tables" (screen-1-tables-grid) and its bottom sheet (screen-2-bottom-sheet): every table of the store with its state, filter chips,
/// a 2-column grid. Tap a free, reserved or cleaning table for the sheet; tap an occupied one for its actions.
/// With [pickFor] set the same grid is used to choose a destination table (transfer): a tap returns that table instead.
class FloorScreen extends StatefulWidget {
  const FloorScreen({super.key, required this.env, this.pickFor, this.pickTitle});
  final TablesEnv env;

  /// Table id being moved; it is not offered as a destination.
  final String? pickFor;
  final String? pickTitle;
  @override
  State<FloorScreen> createState() => _FloorScreenState();
}

class _FloorScreenState extends State<FloorScreen> {
  TablesEnv get env => widget.env;
  Facts? _d;
  String? _error;
  int _seq = 0;
  final _guests = GlobalKey<GuestOrdersPanelState>();

  // Ordering from the Bill (founder, 27 Oct 2026): the menu as squares, a chosen table, and a cart sent with the same call as Add dishes
  // (tbl_order_add: starts or extends the table's order; Send to kitchen makes a KOT, Hold keeps it on the table).
  Facts? _menu;
  String? _menuCat;
  String _menuQuery = ''; // the search beside the Menu title: dish name, any part, any case
  Facts? _orderTable;
  final _cart = <String, int>{};
  String? _key; // one per intent: kept while the cart does not change, so a retried tap is the same request
  bool _sending = false;

  // Dine in / Takeaway / Delivery pills (founder, 27 Oct 2026): Dine in orders for a chosen table; Takeaway and Delivery need no table
  // (pos_counter_order, migration 0604). Values are the database's service types.
  String _mode = 'dine_in';
  static const _modes = {'dine_in': 'Dine in', 'pickup': 'Takeaway', 'delivery': 'Delivery'};
  bool get _dineIn => _mode == 'dine_in';

  // Takeaway dishes on a dine-in bill (founder, 27 Oct 2026; migration 0606): with a table chosen, the Takeaway pill adds dishes to THAT
  // table's order, marked takeaway, so one bill holds both. A cart key is the dish id, then "#" and the size's id for a dish with sizes
  // (0611: Small / Medium / Large), then the add-ons and combos chosen in the pop-up (0624, "~…"), then "|takeaway" for a takeaway line.
  static const _ta = '|takeaway', _sz = '#';
  static String _bare(String k) => k.endsWith(_ta) ? k.substring(0, k.length - _ta.length) : k;
  static String _main(String k) => _bare(k).split('~').first;
  static String _dishOf(String k) => _main(k).split(_sz).first;
  static String? _sizeOf(String k) => _main(k).contains(_sz) ? _main(k).split(_sz).last : null;
  final _extras = <String, DishChoice>{}; // per cart line with add-ons or combos, what was chosen (0624)
  final _lastKey = <String, String>{}; // per dish, the cart line last added ('−' takes from it)

  /// The cart goes on the chosen table's order: Dine in, or Takeaway with a table chosen. Delivery is always its own order.
  bool get _onTable => _orderTable != null && _mode != 'delivery';
  String get _cartFor => _onTable ? 'Table ${_orderTable!.s('label')}' : _modes[_mode]!;
  bool get _showCart => _cart.isNotEmpty && (!_dineIn || _orderTable != null);
  int get _takeawayUnits => _cart.entries.where((e) => e.key.endsWith(_ta)).fold(0, (a, e) => a + e.value);
  int _qtyOf(String dish) => _cart.entries.where((e) => _dishOf(e.key) == dish).fold(0, (a, e) => a + e.value);

  /// A cart line's price: its size's, else the dish's.
  num _priceOf(String k) {
    final item = _menuItem(_dishOf(k));
    final size = _sizeOf(k);
    final v = size == null ? null : item?.l('variants').where((x) => x.s('id') == size).firstOrNull;
    return (v?.n('price') ?? item?.n('price') ?? 0) + (_extras[k]?.extra ?? 0);
  }

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.pickFor == null) _loadMenu();
  }

  Future<void> _loadMenu() async {
    try {
      final m = await env.api.menu();
      if (mounted) setState(() => _menu = m);
    } catch (_) {/* the menu block says so and offers a retry */}
  }

  List<Facts> get _menuItems => _menu?.l('items') ?? const [];
  Facts? _menuItem(String id) => _menuItems.where((i) => i.s('id') == id).firstOrNull;
  int get _cartUnits => _cart.values.fold(0, (a, b) => a + b);
  num get _cartTotal => _cart.entries.fold<num>(0, (a, e) => a + _priceOf(e.key) * e.value);

  /// All tables, three to a row; tapping one chooses it for the order. Null when closed without choosing.
  Future<Facts?> _chooseTable() => showModalBottomSheet<Facts>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (c) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
              const SizedBox(height: 14),
              Text('Choose a table', style: inter(22, 700)),
              Text('The dishes you add go on this table\'s order.', style: inter(13.5, 400, color: kMuted)),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: _tablesGrid(_d?.l('tables') ?? const [], onTap: (t) => Navigator.of(c).pop(t), withAddItems: false),
                ),
              ),
            ]),
          ),
        ),
      );

  Future<void> _pickOrderTable() async {
    final t = await _chooseTable();
    if (t == null || !mounted) return;
    setState(() {
      _orderTable = t;
      _key = null;
    });
  }

  /// A dish square tapped: one more of it in the cart. With no table chosen yet, first a reminder to choose one.
  Future<void> _addDish(Facts item) async {
    if (!item.b('available')) return showToast(context, '${item.s('name')} is out of stock.');
    if (_dineIn && _orderTable == null) {
      final choose = await showOlDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Choose a table first'),
          content: Text('Which table is ${item.s('name')} for? Choose the table, then the dish goes on its order.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(key: const ValueKey('reminder-choose-table'), onPressed: () => Navigator.pop(c, true), child: Text('Choose table', style: inter(14, 700))),
          ],
        ),
      );
      if (choose != true || !mounted) return;
      final t = await _chooseTable();
      if (t == null || !mounted) return;
      setState(() => _orderTable = t);
    }
    // a dish with add-ons or combos (0624): one pop-up with its size, add-ons and combos; a dish with only sizes (0611): Small / Medium / Large
    String? size;
    DishChoice? choice;
    final sizes = item.l('variants');
    if (dishHasExtras(item)) {
      choice = await showDishOptions(context, item);
      if (choice == null || !mounted) return;
      size = choice.variantId;
    } else if (sizes.isNotEmpty) {
      final v = await _pickSize(item, sizes);
      if (v == null || !mounted) return;
      size = v.s('id');
    }
    final k = '${item.s('id')}${size == null ? '' : '$_sz$size'}${choice?.signature ?? ''}${_mode == 'pickup' ? _ta : ''}';
    setState(() {
      if (choice != null && choice.hasExtras) _extras[k] = choice;
      _cart[k] = ((_cart[k] ?? 0) + 1).clamp(1, 99);
      _key = null;
      _lastKey[item.s('id')] = k;
    });
  }

  /// "Which size?": each size with its price, the default first-ticked. Null when closed.
  Future<Facts?> _pickSize(Facts item, List<Facts> sizes) => showModalBottomSheet<Facts>(
        context: context,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (c) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
              const SizedBox(height: 12),
              Text(item.s('name'), style: inter(20, 800)),
              Text('Choose a size', style: inter(13.5, 500, color: kMuted)),
              const SizedBox(height: 12),
              Row(children: [
                for (final (n, v) in sizes.indexed) ...[
                  if (n > 0) const SizedBox(width: 10),
                  Expanded(
                    child: Material(
                      color: v.b('is_default') ? kNote : Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: v.b('is_default') ? kLimeBtn : kLine, width: 1.5)),
                      child: InkWell(
                        key: ValueKey('size-${v.s('name')}'),
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => Navigator.of(c).pop(v),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Column(children: [
                            Icon(LucideIcons.cupSoda, size: 16.0 + 5 * n, color: kInk),
                            const SizedBox(height: 6),
                            Text(v.s('name'), style: inter(15, 800)),
                            Text(rupees(v.n('price')), style: inter(13.5, 600, color: kMuted)),
                            if (v.raw['can_make'] != null)
                              Text('${v.n('can_make').toInt()} can be made', key: ValueKey('size-can-make-${v.s('name')}'),
                                  style: inter(11, 600, color: v.n('can_make') == 0 ? const Color(0xFFB42318) : const Color(0xFF2E7D32))),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ],
              ]),
            ]),
          ),
        ),
      );

  /// − on a square: one off the line last added for that dish (its size, takeaway or not), else off any line of it.
  void _removeDish(String id) => setState(() {
        final keys = [for (final k in _cart.keys) if (_dishOf(k) == id) k];
        if (keys.isEmpty) return;
        final k = keys.contains(_lastKey[id]) ? _lastKey[id]! : keys.last;
        final q = (_cart[k] ?? 0) - 1;
        if (q <= 0) {
          _cart.remove(k);
          _extras.remove(k);
        } else {
          _cart[k] = q;
        }
        _key = null;
      });

  /// Delivery: the customer's name, phone and address before the order is placed. Null when cancelled.
  Map<String, String>? _delivery;
  Future<Map<String, String>?> _askDelivery() {
    final name = TextEditingController(text: _delivery?['name']);
    final phone = TextEditingController(text: _delivery?['phone']);
    final address = TextEditingController(text: _delivery?['address']);
    String? problem;
    return showOlDialog<Map<String, String>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Deliver to'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(key: const ValueKey('delivery-name'), controller: name, decoration: const InputDecoration(labelText: 'Customer name')),
              TextField(key: const ValueKey('delivery-phone'), controller: phone, keyboardType: TextInputType.phone, inputFormatters: mobileFormatters, decoration: const InputDecoration(labelText: 'Mobile number', prefixText: kMobilePrefix)),
              TextField(key: const ValueKey('delivery-address'), controller: address, maxLines: 2, decoration: const InputDecoration(labelText: 'Address')),
              if (problem != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(problem!, style: inter(13, 500, color: kRedText))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton(
              key: const ValueKey('delivery-confirm'),
              onPressed: () {
                if (phone.text.replaceAll(RegExp(r'\D'), '').length < 10) return set(() => problem = 'Enter the customer\'s 10-digit phone number.');
                if (address.text.trim().isEmpty) return set(() => problem = 'Enter the delivery address.');
                Navigator.pop(c, {'name': name.text.trim(), 'phone': phone.text.trim(), 'address': address.text.trim()});
              },
              child: Text('Continue', style: inter(14, 700)),
            ),
          ],
        ),
      ),
    );
  }

  /// Send to kitchen (a KOT) or Hold. Dine in: the same call as Add dishes, for the chosen table; Takeaway / Delivery: an order without a table.
  Future<void> _sendCart(bool send) async {
    final t = _orderTable;
    if (_cart.isEmpty || (_dineIn && t == null)) return;
    final onTable = _onTable;
    if (_mode == 'delivery') {
      final d = await _askDelivery();
      if (d == null || !mounted) return;
      _delivery = d;
    }
    final key = _key ??= TablesApi.newKey();
    final label = _cartFor;
    final lines = [
      for (final e in _cart.entries)
        {
          'menu_item_id': _dishOf(e.key), 'qty': e.value, if (_sizeOf(e.key) != null) 'variant_id': _sizeOf(e.key), if (onTable && e.key.endsWith(_ta)) 'takeaway': true,
          ...?_extras[e.key]?.lineFields,
        },
    ];
    setState(() => _sending = true);
    try {
      final r = onTable
          ? await env.api.addDishes(t!.s('id'), lines, send: send, key: key)
          : await env.api.counterOrder(_mode, lines,
              send: send, key: key, name: _delivery?['name'], phone: _delivery?['phone'], address: _delivery?['address']);
      if (!mounted) return;
      if (!onTable) _delivery = null;
      setState(() {
        _cart.clear();
        _extras.clear();
        _key = null;
        _sending = false;
      });
      if (send) _loadMenu(); // the dishes sent took their ingredients off stock: "can be made" counts go down
      final kot = r.mo('kot');
      final no = r.mo('order')?.so('display_no');
      final shown = onTable || no == null ? label : '$label $no';
      if (send && kot != null) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SentToKitchenScreen(env: env, tableLabel: shown, kot: kot)));
      } else {
        showToast(context, onTable ? 'Saved on $label. Send to the kitchen when ready.' : '$shown saved. Send it to the kitchen from Orders.');
      }
      if (mounted) _load();
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showToast(context, sayError(e));
      }
    }
  }

  Future<void> _load() async {
    final mine = ++_seq;
    _guests.currentState?.reload();
    try {
      final d = await env.api.floor(); // every table: the floor has no status filter (founder, 27 Oct 2026)
      if (!mounted || mine != _seq) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = sayError(e));
    }
  }

  /// Manage tables (add, rename, seats, remove); the floor reloads when it closes.
  Future<void> _manage() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ManageTablesScreen(env: env)));
    if (mounted) _load();
  }

  /// "+ Add items" on a table that already ordered: the menu for that table (Add dishes), the same screen as Add Items on its order;
  /// the new dishes go on the same order as a new KOT. The floor reloads after.
  Future<void> _addItems(Facts t) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddDishesScreen(env: env, tableId: t.s('id'), tableLabel: 'Table ${t.s('label')}')));
    if (mounted) _load();
  }

  Future<void> _tap(Facts t) async {
    if (widget.pickFor != null) {
      if (t.s('id') == widget.pickFor) return showToast(context, 'Choose a different table.');
      if (t.mo('merge') != null) return showToast(context, '${t.s('label')} is joined to other tables. Choose another table.');
      Navigator.of(context).pop(t);
      return;
    }
    if (t.s('status') == 'occupied') {
      // A table with a running order opens that order straight away (founder, 2026-10-20): items, kitchen status,
      // Add Items, Send KOT, Change/Merge Table, Generate Bill. A free table opens the sheet with Start New Order.
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TableOrderScreen(env: env, tableId: t.s('id'))));
    } else {
      await showTableSheet(context, env, t, storeNow: _storeNow());
    }
    if (mounted) _load();
  }

  /// The store's wall clock now (the server's local_today + local_time), so "Today" and the default time follow the store's zone, not the phone's.
  DateTime Function()? _storeNow() {
    final today = _d?.so('local_today'), hm = _d?.so('local_time');
    final base = today == null || hm == null ? null : DateTime.tryParse('${today}T$hm:00');
    if (base == null) return null;
    final at = DateTime.now();
    return () => base.add(DateTime.now().difference(at));
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final tables = d?.l('tables') ?? const <Facts>[];
    return TablesPage(
      env: env,
      title: widget.pickFor != null ? (widget.pickTitle ?? 'Choose table') : 'Tables',
      back: widget.pickFor != null,
      onRefresh: _load,
      // the cart of the chosen table (when it has dishes), then the floating table bars above the bottom bar (the till's "Current Cart"
      // look, one colour per table); neither while picking a table
      footer: widget.pickFor != null
          ? null
          : Column(mainAxisSize: MainAxisSize.min, children: [
              if (_showCart) _cartBar(),
              if (tables.isNotEmpty) TableDeck(key: const ValueKey('table-deck'), tables: tables, onOpen: _tap),
            ]),
      children: [
        if (widget.pickFor == null) ...[
          Padding(padding: const EdgeInsets.only(bottom: 12), child: _modePills()),
          // Ready to serve and Tables side by side (founder, 27 Oct 2026). "Tables": every table lives behind it; choosing one sets the table
          // the menu below orders for. Takeaway: optional, to put the takeaway dishes on a dining table's bill; Delivery: never on a table.
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              Expanded(
                child: OutlineButtonT('Ready to serve', key: const ValueKey('open-ready-to-serve'), icon: LucideIcons.chefHat, height: 52, onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReadyToServeScreen(env: env)));
                  if (mounted) _load();
                }),
              ),
              if (tables.isNotEmpty && _mode != 'delivery') ...[
                const SizedBox(width: 10),
                Expanded(child: _tablesButton()),
              ],
            ]),
          ),
          // guest orders from the table QR codes (0560, 0561); the codes and Manage tables are in the ⋮ beside the pills
          GuestOrdersPanel(key: _guests, env: env, onChanged: _load),
        ],
        if (_d == null && _error == null) tablesLoading(),
        if (_d == null && _error != null) TablesError(_error!, onRetry: _load),
        if (d != null && tables.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(children: [
              Text('No tables set up for this store yet.', textAlign: TextAlign.center, style: inter(15, 400, color: kMuted)),
              if (widget.pickFor == null) ...[
                const SizedBox(height: 14),
                LimeButton('Add tables', key: const ValueKey('floor-add-tables'), icon: LucideIcons.plus, height: 46, onPressed: _manage),
              ],
            ]),
          ),
        // picking a table (move / merge): the tables themselves; the Bill: the menu as squares (the tables are behind "Tables")
        if (tables.isNotEmpty && widget.pickFor != null) _tablesGrid(tables, onTap: _tap, withAddItems: false),
        if (widget.pickFor == null && tables.isNotEmpty) _menuBlock(),
      ],
    );
  }

  /// Three tables to a row (founder, 27 Oct 2026). With [withAddItems], a table that already ordered shows "+ Add items" (more dishes on
  /// its order); when any does, every card is that tall so the rows stay even.
  Widget _tablesGrid(List<Facts> tables, {required ValueChanged<Facts> onTap, required bool withAddItems}) => LayoutBuilder(builder: (context, box) {
        const gap = 10.0;
        final w = (box.maxWidth - 2 * gap) / 3;
        bool canAdd(Facts t) => withAddItems && t.s('status') == 'occupied';
        final h = tables.any(canAdd) ? 150.0 : 112.0;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          // the tables build in one after another (lib/ui/motion.dart)
          for (final (i, t) in tables.indexed)
            Entrance(
              key: ValueKey('floor-in-${t.s('id')}'),
              index: i,
              child: SizedBox(
                width: w,
                child: TableCard(
                  table: t,
                  compact: true,
                  height: h,
                  selected: _orderTable?.s('id') == t.s('id') && widget.pickFor == null,
                  onTap: () => onTap(t),
                  onAddItems: canAdd(t) ? () => _addItems(t) : null,
                ),
              ),
            ),
        ]);
      });

  /// The menu on the Bill: category pills, then the dishes as squares, three to a row; a tap adds one to the chosen table's cart.
  Widget _menuBlock() {
    final m = _menu;
    if (m == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: TextButton(key: const ValueKey('menu-retry'), onPressed: _loadMenu, child: Text('Loading the menu… tap to retry', style: inter(14, 500, color: kMuted)))),
      );
    }
    final cats = (m.raw['categories'] as List? ?? const []).map((e) => e.toString()).toList();
    final q = _menuQuery.trim().toLowerCase();
    final shown = _menuItems.where((i) => (_menuCat == null || i.s('category') == _menuCat) && (q.isEmpty || i.s('name').toLowerCase().contains(q))).toList();
    Widget pill(String? c, String label) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: InkWell(
            key: ValueKey('bill-cat-${c ?? 'all'}'),
            borderRadius: BorderRadius.circular(999),
            onTap: () => setState(() => _menuCat = c),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(color: _menuCat == c ? kLimeBtn : Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: _menuCat == c ? kLimeBtn : kLine)),
              child: Text(label, style: inter(13, _menuCat == c ? 700 : 500, color: _menuCat == c ? kInk : kMuted)),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // "Menu" and its search on one row, under Table QR codes and Manage tables
      Row(children: [
        Text('Menu', style: inter(18, 700)),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 42,
            child: TextField(
              key: const ValueKey('bill-menu-search'),
              onChanged: (v) => setState(() => _menuQuery = v),
              textInputAction: TextInputAction.search,
              style: inter(14.5, 500),
              decoration: InputDecoration(
                hintText: 'Search menu',
                hintStyle: inter(14, 400, color: kMuted),
                prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: const BorderSide(color: kLine)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: const BorderSide(color: kLine)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: const BorderSide(color: kLimeBtn, width: 1.5)),
              ),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [pill(null, 'All'), for (final c in cats) pill(c, c)])),
      const SizedBox(height: 12),
      if (shown.isEmpty)
        Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(q.isEmpty ? 'No dishes here yet.' : 'No dish matches "${_menuQuery.trim()}".', key: const ValueKey('bill-menu-none'), style: inter(14, 500, color: kMuted))))
      else
        LayoutBuilder(builder: (context, box) {
          const gap = 10.0;
          final w = (box.maxWidth - 2 * gap) / 3;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            // the dishes build in one after another; a new category builds in again (lib/ui/motion.dart)
            for (final (n, i) in shown.indexed)
              Entrance(
                key: ValueKey('dish-in-$_menuCat-${i.s('id')}'),
                index: n,
                child: SizedBox(width: w, child: _DishSquare(item: i, qty: _qtyOf(i.s('id')), onAdd: () => _addDish(i), onRemove: () => _removeDish(i.s('id')))),
              ),
          ]);
        }),
    ]);
  }

  /// The right half of the Ready to serve row: "Choose table" (Dine in) or "Add to a table" (Takeaway); once chosen, the table with
  /// its own actions (open it, clear it). Tapping it chooses another table.
  Widget _tablesButton() {
    final t = _orderTable;
    if (t == null) {
      return _dineIn
          ? LimeButton('Choose table', key: const ValueKey('open-tables'), icon: LucideIcons.layoutGrid, height: 52, onPressed: _pickOrderTable)
          : OutlineButtonT('Add to a table', key: const ValueKey('open-tables'), icon: LucideIcons.layoutGrid, height: 52, onPressed: _pickOrderTable);
    }
    return Material(
      color: kNote,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: kLimeBtn, width: 1.5)),
      child: InkWell(
        key: const ValueKey('open-tables'),
        borderRadius: BorderRadius.circular(14),
        onTap: _pickOrderTable,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(children: [
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Table ${t.s('label')}', key: const ValueKey('order-table'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15.5, 700)),
                  Text(_dineIn ? '${pax(t.n('seats'))} · change' : 'Takeaway on its bill',
                      key: const ValueKey('order-table-sub'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
                ]),
              ),
              // the table's own actions (its order, reserve, history, mark as clean), for any table, not just the 5 bars
              IconButton(
                key: const ValueKey('open-order-table'),
                tooltip: 'Open table ${t.s('label')}',
                visualDensity: VisualDensity.compact,
                onPressed: () => _tap((_d?.l('tables') ?? const <Facts>[]).where((x) => x.s('id') == t.s('id')).firstOrNull ?? t),
                icon: const Icon(LucideIcons.squareArrowOutUpRight, size: 18, color: kInk),
              ),
              IconButton(
                key: const ValueKey('clear-order-table'),
                tooltip: 'Clear table and cart',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  _orderTable = null;
                  _cart.clear();
                  _extras.clear();
                  _key = null;
                }),
                icon: const Icon(LucideIcons.x, size: 18, color: kMuted),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Dine in / Takeaway / Delivery, above Ready to serve. Switching keeps the cart.
  Widget _modePills() => Row(children: [
        for (final m in _modes.entries)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: m.key == 'delivery' ? 0 : 8),
              child: Material(
                color: _mode == m.key ? kLimeBtn : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999), side: BorderSide(color: _mode == m.key ? kLimeBtn : kLine)),
                child: InkWell(
                  key: ValueKey('mode-${m.key}'),
                  customBorder: const StadiumBorder(),
                  onTap: () => setState(() {
                    _mode = m.key;
                    _key = null;
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(switch (m.key) { 'pickup' => LucideIcons.shoppingBag, 'delivery' => LucideIcons.bike, _ => LucideIcons.utensils }, size: 16, color: kInk),
                      const SizedBox(width: 6),
                      Flexible(child: Text(m.value, overflow: TextOverflow.ellipsis, style: inter(13.5, _mode == m.key ? 700 : 500))),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        // set-up, not every-order work: the table QR codes and Manage tables (add, rename, re-seat, remove; 0602) behind a ⋮
        if (widget.pickFor == null) ...[
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            key: const ValueKey('floor-more'),
            tooltip: 'Tables and QR codes',
            icon: const Icon(LucideIcons.ellipsisVertical, size: 20, color: kInk),
            onSelected: (v) async {
              if (v == 'qr') {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TableQrScreen(env: env)));
                if (mounted) _load();
              } else {
                await _manage();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(key: const ValueKey('open-qr'), value: 'qr', child: Row(children: [const Icon(LucideIcons.qrCode, size: 18), const SizedBox(width: 10), Text('Table QR codes', style: inter(14, 500))])),
              PopupMenuItem(key: const ValueKey('open-manage-tables'), value: 'manage', child: Row(children: [const Icon(LucideIcons.layoutGrid, size: 18), const SizedBox(width: 10), Text('Manage tables', style: inter(14, 500))])),
            ],
          ),
        ],
      ]);

  /// "Table T3 · 3 items · ₹420", Send to kitchen and Hold, above the floating table bars.
  Widget _cartBar() => Container(
        key: const ValueKey('bill-cart'),
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kLine),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 2))],
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('$_cartFor · $_cartUnits item${_cartUnits == 1 ? '' : 's'}${_onTable && _takeawayUnits > 0 ? ' · $_takeawayUnits takeaway' : ''}',
                  key: const ValueKey('bill-cart-for'), style: inter(14, 700)),
              Text(rupees(_cartTotal), key: const ValueKey('bill-cart-total'), style: inter(16, 800, color: kLink)),
            ]),
          ),
          SizedBox(
            width: 70,
            child: OutlineButtonT('Hold', key: const ValueKey('bill-hold'), height: 42, onPressed: _sending ? null : () => _sendCart(false)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: LimeButton('Send to kitchen', key: const ValueKey('bill-send'), height: 42, busy: _sending, onPressed: () => _sendCart(true)),
          ),
        ]),
      );
}

/// One dish as a square: photo (or a tinted tile), name, price; the count once it is in the cart, with − to take one off.
class _DishSquare extends StatelessWidget {
  const _DishSquare({required this.item, required this.qty, required this.onAdd, required this.onRemove});
  final Facts item;
  final int qty;
  final VoidCallback onAdd, onRemove;
  static const _tints = [Color(0xFFE3F1FC), Color(0xFFFDF0DC), Color(0xFFFBF3D0), Color(0xFFFCE9E7), Color(0xFFE9F2FB), Color(0xFFFFF7D6)];
  @override
  Widget build(BuildContext context) {
    final name = item.s('name');
    final available = item.b('available');
    final img = item.so('image_url');
    return Opacity(
      opacity: available ? 1 : 0.45,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: qty > 0 ? kLimeBtn : kLine, width: qty > 0 ? 2 : 1)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('dish-square-$name'),
          onTap: onAdd,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AspectRatio(
              aspectRatio: 1.25,
              child: Stack(fit: StackFit.expand, children: [
                Container(
                  color: _tints[(name.isEmpty ? 0 : name.codeUnitAt(0)) % _tints.length],
                  child: img != null && img.isNotEmpty
                      ? Image.network(img, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.utensils, color: kMuted))
                      : const Icon(LucideIcons.utensils, color: kMuted),
                ),
                // veg / non-veg / egg sticker (the square-with-dot of Indian menus)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Semantics(
                    label: switch (item.so('food_type')) { 'non_veg' => 'Non-vegetarian', 'egg' => 'Contains egg', _ => 'Vegetarian' },
                    child: Container(
                      key: ValueKey('dish-food-$name'),
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(5)),
                      child: FoodTypeMark(item.so('food_type') ?? 'veg'),
                    ),
                  ),
                ),
                if (qty > 0)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      key: ValueKey('dish-qty-$name'),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(999)),
                      child: Text('$qty', style: inter(13, 800, color: Colors.white)),
                    ),
                  ),
                if (qty > 0)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: Material(
                      color: Colors.white,
                      shape: const CircleBorder(),
                      child: InkWell(
                        key: ValueKey('dish-minus-$name'),
                        customBorder: const CircleBorder(),
                        onTap: onRemove,
                        child: const Padding(padding: EdgeInsets.all(4), child: Icon(LucideIcons.minus, size: 16, color: kInk)),
                      ),
                    ),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(13, 600, height: 1.2)),
                const SizedBox(height: 2),
                // a dish with sizes (0611): its lowest price and how many sizes, short enough to read on a tile; the sizes and what each
                // costs show in the size picker on a tap
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: !available
                          ? 'Out of stock'
                          : rupees(item.l('variants').isEmpty ? item.n('price') : item.l('variants').map((v) => v.n('price')).reduce((a, b) => a < b ? a : b)),
                      style: inter(13, 700, color: available ? kInk : kRedText),
                    ),
                    if (available && item.l('variants').isNotEmpty) TextSpan(text: ' · ${item.l('variants').length} sizes', style: inter(11.5, 500, color: kMuted)),
                  ]),
                  key: ValueKey('dish-price-$name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // how many can be made: of the smallest size for a dish with sizes (Medium uses the recipe twice, Large three times; 0612)
                CanMakeLabel(
                  key: ValueKey('dish-can-make-$name'),
                  hasRecipe: item.raw['has_recipe'] == true,
                  count: item.l('variants').isNotEmpty && item.raw['can_make'] != null
                      ? item.l('variants').first.n('can_make').toInt()
                      : (item.raw['can_make'] as num?)?.toInt(),
                  size: 11.5,
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The bottom sheet of a table that is not occupied: "Table T4 / 4 Pax • Available", Start New Order, Reserve Table, View History.
Future<void> showTableSheet(BuildContext context, TablesEnv env, Facts t, {DateTime Function()? storeNow}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => _TableSheet(env: env, table: t, storeNow: storeNow),
  );
}

class _TableSheet extends StatefulWidget {
  const _TableSheet({required this.env, required this.table, this.storeNow});
  final TablesEnv env;
  final Facts table;
  final DateTime Function()? storeNow;
  @override
  State<_TableSheet> createState() => _TableSheetState();
}

class _TableSheetState extends State<_TableSheet> {
  Facts? _v;
  String? _error;
  bool _cleaning = false;

  /// "Mark as clean" (0603): the table is Available at once instead of after its 10 Cleaning minutes; the floor reloads on close.
  Future<void> _markClean(String label) async {
    setState(() => _cleaning = true);
    try {
      await widget.env.api.markClean(widget.table.s('id'));
      if (!mounted) return;
      showToast(context, 'Table $label is available.');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = sayError(e);
          _cleaning = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await widget.env.api.view(widget.table.s('id'));
      if (mounted) setState(() => _v = v);
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final t = v?.m('table');
    final status = v?.s('status') ?? widget.table.s('status');
    final (word, _, _, color) = tableLook(status);
    final allowed = v?.ls('allowed') ?? const <String>[];
    final label = t?.s('label') ?? widget.table.s('label');
    final seats = t?.n('seats') ?? widget.table.n('seats');
    final nav = Navigator.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Table $label', style: inter(26, 700)),
                const SizedBox(height: 6),
                Row(children: [
                  Container(width: 18, height: 18, decoration: BoxDecoration(color: status == 'available' ? kTableDot : color, shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Text('${pax(seats)} • ${word[0]}${word.substring(1).toLowerCase()}', style: inter(18, 500, color: color)),
                ]),
              ]),
            ),
            Semantics(
              button: true,
              label: 'Close',
              child: InkWell(
                key: const ValueKey('sheet-close'),
                borderRadius: BorderRadius.circular(20),
                onTap: () => nav.pop(),
                child: Container(width: 44, height: 44, decoration: const BoxDecoration(color: kGreyBg, shape: BoxShape.circle), child: const Icon(LucideIcons.x, size: 20, color: kMuted)),
              ),
            ),
          ]),
          const Divider(height: 28, color: kLine),
          if (_v == null && _error == null) Padding(padding: const EdgeInsets.all(20), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: kInk)))),
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_error!, style: inter(14, 400, color: kRedText))),
          if (status == 'cleaning') ...[
            LimeButton('Mark as clean', key: const ValueKey('sheet-mark-clean'), icon: LucideIcons.sparkles, height: 56, busy: _cleaning, onPressed: () => _markClean(label)),
            const SizedBox(height: 6),
            Text('Cleared and reset? It shows Available right away. Otherwise it does by itself 10 minutes after the bill.',
                textAlign: TextAlign.center, style: inter(13, 400, color: kMuted, height: 1.35)),
            const SizedBox(height: 12),
          ],
          if (allowed.contains('start_order')) ...[
            LimeButton('Start New Order', icon: LucideIcons.shoppingCart, height: 56, onPressed: () {
              nav.pop();
              final start = widget.env.onStartOrder;
              final t = v!.m('table');
              if (start == null) {
                // founder-approved flow (2026-10-20): Start New Order opens Add dishes for this table
                nav.push(MaterialPageRoute(builder: (_) => AddDishesScreen(env: widget.env, tableId: t.s('id'), tableLabel: 'Table ${t.s('label')}')));
              } else {
                start(context, t);
              }
            }),
            const SizedBox(height: 12),
          ],
          if (allowed.contains('start_order')) ...[
            OutlineButtonT('Hand to guest', key: const ValueKey('sheet-hand-to-guest'), icon: LucideIcons.smartphone, dark: true, height: 56, onPressed: () {
              nav.pop();
              nav.push(GuestHostScreen.route(widget.env, widget.table.s('id')));
            }),
            const SizedBox(height: 12),
          ],
          if (allowed.contains('reserve')) ...[
            OutlineButtonT('Reserve Table', icon: LucideIcons.calendar, dark: true, height: 56, onPressed: () async {
              nav.pop();
              await nav.push(MaterialPageRoute(builder: (_) => ReserveScreen(env: widget.env, table: v!.m('table'), now: widget.storeNow)));
            }),
          ],
          if (allowed.contains('history'))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton(
                key: const ValueKey('sheet-history'),
                onPressed: () {
                  nav.pop();
                  showHistorySheet(context, widget.env, widget.table.s('id'), label);
                },
                child: Text('View History', style: inter(17, 500, color: kMuted).copyWith(decoration: TextDecoration.underline)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// "View History": orders and reservations of one table, newest first.
Future<void> showHistorySheet(BuildContext context, TablesEnv env, String tableId, String label) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: FutureBuilder<List<Facts>>(
            future: env.api.history(tableId),
            builder: (ctx, snap) {
              final rows = snap.data;
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Table $label history', style: inter(20, 700)),
                const SizedBox(height: 10),
                if (snap.hasError) Text(sayError(snap.error!), style: inter(14, 400, color: kRedText)),
                if (rows == null && !snap.hasError) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: kInk))),
                if (rows != null && rows.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text('Nothing recorded for this table yet.', style: inter(14, 400, color: kMuted))),
                if (rows != null && rows.isNotEmpty)
                  Flexible(
                    child: ListView(shrinkWrap: true, children: [
                      for (final r in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Icon(r.s('kind') == 'order' ? LucideIcons.receiptText : LucideIcons.calendar, size: 18, color: kMuted),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(r.s('title'), style: inter(15, 600)),
                                Text('${r.t('when') == null ? '' : '${stamp(r.t('when')!)} · '}${r.s('detail')} · ${r.s('status').replaceAll('_', ' ')}', style: inter(12.5, 400, color: kMuted)),
                              ]),
                            ),
                          ]),
                        ),
                    ]),
                  ),
              ]);
            },
          ),
        ),
      ),
    ),
  );
}
