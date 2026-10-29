import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'menu_build_api.dart';
import 'menu_build_widgets.dart';
import 'menu_widgets.dart' show MenuError;
import 'recipes_screen.dart' show RecipeEditorScreen;

/// Price control (founder, 29 Oct 2026: the side bar's Inventory → "Price Control Tabular"): every dish (or add-on) in one table with its
/// selling price, its price on OneLocal, Zomato and Swiggy (0627: tap one to set it; "—" sells there at the selling price), what its
/// recipe costs, the food cost % and the margin, sortable by any column. A row opens its recipe, where the selling price and the recipe
/// are changed. The figures are the recipe master's (`rcp_list`).
class PriceControlScreen extends StatefulWidget {
  const PriceControlScreen({super.key, this.api});
  final MenuBuildApi? api;
  @override
  State<PriceControlScreen> createState() => _PriceControlScreenState();
}

const _channels = [('onelocal', 'OneLocal'), ('zomato', 'Zomato'), ('swiggy', 'Swiggy')];

class _PriceControlScreenState extends State<PriceControlScreen> {
  late final MenuBuildApi _api = widget.api ?? MenuBuildApi();
  RecipeList? _d;
  Object? _error;
  String _tab = 'dishes';
  String _sort = 'pct'; // the column sorted by
  bool _asc = false; // highest food cost first

  bool get _dishes => _tab == 'dishes';

  /// The columns shown: the channel prices are a dish's (an add-on is sold with its dish).
  List<(String, String, bool)> get _cols => [
        ('name', _dishes ? 'Dish' : 'Add-on', false),
        ('price', 'Selling price', true),
        if (_dishes) for (final (k, label) in _channels) (k, label, true),
        ('cost', 'Cost', true),
        ('pct', 'Food cost', true),
        ('margin', 'Margin', true),
      ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.recipes();
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Recipe r) async {
    await Navigator.of(context).push(RecipeEditorScreen.route(_api, r.dishId, addon: r.isAddon));
    if (mounted) _load();
  }

  /// Set or clear a dish's price on one channel.
  Future<void> _editChannel(Recipe r, String channel, String label) async {
    final now = r.channelPrice(channel);
    final c = TextEditingController(text: now == null ? '' : (now == now.roundToDouble() ? '${now.toInt()}' : '$now'));
    final result = await showDialog<(bool, double?)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$label price · ${r.name}', style: inter(17, 700)),
        content: TextField(
          key: const ValueKey('pc-channel-price'),
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(prefixText: '₹ ', helperText: 'Empty: sold on $label at the selling price (${rupeesMinor(r.priceMinor)})', helperMaxLines: 2),
        ),
        actions: [
          if (now != null) TextButton(key: const ValueKey('pc-channel-clear'), onPressed: () => Navigator.pop(ctx, (true, null)), child: Text('Clear', style: inter(14, 600, color: kError))),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('pc-channel-save'),
            onPressed: () {
              final v = double.tryParse(c.text.trim());
              if (c.text.trim().isEmpty) return Navigator.pop(ctx, (true, null));
              if (v == null || v <= 0) return;
              Navigator.pop(ctx, (true, v));
            },
            child: Text('Save', style: inter(14, 700)),
          ),
        ],
      ),
    );
    if (result == null || !result.$1 || !mounted) return;
    try {
      await _api.saveChannelPrice(r.dishId, channel, result.$2);
      if (!mounted) return;
      showToast(context, result.$2 == null ? '${r.name} sells on $label at the selling price.' : '${r.name} on $label: ${rupeesMinor((result.$2! * 100).round())}.');
      await _load();
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
    }
  }

  List<Recipe> get _rows {
    final rows = [...?(_dishes ? _d?.items : _d?.addons)];
    num key(Recipe r) => switch (_sort) {
          'price' => r.priceMinor,
          'cost' => r.hasRecipe ? r.costMinor : -1,
          'margin' => r.marginMinor ?? -1 << 30,
          'onelocal' || 'zomato' || 'swiggy' => r.channelPrice(_sort) ?? -1,
          _ => r.foodCostPct ?? -1,
        };
    int c(Recipe a, Recipe b) => _sort == 'name' ? a.name.toLowerCase().compareTo(b.name.toLowerCase()) : key(a).compareTo(key(b));
    rows.sort((a, b) => _asc ? c(a, b) : c(b, a));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final rows = _rows;
    final cols = _cols;
    final costed = rows.where((r) => r.foodCostPct != null).toList();
    final avg = costed.isEmpty ? null : costed.fold<double>(0, (a, r) => a + r.foodCostPct!) / costed.length;
    final high = costed.where((r) => r.foodCostPct! > 35).length;
    final sortIndex = cols.indexWhere((c) => c.$1 == _sort);
    final Widget body = (d == null
          ? (_error != null ? MenuError(error: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator(color: kLink)))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 40), children: [
                Row(children: [
                  StatTile(label: 'Average food cost', value: pct(avg), tone: avg == null ? null : foodCostTone(avg)),
                  const SizedBox(width: 8),
                  StatTile(label: 'Over 35% food cost', value: '$high', tone: high == 0 ? null : foodCostTone(50)),
                ]),
                const SizedBox(height: 12),
                FilterChips(
                  keyPrefix: 'pc-tab',
                  items: [('dishes', 'Dishes (${d.items.length})'), ('addons', 'Add-ons (${d.addons.length})')],
                  selected: _tab,
                  onSelect: (v) => setState(() {
                    _tab = v ?? 'dishes';
                    if (!_cols.any((c) => c.$1 == _sort)) _sort = 'pct';
                  }),
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      key: const ValueKey('pc-table'),
                      sortColumnIndex: sortIndex < 0 ? null : sortIndex,
                      sortAscending: _asc,
                      headingRowColor: WidgetStateProperty.all(const Color(0xFFF3F4EE)),
                      headingTextStyle: inter(12.5, 700, color: kMuted),
                      dataTextStyle: inter(13.5, 500),
                      columnSpacing: 20,
                      horizontalMargin: 14,
                      showCheckboxColumn: false,
                      columns: [
                        for (final (k, label, numeric) in cols)
                          DataColumn(
                            label: Text(label, key: ValueKey('pc-col-$k')),
                            numeric: numeric,
                            onSort: (_, asc) => setState(() {
                              _sort = k;
                              _asc = asc;
                            }),
                          ),
                      ],
                      rows: [
                        for (final r in rows)
                          DataRow(
                            key: ValueKey('pc-row-${r.name}'),
                            onSelectChanged: (_) => _open(r),
                            cells: [
                              DataCell(ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 170),
                                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 700)),
                                  if (r.category.isNotEmpty) Text(r.category, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 500, color: kMuted)),
                                ]),
                              )),
                              DataCell(Text(rupeesMinor(r.priceMinor), style: inter(13.5, 700))),
                              if (_dishes)
                                for (final (k, label) in _channels)
                                  DataCell(
                                    Text(
                                      r.channelPrice(k) == null ? '—' : rupeesMinor((r.channelPrice(k)! * 100).round()),
                                      key: ValueKey('pc-${k}-${r.name}'),
                                      style: r.channelPrice(k) == null ? inter(13, 500, color: kMuted) : inter(13.5, 600),
                                    ),
                                    showEditIcon: true,
                                    onTap: () => _editChannel(r, k, label),
                                  ),
                              DataCell(Text(r.hasRecipe ? rupeesMinor(r.costMinor) : 'No recipe', style: r.hasRecipe ? null : inter(12.5, 600, color: kMuted))),
                              DataCell(Builder(builder: (_) {
                                if (r.foodCostPct == null) return Text('—', style: inter(13, 500, color: kMuted));
                                final tone = foodCostTone(r.foodCostPct);
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(color: tone.$1, borderRadius: BorderRadius.circular(999)),
                                  child: Text(pct(r.foodCostPct), key: ValueKey('pc-pct-${r.name}'), style: inter(12, 700, color: tone.$2)),
                                );
                              })),
                              DataCell(Text(r.marginMinor == null ? '—' : '${rupeesMinor(r.marginMinor)}${r.marginPct == null ? '' : ' · ${pct(r.marginPct)}'}')),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                    'Tap a OneLocal, Zomato or Swiggy price to set it; "—" sells there at the selling price. Tap a dish to change its recipe or selling price. '
                    'Food cost (on the selling price): green up to 35%, amber up to 45%, red above.',
                    style: inter(12, 500, color: kMuted, height: 1.4)),
              ]),
            ));
    return Scaffold(
      backgroundColor: kBg,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // the app's green banner with the round ← (founder, 29 Oct 2026)
        AppHeader(
          title: 'Price control',
          trailing: HeaderRound(key: const ValueKey('pc-refresh'), icon: LucideIcons.refreshCw, label: 'Refresh', onTap: _load),
        ),
        Expanded(child: body),
      ]),
    );
  }
}
