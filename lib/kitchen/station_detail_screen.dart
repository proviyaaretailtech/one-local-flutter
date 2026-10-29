import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'kitchen_widgets.dart';

/// Figma "Main Kitchen station detail": the station and its routing (kitchen display group, printer group, preparation area).
class StationDetailScreen extends StatefulWidget {
  const StationDetailScreen({super.key, required this.env, required this.stationId});
  final KitchenEnv env;
  final String stationId;
  @override
  State<StationDetailScreen> createState() => _StationDetailScreenState();
}

class _StationDetailScreenState extends State<StationDetailScreen> {
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
      final d = await env.api.station(widget.stationId);
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorSentence(e));
    }
  }

  @override
  Widget build(BuildContext context) => KitchenPage(
        env: env,
        title: _d?.s('name').isNotEmpty == true ? _d!.s('name') : 'Station',
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 16, 14, 24), children: [
          const KitchenHeading('', crumb: 'Kitchen setup'),
          InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: _body),
        ]),
      );

  List<Widget> _body(Facts d) {
    final name = d.s('name');
    String of(String k, String none) => d.mo(k)?.s('name') ?? none;
    return [
      InvCard(
        padding: const EdgeInsets.all(18),
        margin: const EdgeInsets.only(bottom: 14),
        child: Row(children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(color: kGreenIconBg, borderRadius: BorderRadius.circular(16)),
            child: const Icon(LucideIcons.house, size: 22, color: kInk),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: inter(22, 700)),
              const SizedBox(height: 4),
              Text('Kitchen station · KDS', style: inter(14.5, 400, color: kMuted)),
            ]),
          ),
        ]),
      ),
      InvCard(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
        margin: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text('Station routing', style: inter(19, 700))),
          const SizedBox(height: 10),
          _Field('Kitchen display group', d.mo('kds_group')?.s('name') ?? name),
          _Field('Printer group', of('printer', 'Not assigned')),
          _Field('Preparation area', of('prep_area', 'Not assigned'), last: true),
        ]),
      ),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
        child: Text('Orders assigned to $name appear in this station\'s KDS queue.', style: inter(14.5, 400, color: kMuted, height: 1.35)),
      ),
    ];
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.last = false});
  final String label, value;
  final bool last;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(border: Border(top: const BorderSide(color: kLine), bottom: last ? BorderSide.none : BorderSide.none)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(14, 400, color: kMuted)),
          const SizedBox(height: 6),
          Text(value, style: inter(17, 500)),
        ]),
      );
}
