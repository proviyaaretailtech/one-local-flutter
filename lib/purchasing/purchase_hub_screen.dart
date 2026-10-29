import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../catalogue/catalogue_api.dart';
import '../catalogue/grn_screens.dart';
import '../catalogue/item_parts.dart';
import '../inventory/inventory_api.dart';
import '../inventory/receiving_screen.dart';
import '../stock/stock_env.dart';
import '../stock/stock_kit.dart';
import '../ui/theme.dart';
import 'po_create_screen.dart';
import 'po_grn_screen.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart';
import 'simple_purchase.dart';
import '../ui/i18n.dart';

/// Opens a receipt note: [id] an existing one, or a new one when null. Tests replace it with [PurchaseHubScreen.openReceipt].
typedef ReceiptOpener = Future<void> Function(BuildContext context, String? id);

/// Item → Purchase (founder's sketch, 26 Oct 2026; simplified 28 Oct 2026): one big "+ Add Purchase" (goods bought without an order) and
/// Past purchases, then two sections, Receipt notes and Purchase orders. An open order shows how long it has waited and has two outcomes,
/// Received (the quantities that came and their MRP; stock goes up) or Cancel; it then leaves the list. A receipt note opens its count while it is being
/// counted, its check once it is sent, and its labels and putaway once received; an order opens its page. Suppliers are
/// picked where they are needed (Add purchase, New order), not listed here (founder, 29 Oct 2026).
class PurchaseHubScreen extends StatefulWidget {
  const PurchaseHubScreen({super.key, required this.env, required this.stock, CatalogueApi? catalogue, this.openReceipt}) : _catalogue = catalogue;
  final PurEnv env;
  final StockEnv stock;
  final CatalogueApi? _catalogue;
  final ReceiptOpener? openReceipt;
  @override
  State<PurchaseHubScreen> createState() => _PurchaseHubScreenState();
}

class _PurchaseHubScreenState extends State<PurchaseHubScreen> {
  PurEnv get env => widget.env;
  late final CatalogueApi _grn = widget._catalogue ?? widget.stock.catalogue;

  String _part = 'receipts'; // receipts | orders (a phone shows one; a wide screen shows both)

  // receipt notes, with their check state from the delivery queue
  List<Facts>? _receipts;
  Map<String, String> _review = const {};
  String? _receiptsError;
  bool _receiptsDone = false; // the Received chip

  // purchase orders: the open ones only (founder, 28 Oct 2026: no Due / Waiting / Received tabs)
  List<PurchaseOrder>? _orders;
  String? _ordersError;
  int? _buyAgain;
  List<Facts> _low = const []; // Stock's reorder list: out of stock or running low, with how much to buy

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async => Future.wait([_loadReceipts(), _loadOrders(), _loadBuyAgain()]);

  Future<void> _loadReceipts() async {
    try {
      final docs = await widget.stock.api.documents('receipt', limit: 40);
      Map<String, String> review = const {};
      try {
        review = {for (final r in await _grn.grnQueue()) r.receiptId: r.reviewStatus};
      } catch (_) {} // a role that cannot check deliveries still sees its notes
      if (!mounted) return;
      setState(() {
        _receipts = docs.where((d) => d.s('status') != 'cancelled').toList();
        _review = review;
        _receiptsError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _receiptsError = e is PartnerApiException ? e.message : 'Could not load receipt notes.');
    }
  }

  Future<void> _loadBuyAgain() async {
    try {
      final dash = await widget.stock.api.dashboard();
      if (mounted) {
        setState(() {
          _low = dash.l('replenishment');
          _buyAgain = _low.length;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadOrders() async {
    try {
      final orders = await env.api.openOrders();
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _ordersError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _ordersError = e is PartnerApiException ? e.message : 'Could not load purchase orders.');
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  /// A receipt note: a new one (+ Add Purchase) or one being counted.
  Future<void> _receipt(String? id) async {
    final open = widget.openReceipt;
    if (open != null) return open(context, id);
    await _push(ReceivingScreen(env: widget.stock.inv, documentId: id, startNew: id == null));
    if (mounted) _load();
  }

  Future<void> _openOrder(PurchaseOrder po) => _push(PoGrnScreen(env: env, orderId: po.id));
  Future<void> _newOrder() => _push(PoCreateScreen(env: env));

  /// "Order these": a new purchase order with every low item on it, at the suggested quantity.
  Future<void> _orderLow() => _push(PoCreateScreen(env: env, want: [
        for (final r in _low) (itemId: r.s('id'), name: r.s('name'), unit: r.s('unit'), qty: r.n('suggest')),
      ]));

  /// Items and Purchase in step (founder, 29 Oct 2026): what Stock says is out or running low shows here, ready to order. Once its
  /// order is marked Received the stock goes up and it leaves this card.
  Widget _needToOrder() {
    final shown = _low.take(4).toList();
    return Container(
      key: const ValueKey('need-to-order'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFF4D9B5)),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFF4E0), Colors.white]),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: const Color(0xFFFFE2B8), borderRadius: BorderRadius.circular(11)),
            child: const Icon(LucideIcons.packageX, size: 18, color: Color(0xFFB45309)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${tr('Need to order')} · ${_low.length}', style: inter(16, 800)),
              Text(tr('Out of stock or running low'), style: inter(12.5, 500, color: kMuted)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        for (final r in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: r.b('urgent') ? const Color(0xFFC62828) : const Color(0xFFE59A1A), shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(r.s('name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 600))),
              Text(tr(r.b('urgent') ? 'Out / very low' : 'Low'), style: inter(12, 600, color: r.b('urgent') ? const Color(0xFFC62828) : const Color(0xFFB45309))),
              const SizedBox(width: 10),
              Text('${tr('buy')} ${qty(r.n('suggest'))}', style: inter(13, 700)),
            ]),
          ),
        if (_low.length > shown.length)
          Text('+ ${_low.length - shown.length} ${tr('more')}', style: inter(12.5, 600, color: kMuted)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              key: const ValueKey('need-order'),
              onPressed: _orderLow,
              icon: const Icon(LucideIcons.clipboardPlus, size: 17),
              label: Text(tr('Order these'), style: inter(14, 700, color: Colors.white)),
              style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: const ValueKey('need-review'),
            onPressed: () => widget.stock.open(context, StockPage.reorder),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14), side: const BorderSide(color: kCardLine), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(tr('Change amounts'), style: inter(13.5, 700)),
          ),
        ]),
      ]),
    );
  }

  /// Received: the order's items, the quantities that came and their MRP (one step; the bill follows).
  Future<void> _receiveOrder(PurchaseOrder po) => _push(ReceiveGoodsScreen(api: env.api, po: po));

  /// + Add Purchase: goods bought without an order.
  Future<void> _addPurchase() async {
    if (widget.openReceipt != null) return _receipt(null);
    await _push(ReceiveGoodsScreen(api: env.api));
  }

  Future<void> _cancelOrder(PurchaseOrder po) async {
    if (await cancelOrder(context, env.api, po) && mounted) _loadOrders();
  }

  // ---------------------------------------------------------------- receipt notes
  /// What a receipt note is waiting for, in plain words, and its colour.
  (String, String) _state(Facts d) => switch (d.s('status')) {
        'draft' => ('Counting', 'low'),
        'review' => _review[d.s('id')] == 'approval_due' ? ('To approve', 'low') : ('To check', 'near_expiry'),
        'posted' => ('Received', 'healthy'),
        final s => (s, ''),
      };

  void _openReceiptNote(Facts d) {
    if (d.s('status') == 'posted') {
      _push(PurchaseBillScreen(api: env.api, receiptId: d.s('id'))); // received: its bill
    } else if (widget.openReceipt == null) {
      // a note started the old way finishes in the one Received step, with its order when it still waits (founder, 29 Oct 2026)
      final po = (_orders ?? const <PurchaseOrder>[]).where((o) => d.s('po_ref').isNotEmpty && o.number == d.s('po_ref')).firstOrNull;
      _push(ReceiveGoodsScreen(api: env.api, po: po, replaces: d));
    } else if (d.s('status') == 'draft') {
      _receipt(d.s('id'));
    } else if (d.s('status') == 'posted') {
      _push(PurchaseBillScreen(api: env.api, receiptId: d.s('id'))); // received: its bill
    } else {
      _push(GrnDashboardScreen(receiptId: d.s('id'), api: _grn));
    }
  }

  List<Facts> get _shownReceipts => (_receipts ?? const <Facts>[]).where((d) => _receiptsDone ? d.s('status') == 'posted' : d.s('status') != 'posted').toList();

  int get _openReceipts => (_receipts ?? const <Facts>[]).where((d) => d.s('status') != 'posted').length;

  Widget _receiptCard(Facts d) {
    final (word, tone) = _state(d);
    final t = d.m('totals');
    final when = d.t('posted_at') ?? d.t('created_at');
    final amount = d.no('amount_minor');
    final posted = d.s('status') == 'posted';
    return PurchaseListCard(
      key: ValueKey('receipt-${d.s('id')}'),
      onTap: () => _openReceiptNote(d),
      date: when == null ? '' : dayMonth(when),
      status: StockStatusChip(tone, label: tr(word)),
      title: d.s('supplier_name').isEmpty ? tr('No supplier') : d.s('supplier_name'),
      // the invoice total once entered; before that, what the counted goods cost at the order's or the product's price
      amount: amount == null ? '—' : '${d.s('amount_kind') == 'estimate' ? '≈ ' : ''}${money(amount)}',
      details: [
        d.s('doc_no'),
        if (d.s('po_ref').isNotEmpty) d.s('po_ref') else tr('No order'),
        if (d.s('invoice_ref').isNotEmpty) '${tr('Invoice')} ${d.s('invoice_ref')}',
        if (t.no('received') != null) '${qty(t.n('received'))} ${tr('units')}',
      ].join(' · '),
      // received: the lot's next steps, one tap each
      footer: posted
          ? Row(children: [
              _smallAction('receipt-labels-${d.s('id')}', LucideIcons.tag, 'Labels', () => widget.stock.open(context, StockPage.lotLabels, itemId: d.s('id'))),
              const SizedBox(width: 8),
              _smallAction('receipt-putaway-${d.s('id')}', LucideIcons.packageOpen, 'Put away', () => widget.stock.open(context, StockPage.putaway, itemId: d.s('id'))),
            ])
          : null,
    );
  }

  Widget _smallAction(String key, IconData icon, String label, VoidCallback onTap) => OutlinedButton.icon(
        key: ValueKey(key),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          side: const BorderSide(color: kCardLine),
          shape: const StadiumBorder(),
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 15, color: kInk),
        label: Text(tr(label), style: inter(12.5, 700)),
      );

  List<Widget> _receiptsList() {
    final list = _receipts;
    return [
      InvChips(
        items: [('open', 'Open', null), ('done', 'Received', null)],
        active: _receiptsDone ? 'done' : 'open',
        onTap: (c) => setState(() => _receiptsDone = c == 'done'),
      ),
      if (_receiptsError != null && list == null)
        StockEmpty(tr('Receipt notes could not load'), _receiptsError!, icon: LucideIcons.cloudOff, action: tr('Try again'), onAction: _loadReceipts)
      else if (list == null)
        const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
      else if (_shownReceipts.isEmpty)
        StockEmpty(
          tr(_receiptsDone ? 'Nothing received yet' : 'No receipt notes open'),
          tr(_receiptsDone ? 'Received deliveries show here, with their labels.' : 'When goods come in, tap + Add Purchase and count them.'),
          icon: LucideIcons.packageCheck,
        )
      else
        for (final d in _shownReceipts) _receiptCard(d),
    ];
  }

  // ---------------------------------------------------------------- orders
  Widget _orderRow(PurchaseOrder po) => OpenOrderCard(po: po, onOpen: () => _openOrder(po), onReceived: () => _receiveOrder(po), onCancel: () => _cancelOrder(po));

  List<Widget> _ordersList() {
    final orders = _orders;
    return [
      Wrap(spacing: 8, runSpacing: 6, children: [
        _smallAction('po-new', LucideIcons.plus, 'New order', _newOrder),
        // what is running low, ready to order again
        _smallAction('po-buy-again', LucideIcons.shoppingCart, _buyAgain == null || _buyAgain == 0 ? 'Buy again' : '${tr('Buy again')} · $_buyAgain',
            () => widget.stock.open(context, StockPage.reorder)),
      ]),
      const SizedBox(height: 8),
      if (_ordersError != null && orders == null)
        StockEmpty(tr('Orders could not load'), _ordersError!, icon: LucideIcons.cloudOff, action: tr('Try again'), onAction: _loadOrders)
      else if (orders == null)
        const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
      else if (orders.isEmpty)
        StockEmpty(tr('No open orders'), tr('Orders you place show here until they arrive.'), icon: LucideIcons.clipboardList)
      else
        for (final po in orders) _orderRow(po),
    ];
  }

  // ---------------------------------------------------------------- build
  /// The two sections side by side, as in the sketch: tap one to show its cards.
  Widget _parts() {
    final open = _orders?.length;
    final parts = [
      ('receipts', LucideIcons.fileCheck, 'Receipt notes', _receipts == null ? null : _openReceipts),
      ('orders', LucideIcons.clipboardList, 'Purchase orders', open),
    ];
    return Row(children: [
      for (final (i, (id, icon, title, n)) in parts.indexed) ...[
        if (i > 0) const SizedBox(width: 10),
        Expanded(
          child: Material(
            color: _part == id ? kNavyH : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: _part == id ? kNavyH : kCardLine)),
            child: InkWell(
              key: ValueKey('part-$id'),
              borderRadius: BorderRadius.circular(16),
              onTap: () => setState(() => _part = id),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                child: Row(children: [
                  Icon(icon, size: 18, color: _part == id ? kLimeH : kInk),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tr(title), maxLines: 2, style: inter(13.5, 700, color: _part == id ? Colors.white : kInk, height: 1.2))),
                  if ((n ?? 0) > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: kLimeH, borderRadius: BorderRadius.circular(99)),
                      child: Text('$n', key: ValueKey('part-$id-count'), style: inter(12, 800)),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return StockScaffold(
      env: widget.stock,
      title: '', // the compact heading below, laid out like Item → Products and Stock
      onRefresh: _load,
      children: [
        const ItemPartSwitcher(bottom: 10),
        // goods came in, with or without a purchase order: a new receipt note
        _AddPurchaseButton(onPressed: _addPurchase),
        const SizedBox(height: 10),
        if (_low.isNotEmpty) _needToOrder(),
        // every received delivery, by week, month or any dates (founder, 28 Oct 2026)
        Align(
          alignment: Alignment.centerRight,
          child: _smallAction('past-purchases', LucideIcons.history, 'Past purchases', () => _push(PastPurchasesScreen(api: env.api))),
        ),
        const SizedBox(height: 10),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_heading('Receipt notes'), ..._receiptsList()])),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_heading('Purchase orders'), ..._ordersList()])),
          ])
        else ...[
          _parts(),
          const SizedBox(height: 10),
          ...(_part == 'receipts' ? _receiptsList() : _ordersList()),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _heading(String t) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(tr(t), style: inter(15, 700)));
}

/// The big lime "+ Add Purchase" across the screen, the first thing on Purchase.
class _AddPurchaseButton extends StatelessWidget {
  const _AddPurchaseButton({required this.onPressed});
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Material(
        color: kLimeH,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: const ValueKey('add-purchase'),
          borderRadius: BorderRadius.circular(18),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Row(children: [
              const Icon(LucideIcons.plus, size: 24, color: kInk),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Add Purchase'), style: inter(18, 800)),
                  Text(tr('Goods bought without an order? Add them here.'), style: inter(12.5, 500, color: kInk.withValues(alpha: 0.75))),
                ]),
              ),
              const Icon(LucideIcons.chevronRight, size: 20, color: kInk),
            ]),
          ),
        ),
      );
}

/// One row of the Purchase lists (founder, 26 Oct 2026): the date and the state on top, the supplier and the amount in bold, then the
/// small details (number, order, invoice, units) in one muted line.
class PurchaseListCard extends StatelessWidget {
  const PurchaseListCard({super.key, required this.date, required this.status, required this.title, required this.amount, required this.details,
      this.dateColor, this.footer, this.onTap});
  final String date, title, amount, details;
  final Color? dateColor;
  final Widget status;
  final Widget? footer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InvCard(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(date, style: inter(12.5, 700, color: dateColor ?? kMuted))),
            status,
          ]),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(15.5, 800, height: 1.25))),
            const SizedBox(width: 10),
            Text(amount, style: inter(15.5, 800)),
          ]),
          const SizedBox(height: 3),
          Text(details, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(12, 400, color: kMuted, height: 1.3)),
          if (footer != null) ...[const SizedBox(height: 10), footer!],
        ]),
      );
}
