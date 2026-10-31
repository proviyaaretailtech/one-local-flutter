import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/theme.dart';
import 'bill_api.dart';
import 'table_widgets.dart';

/// A manual discount at checkout (founder, 31 Oct 2026): ₹ or % off the bill, with a reason. Up to the business's limit (10 % unless
/// set) anyone who takes payment can give it; above it only a manager (the database checks and says so, and records who approved).
/// Answers true when the discount was given or taken off.
Future<bool> showManualDiscountSheet(BuildContext context, {required BillApi api, required Facts order}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _DiscountSheet(api: api, order: order),
    ) ??
    false;

const _reasons = ['Regular guest', 'Complaint', 'Staff meal', "Owner's guest", 'Festival offer'];

class _DiscountSheet extends StatefulWidget {
  const _DiscountSheet({required this.api, required this.order});
  final BillApi api;
  final Facts order;
  @override
  State<_DiscountSheet> createState() => _DiscountSheetState();
}

class _DiscountSheetState extends State<_DiscountSheet> {
  String _kind = 'percent';
  final _value = TextEditingController(), _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _value.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _value.dispose();
    _reason.dispose();
    super.dispose();
  }

  /// The dishes' value (what the % is of), from the bill's lines.
  num get _gross => billItems(widget.order).fold<num>(0, (s, i) => s + i.n('line_total'));
  num get _typed => num.tryParse(_value.text.trim()) ?? 0;
  num get _off => _kind == 'percent' ? (_gross * _typed / 100 * 100).round() / 100 : _typed;
  num get _limit => widget.order.no('discount_limit_pct') ?? 10;

  Future<void> _save({bool remove = false}) async {
    if (!remove) {
      if (_typed <= 0) return setState(() => _error = 'Enter the discount.');
      if (_kind == 'percent' && _typed > 100) return setState(() => _error = 'A percentage is at most 100.');
      if (_reason.text.trim().length < 3) return setState(() => _error = 'Say why (3 characters or more).');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.discount(widget.order.s('id'), kind: remove ? 'amount' : _kind, value: remove ? 0 : _typed, reason: remove ? '' : _reason.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = sayError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final manual = widget.order.mo('manual_discount');
    final pct = _gross == 0 ? 0 : _off * 100 / _gross;
    Widget kindPill(String kind, String label) => Expanded(
          child: ChoiceChip(
            key: ValueKey('disc-kind-$kind'),
            label: SizedBox(width: double.infinity, child: Text(label, textAlign: TextAlign.center, style: inter(14, 800, color: _kind == kind ? kLimeBtn : kInk))),
            selected: _kind == kind,
            showCheckmark: false,
            selectedColor: kInk,
            backgroundColor: Colors.white,
            onSelected: (_) => setState(() => _kind = kind),
          ),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 14, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 12),
          Row(children: [
            const Icon(LucideIcons.badgePercent, size: 20, color: kInk),
            const SizedBox(width: 8),
            Expanded(child: Text('Manual discount · ${widget.order.s('display_no')}', style: inter(19, 800))),
          ]),
          Text('Dishes ${money(_gross)}. Up to ${_limit.toStringAsFixed(_limit == _limit.roundToDouble() ? 0 : 1)}% for cashiers; more needs a manager.',
              key: const ValueKey('disc-limit'), style: inter(13, 500, color: kMuted)),
          const SizedBox(height: 14),
          Row(children: [kindPill('percent', '% off'), const SizedBox(width: 10), kindPill('amount', '₹ off')]),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('disc-value'),
            controller: _value,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            style: inter(26, 800),
            decoration: InputDecoration(
              prefixText: _kind == 'amount' ? '₹ ' : null,
              suffixText: _kind == 'percent' ? '%' : null,
              hintText: '0',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          if (_kind == 'percent')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 8, children: [
                for (final p in const [5, 10, 15, 20])
                  ActionChip(key: ValueKey('disc-quick-$p'), label: Text('$p%', style: inter(13, 700)), onPressed: () => _value.text = '$p'),
              ]),
            ),
          if (_typed > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${money(_off)} off · ${pct.toStringAsFixed(1)}% of the dishes${pct > _limit ? ' · needs a manager' : ''}',
                  key: const ValueKey('disc-preview'), style: inter(13.5, 700, color: pct > _limit ? const Color(0xFFB45309) : kInk)),
            ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('disc-reason'),
            controller: _reason,
            maxLength: 120,
            decoration: InputDecoration(labelText: 'Reason', border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
          ),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final r in _reasons)
              ActionChip(key: ValueKey('disc-reason-$r'), label: Text(r, style: inter(12.5, 600)), onPressed: () => _reason.text = r),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const ValueKey('disc-error'), style: inter(14, 500, color: kError))),
          const SizedBox(height: 14),
          LimeButton('Give discount', key: const ValueKey('disc-save'), height: 52, busy: _busy, onPressed: _busy ? null : _save),
          if (manual != null)
            TextButton(
              key: const ValueKey('disc-remove'),
              onPressed: _busy ? null : () => _save(remove: true),
              child: Text('Take the discount off', style: inter(14, 700, color: kError)),
            ),
        ]),
      ),
    );
  }
}
