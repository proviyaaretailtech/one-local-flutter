import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'table_widgets.dart';

/// Figma "Merge Tables" (screen-merge-tables): pick tables of one dining area, see the combined seating, Join Tables, Split Existing Merges, Cancel.
/// The server states the rule (same area, at most one table with an open order) and enforces it; its sentence is shown when it refuses.
class MergeScreen extends StatefulWidget {
  const MergeScreen({super.key, required this.env, this.startTableId});
  final TablesEnv env;

  /// Table already ticked when the screen opens (from "Merge Table" on an order).
  final String? startTableId;
  @override
  State<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends State<MergeScreen> {
  Facts? _d;
  String? _error;
  late final Set<String> _sel = {if (widget.startTableId != null) widget.startTableId!};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.env.api.floor();
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  List<Facts> get _tables => _d?.l('tables') ?? const [];
  List<Facts> get _chosen => [for (final t in _tables) if (_sel.contains(t.s('id'))) t];

  Future<void> _join() async {
    setState(() => _busy = true);
    try {
      final r = await widget.env.api.merge(_chosen.map((t) => t.s('id')).toList());
      if (!mounted) return;
      showToast(context, 'Tables joined: ${r.n('combined_seats').toInt()} Pax.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, sayError(e));
    }
  }

  Future<void> _splitExisting() async {
    final groups = <String, Facts>{};
    for (final t in _tables) {
      final m = t.mo('merge');
      if (m != null) groups[m.s('id')] = m;
    }
    if (groups.isEmpty) return showToast(context, 'No tables are joined right now.');
    final pick = await pickOne<String>(context, 'Split which tables?', [
      for (final g in groups.values) (g.s('id'), g.ls('labels').join(' + '), '${g.n('combined_seats').toInt()} Pax')
    ]);
    if (pick == null || !mounted) return;
    try {
      await widget.env.api.split(mergeId: pick);
      if (!mounted) return;
      showToast(context, 'Tables split.');
      setState(() => _sel.clear());
      _load();
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final chosen = _chosen;
    final total = chosen.fold<num>(0, (a, t) => a + t.n('own_seats'));
    final rule = _d?.m('rule').so('merge');
    final ids = chosen.map((t) => t.s('label')).toList();
    return TablesPage(
      env: widget.env,
      title: 'Merge Tables',
      subtitle: 'Select tables to combine seating capacity',
      back: true,
      onRefresh: _load,
      children: [
        if (_d == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (_d != null)
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.5,
            children: [
              for (final t in _tables)
                TableCard(
                  table: t,
                  compact: true,
                  busyLook: true,
                  selected: _sel.contains(t.s('id')),
                  onTap: () => setState(() => _sel.contains(t.s('id')) ? _sel.remove(t.s('id')) : _sel.add(t.s('id'))),
                ),
            ],
          ),
        if (_d != null)
          Container(
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: kLine)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Merge Seating', style: inter(20, 700)),
              const Divider(height: 24, color: kLine),
              if (chosen.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 14), child: Text('Tap tables above to select them.', style: inter(15, 400, color: kMuted))),
              if (chosen.isNotEmpty)
                Wrap(spacing: 12, runSpacing: 12, children: [
                  for (final t in chosen)
                    Container(
                      width: 150,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: kAvailBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: kAvailBorder, width: 1.6)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t.s('label'), style: inter(22, 700, color: kPostedText)), Text(pax(t.n('own_seats')), style: inter(15, 400, color: kMuted))]),
                    ),
                ]),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                decoration: BoxDecoration(color: kGreyBg, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Expanded(child: Text('Combined Total', style: inter(18, 500, color: kMuted))),
                  Text(pax(total), key: const ValueKey('merge-total'), style: inter(24, 700, color: kPostedText)),
                ]),
              ),
              if (rule != null)
                Container(
                  margin: const EdgeInsets.only(top: 14),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFFFEF9E7), borderRadius: BorderRadius.circular(12), border: Border.all(color: kBusyBorder)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(LucideIcons.circleAlert, size: 20, color: kBusyBorder),
                    const SizedBox(width: 10),
                    Expanded(child: Text(ids.length >= 2 ? '${ids.join(' & ')}: $rule' : rule, style: inter(15.5, 400, color: const Color(0xFFB45309)))),
                  ]),
                ),
              const SizedBox(height: 18),
              LimeButton('Join Tables', busy: _busy, height: 58, onPressed: chosen.length >= 2 ? _join : null),
              TextButton(onPressed: _splitExisting, child: Text('Split Existing Merges', style: inter(18, 500, color: kMuted))),
              TextButton(onPressed: () => Navigator.of(context).maybePop(), child: Text('Cancel', style: inter(18, 500, color: kMuted))),
            ]),
          ),
      ],
    );
  }
}
