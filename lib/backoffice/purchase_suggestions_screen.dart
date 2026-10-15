import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart' show PosBottomNav, SmallPill, kDark, kGreenText, kLime;
import '../orders/orders_api.dart' show rupees;
import '../ui/theme.dart';
import 'backoffice_api.dart';
import 'backoffice_widgets.dart';

/// Figma "OneLocal · Purchase Suggestions" (section J): open suggestions recorded for low items. The person ticks items, keeps or
/// changes the quantity, and drafts a purchase order. Typed quantities stay on the phone until "Create Purchase Order"; they never
/// change posted stock. Opening the screen asks the server to record suggestions for items that are low now.
class PurchaseSuggestionsScreen extends StatefulWidget {
  const PurchaseSuggestionsScreen({super.key, this.api, this.onNavigate, this.onMenu, this.onItems});
  final BackofficeApi? api;
  final ValueChanged<String>? onNavigate;
  final VoidCallback? onMenu, onItems;
  @override
  State<PurchaseSuggestionsScreen> createState() => _PurchaseSuggestionsScreenState();
}

class _PurchaseSuggestionsScreenState extends State<PurchaseSuggestionsScreen> {
  late final BackofficeApi _api = widget.api ?? BackofficeApi();
  SuggestionsView? _view;
  String? _error;
  final _selected = <String>{};
  final _qty = <String, TextEditingController>{};
  bool _busy = false;
  String? _poKey; // one key per "Create Purchase Order" intent; kept for a retry of the same selection

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    try {
      SuggestionsView v;
      if (refresh) {
        try {
          v = await _api.refreshSuggestions(key: BackofficeApi.newKey());
        } on BackofficeApiException catch (e) {
          if (e.status != 403) rethrow;
          v = await _api.suggestions(); // a role that may read but not record suggestions
        }
      } else {
        v = await _api.suggestions();
      }
      if (!mounted) return;
      setState(() {
        _view = v;
        _error = null;
        final ids = v.suggestions.map((s) => s.id).toSet();
        _selected.retainAll(ids);
        for (final s in v.suggestions) {
          _qty.putIfAbsent(s.id, () => TextEditingController(text: s.suggestedQty == null ? '' : qty(s.suggestedQty!)));
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  num? _typed(Suggestion s) {
    final v = num.tryParse((_qty[s.id]?.text ?? '').trim());
    return v == null || v <= 0 || v > 100000 ? null : v;
  }

  void _toggle(Suggestion s) {
    setState(() {
      _poKey = null;
      if (_selected.contains(s.id)) {
        _selected.remove(s.id);
      } else if (_typed(s) == null) {
        showToast(context, 'Enter a quantity before including this item.');
      } else {
        _selected.add(s.id);
      }
    });
  }

  List<Suggestion> get _chosen => (_view?.suggestions ?? const []).where((s) => _selected.contains(s.id)).toList();

  String _selectedLine() {
    final c = _chosen;
    if (c.isEmpty) return 'Selected: none';
    return 'Selected: ${c.map((s) => '${s.name} · ${withUnit(_typed(s) ?? 0, s.unit)}').join(', ')} suggested';
  }

  String _estimate() {
    final c = _chosen;
    if (c.isEmpty || c.any((s) => s.estimatedUnitCost == null)) return 'Estimate unavailable';
    return rupees(c.fold<num>(0, (sum, s) => sum + (_typed(s) ?? 0) * s.estimatedUnitCost!));
  }

  Future<void> _createPo() async {
    final c = _chosen;
    if (c.isEmpty) {
      showToast(context, 'Select items to include.');
      return;
    }
    if (c.any((s) => _typed(s) == null)) {
      showToast(context, 'Enter a quantity before including this item.');
      return;
    }
    _poKey ??= BackofficeApi.newKey();
    setState(() => _busy = true);
    try {
      final ref = await _api.createPurchaseOrder([for (final s in c) PoLine(s.id, _typed(s)!)], key: _poKey!);
      if (!mounted) return;
      _poKey = null;
      _selected.clear();
      showToast(context, ref.isEmpty ? 'Purchase order drafted.' : 'Purchase order $ref drafted.');
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _tab(String id) {
    if (id == 'stock') {
      Navigator.of(context).maybePop();
      return;
    }
    if (widget.onNavigate != null) {
      widget.onNavigate!(id);
    } else {
      showToast(context, 'That part of the app is not built yet.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _view;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        BackofficeTopBar(initials: initialsOf(v?.snapshot.viewerName), onMenu: widget.onMenu, onItems: widget.onItems),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(refresh: true),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                BackofficeHeader(title: 'Purchase Suggestions', snapshotLine: v == null ? ' ' : snapshotLine(v.snapshot.at, v.snapshot.locationName)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Review items and suggested quantities before creating a purchase order.', style: inter(11.5, 400, color: kMuted, height: 1.4)),
                    const SizedBox(height: 8),
                    Text('Select items to include. Quantities are recorded suggestions, not calculated shortfalls.', style: inter(9.5, 400, color: kMuted, height: 1.4)),
                    const SizedBox(height: 8),
                    ..._body(),
                    if (v != null && v.suggestions.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(_selectedLine(), style: inter(11, 600)),
                      const SizedBox(height: 3),
                      Text('Estimated total: ${_estimate()}', style: inter(9.5, 400, color: kMuted)),
                    ],
                    const SizedBox(height: 8),
                    LimeCta(label: 'Create Purchase Order', busy: _busy, onPressed: v == null || v.suggestions.isEmpty ? null : _createPo),
                    const SizedBox(height: 8),
                    Text(snapshotFootnote(v?.snapshot.at), style: inter(9.5, 400, color: kMuted, height: 1.4)),
                  ]),
                ),
              ],
            ),
          ),
        ),
        PosBottomNav(active: 'stock', onTap: _tab),
      ]),
    );
  }

  List<Widget> _body() {
    if (_error != null && _view == null) {
      return [
        const SizedBox(height: 40),
        Text(_error!, textAlign: TextAlign.center, style: inter(13, 400, color: kMuted)),
        const SizedBox(height: 12),
        Center(child: SmallPill('Try again', onTap: () => _load(refresh: true))),
      ];
    }
    if (_view == null) return const [SizedBox(height: 60), Center(child: CircularProgressIndicator(color: kGreenText))];
    if (_view!.suggestions.isEmpty) {
      return [
        const SizedBox(height: 32),
        Text('No purchase suggestions. Items running low are suggested here.', textAlign: TextAlign.center, style: inter(13, 400, color: kMuted)),
      ];
    }
    return [
      for (final s in _view!.suggestions)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SuggestionCard(
            suggestion: s,
            selected: _selected.contains(s.id),
            controller: _qty[s.id]!,
            onToggle: () => _toggle(s),
            onQtyChanged: () => setState(() {
              _poKey = null;
              if (_typed(s) == null) _selected.remove(s.id);
            }),
          ),
        ),
    ];
  }
}

/// One suggestion: tick box, item, reason, optional inbound note, quantity box and supplier rows.
class SuggestionCard extends StatelessWidget {
  const SuggestionCard({super.key, required this.suggestion, required this.selected, required this.controller, required this.onToggle, required this.onQtyChanged});
  final Suggestion suggestion;
  final bool selected;
  final TextEditingController controller;
  final VoidCallback onToggle, onQtyChanged;

  @override
  Widget build(BuildContext context) {
    final s = suggestion;
    final critical = s.level == 'critical' || (s.level == null && s.urgent);
    final inbound = inboundTitle(inboundQty: s.inboundQty, inboundEta: s.inboundEta, unit: s.unit)?.replaceFirst('ETA', 'Inbound ETA');
    final typed = num.tryParse(controller.text.trim());
    final cost = s.estimatedUnitCost == null || typed == null || typed <= 0 ? 'Estimate unavailable' : rupees(typed * s.estimatedUnitCost!);
    return BoCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 9), child: _TickBox(selected: selected, name: s.name, onTap: onToggle)),
          const SizedBox(width: 10),
          const ItemTile(),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name, style: inter(12.5, 500), overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text('${withUnit(s.available, s.unit)} in stock', style: inter(11.5, 600, color: critical ? kBoRed : kBoAmber)),
            ]),
          ),
          if (s.level != null) Padding(padding: const EdgeInsets.only(top: 4), child: LevelBadge(critical: critical)),
        ]),
        const SizedBox(height: 8),
        Text(
          s.urgent ? 'Reason: Urgent replenishment${s.daysCover == null ? '' : ' · ${qty(s.daysCover!)} days cover'}' : 'Reason: Low stock',
          style: inter(10, 400, color: kMuted),
        ),
        if (inbound != null) ...[
          const SizedBox(height: 6),
          InboundBox(
            title: inbound,
            body: s.suggestedQty == null
                ? 'Review inbound before ordering.'
                : 'Review inbound before ordering. The recorded ${qty(s.suggestedQty!)}${shortUnit(s.unit)} suggestion is not a net requirement.',
          ),
        ],
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text('Suggested quantity', style: inter(11, 600))),
          _QtyBox(controller: controller, unit: s.unit, name: s.name, onChanged: onQtyChanged),
        ]),
        const SizedBox(height: 8),
        BoRow('Preferred supplier', s.supplierName ?? 'Not recorded'),
        BoRow('Estimated purchase cost', cost),
        BoRow('New order delivery', s.deliveryDays == null ? 'Not recorded' : 'In ${qty(s.deliveryDays!)} ${s.deliveryDays == 1 ? 'day' : 'days'}'),
        if (s.suggestedQty == null && controller.text.trim().isEmpty) ...[
          const SizedBox(height: 2),
          Text('No suggestion quantity recorded. Enter a quantity before including this item.', style: inter(10, 400, color: kMuted, height: 1.4)),
        ],
      ]),
    );
  }
}

class _TickBox extends StatelessWidget {
  const _TickBox({required this.selected, required this.name, required this.onTap});
  final bool selected;
  final String name;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        checked: selected,
        label: 'Include $name',
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: onTap,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: selected ? kLime : Colors.white,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: selected ? kDark : const Color(0xFF6B7280), width: selected ? 1.2 : 1),
            ),
            child: selected ? const Icon(LucideIcons.check, size: 14, color: kDark) : null,
          ),
        ),
      );
}

/// Grey quantity box: "6  units", or "Not recorded" until the person types a quantity.
class _QtyBox extends StatelessWidget {
  const _QtyBox({required this.controller, required this.unit, required this.name, required this.onChanged});
  final TextEditingController controller;
  final String unit, name;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) {
    final empty = controller.text.trim().isEmpty;
    return Container(
      width: 106,
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(color: kBoTile, borderRadius: BorderRadius.circular(8), border: Border.all(color: kBoCardLine)),
      child: Row(children: [
        SizedBox(
          // the number sits next to its unit ("6  units"); the hint takes the whole box
          width: empty ? 86 : 8.0 * controller.text.length + 8,
          child: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,6}(\.\d{0,3})?'))],
            style: inter(empty ? 12 : 12.5, empty ? 500 : 600),
            decoration: InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
              hintText: 'Not recorded',
              hintStyle: inter(12, 500, color: kMuted),
              semanticCounterText: 'Quantity of $name',
            ),
            onChanged: (_) => onChanged(),
          ),
        ),
        if (!empty) ...[const SizedBox(width: 8), Text(unit, style: inter(10, 400, color: kMuted))],
      ]),
    );
  }
}
