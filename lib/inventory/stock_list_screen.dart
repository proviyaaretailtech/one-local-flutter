import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'adjustment_screen.dart';
import 'inventory_api.dart';
import 'inventory_dashboard.dart';
import 'inventory_widgets.dart';
import 'stock_detail_screen.dart';

/// Figma "Stock" (Store Inventory View): every item of the store with its status, filters, search, category and pages of 8.
class StockListScreen extends StatefulWidget {
  const StockListScreen({super.key, required this.env, this.filter = 'all'});
  final InvEnv env;
  final String filter;
  @override
  State<StockListScreen> createState() => _StockListScreenState();
}

class _StockListScreenState extends State<StockListScreen> {
  InvEnv get env => widget.env;
  final _search = TextEditingController();
  Timer? _debounce;
  late String _filter = widget.filter;
  String _category = '';
  int _page = 1;
  Facts? _d;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final d = await env.api.stock(filter: _filter, q: _search.text, category: _category, page: _page);
      if (!mounted || mine != _seq) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = e.toString());
    }
  }

  void _set({String? filter, String? category}) {
    setState(() {
      _filter = filter ?? _filter;
      _category = category ?? _category;
      _page = 1;
    });
    _load();
  }

  Future<void> _open(String itemId) async {
    await env.push(context, StockDetailScreen(env: env, itemId: itemId));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = _d?.m('counts');
    return InvScaffold(env: env, onRefresh: _load, children: [
      InvTitle('Store Inventory View',
          subtitle: 'Manage physical stocks, damages, and expiration tracking',
          trailing: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _MiniButton('Adjust Stock', () => env.push(context, AdjustmentScreen(env: env)).then((_) => mounted ? _load() : null)),
              const SizedBox(width: 8),
              _MiniButton('Export', () => env.later(context, 'Export')),
            ]),
          )),
      InvChips(active: _filter, onTap: (id) => _set(filter: id), items: [
        ('all', 'All Items', c?.n('all')),
        ('healthy', 'Healthy', c?.n('healthy')),
        ('low', 'Low Stock', c?.n('low')),
        ('critical', 'Critical', c?.n('critical')),
        ('sku', 'SKU', c?.n('sku')),
        ('ingredient', 'Ingredients', c?.n('ingredient')),
      ]),
      SizedBox(
        height: 48,
        child: TextField(
          controller: _search,
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), () {
              _page = 1;
              _load();
            });
          },
          style: inter(15, 400),
          decoration: InputDecoration(
            hintText: 'Search product name, SKU...',
            hintStyle: inter(15, 400, color: kMuted),
            prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFD9DBD5))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kInk)),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: _Drop(_category.isEmpty ? 'Categories' : _category, () async {
            final cats = _d?.ls('categories') ?? const <String>[];
            final v = await pickOne<String>(context, 'Category', [('', 'All categories', null), for (final x in cats) (x, x, null)], current: _category);
            if (v != null) _set(category: v);
          }),
        ),
        const SizedBox(width: 10),
        Expanded(child: _Drop('More Filters', () => env.later(context, 'More filters'))),
      ]),
      const SizedBox(height: 10),
      InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: _body),
    ]);
  }

  List<Widget> _body(Facts d) {
    final items = d.l('items');
    final total = d.n('total').toInt();
    final size = d.n('page_size').toInt();
    final pages = total == 0 ? 1 : (total / size).ceil();
    final from = total == 0 ? 0 : (_page - 1) * size + 1;
    final to = (from + items.length - 1).clamp(0, total);
    return [
      InvPrimary('View Details', onPressed: items.isEmpty ? null : () => _open(items.first.s('id'))),
      if (items.isEmpty) InvCard(child: Text('No items match.', style: inter(14, 400, color: kMuted))),
      for (final it in items) _card(it),
      InvCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Expanded(child: Text('Showing $from-$to of ${qty(total)} items', style: inter(13.5, 400))),
          for (var p = 1; p <= pages && p <= 5; p++)
            Semantics(
              button: true,
              label: 'Page $p',
              child: InkWell(
                onTap: () {
                  setState(() => _page = p);
                  _load();
                },
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text('$p', style: inter(14, p == _page ? 800 : 600, color: kLink))),
              ),
            ),
        ]),
      ),
      InvFootnote(at: d.t('snapshot_at')),
    ];
  }

  Widget _card(Facts it) {
    final unit = it.s('unit');
    final days = it.no('expiry_days');
    final exp = days == null ? '–' : (days < 0 ? 'Expired' : '${days.toInt()} days');
    return InvCard(
      onTap: () => _open(it.s('id')),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(it.s('name'), style: inter(16.5, 700)),
              Text('SKU: ${it.s('sku')}', style: inter(12.5, 400, color: kMuted)),
            ]),
          ),
          InvStatusChip(it.s('status')),
        ]),
        const Divider(height: 22, color: Color(0xFFEDEEE9)),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _kv('Avail. Stock: ', units(it.n('available'), unit)),
              _kv('In Transit: ', qty(it.n('in_transit'))),
              _kv('Expiry: ', exp, color: (days != null && days <= 7) ? kRedText : kInk),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _kv('Reserved: ', qty(it.n('reserved'))),
            _kv('Damaged: ', qty(it.n('damaged')), color: it.n('damaged') > 0 ? kRedText : kRedText),
            _kv('Stock Days: ', it.no('stock_days') == null ? '–' : '${qty(it.n('stock_days'))} days'),
          ]),
        ]),
      ]),
    );
  }

  Widget _kv(String k, String v, {Color color = kInk}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text.rich(TextSpan(children: [TextSpan(text: k, style: inter(13.5, 400, color: kMuted)), TextSpan(text: v, style: inter(13.5, 600, color: color))])),
      );
}

class _MiniButton extends StatelessWidget {
  const _MiniButton(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Color(0xFFD9DBD5))),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9), child: Text(label, style: inter(12.5, 600))),
          ),
        ),
      );
}

class _Drop extends StatelessWidget {
  const _Drop(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFD9DBD5))),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(height: 46, alignment: Alignment.center, child: Text('$label ⌄', style: inter(14.5, 600))),
          ),
        ),
      );
}
