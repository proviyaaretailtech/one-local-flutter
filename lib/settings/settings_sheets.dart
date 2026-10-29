import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../setup/setup_widgets.dart' show SetupSelect;
import '../ui/theme.dart';
import 'settings_api.dart';
import 'settings_widgets.dart';
import '../ui/i18n.dart';
import 'store_qr.dart';

// The edit sheets of the Settings page (Figma section P). Each one asks the server to save and shows the database's own sentence when it
// refuses; the only checks here are "is it empty". A sheet that saves answers with the new page state.

/// What a form field can see: its text controllers, the non-text values the sheet keeps, and a way to redraw.
class FormCtx {
  FormCtx(this._ctl, this.values, this.refresh);
  final Map<String, TextEditingController> _ctl;
  final Map<String, Object?> values;
  final VoidCallback refresh;
  TextEditingController ctl(String k) => _ctl[k]!;
  String text(String k) => _ctl[k]!.text.trim();
}

/// A sheet body: fields, an error line, one lime button. Runs [submit]; on success closes the sheet with its answer.
class FormSheet<T> extends StatefulWidget {
  const FormSheet({super.key, required this.button, required this.children, required this.submit, this.validate, this.initial = const {}, this.values = const {}});
  final String button;
  final Map<String, String> initial;
  final Map<String, Object?> values;
  final List<Widget> Function(FormCtx f) children;
  final String? Function(FormCtx f)? validate;
  final Future<T?> Function(FormCtx f) submit;

  @override
  State<FormSheet<T>> createState() => _FormSheetState<T>();
}

class _FormSheetState<T> extends State<FormSheet<T>> {
  late final Map<String, TextEditingController> _ctl = {for (final e in widget.initial.entries) e.key: TextEditingController(text: e.value)};
  late final Map<String, Object?> _values = {...widget.values};
  String? _error;
  bool _busy = false;
  late final FormCtx _f = FormCtx(_ctl, _values, () => setState(() => _error = null));

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final bad = widget.validate?.call(_f);
    if (bad != null) return setState(() => _error = bad);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await widget.submit(_f);
      if (mounted) Navigator.of(context).pop(s);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is Exception && e.toString().isNotEmpty ? _sentence(e) : 'Something went wrong. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...widget.children(_f),
        FormError(_error),
        SaveButton(label: widget.button, onPressed: _save, busy: _busy),
      ]);
}

String _sentence(Object e) {
  try {
    return (e as dynamic).message as String;
  } catch (_) {
    return 'Something went wrong. Please try again.';
  }
}

final _digits = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)];

Future<String?> _defaultPickTime(BuildContext context, String? current) async {
  final now = TimeOfDay.now();
  final init = current != null && current.length == 5 ? TimeOfDay(hour: int.parse(current.substring(0, 2)), minute: int.parse(current.substring(3))) : now;
  final t = await showTimePicker(context: context, initialTime: init);
  return t == null ? null : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

Future<SettingsState?> openHoursSheet(BuildContext context, SettingsEnv env, SettingsState s) => showSettingsSheet<SettingsState>(
      context,
      title: tr('Opening & closing timings'),
      subtitle: tr('Set when your store opens and closes.'),
      body: (_) => FormSheet(
        button: tr('Save'),
        values: {'opens': s.opensAt, 'closes': s.closesAt},
        validate: (f) => f.values['opens'] == null || f.values['closes'] == null ? 'Choose both an opening and a closing time.' : null,
        submit: (f) => env.api.saveHours(f.values['opens'] as String, f.values['closes'] as String),
        children: (f) => [
          for (final (key, label, hint) in [('opens', 'Opening time', 'Select opening time'), ('closes', 'Closing time', 'Select closing time')])
            PickField(
              label: label,
              hint: hint,
              value: f.values[key] == null ? null : clock12(f.values[key] as String),
              showNotSet: true,
              onTap: () async {
                final t = await (env.pickTime ?? _defaultPickTime)(context, f.values[key] as String?);
                if (t != null) {
                  f.values[key] = t;
                  f.refresh();
                }
              },
            ),
        ],
      ),
    );

Future<SettingsState?> openReadinessSheet(BuildContext context, SettingsEnv env, SettingsState s) => showSettingsSheet<SettingsState>(
      context,
      title: tr('Delivery time / readiness'),
      subtitle: tr('Set how long orders take to be ready.'),
      body: (_) => FormSheet(
        button: tr('Save'),
        initial: {'min': s.prepMinutes?.toString() ?? ''},
        validate: (f) => int.tryParse(f.text('min')) == null ? 'Enter the preparation time in minutes.' : null,
        submit: (f) => env.api.saveReadiness(int.parse(f.text('min'))),
        children: (f) => [
          SheetField(
            label: tr('Preparation / readiness time'),
            controller: f.ctl('min'),
            hint: tr('Enter time in minutes'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
            helper: s.prepMinutes == null ? 'Not set' : null,
          ),
        ],
      ),
    );

Future<SettingsState?> openHelpSheet(BuildContext context, SettingsEnv env, SettingsState s) => showSettingsSheet<SettingsState>(
      context,
      title: tr('Help / replacements'),
      subtitle: tr('Add a contact and guidance for customer help.'),
      body: (_) => FormSheet(
        button: tr('Save'),
        initial: {'name': s.helpName ?? '', 'phone': s.helpPhone ?? '', 'info': s.helpInfo ?? ''},
        validate: (f) => f.text('name').isEmpty || f.text('phone').isEmpty ? 'Enter a contact name and a mobile number.' : null,
        submit: (f) => env.api.saveHelp(name: f.text('name'), phone: f.text('phone'), info: f.text('info')),
        children: (f) => [
          SheetField(label: tr('Contact name'), controller: f.ctl('name'), hint: tr('Enter contact name'), maxLength: 120),
          SheetField(label: tr('Contact number'), controller: f.ctl('phone'), hint: tr('Enter mobile number'), prefix: '+91', keyboardType: TextInputType.phone, inputFormatters: _digits),
          SheetField(label: tr('Help / replacement information'), controller: f.ctl('info'), hint: tr('Enter help or replacement instructions'), maxLines: 4, maxLength: 500),
        ],
      ),
    );

Future<SettingsState?> openOwnerSheet(BuildContext context, SettingsEnv env, SettingsState s) => showSettingsSheet<SettingsState>(
      context,
      title: tr('Owner'),
      subtitle: tr('Add the store owner’s contact details.'),
      body: (_) => FormSheet(
        button: tr('Save'),
        initial: {'name': s.ownerName ?? '', 'phone': s.ownerPhone ?? ''},
        validate: (f) => f.text('name').isEmpty || f.text('phone').isEmpty ? 'Enter the owner’s name and mobile number.' : null,
        submit: (f) => env.api.saveOwner(name: f.text('name'), phone: f.text('phone')),
        children: (f) => [
          SheetField(label: tr('Owner name'), controller: f.ctl('name'), hint: tr('Enter owner name'), maxLength: 120),
          SheetField(label: tr('Mobile number'), controller: f.ctl('phone'), hint: tr('Enter mobile number'), prefix: '+91', keyboardType: TextInputType.phone, inputFormatters: _digits),
        ],
      ),
    );

Future<SettingsState?> openStaffPhoneSheet(BuildContext context, SettingsEnv env, SettingsState s) => showSettingsSheet<SettingsState>(
      context,
      title: tr('Staff number'),
      subtitle: tr('Add a phone number for your store staff.'),
      body: (_) => FormSheet(
        button: tr('Save'),
        initial: {'phone': s.staffPhone ?? ''},
        validate: (f) => f.text('phone').isEmpty ? 'Enter a mobile number.' : null,
        submit: (f) => env.api.saveStaffPhone(f.text('phone')),
        children: (f) => [SheetField(label: tr('Phone number'), controller: f.ctl('phone'), hint: tr('Enter staff mobile number'), prefix: '+91', keyboardType: TextInputType.phone, inputFormatters: _digits)],
      ),
    );

/// The two switch sheets (pickup, QR self-checkout) share one shape: a bordered row with Off / On, a paragraph, Save.
Future<SettingsState?> _switchSheet(BuildContext context, {required String title, required String subtitle, required String label, required String note, required bool current, required Future<SettingsState> Function(bool on) save}) =>
    showSettingsSheet<SettingsState>(
      context,
      title: title,
      subtitle: subtitle,
      body: (_) => FormSheet(
        button: tr('Save'),
        values: {'on': current},
        submit: (f) => save(f.values['on'] == true),
        children: (f) => [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
            decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(14), border: Border.all(color: kFieldBorder)),
            child: Row(children: [
              Expanded(child: Text(label, style: inter(14, 700))),
              Text(f.values['on'] == true ? 'On' : 'Off', style: inter(12.5, 400, color: kMuted)),
              LimeSwitch(label: label, value: f.values['on'] == true, onChanged: (v) {
                f.values['on'] = v;
                f.refresh();
              }),
            ]),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(2, 10, 2, 16), child: Text(note, style: inter(13, 400, color: kMuted, height: 1.45))),
        ],
      ),
    );

Future<SettingsState?> openPickupSheet(BuildContext context, SettingsEnv env, SettingsState s) => _switchSheet(context,
    title: tr('Online self-pickup orders'),
    subtitle: tr('Choose whether to accept store pickup orders.'),
    label: tr('Accept pickup orders'),
    note: tr('When enabled, customers can place orders online and collect them from your store.'),
    current: s.pickup,
    save: env.api.setPickup);

Future<SettingsState?> openQrCheckoutSheet(BuildContext context, SettingsEnv env, SettingsState s) => _switchSheet(context,
    title: tr('QR self-checkout'),
    subtitle: tr('Choose whether customers can scan and pay.'),
    label: tr('Enable QR self-checkout'),
    note: tr('When enabled, customers can scan your store QR code to check out and pay themselves.'),
    current: s.qrCheckout,
    save: env.api.setQrCheckout);

Future<SettingsState?> openLocationSheet(BuildContext context, SettingsEnv env, SettingsState s) => showSettingsSheet<SettingsState>(
      context,
      title: tr('Location'),
      subtitle: tr('Add the address customers will visit.'),
      body: (_) => FormSheet(
        button: tr('Save'),
        initial: {'address': s.address ?? ''},
        validate: (f) => f.text('address').isEmpty ? 'Enter the full store address.' : null,
        submit: (f) => env.api.saveLocation(f.text('address')),
        children: (f) => [
          Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [Expanded(child: Text(s.address ?? 'Not added', style: inter(12.5, 400, color: kMuted)))])),
          SheetField(label: tr('Store address'), controller: f.ctl('address'), hint: tr('Enter full store address'), maxLines: 3, maxLength: 250),
        ],
      ),
    );

Future<SettingsState?> openLanguageSheet(BuildContext context, SettingsEnv env, SettingsState s) => showSettingsSheet<SettingsState>(
      context,
      title: tr('Language'),
      subtitle: tr('Choose App’s primary language'),
      body: (_) => FormSheet(
        button: tr('Save'),
        values: {'lang': s.language},
        submit: (f) => env.api.saveLanguage(f.values['lang'] as String),
        children: (f) => [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SetupSelect<String>(
              label: '',
              hint: tr('Choose a language'),
              value: f.values['lang'] as String?,
              options: kLanguages.keys.toList(),
              display: (c) => kLanguages[c] ?? c,
              onChanged: (c) {
                f.values['lang'] = c;
                f.refresh();
              },
            ),
          ),
        ],
      ),
    );

/// Bank details: status on top, the Shop Act note, then holder / account / IFSC. The account number is typed here and goes straight to the
/// server's secure handler; it is never shown again (only the last four digits come back). Verify saves it and leaves the status Unverified.
Future<SettingsState?> openBankSheet(BuildContext context, SettingsEnv env, SettingsState s) => showSettingsSheet<SettingsState>(
      context,
      title: tr('Bank details'),
      subtitle: tr('Add bank details for your store payouts.'),
      body: (_) => FormSheet(
        button: tr('Verify'),
        initial: {'holder': s.bankHolder ?? '', 'account': '', 'ifsc': s.bankIfsc ?? ''},
        validate: (f) {
          if (f.text('holder').isEmpty) return 'Enter the account holder name.';
          if (s.bankLast4 == null && f.text('account').isEmpty) return 'Enter the account number.';
          if (s.bankIfsc == null && f.text('ifsc').isEmpty) return 'Enter the IFSC code.';
          return null;
        },
        submit: (f) async {
          await env.api.saveBank(holder: f.text('holder'), accountNumber: f.text('account'), ifsc: f.text('ifsc').toUpperCase());
          return env.api.get();
        },
        children: (f) => [
          Row(children: [
            Expanded(child: Text(s.bankLast4 == null ? 'Not added' : 'Account ending ${s.bankLast4}', style: inter(12.5, 400, color: kMuted))),
            StatusPill(s.bankStatus == 'verified' ? 'Verified' : 'Unverified', good: s.bankStatus == 'verified'),
          ]),
          const SizedBox(height: 10),
          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFFFFF9E6), borderRadius: BorderRadius.circular(10)), child: Text(tr('Bank details must match the Shop Act.'), style: inter(12, 500, color: const Color(0xFF92400E)))),
          const SizedBox(height: 14),
          SheetField(label: tr('Account holder name'), controller: f.ctl('holder'), hint: tr('Enter name as per Shop Act'), maxLength: 120),
          SheetField(
            label: tr('Account number'),
            controller: f.ctl('account'),
            hint: tr('Enter account number'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(18)],
            helper: s.bankLast4 == null ? null : 'Saved account ending ${s.bankLast4}. Leave blank to keep it.',
          ),
          SheetField(label: tr('IFSC code'), controller: f.ctl('ifsc'), hint: tr('Enter IFSC code'), maxLength: 11),
        ],
      ),
    );

// ---------------------------------------------------------------- documents and QR (files)

/// Documents: the list, Upload document (pick a file, name it, send it), Open, Remove.
Future<void> openDocumentsSheet(BuildContext context, SettingsEnv env, SettingsState s) =>
    showSettingsSheet<void>(context, title: tr('Documents'), subtitle: tr('Upload and manage your store documents.'), body: (_) => _Documents(env: env, canEdit: s.canEdit));

const kDocTypes = <String, String>{'tax': 'Tax', 'food_safety': 'Food safety', 'business': 'Business licence', 'safety': 'Safety', 'liquor': 'Liquor', 'environment': 'Environment', 'other': 'Other'};

class _Documents extends StatefulWidget {
  const _Documents({required this.env, required this.canEdit});
  final SettingsEnv env;
  final bool canEdit;
  @override
  State<_Documents> createState() => _DocumentsState();
}

class _DocumentsState extends State<_Documents> {
  List<Map<String, dynamic>>? _docs;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.env.api.documents();
      if (mounted) setState(() => _docs = d);
    } catch (e) {
      if (mounted) setState(() => _error = _sentence(e));
    }
  }

  Future<void> _upload() async {
    final file = await widget.env.picker.pick();
    if (file == null || !mounted) return;
    final details = await showSettingsSheet<Map<String, String>>(
      context,
      title: tr('Document details'),
      subtitle: tr('Name the document so you can find it later.'),
      body: (_) => _DocumentDetails(initialName: file.name.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '')),
    );
    if (details == null || !mounted) return;
    setState(() => _busy = true);
    final ok = await guarded(context, () => widget.env.api.uploadFile(kind: 'document', file: file, details: {'name': details['name'], 'doc_type': details['type'], if ((details['number'] ?? '').isNotEmpty) 'doc_no': details['number']}));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok != null) _load();
  }

  Future<void> _open(String id) async {
    final url = await guarded(context, () => widget.env.api.fileLink('document', id: id));
    if (url != null) widget.env.onOpenLink?.call(url);
  }

  Future<void> _remove(String id) async {
    final done = await guarded(context, () => widget.env.api.removeDocument(id).then((_) => true));
    if (done == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return EmptyPanel(
        title: tr('Could not load documents'),
        body: _error!,
        child: PanelButton('Try again', onPressed: () {
          setState(() => _error = null);
          _load();
        }),
      );
    }
    if (_docs == null) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(color: kInk)));
    final docs = _docs!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (docs.isEmpty)
        EmptyPanel(title: tr('No documents available'), body: tr('Upload a store document from your device.'), child: widget.canEdit ? PanelButton('Upload document', onPressed: _upload, busy: _busy) : null)
      else ...[
        for (final d in docs)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(14), border: Border.all(color: kFieldBorder)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('${d['name']}', style: inter(14, 700))),
                StatusPill(d['review_status'] == 'verified' ? 'Verified' : 'Pending', good: d['review_status'] == 'verified'),
              ]),
              const SizedBox(height: 2),
              Text([kDocTypes[d['doc_type']] ?? '${d['doc_type']}', if (d['doc_no_masked'] != null) '${d['doc_no_masked']}', if (d['expiry_date'] != null) 'Expires ${d['expiry_date']}'].join(' · '), style: inter(12, 400, color: kMuted)),
              Row(children: [
                if (d['has_file'] == true) RowAction(tr('Open'), onTap: () => _open('${d['id']}')),
                if (widget.canEdit) RowAction(tr('Remove'), onTap: () => _remove('${d['id']}')),
              ]),
            ]),
          ),
        if (widget.canEdit) PanelButton('Upload document', onPressed: _upload, busy: _busy),
      ],
    ]);
  }
}

class _DocumentDetails extends StatefulWidget {
  const _DocumentDetails({required this.initialName});
  final String initialName;
  @override
  State<_DocumentDetails> createState() => _DocumentDetailsState();
}

class _DocumentDetailsState extends State<_DocumentDetails> {
  late final _name = TextEditingController(text: widget.initialName);
  final _number = TextEditingController();
  String _type = 'other';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SheetField(label: tr('Document name'), controller: _name, hint: tr('For example FSSAI licence'), maxLength: 120),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SetupSelect<String>(label: tr('Type'), hint: tr('Choose a type'), value: _type, options: kDocTypes.keys.toList(), display: (k) => kDocTypes[k]!, onChanged: (k) => setState(() => _type = k)),
        ),
        SheetField(label: tr('Document number (optional)'), controller: _number, hint: tr('Enter number'), maxLength: 60),
        FormError(_error),
        SaveButton(
          label: tr('Upload'),
          onPressed: () {
            if (_name.text.trim().length < 2) return setState(() => _error = 'Name the document, 2 to 120 characters.');
            Navigator.of(context).pop({'name': _name.text.trim(), 'type': _type, 'number': _number.text.trim()});
          },
        ),
      ]);
}

/// Upload your QR: upload, view, replace, remove. The file goes to a private bucket; Save just closes (the upload saves itself).
Future<SettingsState?> openQrSheet(BuildContext context, SettingsEnv env, SettingsState s) =>
    showSettingsSheet<SettingsState>(context, title: tr('Upload your QR'), subtitle: tr('Upload or manage your store QR code.'), body: (_) => _QrSheet(env: env, state: s));

class _QrSheet extends StatefulWidget {
  const _QrSheet({required this.env, required this.state});
  final SettingsEnv env;
  final SettingsState state;
  @override
  State<_QrSheet> createState() => _QrSheetState();
}

class _QrSheetState extends State<_QrSheet> {
  late SettingsState _s = widget.state;
  bool _busy = false;

  Future<void> _upload() async {
    final file = await widget.env.picker.pick();
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    final fresh = await guarded(context, () async {
      await widget.env.api.uploadFile(kind: 'store_qr', file: file);
      return widget.env.api.get();
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (fresh != null) _s = fresh;
      _version++; // the picture reloads
    });
  }

  int _version = 0;

  Future<void> _remove() async {
    final fresh = await guarded(context, () async {
      await widget.env.api.removeQr();
      return widget.env.api.get();
    });
    if (mounted && fresh != null) setState(() => _s = fresh);
  }

  Future<void> _view() async {
    final url = await guarded(context, () => widget.env.api.fileLink('store_qr'));
    if (url != null) widget.env.onOpenLink?.call(url);
  }

  @override
  Widget build(BuildContext context) {
    final up = _s.qrUploaded;
    final can = _s.canEdit;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // the QR itself (founder, 29 Oct 2026): the picture customers scan on the Bill screen when they pay by UPI
      if (up) ...[
        StoreQrCard(
          key: ValueKey('settings-qr-${_version}'),
          load: () async {
            final r = await widget.env.api.fileLinkInfo('store_qr');
            return (url: r['url'] as String, pdf: r['content_type'] == 'application/pdf');
          },
          openLink: widget.env.onOpenLink,
        ),
        const SizedBox(height: 12),
      ],
      EmptyPanel(
        title: up ? 'QR uploaded' : 'No QR uploaded',
        body: up ? 'Your store QR code is saved.' : 'Choose your store QR code from your device.',
        child: can ? PanelButton(up ? 'Replace' : 'Upload', onPressed: _upload, busy: _busy) : null,
      ),
      const SizedBox(height: 14),
      Text(tr('Supported formats: JPG / PNG / PDF'), style: inter(12.5, 400, color: kMuted)),
      const SizedBox(height: 10),
      Text(tr('Once uploaded, you can replace or remove your QR. It shows on the Bill screen when a customer pays by UPI.'), style: inter(12.5, 400, color: kMuted)),
      Row(children: [
        if (up) RowAction(tr('View'), onTap: _view),
        if (up && can) RowAction(tr('Remove'), onTap: _remove),
      ]),
      const SizedBox(height: 8),
      SaveButton(label: tr('Save'), onPressed: () => Navigator.of(context).pop(_s)),
    ]);
  }
}

/// Used by the page for a quick "Saved" confirmation.
void saved(BuildContext context, String what) => showToast(context, '$what saved.');
