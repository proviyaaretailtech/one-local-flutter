import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'damage_flow.dart';
import 'stock_env.dart';
import 'stock_kit.dart';

enum AdjustKind { damage, throwAway }

/// The short form behind "Record damage" and "Throw away": product, where it is, how many, why. It makes one adjustment document and
/// sends it for approval; nothing changes in stock until it is approved.
class AdjustForm extends StatefulWidget {
  const AdjustForm({super.key, required this.env, required this.kind, required this.reasons, required this.onCancel, required this.onSent, this.itemId});
  final StockEnv env;
  final AdjustKind kind;
  final List<String> reasons;
  final String? itemId;
  final VoidCallback onCancel, onSent;
  @override
  State<AdjustForm> createState() => _AdjustFormState();
}

class _AdjustFormState extends State<AdjustForm> {
  StockEnv get env => widget.env;
  bool get _damage => widget.kind == AdjustKind.damage;
  final _qty = TextEditingController(), _note = TextEditingController();
  Facts? _detail;
  List<StockPlace> _places = const [];
  StockPlace? _place;
  String _reason = '';
  String? _key; // one key for this send, kept for a retry
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final rs = widget.reasons;
    _reason = rs.contains('Damaged in store') ? 'Damaged in store' : rs.firstOrNull ?? '';
    if (widget.itemId != null) _useItem(widget.itemId!);
  }

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _useItem(String id) async {
    try {
      final d = await env.api.stockDetail(id);
      if (!mounted) return;
      final places = placesOf(d, quarantine: !_damage);
      setState(() {
        _detail = d;
        _places = places;
        _place = places.firstOrNull;
        _key = null;
        if (!_damage && _place != null) _qty.text = qty(_place!.onHand).replaceAll(',', '');
      });
    } catch (e) {
      if (mounted) showToast(context, problem(e));
    }
  }

  Future<void> _pickItem() async {
    final it = await pickItem(context, env.api);
    if (it != null) await _useItem(it.s('id'));
  }

  Future<void> _pickPlace() async {
    final unit = _detail?.m('item').s('unit') ?? '';
    final v = await pickOne<StockPlace>(context, _damage ? 'Where is the damaged stock?' : 'Which held-apart stock?', [for (final p in _places) (p, p.label, units(p.onHand, unit))], current: _place);
    if (v != null) setState(() => _place = v);
  }

  Future<void> _pickReason() async {
    final v = await pickOne<String>(context, 'Why?', [for (final r in widget.reasons) (r, r, null)], current: _reason);
    if (v != null) setState(() => _reason = v);
  }

  Future<void> _send() async {
    final d = _detail, p = _place;
    final n = num.tryParse(_qty.text.trim());
    if (d == null) return showToast(context, 'Choose a product first.');
    if (p == null) return showToast(context, _damage ? 'There is no stock of this product to mark as damaged.' : 'Nothing of this product is held apart.');
    if (n == null || n <= 0) return showToast(context, 'Enter how many units.');
    if (n > p.onHand) return showToast(context, 'Only ${qty(p.onHand)} there. Enter ${qty(p.onHand)} or fewer.');
    if (_reason.isEmpty) return showToast(context, 'Choose why.');
    final item = d.m('item');
    setState(() => _busy = true);
    try {
      _key ??= InventoryApi.newKey();
      final doc = await env.api.createDraft(
        'adjustment',
        fields: {'title': _damage ? damageTitle : 'Throw away', 'reason': _reason, 'note': _note.text.trim()},
        lines: [DraftLine(itemId: item.s('id'), itemName: item.s('name'), sku: item.s('sku'), fromBinId: p.binId, lotId: p.lotId, adjustType: _damage ? 'quarantine' : 'write_off', qty: n)],
        key: _key!,
      );
      await env.api.act(doc.id, 'submit', version: doc.version);
      _key = null;
      if (!mounted) return;
      showToast(context, 'Sent for approval. Nothing changes in stock until it is approved.');
      widget.onSent();
    } catch (e) {
      if (mounted) showToast(context, problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final unit = d?.m('item').s('unit') ?? '';
    return InvCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InvCardHead(_damage ? 'Record damage' : 'Throw away ${d?.m('item').s('name') ?? ''}'.trim(),
            subtitle: _damage ? 'Keeps it off the shelf. An owner or manager approves it.' : 'Removes it for good. An owner or manager approves it.'),
        if (_damage || widget.itemId == null) ...[
          const InvLabel('Product'),
          InvPickBox(value: d == null ? 'Choose a product' : '${d.m('item').s('name')} · ${d.m('item').s('sku')}', onTap: _busy ? null : _pickItem, semantic: 'Product'),
        ],
        if (d != null) ...[
          InvLabel(_damage ? 'Where is it?' : 'From'),
          InvPickBox(
            value: _place == null ? (_damage ? 'No stock of it on hand' : 'Nothing held apart') : '${_place!.label} · ${units(_place!.onHand, unit)}',
            onTap: _places.length > 1 && !_busy ? _pickPlace : null,
            chevron: _places.length > 1,
            semantic: 'Place',
          ),
        ],
        const InvLabel('How many?'),
        InvInput(key: const ValueKey('adjust-qty'), controller: _qty, number: true, hint: _place == null ? 'Units' : 'Up to ${qty(_place!.onHand)}'),
        const InvLabel('Why?'),
        InvPickBox(value: _reason.isEmpty ? 'Choose why' : _reason, onTap: _busy || widget.reasons.isEmpty ? null : _pickReason, semantic: 'Reason'),
        const InvLabel('Note (optional)'),
        InvInput(controller: _note, hint: _damage ? 'For example: bottle cap leaking' : 'For example: returned to supplier'),
        const SizedBox(height: 12),
        InvPrimary('Send for approval', busy: _busy, onPressed: _busy ? null : _send),
        InvSecondary('Cancel', onPressed: _busy ? null : widget.onCancel),
      ]),
    );
  }
}
