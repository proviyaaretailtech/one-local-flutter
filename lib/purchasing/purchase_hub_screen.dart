import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../catalogue/catalogue_api.dart';
import '../catalogue/grn_screens.dart';
import '../catalogue/item_parts.dart';
import '../inventory/inventory_api.dart';
import '../stock/stock_env.dart';
import '../stock/stock_kit.dart';
import '../ui/theme.dart';
import 'po_create_screen.dart';
import 'po_grn_screen.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart';

/// Item → Purchase (founder, 25 Oct 2026; "keep it minimal"): what needs doing first (buy again, deliveries due, invoices to match,
/// waiting for approval), then the purchase orders and the suppliers. Every card opens its job in one tap; the order, receiving and
/// matching screens are the existing ones.
class PurchaseHubScreen extends StatefulWidget {
  const PurchaseHubScreen({super.key, required this.env, required this.stock, CatalogueApi? catalogue}) : _catalogue = catalogue;
  final PurEnv env;
  final StockEnv stock;
  final CatalogueApi? _catalogue;
  @override
  State<PurchaseHubScreen> createState() => _PurchaseHubScreenState();
}

class _PurchaseHubScreenState extends State<PurchaseHubScreen> {
  PurEnv get env => widget.env;
  late final CatalogueApi _grn = widget._catalogue ?? widget.stock.catalogue;

  // the "To do" counts: null while loading or when that source could not be read (the card then shows no number)
  int? _buyAgain;
  List<PurchaseOrder>? _due, _waiting;
  List<GrnQueueRow>? _toMatch, _receiptsWaiting;

  // the purchase orders list
  String _chip = 'open';
  List<PurchaseOrder>? _orders;
  String? _ordersError;

  // suppliers
  List<Facts>? _suppliers;
  List<Facts> _prices = const [];
  String? _suppliersError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async => Future.wait([_loadTodo(), _loadOrders(), _loadSuppliers()]);

  Future<void> _loadTodo() async {
    Future<T?> safe<T>(Future<T> f) async {
      try {
        return await f;
      } catch (_) {
        return null;
      }
    }

    final dash = await safe(widget.stock.api.dashboard());
    final open = await safe(env.api.orders(status: 'open', limit: 50));
    final pending = await safe(env.api.orders(status: 'pending', limit: 50));
    final queue = await safe(_grn.grnQueue());
    if (!mounted) return;
    setState(() {
      _buyAgain = dash?.l('replenishment').length;
      _due = open?.l('orders').map((f) => PurchaseOrder(f.raw)).toList();
      _waiting = pending?.l('orders').map((f) => PurchaseOrder(f.raw)).where((o) => o.status == 'Pending').toList();
      _toMatch = queue?.where((r) => r.reviewStatus != 'approved' && r.reviewStatus != 'cancelled' && r.reviewStatus != 'approval_due').toList();
      _receiptsWaiting = queue?.where((r) => r.reviewStatus == 'approval_due').toList();
    });
  }

  static const _chips = [('open', 'Open'), ('due', 'Due'), ('pending', 'Waiting'), ('received', 'Received')];

  Future<void> _loadOrders() async {
    try {
      final d = _chip == 'due' ? await env.api.orders(due: 'overdue') : await env.api.orders(status: _chip);
      if (!mounted) return;
      setState(() {
        _orders = d.l('orders').map((f) => PurchaseOrder(f.raw)).toList();
        _ordersError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _ordersError = e is PartnerApiException ? e.message : 'Could not load purchase orders.');
    }
  }

  Future<void> _loadSuppliers() async {
    try {
      final list = await env.api.suppliers();
      List<Facts> prices = const [];
      try {
        prices = (await env.api.options()).l('prices');
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _suppliers = list;
        _prices = prices;
        _suppliersError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _suppliersError = e is PartnerApiException ? e.message : 'Could not load suppliers.');
    }
  }

  void _setChip(String c) {
    setState(() {
      _chip = c;
      _orders = null;
    });
    _loadOrders();
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  void _receive() {
    final open = widget.stock.onOpenReceiving;
    if (open == null) return showToast(context, 'Receiving is not available here.');
    open(context);
  }

  Future<void> _openOrder(PurchaseOrder po) => _push(PoGrnScreen(env: env, orderId: po.id));
  Future<void> _newOrder() => _push(PoCreateScreen(env: env));

  // ---------------------------------------------------------------- to do
  void _deliveries() {
    final d = _due ?? const [];
    if (d.length == 1) {
      _openOrder(d.single);
    } else {
      _setChip('open');
    }
  }

  void _invoices() {
    final m = _toMatch ?? const [];
    if (m.length == 1) {
      _push(GrnDashboardScreen(receiptId: m.single.receiptId, api: _grn));
    } else {
      _push(GrnQueueScreen(api: _grn, onReceive: widget.stock.onOpenReceiving));
    }
  }

  void _approvals() {
    final w = _waiting ?? const [], r = _receiptsWaiting ?? const [];
    if (w.isEmpty && r.length == 1) {
      _push(GrnDashboardScreen(receiptId: r.single.receiptId, api: _grn));
    } else if (w.isEmpty && r.isNotEmpty) {
      _push(GrnQueueScreen(api: _grn, onReceive: widget.stock.onOpenReceiving));
    } else {
      _setChip('pending');
    }
  }

  Widget _todo() {
    final waiting = _waiting == null && _receiptsWaiting == null ? null : (_waiting?.length ?? 0) + (_receiptsWaiting?.length ?? 0);
    final cards = [
      ('todo-buy', LucideIcons.shoppingCart, 'Buy again', 'products running low', _buyAgain, () => widget.stock.open(context, StockPage.reorder)),
      ('todo-due', LucideIcons.truck, 'Deliveries due', 'orders to receive', _due?.length, _deliveries),
      ('todo-match', LucideIcons.fileCheck, 'Invoices to match', 'deliveries to check', _toMatch?.length, _invoices),
      ('todo-approve', LucideIcons.badgeCheck, 'Waiting for approval', 'orders and deliveries', waiting, _approvals),
    ];
    return LayoutBuilder(builder: (_, c) {
      final w = (c.maxWidth - 10) / 2;
      return Wrap(spacing: 10, runSpacing: 10, children: [
        for (final (key, icon, title, line, n, onTap) in cards)
          SizedBox(
            width: w,
            child: Material(
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: (n ?? 0) > 0 ? kLimeH : kCardLine)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey(key),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(icon, size: 18, color: kInk),
                      const Spacer(),
                      Text(n == null ? '' : '$n', style: inter(20, 800, color: (n ?? 0) > 0 ? kInk : kMuted)),
                    ]),
                    const SizedBox(height: 6),
                    Text(title, style: inter(14, 700)),
                    Text(line, style: inter(11.5, 400, color: kMuted)),
                  ]),
                ),
              ),
            ),
          ),
      ]);
    });
  }

  // ---------------------------------------------------------------- orders
  Widget _orderRow(PurchaseOrder po) {
    final total = po.totals.no('total_minor') ?? po.totals.no('estimated_minor');
    final expected = po.t('expected_delivery');
    return InvCard(
      key: ValueKey('po-${po.id}'),
      onTap: () => _openOrder(po),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${po.number} · ${po.supplierName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700)),
            Text(
              [if (total != null) money(total), if (expected != null) '${po.overdue ? 'overdue · ' : ''}expected ${dayMonth(expected)}'].join(' · '),
              style: inter(12.5, 400, color: po.overdue ? kRedText : kMuted),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        StockStatusChip(_tone(po.status), label: _statusWord(po.status)),
      ]),
    );
  }

  static String _tone(String s) => switch (s) {
        'Received' => 'healthy',
        'Pending' || 'Draft' || 'Partially Received' => 'low',
        'Cancelled' => '',
        _ => 'near_expiry',
      };

  static String _statusWord(String s) => switch (s) {
        'Pending' => 'Waiting approval',
        'Approved' => 'To receive',
        'Partially Received' => 'Part received',
        _ => s,
      };

  // ---------------------------------------------------------------- suppliers
  Future<void> _supplierSheet(Facts s) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (ctx) {
          final prices = _prices.where((p) => p.s('supplier_id') == s.s('id')).toList();
          String or(String k) => s.s(k).isEmpty ? '—' : s.s(k);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(s.s('name'), style: inter(19, 800)),
                  const SizedBox(height: 10),
                  StockRow('Contact', or('contact_person')),
                  StockRow('Phone', or('phone')),
                  StockRow('City', or('city')),
                  StockRow('GSTIN', or('gstin')),
                  StockRow('Payment terms', or('payment_terms')),
                  const SizedBox(height: 10),
                  Text('Prices', style: inter(15, 700)),
                  if (prices.isEmpty)
                    Padding(padding: const EdgeInsets.only(top: 4), child: Text('No prices recorded yet.', style: inter(13, 400, color: kMuted)))
                  else
                    for (final p in prices) StockRow(p.s('ingredient_name'), '${money(p.no('price_minor'))} / ${unitWord(p.s('unit'))}'),
                  const SizedBox(height: 14),
                  InvPrimary('New order', key: const ValueKey('supplier-new-order'), onPressed: () {
                    Navigator.of(ctx).pop();
                    _newOrder();
                  }),
                ]),
              ),
            ),
          );
        },
      );

  Future<void> _addSupplier() async {
    final added = await showModalBottomSheet<Facts>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _AddSupplierSheet(api: env.api),
    );
    if (added == null || !mounted) return;
    showToast(context, '${added.s('name')} added.');
    _loadSuppliers();
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final orders = _orders, suppliers = _suppliers;
    return StockScaffold(
      env: widget.stock,
      title: 'Purchase',
      line: 'What to buy, what is coming and who you buy from.',
      onRefresh: _load,
      children: [
        const ItemPartSwitcher(),
        Text('To do', style: inter(16, 700)),
        const SizedBox(height: 10),
        _todo(),
        const SizedBox(height: 12),
        // goods that came in, with or without a purchase order: count them, note damaged ones, send for approval
        InvPrimary('Receive a delivery', key: const ValueKey('receive-delivery'), onPressed: _receive),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: Text('Purchase orders', style: inter(16, 700))),
          TextButton.icon(
            key: const ValueKey('po-new'),
            onPressed: _newOrder,
            icon: const Icon(LucideIcons.plus, size: 16, color: kLink),
            label: Text('New purchase order', style: inter(13.5, 700, color: kLink)),
          ),
        ]),
        InvChips(items: [for (final (id, label) in _chips) (id, label, null)], active: _chip, onTap: _setChip),
        const SizedBox(height: 10),
        if (_ordersError != null && orders == null)
          StockEmpty('Orders could not load', _ordersError!, icon: LucideIcons.cloudOff, action: 'Try again', onAction: _loadOrders)
        else if (orders == null)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
        else if (orders.isEmpty)
          StockEmpty('No orders here', _chip == 'open' ? 'Orders you place show here until they arrive.' : 'Nothing in this list right now.', icon: LucideIcons.clipboardList)
        else
          for (final po in orders) _orderRow(po),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: Text('Suppliers', style: inter(16, 700))),
          TextButton.icon(
            key: const ValueKey('supplier-add'),
            onPressed: _addSupplier,
            icon: const Icon(LucideIcons.plus, size: 16, color: kLink),
            label: Text('Add supplier', style: inter(13.5, 700, color: kLink)),
          ),
        ]),
        const SizedBox(height: 6),
        if (_suppliersError != null && suppliers == null)
          StockEmpty('Suppliers could not load', _suppliersError!, icon: LucideIcons.cloudOff, action: 'Try again', onAction: _loadSuppliers)
        else if (suppliers == null)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
        else if (suppliers.isEmpty)
          StockEmpty('No suppliers yet', 'Add the people you buy from to place purchase orders.', icon: LucideIcons.users, action: 'Add supplier', onAction: _addSupplier)
        else
          for (final s in suppliers)
            InvCard(
              key: ValueKey('supplier-${s.s('id')}'),
              onTap: () => _supplierSheet(s),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.s('name'), style: inter(14.5, 700)),
                    Text([if (s.s('city').isNotEmpty) s.s('city'), if (s.s('phone').isNotEmpty) s.s('phone')].join(' · ').ifEmpty('No contact details'),
                        style: inter(12.5, 400, color: kMuted)),
                  ]),
                ),
                const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
              ]),
            ),
        const SizedBox(height: 12),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// "+ Add supplier": name (required), phone, GSTIN, city. One key per sheet, so a retried tap never adds twice.
class _AddSupplierSheet extends StatefulWidget {
  const _AddSupplierSheet({required this.api});
  final PurchasingApi api;
  @override
  State<_AddSupplierSheet> createState() => _AddSupplierSheetState();
}

class _AddSupplierSheetState extends State<_AddSupplierSheet> {
  final _name = TextEditingController(), _phone = TextEditingController(), _gstin = TextEditingController(), _city = TextEditingController();
  final _key = PurchasingApi.newKey();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _phone, _gstin, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().length < 2) return setState(() => _error = 'Enter the supplier name.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await widget.api.saveSupplier(name: _name.text, phone: _phone.text, gstin: _gstin.text, city: _city.text, key: _key);
      if (mounted) Navigator.of(context).pop(s);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is PartnerApiException ? e.message : 'Could not add the supplier. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Add supplier', style: inter(19, 800)),
            Text('Only the name is needed. You can add the rest later.', style: inter(12.5, 400, color: kMuted)),
            const SizedBox(height: 10),
            const InvLabel('Name'),
            InvInput(key: const ValueKey('supplier-name'), controller: _name, hint: 'For example ABC Foods'),
            const InvLabel('Phone (optional)'),
            InvInput(key: const ValueKey('supplier-phone'), controller: _phone, number: true, hint: '10-digit mobile'),
            const InvLabel('GSTIN (optional)'),
            InvInput(key: const ValueKey('supplier-gstin'), controller: _gstin, hint: '15 letters and numbers'),
            const InvLabel('City (optional)'),
            InvInput(key: const ValueKey('supplier-city'), controller: _city, hint: 'For example Latur'),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const ValueKey('supplier-error'), style: inter(12.5, 600, color: kRedText))),
            const SizedBox(height: 14),
            InvPrimary('Add supplier', key: const ValueKey('supplier-save'), busy: _busy, onPressed: _busy ? null : _save),
          ]),
        ),
      );
}
