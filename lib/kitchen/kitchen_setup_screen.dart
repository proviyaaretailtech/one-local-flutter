import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'add_station_screen.dart';
import 'kitchen_widgets.dart';
import 'station_detail_screen.dart';

/// Figma "Kitchen Configuration" (title bar: "Kitchen Setup"): kitchen stations, printer groups and preparation areas.
class KitchenSetupScreen extends StatefulWidget {
  const KitchenSetupScreen({super.key, required this.env});
  final KitchenEnv env;
  static Route<void> route(KitchenEnv env) => MaterialPageRoute(settings: const RouteSettings(name: KitchenEnv.setupRoute), builder: (_) => KitchenSetupScreen(env: env));
  @override
  State<KitchenSetupScreen> createState() => _KitchenSetupScreenState();
}

class _KitchenSetupScreenState extends State<KitchenSetupScreen> {
  KitchenEnv get env => widget.env;
  Facts? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.config();
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _add(Facts d) async {
    final created = await env.push<bool>(context, AddStationScreen(env: env, config: d));
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) => KitchenPage(
        env: env,
        title: 'Kitchen Setup',
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 16, 14, 24), children: [
          const KitchenHeading('Stations, printers & prep areas', subtitle: 'Set up where orders are prepared and printed.'),
          InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: _body),
        ]),
      );

  List<Widget> _body(Facts d) {
    final can = d.m('can').b('configure');
    final stations = d.l('stations'), printers = d.l('printers'), areas = d.l('prep_areas');
    final unassigned = d.l('unassigned');
    return [
      if (unassigned.isNotEmpty)
        Container(
          key: const ValueKey('unassigned-warning'),
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(color: kAmberBgH, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Some menu items have no kitchen station', style: inter(15, 700, color: kAmberText)),
            const SizedBox(height: 4),
            Text(
              'Their orders show under "Unassigned" on the kitchen display until a station with the same name is added: '
              '${unassigned.map((u) => '${u.s('key')} (${u.n('items').toInt()} ${u.n('items') == 1 ? 'item' : 'items'})').join(', ')}.',
              style: inter(13.5, 400, height: 1.35),
            ),
          ]),
        ),
      _Section(
        title: 'Kitchen stations',
        action: can ? KitchenAddButton('Add station', onPressed: () => _add(d)) : null,
        children: [
          if (stations.isEmpty) _Empty('No stations yet', 'Add a station to route orders to a kitchen.'),
          for (var i = 0; i < stations.length; i++)
            _Row(
              key: ValueKey('station-${stations[i].s('key')}'),
              title: stations[i].s('name'),
              sub: 'Kitchen station',
              last: i == stations.length - 1,
              onTap: () => env.push(context, StationDetailScreen(env: env, stationId: stations[i].s('id'))),
            ),
        ],
      ),
      _Section(
        title: 'Printer groups',
        action: can ? KitchenAddButton('Add printer', onPressed: () => env.later(context, 'Adding a printer')) : null,
        children: [
          if (printers.isEmpty) _Empty('No printer groups yet', 'Add a printer to print kitchen tickets.'),
          for (var i = 0; i < printers.length; i++) _Row(title: printers[i].s('name'), sub: 'Printer group', last: i == printers.length - 1),
        ],
      ),
      _Section(
        title: 'Preparation areas',
        action: can ? KitchenAddButton('Add area', onPressed: () => env.later(context, 'Adding a preparation area')) : null,
        children: [
          if (areas.isEmpty) _Empty('No preparation areas yet', 'Create an area to organize kitchen prep.'),
          for (var i = 0; i < areas.length; i++) _Row(title: areas[i].s('name'), sub: 'Preparation area', last: i == areas.length - 1),
        ],
      ),
      // Kitchen setup is optional (founder, 2026-10-20): with nothing set up, every order goes to the Main Kitchen queue and billing and KOTs work.
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(children: [
          Text('Optional. Until you add stations, every order goes to the Main Kitchen on the kitchen display.',
              key: const ValueKey('kitchen-optional'), textAlign: TextAlign.center, style: inter(13, 400, color: kMuted)),
          TextButton(key: const ValueKey('kitchen-skip'), onPressed: () => Navigator.of(context).maybePop(), child: Text('Skip for now', style: inter(15, 600, color: kLink))),
        ]),
      ),
    ];
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.action});
  final String title;
  final Widget? action;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => InvCard(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
        margin: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Semantics(header: true, child: Text(title, style: inter(19, 700)))),
            ?action,
          ]),
          const SizedBox(height: 8),
          ...children,
        ]),
      );
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.title, required this.sub, this.onTap, this.last = false});
  final String title, sub;
  final VoidCallback? onTap;
  final bool last;
  @override
  Widget build(BuildContext context) => Semantics(
        button: onTap != null,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: kLine))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: inter(17, 500)),
                  const SizedBox(height: 2),
                  Text(sub, style: inter(13.5, 400, color: kMuted)),
                ]),
              ),
              if (onTap != null) const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
            ]),
          ),
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.title, this.sub);
  final String title, sub;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: inter(17, 500)),
          const SizedBox(height: 6),
          Text(sub, style: inter(14, 400, color: kMuted)),
        ]),
      );
}
