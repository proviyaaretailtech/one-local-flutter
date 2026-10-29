import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'money_flow.dart';
import 'store_money.dart';
import '../ui/motion.dart';

// Transfer (founder's sketch, 28 Oct 2026): select a contact, then UPI or card. UPI opens GPay or PhonePe with the contact's UPI ID and the
// amount filled in; the owner pays there, says it went through, and it is recorded in Money out. The app never moves money itself; card is
// recorded only. Moving money between the store's own accounts (cash to bank) is kept as a small link.

/// The UPI payment link for an app: GPay (tez://), PhonePe (phonepe://) or any UPI app (upi://).
Uri upiPayLink(String app, {required String upiId, required String name, required int amountMinor, String note = ''}) {
  final q = {'pa': upiId, 'pn': name, 'am': (amountMinor / 100).toStringAsFixed(2), 'cu': 'INR', if (note.isNotEmpty) 'tn': note};
  final query = q.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
  return Uri.parse('${switch (app) {
    'gpay' => 'tez://upi/pay',
    'phonepe' => 'phonepe://pay',
    _ => 'upi://pay',
  }}?$query');
}

class MoneyTransferScreen extends StatefulWidget {
  const MoneyTransferScreen({super.key, required this.api, this.shop = const {}});
  final StoreMoneyApi api;
  final Map<String, dynamic> shop;
  @override
  State<MoneyTransferScreen> createState() => _MoneyTransferScreenState();
}

class _MoneyTransferScreenState extends State<MoneyTransferScreen> {
  MoneyContact? _to;
  String _how = 'upi'; // upi | card
  String _kind = 'supplier_payment';
  final _amount = TextEditingController(), _note = TextEditingController();
  String _key = StoreMoneyApi.newKey();
  bool _busy = false, _changed = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  int? get _amountMinor {
    final a = num.tryParse(_amount.text.trim());
    return a == null || a <= 0 ? null : (a * 100).round();
  }

  Future<void> _choose() async {
    final c = await chooseMoneyContact(context, widget.api);
    if (c != null && mounted) setState(() => _to = c);
  }

  Future<void> _editContact() async {
    final c = await editMoneyContact(context, widget.api, contact: _to);
    if (c != null && mounted) setState(() => _to = c);
  }

  bool _ready() {
    if (_to == null) {
      showToast(context, tr('Select who you are paying.'));
      return false;
    }
    if (_amountMinor == null) {
      showToast(context, tr('Enter the amount.'));
      return false;
    }
    return true;
  }

  Future<bool> _record(String method, {String reference = ''}) async {
    setState(() => _busy = true);
    try {
      final r = await widget.api.record({
        'kind': _kind,
        'method': method,
        'amount_minor': _amountMinor,
        'party': _to!.name,
        'party_phone': _to!.phone,
        'reference': reference,
        'note': _note.text.trim(),
      }, key: _key);
      _changed = true;
      _key = StoreMoneyApi.newKey(); // the next payment is a new one
      if (!mounted) return true;
      await showMoneyReceipt(context, {
        'id': r['id'],
        'no': r['no'],
        'date': r['date'],
        'direction': 'out',
        'kind': _kind,
        'method': method,
        'amount_minor': _amountMinor,
        'party': _to!.name,
        'party_phone': _to!.phone,
        'reference': reference,
        'note': _note.text.trim(),
        'created_at': DateTime.now().toIso8601String(),
      }, api: widget.api, shop: widget.shop);
      if (mounted) Navigator.of(context).pop(true);
      return true;
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not save. Check your connection and try again.'));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _payUpi(String app) async {
    if (!_ready()) return;
    if (_to!.upiId.isEmpty) {
      showToast(context, tr("Add the contact's UPI ID first."));
      return _editContact();
    }
    final opened = await openMoneyLink(upiPayLink(app, upiId: _to!.upiId, name: _to!.name, amountMinor: _amountMinor!, note: _note.text.trim()));
    if (!mounted) return;
    if (!opened) {
      showToast(context, tr('Could not open the UPI app. Pay from the OneLocal app on your phone.'));
      return;
    }
    final utr = TextEditingController();
    final paid = await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${tr('Did the payment of')} ${rs(_amountMinor)} ${tr('to')} ${_to!.name} ${tr('go through?')}', style: inter(17, 700)),
        content: TextField(key: const ValueKey('transfer-utr'), controller: utr, decoration: InputDecoration(labelText: tr('UTR / reference (optional)'))),
        actions: [
          TextButton(key: const ValueKey('transfer-not-paid'), onPressed: () => Navigator.pop(c, false), child: Text(tr('No'), style: inter(14, 600))),
          TextButton(key: const ValueKey('transfer-paid'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Yes, record it'), style: inter(14, 700, color: kMoneyGreen))),
        ],
      ),
    );
    if (paid == true && mounted) await _record(app == 'any' ? 'upi' : app, reference: utr.text.trim());
  }

  Future<void> _payCard() async {
    if (!_ready()) return;
    await _record('card');
  }

  Future<void> _moveBetweenAccounts() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true, // above the bottom bar
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _MoveSheet(api: widget.api),
    );
    if (saved == true && mounted) {
      _changed = true;
      showToast(context, tr('Saved.'));
    }
  }

  Widget _contactCard() {
    final c = _to;
    if (c == null) {
      return Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: const ValueKey('transfer-contact'),
          borderRadius: BorderRadius.circular(16),
          onTap: _choose,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
            child: Row(children: [
              Expanded(child: Text(tr('Select a contact'), style: inter(15.5, 600, color: kMuted))),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kInk)),
                child: const Icon(LucideIcons.userPlus, size: 18),
              ),
            ]),
          ),
        ),
      );
    }
    return Container(
      key: const ValueKey('transfer-selected'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFCDEFAA))),
      child: Row(children: [
        CircleAvatar(backgroundColor: const Color(0xFFEFFAE3), child: Text(c.name.isEmpty ? '?' : c.name.characters.first.toUpperCase(), style: inter(16, 800, color: kMoneyGreen))),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.name, style: inter(15.5, 800)),
            if (c.phone.isNotEmpty) Text(c.phone, style: inter(12.5, 500, color: kMuted)),
            c.upiId.isNotEmpty
                ? Text(c.upiId, style: inter(12.5, 600, color: kMoneyGreen))
                : GestureDetector(key: const ValueKey('transfer-add-upi'), onTap: _editContact, child: Text(tr('+ Add UPI ID'), style: inter(12.5, 700, color: kLink))),
          ]),
        ),
        TextButton(key: const ValueKey('transfer-change'), onPressed: _choose, child: Text(tr('Change'), style: inter(13, 700, color: kLink))),
      ]),
    );
  }

  Widget _payOption(String app, String label, Key key) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(14),
          onTap: _busy ? null : () => _payUpi(app),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
            child: Row(children: [
              const Icon(LucideIcons.smartphone, size: 20, color: kMoneyGreen),
              const SizedBox(width: 12),
              Expanded(child: Text(tr(label), style: inter(15, 700))),
              const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.of(context).pop(_changed);
        },
        child: Scaffold(
          backgroundColor: kBg,
          body: Column(children: [
            AppHeader(title: tr('Transfer'), onBack: () => Navigator.of(context).pop(_changed)),
            Expanded(
              child: ListView(key: const ValueKey('money-transfer-screen'), padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), children: [
                _contactCard(),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      key: const ValueKey('transfer-amount'),
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      style: inter(18, 700),
                      decoration: moneyField('Amount', prefix: '₹ ').copyWith(fillColor: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('transfer-kind'),
                      initialValue: _kind,
                      isExpanded: true,
                      decoration: moneyField('For').copyWith(fillColor: Colors.white),
                      items: [
                        for (final (id, label) in kMoneyOut)
                          if (id != 'refund' && !kOtherKinds.contains(id)) DropdownMenuItem(value: id, child: Text(tr(label), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 600))),
                      ],
                      onChanged: (v) => setState(() => _kind = v ?? _kind),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                TextField(controller: _note, style: inter(14.5, 500), decoration: moneyField('Note (optional)').copyWith(fillColor: Colors.white)),
                const SizedBox(height: 16),
                Row(children: [
                  for (final (id, label, icon) in const [('upi', 'UPI', LucideIcons.smartphone), ('card', 'Card', LucideIcons.creditCard)]) ...[
                    if (id == 'card') const SizedBox(width: 10),
                    Expanded(
                      child: Material(
                        color: _how == id ? kPrimary : Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          key: ValueKey('transfer-how-$id'),
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => setState(() => _how = id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: _how == id ? kPrimary : kLine)),
                            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Icon(icon, size: 18, color: _how == id ? Colors.white : kInk),
                              const SizedBox(width: 8),
                              Text(tr(label), style: inter(15, 800, color: _how == id ? Colors.white : kInk)),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ],
                ]),
                const SizedBox(height: 14),
                if (_how == 'upi') ...[
                  Text(tr('Pay through'), style: inter(13, 700, color: kMuted)),
                  const SizedBox(height: 6),
                  _payOption('gpay', 'GPay', const ValueKey('transfer-gpay')),
                  const SizedBox(height: 8),
                  _payOption('phonepe', 'PhonePe', const ValueKey('transfer-phonepe')),
                  const SizedBox(height: 8),
                  _payOption('any', 'Other UPI app', const ValueKey('transfer-any-upi')),
                  const SizedBox(height: 8),
                  Text(tr('The app opens with the amount filled in. After you pay, come back and say it went through, and it is saved in Money out.'),
                      style: inter(12, 500, color: kMuted)),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(12)),
                    child: Text(tr('Pay on your card machine or bank app, then record it here.'), style: inter(13, 600)),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    key: const ValueKey('transfer-card-record'),
                    onPressed: _busy ? null : _payCard,
                    style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    child: Text(_busy ? '…' : tr('Record card payment'), style: inter(15.5, 700, color: Colors.white)),
                  ),
                ],
                const SizedBox(height: 20),
                Center(
                  child: TextButton.icon(
                    key: const ValueKey('transfer-move'),
                    onPressed: _moveBetweenAccounts,
                    icon: const Icon(LucideIcons.arrowLeftRight, size: 16, color: kLink),
                    label: Text(tr('Move money between your accounts (cash, UPI, bank)'), style: inter(13, 700, color: kLink)),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      );
}

/// Moving the store's own money between the cash drawer, UPI and the bank.
class _MoveSheet extends StatefulWidget {
  const _MoveSheet({required this.api});
  final StoreMoneyApi api;
  @override
  State<_MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<_MoveSheet> {
  String _from = 'cash', _to = 'bank';
  final _amount = TextEditingController();
  final _key = StoreMoneyApi.newKey();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final a = num.tryParse(_amount.text.trim());
    if (a == null || a <= 0) return showToast(context, tr('Enter the amount.'));
    if (_from == _to) return showToast(context, tr('Choose two different accounts.'));
    setState(() => _busy = true);
    try {
      await widget.api.record({'kind': 'transfer', 'account': _from, 'to_account': _to, 'amount_minor': (a * 100).round()}, key: _key);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not save. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _accounts(String value, ValueChanged<String> on, String prefix) => Wrap(spacing: 6, children: [
        for (final e in kAccountNames.entries)
          ChoiceChip(key: ValueKey('$prefix-${e.key}'), avatar: Icon(kAccountIcons[e.key], size: 15), label: Text(tr(e.value), style: inter(12.5, 600)), selected: value == e.key, onSelected: (_) => on(e.key)),
      ]);

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(key: const ValueKey('move-sheet'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Move between your accounts'), style: inter(19, 800)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('move-amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            style: inter(18, 700),
            decoration: moneyField('Amount', prefix: '₹ '),
          ),
          const SizedBox(height: 12),
          Text(tr('From'), style: inter(12.5, 700, color: kMuted)),
          _accounts(_from, (v) => setState(() => _from = v), 'move-from'),
          const SizedBox(height: 8),
          Text(tr('To'), style: inter(12.5, 700, color: kMuted)),
          _accounts(_to, (v) => setState(() => _to = v), 'move-to'),
          const SizedBox(height: 14),
          FilledButton(
            key: const ValueKey('move-save'),
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: Text(_busy ? '…' : tr('Move money'), style: inter(15.5, 700, color: Colors.white)),
          ),
        ]),
      );
}
