import 'package:flutter/material.dart';

import '../api/rpc_client.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'kitchen_api.dart';
import 'kitchen_widgets.dart';

/// Figma "Add Kitchen Station": station name, preparation area, KDS group and printer group, then "Create station".
/// [config] is the answer of `kitchen_config` the setup screen already has (the lists to choose from).
class AddStationScreen extends StatefulWidget {
  const AddStationScreen({super.key, required this.env, required this.config});
  final KitchenEnv env;
  final Facts config;
  @override
  State<AddStationScreen> createState() => _AddStationScreenState();
}

class _AddStationScreenState extends State<AddStationScreen> {
  KitchenEnv get env => widget.env;
  final _name = TextEditingController();
  String? _areaId, _groupId, _printerId;
  bool _busy = false;
  // One key for this form: a second tap after a lost answer sends the same request again and gets the same station back.
  final _key = KitchenApi.newKey();

  @override
  void initState() {
    super.initState();
    final printers = widget.config.l('printers');
    if (printers.isNotEmpty) _printerId = printers.first.s('id'); // the frame opens with the first printer group chosen
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String _nameOf(List<Facts> list, String? id, String empty) {
    for (final f in list) {
      if (f.s('id') == id) return f.s('name');
    }
    return empty;
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showToast(context, 'Enter a station name.');
      return;
    }
    setState(() => _busy = true);
    try {
      await env.api.saveStation(name: name, kdsGroupId: _groupId, printerId: _printerId, prepAreaId: _areaId, key: _key);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on KitchenApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } on RpcException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not create the station. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final areas = widget.config.l('prep_areas'), stations = widget.config.l('stations'), printers = widget.config.l('printers');
    return KitchenPage(
      env: env,
      title: 'Add Station',
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 16, 14, 24), children: [
        const KitchenHeading('Station details', subtitle: 'Add a kitchen station and connect its routing.', crumb: 'Kitchen setup'),
        InvCard(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          margin: const EdgeInsets.only(bottom: 14, top: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const InvLabel('Station name *'),
            InvInput(controller: _name, hint: 'Enter station name', label: 'Station name'),
            const SizedBox(height: 8),
            const InvLabel('Preparation area'),
            InvPickBox(
              value: areas.isEmpty ? 'No areas configured' : _nameOf(areas, _areaId, 'Select a preparation area'),
              semantic: 'Preparation area',
              onTap: areas.isEmpty
                  ? null
                  : () async {
                      final v = await pickOne<String>(context, 'Preparation area', [for (final a in areas) (a.s('id'), a.s('name'), null)], current: _areaId);
                      if (v != null) setState(() => _areaId = v);
                    },
            ),
            const SizedBox(height: 8),
            const InvLabel('KDS group'),
            InvPickBox(
              value: _nameOf(stations, _groupId, 'Select a KDS group'),
              semantic: 'KDS group',
              onTap: () async {
                final v = await pickOne<String>(context, 'KDS group', [for (final s in stations) (s.s('id'), s.s('name'), 'Orders also show on this station\'s display')], current: _groupId);
                if (v != null) setState(() => _groupId = v);
              },
            ),
            const SizedBox(height: 8),
            const InvLabel('Printer group'),
            InvPickBox(
              value: printers.isEmpty ? 'No printer groups' : _nameOf(printers, _printerId, 'Select a printer group'),
              semantic: 'Printer group',
              onTap: printers.isEmpty
                  ? null
                  : () async {
                      final v = await pickOne<String>(context, 'Printer group', [for (final p in printers) (p.s('id'), p.s('name'), null)], current: _printerId);
                      if (v != null) setState(() => _printerId = v);
                    },
            ),
          ]),
        ),
        if (areas.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 18),
            decoration: BoxDecoration(color: kLimeSoftH, borderRadius: BorderRadius.circular(16)),
            child: Text('You can assign a preparation area after one is created.', style: inter(14.5, 400)),
          ),
        Row(children: [
          Expanded(
            flex: 4,
            child: Material(
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kLine, width: 1.2)),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _busy ? null : () => Navigator.of(context).maybePop(),
                child: Container(height: 54, alignment: Alignment.center, child: Text('Cancel', style: inter(16, 600))),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 5,
            child: Material(
              color: const Color(0xFF76EC00),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                key: const ValueKey('create-station'),
                borderRadius: BorderRadius.circular(16),
                onTap: _busy ? null : _create,
                child: Container(
                  height: 54,
                  alignment: Alignment.center,
                  child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kInk)) : Text('Create station', style: inter(16, 600)),
                ),
              ),
            ),
          ),
          const Spacer(flex: 2),
        ]),
      ]),
    );
  }
}
