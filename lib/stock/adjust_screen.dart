import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'damage_flow.dart' show PendingCard, problem;
import 'damage_screens.dart' show AdjustForm, AdjustKind;
import 'stock_env.dart';
import 'stock_kit.dart';
import '../ui/i18n.dart';
import '../ui/motion.dart';

/// Adjust (J.101): correct stock in four plain ways — add stock, remove stock, mark damaged, throw away. Each one is sent for
/// approval (the person who raised it cannot approve it); below the form, everything waiting for approval, with Approve and
/// Send back for those allowed to.
class AdjustStockScreen extends StatefulWidget {
  const AdjustStockScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;
  @override
  State<AdjustStockScreen> createState() => _AdjustStockScreenState();
}

const _kinds = [
  ('add', 'Add stock', LucideIcons.plus),
  ('remove', 'Remove stock', LucideIcons.minus),
  ('damage', 'Damaged', LucideIcons.packageX),
  ('throw', 'Throw away', LucideIcons.trash2),
];

class _AdjustStockScreenState extends State<AdjustStockScreen> {
  StockEnv get env => widget.env;
  String _kind = 'add';
  Facts? _options;
  List<InvDocument>? _pending;
  String? _busyId;
  int _formSeq = 0; // a fresh form after each send

  // add / remove form
  Facts? _item, _detail;
  String? _binId, _reason, _key;
  final _qty = TextEditingController(), _note = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.itemId != null) _chooseItem(widget.itemId!);
  }

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await env.api.options();
      if (mounted) setState(() => _options = o);
    } catch (_) {}
    try {
      final rows = await env.api.documents('adjustment', statuses: ['awaiting_approval'], limit: 20);
      final docs = [for (final r in rows) await env.api.document(r.s('id'))];
      if (mounted) setState(() => _pending = docs);
    } catch (_) {
      if (mounted) setState(() => _pending = const []);
    }
  }

  List<String> get _reasons => _options?.m('reasons').ls('adjustment') ?? const [];
  String? get _meId => _options?.m('me').so('id');

  Future<void> _chooseItem(String id) async {
    try {
      final d = await env.api.stockDetail(id);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _item = d.m('item');
        _binId = null;
      });
    } catch (e) {
      if (mounted) showToast(context, problem(e));
    }
  }

  Future<void> _pickItem() async {
    final it = await pickItem(context, env.api);
    if (it != null && mounted) await _chooseItem(it.s('id'));
  }

  /// Where to take from (remove: places that have it, not the damaged area) or put to (add: any place, not the damaged area).
  List<(String id, String label, String? sub)> get _places {
    if (_kind == 'remove') {
      return [
        for (final b in _detail?.l('bins') ?? const <Facts>[])
          if (b.s('zone') != 'quarantine' && b.n('on_hand') > 0) (b.s('id'), b.s('name'), '${qty(b.n('on_hand'))} here'),
      ];
    }
    return [
      for (final b in _options?.l('bins') ?? const <Facts>[])
        if (b.s('zone') != 'quarantine') (b.s('id'), b.s('name'), null),
    ];
  }

  Future<void> _send() async {
    final item = _item, n = num.tryParse(_qty.text.trim());
    if (item == null) return showToast(context, 'Choose a product first.');
    if (n == null || n <= 0) return showToast(context, 'Enter how many.');
    final places = _places;
    final bin = _binId ?? (places.isEmpty ? null : places.first.$1);
    if (_kind == 'remove' && bin == null) return showToast(context, 'There is no stock of this product to remove.');
    final here = _kind == 'remove' ? _detail!.l('bins').firstWhere((b) => b.s('id') == bin).n('on_hand') : null;
    if (here != null && n > here) return showToast(context, 'Only ${qty(here)} are there.');
    final reason = _reason ?? (_reasons.isEmpty ? '' : _reasons.first);
    setState(() => _sending = true);
    _key ??= InventoryApi.newKey();
    try {
      final doc = await env.api.createDraft(
        'adjustment',
        fields: {'title': _kind == 'add' ? 'Stock added' : 'Stock removed', 'reason': reason, if (_note.text.trim().isNotEmpty) 'note': _note.text.trim()},
        lines: [
          DraftLine(
            itemId: item.s('id'),
            itemName: item.s('name'),
            sku: item.s('sku'),
            adjustType: _kind == 'add' ? 'increase' : 'decrease',
            qty: n,
            fromBinId: _kind == 'remove' ? bin : null,
            toBinId: _kind == 'add' ? bin : null,
          ),
        ],
        key: _key!,
      );
      final sent = await env.api.act(doc.id, 'submit', version: doc.version);
      if (!mounted) return;
      showToast(context, 'Sent for approval as ${sent.number}. Stock changes once a manager approves it.');
      setState(() {
        _key = null;
        _qty.clear();
        _note.clear();
      });
      _load();
    } catch (e) {
      if (mounted) showToast(context, problem(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _approve(InvDocument d) async {
    final ok = await showOlDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Approve ${d.number}?', style: inter(18, 700)),
        content: Text(tr('Stock changes as soon as you approve. This cannot be undone; a mistake needs a new adjustment.'), style: inter(14, 400, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Approve'))),
        ],
      ),
    );
    if (ok == true) await _act(d, 'approve', done: '${d.number} approved. Stock is updated.');
  }

  Future<void> _sendBack(InvDocument d) async {
    final note = await askNote(context, 'Why send it back?', hint: tr('For example: wrong quantity'), action: tr('Send back'));
    if (note != null && note.trim().isNotEmpty) await _act(d, 'reject', note: note.trim(), done: '${d.number} sent back. Nothing changed in stock.');
  }

  Future<void> _act(InvDocument d, String action, {String? note, required String done}) async {
    setState(() => _busyId = d.id);
    try {
      await env.api.act(d.id, action, version: d.version, note: note);
      if (mounted) showToast(context, done);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, problem(e));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) => StockScaffold(
        env: env,
        title: tr('Adjust stock'),
        line: tr('Fix stock that is wrong, damaged or to be thrown away. A manager approves each change.'),
        onRefresh: _load,
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (id, label, icon) in _kinds)
              Material(
                color: id == _kind ? kLimeH : Colors.white,
                shape: StadiumBorder(side: BorderSide(color: id == _kind ? kLimeH : kCardLine)),
                child: InkWell(
                  key: ValueKey('adjust-kind-$id'),
                  customBorder: const StadiumBorder(),
                  onTap: () => setState(() {
                    _kind = id;
                    _binId = null;
                    _formSeq++;
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 15, color: kInk), const SizedBox(width: 6), Text(label, style: inter(13.5, id == _kind ? 700 : 500))]),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 14),
          if (_kind == 'damage' || _kind == 'throw')
            AdjustForm(
              key: ValueKey('adjust-form-$_kind-$_formSeq'),
              env: env,
              kind: _kind == 'damage' ? AdjustKind.damage : AdjustKind.throwAway,
              reasons: _reasons,
              itemId: widget.itemId,
              onCancel: () => setState(() => _formSeq++),
              onSent: () {
                setState(() => _formSeq++);
                _load();
              },
            )
          else
            _addRemoveForm(),
          const SizedBox(height: 18),
          Text(tr('Waiting for approval'), style: inter(16, 700)),
          const SizedBox(height: 10),
          if (_pending == null)
            const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
          else if (_pending!.isEmpty)
            StockEmpty(tr('Nothing waiting'), 'Changes you send show here until a manager approves them.', icon: LucideIcons.circleCheck)
          else
            for (final d in _pending!)
              PendingCard(
                doc: d,
                meId: _meId,
                verb: 'Approve',
                busy: _busyId == d.id,
                onApprove: () => _approve(d),
                onSendBack: () => _sendBack(d),
                onItem: (id) => env.open(context, StockPage.item, itemId: id),
              ),
        ],
      );

  Widget _addRemoveForm() {
    final item = _item;
    final places = _places;
    final bin = _binId ?? (places.isEmpty ? null : places.first.$1);
    final binLabel = places.where((p) => p.$1 == bin).map((p) => p.$2).firstOrNull;
    final reason = _reason ?? (_reasons.isEmpty ? null : _reasons.first);
    return InvCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_kind == 'add' ? 'Add stock' : 'Remove stock', style: inter(16, 700)),
        Text(_kind == 'add' ? 'Found more than the app shows, or stock came in without a delivery.' : 'Fewer on the shelf than the app shows (lost, used, miscounted).',
            style: inter(12.5, 400, color: kMuted, height: 1.35)),
        const SizedBox(height: 12),
        InvLabel(tr('Product')),
        InvPickBox(key: const ValueKey('adjust-item'), value: item == null ? 'Choose a product' : item.s('name'), onTap: _pickItem),
        if (item != null && _detail != null)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('In stock now: ${qty(_detail!.n('available'))}', style: inter(12.5, 500, color: kMuted))),
        const SizedBox(height: 12),
        InvLabel(_kind == 'add' ? 'Put it in' : 'Take it from'),
        InvPickBox(
          value: binLabel ?? (item == null && _kind == 'remove' ? 'Choose a product first' : places.isEmpty ? 'No place available' : 'Choose a place'),
          onTap: places.isEmpty
              ? null
              : () async {
                  final v = await pickOne<String>(context, _kind == 'add' ? 'Put it in' : 'Take it from', places, current: bin);
                  if (v != null) setState(() => _binId = v);
                },
        ),
        const SizedBox(height: 12),
        InvLabel(tr('How many')),
        InvInput(key: const ValueKey('adjust-qty'), controller: _qty, number: true, hint: '0'),
        const SizedBox(height: 12),
        InvLabel(tr('Why')),
        InvPickBox(
          value: reason ?? 'Choose a reason',
          onTap: _reasons.isEmpty
              ? null
              : () async {
                  final v = await pickOne<String>(context, 'Why', [for (final r in _reasons) (r, r, null)], current: reason);
                  if (v != null) setState(() => _reason = v);
                },
        ),
        const SizedBox(height: 12),
        InvLabel(tr('Note (optional)')),
        InvInput(controller: _note, hint: tr('Anything the approver should know')),
        const SizedBox(height: 14),
        InvPrimary(tr('Send for approval'), busy: _sending, onPressed: _sending ? null : _send, key: const ValueKey('adjust-send')),
      ]),
    );
  }
}
