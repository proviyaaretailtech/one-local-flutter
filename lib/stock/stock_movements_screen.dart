import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'stock_env.dart';
import 'stock_kit.dart';
import '../ui/i18n.dart';

/// The plain words for each kind of stock movement the server records.
String movementLabel(String kind) => switch (kind) {
      'receipt' => 'Delivery received',
      'sale' => 'Sold',
      'sale_reversal' => 'Sale returned',
      'adjustment' => 'Correction',
      'wastage' => 'Thrown away',
      'transfer_in' => 'Moved in',
      'transfer_out' => 'Moved out',
      'reservation' => 'Put on hold',
      'reservation_release' => 'Hold released',
      _ => kind.isEmpty ? 'Movement' : kind[0].toUpperCase() + kind.substring(1).replaceAll('_', ' '),
    };

const _filters = {
  'in': {'receipt', 'sale_reversal', 'transfer_in'},
  'out': {'sale', 'wastage', 'transfer_out'},
  'moves': {'transfer_in', 'transfer_out'},
  'fixes': {'adjustment', 'wastage'},
};

/// "Stock movements" (Figma "Stock Movement" + "Inventory Tracking" in one): every sale, delivery, move and correction, newest first,
/// for all products or one. Tap a movement to see where it came from and what it changed.
class StockMovementsScreen extends StatefulWidget {
  const StockMovementsScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;
  @override
  State<StockMovementsScreen> createState() => _StockMovementsScreenState();
}

class _StockMovementsScreenState extends State<StockMovementsScreen> {
  static const _page = 30;
  InventoryApi get api => widget.env.api;
  String? _itemId;
  String? _itemName;
  Facts? _position; // the chosen product's stock right now
  List<Facts>? _moves;
  String? _error;
  String _kind = 'all';
  bool _more = false, _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _itemId = widget.itemId;
    _load();
  }

  Future<void> _load() async {
    try {
      final id = _itemId;
      final detail = id == null ? null : await api.stockDetail(id);
      final moves = await api.movements(itemId: id, limit: _page);
      if (!mounted) return;
      setState(() {
        _position = detail;
        if (detail != null) _itemName = detail.m('item').s('name');
        _moves = moves;
        _more = moves.length == _page;
        _error = null;
      });
    } on PartnerApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the movements. Check your connection.');
    }
  }

  Future<void> _older() async {
    final last = _moves?.lastOrNull;
    if (last == null) return;
    setState(() => _loadingMore = true);
    try {
      final more = await api.movements(itemId: _itemId, beforeId: last.n('id').toInt(), limit: _page);
      if (!mounted) return;
      setState(() {
        _moves = [..._moves!, ...more];
        _more = more.length == _page;
      });
    } on PartnerApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not load more. Try again.');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _pickProduct() async {
    final it = await pickItem(context, api);
    if (it == null || !mounted) return;
    setState(() {
      _itemId = it.s('id');
      _itemName = it.s('name');
      _moves = null;
    });
    _load();
  }

  void _allProducts() => setState(() {
        _itemId = null;
        _itemName = null;
        _position = null;
        _moves = null;
        _load();
      });

  @override
  Widget build(BuildContext context) => StockScaffold(
        env: widget.env,
        title: tr('Stock movements'),
        line: tr('Every sale, delivery, move and correction, newest first. Tap one to see what it changed.'),
        onRefresh: _load,
        children: [
          InvLabel(tr('Product')),
          Row(children: [
            Expanded(child: InvPickBox(value: _itemName ?? 'All products', onTap: _pickProduct, semantic: 'Choose a product')),
            if (_itemId != null) IconButton(tooltip: tr('Show all products'), onPressed: _allProducts, icon: const Icon(LucideIcons.x, size: 18, color: kMuted)),
          ]),
          const SizedBox(height: 12),
          if (_position != null) ...[
            StockNumbers([
              StockNumber(qty(_position!.n('available')), 'Ready to sell'),
              StockNumber(qty(_position!.n('in_transit')), 'On the way'),
              StockNumber(qty(_position!.n('reserved')), 'On hold'),
            ]),
            const SizedBox(height: 12),
          ],
          InvChips(active: _kind, onTap: (k) => setState(() => _kind = k), items: const [
            ('all', 'All', null),
            ('in', 'In', null),
            ('out', 'Out', null),
            ('moves', 'Moves', null),
            ('fixes', 'Corrections', null),
          ]),
          const SizedBox(height: 12),
          InvLoad<List<Facts>>(data: _moves, error: _error, onRetry: _load, builder: _list),
        ],
      );

  List<Widget> _list(List<Facts> all) {
    final shown = _kind == 'all' ? all : all.where((m) => _filters[_kind]!.contains(m.s('kind'))).toList();
    return [
      if (shown.isEmpty)
        StockEmpty(tr('No movements here'), _kind == 'all' ? 'Sales, deliveries and corrections show here as they happen.' : 'Nothing of this kind in the movements loaded so far.', icon: LucideIcons.history),
      for (final m in shown) _card(m),
      if (_more) InvSecondary(_loadingMore ? 'Loading…' : 'Show older movements', onPressed: _loadingMore ? null : _older),
      InvFootnote(at: _position?.t('snapshot_at')),
    ];
  }

  Widget _card(Facts m) {
    final d = m.no('delta') ?? m.n('quantity');
    final up = d > 0;
    final when = m.t('created_at');
    final ref = m.m('ref');
    final item = m.m('item');
    return InvCard(
      onTap: () => showMovement(context, widget.env, m.n('id').toInt()),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text('${movementLabel(m.s('kind'))} · ${signed(d)} ${item.s('unit').isEmpty ? 'units' : item.s('unit')}', style: inter(16, 700))),
          InvDotChip(up ? 'In' : d < 0 ? 'Out' : 'No change', bg: up ? kGreenIconBg : d < 0 ? kRedBgH : kGreyBg, fg: up ? kPostedText : d < 0 ? kRedText : kMuted),
        ]),
        if (_itemId == null) ...[const SizedBox(height: 2), Text(item.s('name'), style: inter(13.5, 600))],
        const SizedBox(height: 6),
        if (ref.s('label').isNotEmpty) StockRow(tr('Reference'), [ref.s('label'), ref.s('method')].where((s) => s.isNotEmpty).join(' · ')),
        StockRow(tr('By'), m.m('actor').s('name').isEmpty ? '—' : m.m('actor').s('name')),
        StockRow(tr('When'), when == null ? '—' : stamp(when)),
        const SizedBox(height: 4),
        Text(tr('See details ›'), style: inter(13, 700, color: kLink)),
      ]),
    );
  }
}

/// The detail of one movement (inv_movement_detail): before → after, where it was taken from or put, the reference and its trail.
Future<void> showMovement(BuildContext context, StockEnv env, int id) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
          child: FutureBuilder<Facts>(
            future: env.api.movement(id),
            builder: (ctx, snap) {
              if (snap.hasError) {
                final e = snap.error;
                return Padding(padding: const EdgeInsets.all(24), child: Text(e is PartnerApiException ? e.message : 'Could not load this movement.', style: inter(14, 400, color: kMuted)));
              }
              if (!snap.hasData) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk)));
              final m = snap.data!;
              final item = m.m('item');
              final unit = item.s('unit').isEmpty ? 'units' : item.s('unit');
              final ref = m.m('reference');
              final when = m.t('created_at');
              return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 20, 20, 20), children: [
                Row(children: [
                  Expanded(child: Text(movementLabel(m.s('kind')), style: inter(20, 800))),
                  IconButton(tooltip: tr('Close'), onPressed: () => Navigator.pop(ctx), icon: const Icon(LucideIcons.x, size: 20, color: kMuted)),
                ]),
                InkWell(
                  onTap: () {
                    Navigator.pop(ctx);
                    env.open(context, StockPage.item, itemId: item.s('id'));
                  },
                  child: Text('${item.s('name')}${item.s('sku').isEmpty ? '' : ' · System Code ${item.s('sku')}'}', style: inter(13.5, 600, color: kLink)),
                ),
                const SizedBox(height: 14),
                StockNumbers([
                  StockNumber(qty(m.n('before')), 'Before'),
                  StockNumber(signed(m.n('delta')), 'Change', color: m.n('delta') >= 0 ? kPostedText : kRedText),
                  StockNumber(qty(m.n('after')), 'After'),
                ]),
                const SizedBox(height: 12),
                for (final a in m.l('allocations'))
                  StockRow(
                    '${a.m('bin').s('name')}${a.mo('lot') == null || a.m('lot').s('lot_code').isEmpty ? '' : ' · batch ${a.m('lot').s('lot_code')}'}',
                    '${qty(a.n('bin_before'))} → ${qty(a.n('bin_after'))} $unit',
                  ),
                if (ref.s('label').isNotEmpty) StockRow(tr('Reference'), [ref.s('label'), ref.s('method')].where((s) => s.isNotEmpty).join(' · ')),
                if (ref.m('recorded_by').s('name').isNotEmpty) StockRow(tr('Recorded by'), ref.m('recorded_by').s('name')),
                StockRow(tr('Store'), m.m('location').s('name')),
                StockRow(tr('When'), when == null ? '—' : stamp(when)),
                if (m.s('note').isNotEmpty) StockRow(tr('Note'), m.s('note')),
                if (m.l('trail').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(tr('What happened'), style: inter(15, 700)),
                  const SizedBox(height: 6),
                  for (final t in m.l('trail'))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Padding(padding: EdgeInsets.only(top: 5), child: Icon(LucideIcons.circle, size: 8, color: kMuted)),
                        const SizedBox(width: 10),
                        Expanded(child: Text(t.s('label'), style: inter(13.5, 400))),
                        if (t.t('at') != null) Text(hm(t.t('at')!), style: inter(12.5, 400, color: kMuted)),
                      ]),
                    ),
                ],
              ]);
            },
          ),
        ),
      ),
    );
