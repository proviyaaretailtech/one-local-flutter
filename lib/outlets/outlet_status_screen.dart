import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../home/home_nav.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'add_outlet_screen.dart';
import 'outlet_header.dart' show OutletHeader, outletStatusColor, kOutletChipBg, kOutletChipText, kOutletOnline;
import 'outlets_api.dart';

/// Restaurant status (Figma `ALL ONLINE`): every outlet the person may see, searchable by name, ID or locality. Each card: name, ID,
/// locality, Delivery status (taking One Local orders or "Not receiving orders"), Rush mode, and a gear to the outlet's settings.
/// Outlets still being verified (or rejected) show that instead, with the switches off. "Add another restaurant/store" at the end.
/// Every rule (who may switch, which outlet is verified) is the server's; the screen draws its answer.
class OutletStatusScreen extends StatefulWidget {
  const OutletStatusScreen({super.key, required this.api});
  final OutletsApi api;

  @override
  State<OutletStatusScreen> createState() => _OutletStatusScreenState();
}

class _OutletStatusScreenState extends State<OutletStatusScreen> {
  final _search = TextEditingController();
  OutletOverview? _o;
  String? _error;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await widget.api.list();
      if (mounted) setState(() => (_o = o, _error = null));
    } on PartnerApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load your outlets. Check your connection and try again.');
    }
  }

  Future<void> _set(Outlet o, {bool? accepting, bool? rushMode}) async {
    setState(() => _busy.add(o.id));
    try {
      await widget.api.setChannel(o.id, accepting: accepting, rushMode: rushMode);
      await _load();
    } on PartnerApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not change the outlet. Try again.');
    } finally {
      if (mounted) setState(() => _busy.remove(o.id));
    }
  }

  Future<void> _add() async {
    final o = _o;
    final added = await Navigator.of(context).push<Outlet>(
        MaterialPageRoute(builder: (_) => AddOutletScreen(api: widget.api, needsFssai: o?.needsFssai ?? false)));
    await _load();
    OutletHeader.refresh();
    if (added != null && mounted) showToast(context, '${added.name} was sent to One Local for verification.');
  }

  List<Outlet> get _shown {
    final q = _search.text.trim().toLowerCase();
    final all = _o?.outlets ?? const <Outlet>[];
    if (q.isEmpty) return all;
    return all.where((o) => o.name.toLowerCase().contains(q) || o.code.toLowerCase().contains(q) || o.locality.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          AppHeader(
            title: '${outletNounTitle()} status',
            safeTop: false,
            back: true,
            backKey: const ValueKey('outlets-back'),
            under: o == null || o.chip.isEmpty
                ? null
                : Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(color: kOutletChipBg, borderRadius: BorderRadius.circular(999)),
                      child: Text(o.chip, style: inter(11, 600, color: kOutletChipText)),
                    ),
                  ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 32), children: [
                TextField(
                  key: const ValueKey('outlets-search'),
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search ${outletNoun()} name or ID',
                    prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
                    filled: true,
                    fillColor: Colors.white,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
                  ),
                ),
                const SizedBox(height: 14),
                if (_error != null && o == null) ...[
                  Text(_error!, style: inter(14, 500, color: kError)),
                  const SizedBox(height: 10),
                  OutlinedButton(onPressed: _load, child: const Text('Try again')),
                ] else if (o == null)
                  const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
                else ...[
                  for (final x in _shown) ...[_OutletCard(outlet: x, busy: _busy.contains(x.id), onSet: _set), const SizedBox(height: 12)],
                  if (_shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(o.outlets.isEmpty ? 'No outlet yet.' : 'No outlet matches “${_search.text.trim()}”.',
                          textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
                    ),
                  if (o.canAdd && o.draft != null) ...[
                    Semantics(
                      button: true,
                      label: 'Continue adding ${o.draft!['name'] ?? 'the new outlet'}',
                      excludeSemantics: true,
                      child: InkWell(
                        key: const ValueKey('outlets-continue-draft'),
                        borderRadius: BorderRadius.circular(16),
                        onTap: _add,
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: const Color(0xFFFFF7E6), borderRadius: BorderRadius.circular(16)),
                          child: Row(children: [
                            const Icon(LucideIcons.filePen, size: 20, color: Color(0xFF92400E)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('Continue: ${(o.draft!['name'] ?? '').toString().isEmpty ? 'new outlet' : o.draft!['name']}', style: inter(15, 600, color: const Color(0xFF92400E))),
                                Text('Saved draft · not sent to One Local yet', style: inter(12.5, 400, color: const Color(0xFF92400E))),
                              ]),
                            ),
                            const Icon(LucideIcons.chevronRight, size: 18, color: Color(0xFF92400E)),
                          ]),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (o.canAdd)
                    Semantics(
                      button: true,
                      label: 'Add another ${outletNoun()}',
                      excludeSemantics: true,
                      child: InkWell(
                        key: const ValueKey('outlets-add'),
                        borderRadius: BorderRadius.circular(16),
                        onTap: _add,
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                              color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kOutletOnline.withValues(alpha: 0.5))),
                          child: Row(children: [
                            const Icon(LucideIcons.plus, size: 20, color: kOutletOnline),
                            const SizedBox(width: 10),
                            Expanded(child: Text('Add another ${outletNoun()}', style: inter(15, 600, color: kOutletOnline))),
                            const Icon(LucideIcons.chevronRight, size: 18, color: kOutletOnline),
                          ]),
                        ),
                      ),
                    ),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _OutletCard extends StatelessWidget {
  const _OutletCard({required this.outlet, required this.busy, required this.onSet});
  final Outlet outlet;
  final bool busy;
  final Future<void> Function(Outlet, {bool? accepting, bool? rushMode}) onSet;

  @override
  Widget build(BuildContext context) {
    final o = outlet;
    final enabled = o.canToggle && !busy;
    final where = [o.code, if (o.locality.isNotEmpty) o.locality].join(' · ');
    return Container(
      key: ValueKey('outlet-card-${o.id}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(o.name, style: inter(16, 700)),
              const SizedBox(height: 2),
              Text('ID $where', style: inter(12.5, 400, color: kMuted)),
              const SizedBox(height: 6),
              Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: outletStatusColor(o.status), shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(o.statusLabel, style: inter(12.5, 600, color: outletStatusColor(o.status))),
              ]),
            ]),
          ),
          Semantics(
            button: true,
            label: 'Settings of ${o.name}',
            excludeSemantics: true,
            child: IconButton(
              key: ValueKey('outlet-gear-${o.id}'),
              onPressed: () => HomeNav.go(context, HomeNav.setup, 'Outlet settings'),
              icon: const Icon(LucideIcons.settings, size: 20, color: kInk),
            ),
          ),
        ]),
        if (!o.verified) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: o.verification == 'rejected' ? const Color(0xFFFDECEA) : const Color(0xFFFFF7E6), borderRadius: BorderRadius.circular(10)),
            child: Text(
              o.verification == 'rejected'
                  ? 'One Local did not approve this outlet${o.reviewNote.isEmpty ? '.' : ': ${o.reviewNote}'}'
                  : 'Waiting for One Local to verify this outlet${o.reference.isEmpty ? '.' : ' (${o.reference}).'}',
              style: inter(12.5, 500, color: o.verification == 'rejected' ? kError : const Color(0xFF92400E)),
            ),
          ),
        ],
        const Divider(height: 22, color: kLine),
        _Toggle(
          key: ValueKey('outlet-delivery-${o.id}'),
          title: 'Delivery status',
          subtitle: o.accepting ? 'Receiving One Local orders' : o.deliveryLabel,
          value: o.accepting,
          onChanged: enabled ? (v) => onSet(o, accepting: v) : null,
        ),
        const SizedBox(height: 6),
        _Toggle(
          key: ValueKey('outlet-rush-${o.id}'),
          title: 'Rush mode',
          subtitle: outletIsRestaurant()
              ? (o.rushMode ? '+${o.rushExtraMinutes} min added to preparation time' : 'Adds ${o.rushExtraMinutes} min when the kitchen is busy')
              : (o.rushMode ? '+${o.rushExtraMinutes} min added to packing time' : 'Adds ${o.rushExtraMinutes} min to packing time when the store is busy'),
          value: o.rushMode,
          onChanged: enabled ? (v) => onSet(o, rushMode: v) : null,
        ),
        if (o.verified && !o.canToggle && o.toggleNote.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(o.toggleNote, style: inter(12, 400, color: kMuted)),
        ],
      ]),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({super.key, required this.title, required this.subtitle, required this.value, required this.onChanged});
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: inter(14, 600)),
              Text(subtitle, style: inter(12.5, 400, color: kMuted)),
            ]),
          ),
          Switch(value: value, onChanged: onChanged, activeTrackColor: kOutletOnline),
        ]),
      );
}
