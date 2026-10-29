import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_native_contact_picker/flutter_native_contact_picker.dart';

import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'purchasing_api.dart';
import '../ui/i18n.dart';

/// A contact picked from the phone: its name and number.
typedef PickedContact = ({String name, String phone});

/// Opens the phone's own contact list (no contacts permission: the person picks one). Null when nothing was picked or the device
/// cannot (the browser). Tests replace it.
Future<PickedContact?> Function() pickPhoneContact = () async {
  if (kIsWeb) return null;
  final c = await FlutterNativeContactPicker().selectPhoneNumber();
  if (c == null) return null;
  return (name: c.fullName ?? '', phone: c.selectedPhoneNumber ?? c.phoneNumbers?.firstOrNull ?? '');
};

/// "+ Add supplier" (Purchase and Quick Add): the phone's contact list opens straight away, and the contact picked is added as the
/// supplier — nothing to type (founder, 26 Oct 2026). Only where contacts cannot open (the browser) does the short typed form show.
/// The new supplier, or null when nothing was picked.
Future<Facts?> showAddSupplier(BuildContext context, PurchasingApi api) async {
  PickedContact? c;
  var canPick = !kIsWeb;
  if (canPick) {
    try {
      c = await pickPhoneContact();
      if (c == null) return null; // closed the contact list
    } catch (_) {
      canPick = false; // no contact picker on this device
    }
  }
  if (!context.mounted) return null;
  if (canPick && c != null && c.name.trim().length >= 2) {
    try {
      final s = await api.saveSupplier(name: c.name.trim(), phone: _tenDigits(c.phone), key: PurchasingApi.newKey());
      if (context.mounted) showToast(context, '${s.s('name')} added as a supplier.');
      return s;
    } catch (e) {
      if (context.mounted) showToast(context, e is PartnerApiException ? e.message : 'Could not add ${c.name}. Try again.');
      return null;
    }
  }
  return showModalBottomSheet<Facts>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => _AddSupplierSheet(api: api, prefill: c),
  );
}

/// The number as the server keeps it: the last 10 digits of an Indian mobile ("+91 98765 43210" → "9876543210").
String _tenDigits(String raw) {
  final d = raw.replaceAll(RegExp(r'\D'), '');
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

/// The typed form, only where the contact list cannot open: name (required), phone, GSTIN, city. One key per sheet, so a retried tap
/// never adds twice.
class _AddSupplierSheet extends StatefulWidget {
  const _AddSupplierSheet({required this.api, this.prefill});
  final PurchasingApi api;
  final PickedContact? prefill;
  @override
  State<_AddSupplierSheet> createState() => _AddSupplierSheetState();
}

class _AddSupplierSheetState extends State<_AddSupplierSheet> {
  late final _name = TextEditingController(text: widget.prefill?.name.trim() ?? ''), _phone = TextEditingController(text: _tenDigits(widget.prefill?.phone ?? ''));
  final _gstin = TextEditingController(), _city = TextEditingController();
  final _key = PurchasingApi.newKey();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _phone, _gstin, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().length < 2) return setState(() => _error = 'Enter the supplier name.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await widget.api.saveSupplier(name: _name.text, phone: _phone.text, gstin: _gstin.text, city: _city.text, key: _key);
      if (mounted) Navigator.of(context).pop(s);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is PartnerApiException ? e.message : 'Could not add the supplier. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Add supplier'), style: inter(19, 800)),
            // only shown where the phone's contact list cannot open (the browser); in the phone app a contact is picked instead
            Text(tr('Contacts open in the phone app. Here, type the name; the rest can come later.'), style: inter(12.5, 400, color: kMuted)),
            const SizedBox(height: 4),
            InvLabel(tr('Name')),
            InvInput(key: const ValueKey('supplier-name'), controller: _name, hint: tr('For example ABC Foods')),
            InvLabel(tr('Phone (optional)')),
            InvInput(key: const ValueKey('supplier-phone'), controller: _phone, number: true, hint: tr('10-digit mobile')),
            InvLabel(tr('GSTIN (optional)')),
            InvInput(key: const ValueKey('supplier-gstin'), controller: _gstin, hint: tr('15 letters and numbers')),
            InvLabel(tr('City (optional)')),
            InvInput(key: const ValueKey('supplier-city'), controller: _city, hint: tr('For example Latur')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const ValueKey('supplier-error'), style: inter(12.5, 600, color: kRedText))),
            const SizedBox(height: 14),
            InvPrimary(tr('Add supplier'), key: const ValueKey('supplier-save'), busy: _busy, onPressed: _busy ? null : _save),
          ]),
        ),
      );
}
