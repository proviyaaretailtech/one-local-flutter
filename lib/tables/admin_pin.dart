import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../orders/orders_api.dart' show OrdersApiException;
import '../ui/app_header.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'bill_api.dart';
import 'table_widgets.dart';
import 'tables_api.dart' show TablesApiException;

/// The admin PIN (0645, founder 3 Nov 2026): a generated bill can only be changed, and an order the kitchen has can only be cancelled, with an
/// owner's or admin's PIN and a note. The database asks for it (code admin_pin_required); [withAdminPin] then shows the PIN and note,
/// checks the PIN (a pass for 5 minutes, 5 wrong tries lock it) and runs the change again with the pass. Every such change is logged with
/// who did it and whose PIN, and shows in the Leakage audit and on the owner's dashboard.

bool isAdminPinNeeded(Object e) => switch (e) {
      TablesApiException(:final code) => code == 'admin_pin_required',
      OrdersApiException(:final code) => code == 'admin_pin_required',
      RpcException(:final code) => code == 'admin_pin_required',
      _ => false,
    };

/// Runs [run] without a pass; when the server asks for the admin PIN, asks for it and a note, and runs [run] again with them
/// ({admin_pass, admin_note}). Answers null when the person gives up. Other errors are thrown as they are.
Future<T?> withAdminPin<T>(BuildContext context, {required BillApi pins, required Future<T> Function(Map<String, String>? admin) run}) async {
  try {
    return await run(null);
  } catch (e) {
    if (!isAdminPinNeeded(e) || !context.mounted) rethrow;
    final why = e is PartnerApiException ? e.message : 'An admin PIN and a note are needed.';
    var admin = await showAdminPinDialog(context, pins: pins, why: why);
    while (admin != null) {
      try {
        return await run(admin);
      } catch (e2) {
        // the pass ran out between the PIN and the change (5 minutes), or a note was too short: ask again
        if (!isAdminPinNeeded(e2) || !context.mounted) rethrow;
        admin = await showAdminPinDialog(context, pins: pins, why: e2 is PartnerApiException ? e2.message : why);
      }
    }
    return null;
  }
}

/// The admin PIN and a note: {admin_pass, admin_note}, or null for Cancel.
Future<Map<String, String>?> showAdminPinDialog(BuildContext context, {required BillApi pins, required String why}) =>
    showOlDialog<Map<String, String>>(context: context, builder: (_) => _AdminPinDialog(pins: pins, why: why));

class _AdminPinDialog extends StatefulWidget {
  const _AdminPinDialog({required this.pins, required this.why});
  final BillApi pins;
  final String why;
  @override
  State<_AdminPinDialog> createState() => _AdminPinDialogState();
}

class _AdminPinDialogState extends State<_AdminPinDialog> {
  final _pin = TextEditingController(), _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_pin.text.length != 6) return setState(() => _error = 'Enter the 6-digit admin PIN.');
    if (_note.text.trim().length < 3) return setState(() => _error = 'Write a note: why this change (3 characters or more).');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.pins.adminPinCheck(_pin.text);
      if (!mounted) return;
      if (r.b('ok')) {
        Navigator.of(context).pop({'admin_pass': r.s('pass_id'), 'admin_note': _note.text.trim()});
        return;
      }
      final left = r.n('tries_left').toInt();
      setState(() {
        _busy = false;
        _pin.clear();
        _error = left > 0 ? 'Wrong PIN. $left ${left == 1 ? 'try' : 'tries'} left.' : 'Wrong PIN. No tries left: wait 15 minutes.';
      });
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
  Widget build(BuildContext context) => AlertDialog(
        title: Row(children: [
          const Icon(LucideIcons.keyRound, size: 20, color: Color(0xFFB45309)),
          const SizedBox(width: 8),
          Expanded(child: Text('Admin PIN needed', style: inter(18, 700))),
        ]),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.why, style: inter(14, 500, color: kMuted)),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('admin-pin'),
              controller: _pin,
              obscureText: true,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              style: inter(22, 800).copyWith(letterSpacing: 8),
              decoration: const InputDecoration(labelText: 'Owner or admin PIN', border: OutlineInputBorder(), counterText: ''),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('admin-note'),
              controller: _note,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Note: why this change', border: OutlineInputBorder()),
            ),
            Text('Logged with your name and shown to the owner in the Leakage audit.', style: inter(12.5, 500, color: kMuted)),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const ValueKey('admin-error'), style: inter(14, 600, color: kError))),
          ]),
        ),
        actions: [
          TextButton(key: const ValueKey('admin-cancel'), onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(key: const ValueKey('admin-go'), onPressed: _busy ? null : _go, child: Text(_busy ? 'Checking…' : 'Confirm')),
        ],
      );
}

/// Settings → Admin PIN: an owner or admin sets or changes their own 6-digit PIN; others see that one exists.
class AdminPinScreen extends StatefulWidget {
  const AdminPinScreen({super.key, this.api});
  final BillApi? api;
  static Route<void> route() => MaterialPageRoute(builder: (_) => const AdminPinScreen());
  @override
  State<AdminPinScreen> createState() => _AdminPinScreenState();
}

class _AdminPinScreenState extends State<AdminPinScreen> {
  late final BillApi _api = widget.api ?? BillApi();
  final _pin = TextEditingController(), _again = TextEditingController();
  Facts? _s;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pin.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await _api.adminPinStatus();
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  Future<void> _save() async {
    if (!RegExp(r'^\d{6}$').hasMatch(_pin.text)) return setState(() => _error = 'The admin PIN is 6 digits.');
    if (_pin.text != _again.text) return setState(() => _error = 'The two PINs are not the same.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await _api.adminPinSet(_pin.text);
      if (!mounted) return;
      _pin.clear();
      _again.clear();
      setState(() {
        _s = s;
        _busy = false;
      });
      showToast(context, 'Admin PIN saved. Keep it to yourself.');
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
    final s = _s;
    Widget pinField(TextEditingController c, String label, String key) => TextField(
          key: ValueKey(key),
          controller: c,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          style: inter(22, 800).copyWith(letterSpacing: 8),
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), counterText: ''),
        );
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          AppHeader(title: 'Admin PIN', back: true, backKey: const ValueKey('pin-back')),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text('A generated bill cannot be changed, and an order the kitchen has cannot be cancelled, without an owner\'s or admin\'s PIN and a note. '
                  'Every such change is logged with who made it and shown in the Leakage audit and on your dashboard.',
                  style: inter(14, 500, color: kMuted)),
              const SizedBox(height: 16),
              if (s == null && _error == null) tablesLoading(),
              if (s != null) ...[
                Container(
                  key: const ValueKey('pin-state'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFE5E7EB))),
                  child: Row(children: [
                    Icon(s.b('has_pin') ? LucideIcons.shieldCheck : LucideIcons.shieldAlert, color: s.b('has_pin') ? const Color(0xFF15803D) : const Color(0xFFB45309)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.b('can_set')
                            ? (s.b('has_pin') ? 'Your admin PIN is set.' : 'You have no admin PIN yet.')
                            : (s.n('admins_with_pin') > 0 ? 'The owner has set an admin PIN.' : 'No admin PIN is set yet: ask the owner to set one.'),
                        style: inter(15, 700),
                      ),
                    ),
                  ]),
                ),
                if (s.b('can_set')) ...[
                  const SizedBox(height: 16),
                  Text(s.b('has_pin') ? 'Change your PIN' : 'Set your PIN', style: inter(16, 800)),
                  const SizedBox(height: 10),
                  pinField(_pin, 'New 6-digit PIN', 'pin-new'),
                  const SizedBox(height: 10),
                  pinField(_again, 'The same PIN again', 'pin-again'),
                  const SizedBox(height: 14),
                  LimeButton('Save PIN', key: const ValueKey('pin-save'), busy: _busy, onPressed: _busy ? null : _save),
                ],
              ],
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, key: const ValueKey('pin-error'), style: inter(14, 600, color: kError))),
            ]),
          ),
        ]),
      ),
    );
  }
}
