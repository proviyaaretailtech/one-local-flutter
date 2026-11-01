import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../auth/partner_api.dart' show PartnerApiException;
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'devices_api.dart';
import 'print_service.dart' show forgetPrinters;

// Settings → Devices (founder, 31 Oct 2026): a simple phone version of the restaurant panel's System · Devices. The store's printers
// by job — receipts, barcode labels, the kitchen (restaurants) — each with how it connects, its paper or label size, auto-cut,
// the default for its job, and its last test. A network printer prints straight to its port 9100; Bluetooth and USB printers print
// through the phone's print service (the printer maker's app), so their test opens the print dialog and asks whether it came out.

/// Tests replace the print dialog.
Future<void> Function(Uint8List pdf, String name) printDevicePdf = (pdf, name) => Printing.layoutPdf(onLayout: (_) async => pdf, name: name);

const _jobs = [
  ('receipt', 'Receipt printers', 'Bills for customers', LucideIcons.receiptText),
  ('label', 'Barcode label printers', 'Barcode and price labels', LucideIcons.barcode),
  ('kot', 'Kitchen printers (KOT)', 'Orders for the kitchen', LucideIcons.chefHat),
];
const _conn = {'lan': 'Network (Wi-Fi / LAN)', 'bluetooth': 'Bluetooth', 'usb': 'USB', 'system': 'Phone’s print service'};
const _labels = ['38x25', '50x25', '50x30', '75x50', '100x50'];
const _green = Color(0xFF15803D), _red = Color(0xFFC62828), _amber = Color(0xFFB45309);

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 31) return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
  final m = d.inDays ~/ 30;
  return '$m ${m == 1 ? 'month' : 'months'} ago';
}

class DeviceManagerScreen extends StatefulWidget {
  const DeviceManagerScreen({super.key, this.api, this.store = ''});
  final DevicesApi? api;

  /// The store's name, printed on test slips.
  final String store;
  @override
  State<DeviceManagerScreen> createState() => _DeviceManagerScreenState();
}

class _DeviceManagerScreenState extends State<DeviceManagerScreen> {
  late final DevicesApi _api = widget.api ?? DevicesApi();
  List<StorePrinter>? _printers;
  bool _canEdit = false, _restaurant = false;
  String? _error, _testing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    forgetPrinters(); // printing picks up a change at once
    try {
      final r = await _api.printers();
      if (!mounted) return;
      setState(() {
        _printers = r.printers;
        _canEdit = r.canEdit;
        _restaurant = r.restaurant;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load the devices. Check your connection.'));
    }
  }

  Future<void> _edit([StorePrinter? p]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => PrinterFormScreen(api: _api, printer: p, restaurant: _restaurant)));
    if (saved == true) await _load();
  }

  Future<void> _remove(StorePrinter p) async {
    final yes = await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${tr('Remove')} ${p.name}?', style: inter(17, 700)),
        content: Text(tr('It will no longer be used for printing. You can add it again any time.'), style: inter(14, 400)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'), style: inter(14, 600, color: kMuted))),
          TextButton(key: const ValueKey('printer-remove-yes'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Remove'), style: inter(14, 700, color: _red))),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await _api.remove(p.id);
      if (mounted) showToast(context, '${p.name} ${tr('removed')}.');
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not remove it. Try again.'));
    }
  }

  /// Test print: a network printer gets a slip straight to its port; any other opens the print dialog and asks whether it printed.
  Future<void> _test(StorePrinter p) async {
    if (_testing != null) return;
    setState(() => _testing = p.id);
    var ok = false;
    var note = '';
    try {
      if (p.direct) {
        try {
          await sendRawToPrinter(p.host, p.port, escPosTestSlip(store: widget.store, printer: p));
          ok = true;
          note = 'Printed over the network';
        } catch (e) {
          note = e is UnsupportedError ? '${e.message}' : 'No answer from ${p.host}:${p.port}. Check it is on and on the same Wi-Fi.';
        }
      } else {
        await printDevicePdf(await _testPdf(p), 'Test print · ${p.name}');
        if (!mounted) return;
        setState(() => _testing = null); // no spinner while the question is open
        final came = await showOlDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(tr('Did the test page print?'), style: inter(17, 700)),
            content: Text(tr('Choose this printer in the print dialog. Bluetooth and USB printers need the printer maker’s print app on this phone.'), style: inter(14, 400)),
            actions: [
              TextButton(key: const ValueKey('printer-test-no'), onPressed: () => Navigator.pop(c, false), child: Text(tr('No'), style: inter(14, 700, color: _red))),
              TextButton(key: const ValueKey('printer-test-yes'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Yes, it printed'), style: inter(14, 700, color: _green))),
            ],
          ),
        );
        if (came == null) return;
        ok = came;
        note = came ? 'Printed through the print dialog' : 'Did not print through the print dialog';
      }
      final r = await _api.tested(p.id, ok: ok, note: note);
      if (!mounted) return;
      setState(() => _printers = [for (final x in _printers ?? const <StorePrinter>[]) x.id == r.id ? r : x]);
      showToast(context, ok ? '${p.name}: ${tr('test print OK')}.' : '${p.name}: ${tr(note)}');
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not run the test. Try again.'));
    } finally {
      if (mounted) setState(() => _testing = null);
    }
  }

  /// A test page the size of the printer's paper or label.
  Future<Uint8List> _testPdf(StorePrinter p) async {
    final doc = pw.Document();
    final mm = PdfPageFormat.mm;
    final size = p.type == 'label' ? p.labelSize.split('x').map((v) => double.tryParse(v) ?? 50).toList() : <double>[p.paperMm.toDouble(), 80];
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(size[0] * mm, size[1] * mm, marginAll: 2 * mm),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
        pw.Text(widget.store.isEmpty ? 'OneLocal' : widget.store, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        pw.Text('Test print · ${p.name}', style: const pw.TextStyle(fontSize: 7)),
        pw.SizedBox(height: 2 * mm),
        if (p.type == 'label')
          pw.BarcodeWidget(barcode: pw.Barcode.ean13(), data: '200000000001', height: (size[1] * 0.4) * mm, drawText: true, textStyle: const pw.TextStyle(fontSize: 6))
        else
          pw.Text('${p.paperMm} mm paper', style: const pw.TextStyle(fontSize: 7)),
      ]),
    ));
    return doc.save();
  }

  Widget _status(StorePrinter p) {
    final (text, color) = p.lastTestAt == null
        ? ('Not tested yet', _amber)
        : p.lastTestOk == true
            ? ('Tested OK · ${_ago(p.lastTestAt!)}', _green)
            : ('Test failed · ${_ago(p.lastTestAt!)}', _red);
    return Container(
      key: ValueKey('printer-status-${p.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(99)),
      child: Text(tr(text), style: inter(11.5, 700, color: color)),
    );
  }

  Widget _card(StorePrinter p) => Container(
        key: ValueKey('printer-${p.id}'),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE7E8E3))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(p.name, style: inter(15.5, 800))),
            if (p.isDefault)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: const Color(0xFFD2F64B), borderRadius: BorderRadius.circular(99)),
                child: Text(tr('Default'), style: inter(11, 800)),
              ),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              tr(_conn[p.connection] ?? p.connection),
              if (p.address.isNotEmpty) p.address,
              p.type == 'label' ? '${p.labelSize.replaceAll('x', ' × ')} mm ${tr('labels')}' : '${p.paperMm} mm',
              if (p.type != 'label') tr(p.autoCut ? 'auto cut' : 'no cut'),
            ].join(' · '),
            style: inter(12.5, 500, color: kMuted),
          ),
          const SizedBox(height: 8),
          _status(p),
          if (p.lastTestOk == false && p.lastTestNote.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(p.lastTestNote, style: inter(12, 500, color: _red))),
          const SizedBox(height: 10),
          Row(children: [
            FilledButton.icon(
              key: ValueKey('printer-test-${p.id}'),
              onPressed: _testing == null ? () => _test(p) : null,
              icon: _testing == p.id ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kInk)) : const Icon(LucideIcons.printer, size: 17),
              label: Text(tr('Test print'), style: inter(13.5, 700)),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB9F04F), foregroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
            const Spacer(),
            if (_canEdit) ...[
              IconButton(key: ValueKey('printer-edit-${p.id}'), tooltip: tr('Edit'), onPressed: () => _edit(p), icon: const Icon(LucideIcons.slidersHorizontal, size: 19)),
              IconButton(key: ValueKey('printer-remove-${p.id}'), tooltip: tr('Remove'), onPressed: () => _remove(p), icon: const Icon(LucideIcons.trash2, size: 19, color: _red)),
            ],
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final list = _printers;
    final tested = list?.where((p) => p.lastTestOk == true).length ?? 0;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr('Devices'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: list == null
              ? Center(child: _error != null ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))) : const CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(key: const ValueKey('device-manager'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 100), children: [
                    Text(tr('Printers for receipts, barcode labels and the kitchen.'), style: inter(13.5, 500, color: kMuted)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, children: [
                      Chip(label: Text('${list.length} ${tr(list.length == 1 ? 'printer' : 'printers')}', style: inter(12.5, 700)), visualDensity: VisualDensity.compact),
                      Chip(label: Text('$tested ${tr('tested OK')}', style: inter(12.5, 700, color: _green)), visualDensity: VisualDensity.compact),
                    ]),
                    const SizedBox(height: 8),
                    // how printing works on a phone, once, in plain words
                    Container(
                      key: const ValueKey('device-help'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFFEFF7E6), borderRadius: BorderRadius.circular(14)),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Icon(LucideIcons.info, size: 17, color: Color(0xFF2F8A0B)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr('Network printers print straight away, no dialog. Bluetooth and USB printers print through the phone’s print service: install the printer maker’s print app once. A barcode scanner needs no setup: it types into any search box, and the camera scans too.'),
                            style: inter(12.5, 500, color: const Color(0xFF2F6B0B), height: 1.4),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 14),
                    for (final (job, title, sub, icon) in _jobs)
                      if (job != 'kot' || _restaurant || list.any((p) => p.type == 'kot')) ...[
                        Row(children: [
                          Icon(icon, size: 18, color: kInk),
                          const SizedBox(width: 8),
                          Expanded(child: Text(tr(title), style: inter(15, 800))),
                        ]),
                        Padding(padding: const EdgeInsets.only(left: 26, bottom: 8), child: Text(tr(sub), style: inter(12, 500, color: kMuted))),
                        if (!list.any((p) => p.type == job))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14, left: 26),
                            child: Text(tr(job == 'label' ? 'None yet. Labels print through the print dialog until you add one.' : 'None yet.'), style: inter(12.5, 500, color: kMuted)),
                          )
                        else ...[
                          for (final p in list.where((p) => p.type == job)) _card(p),
                          const SizedBox(height: 6),
                        ],
                      ],
                  ]),
                ),
        ),
      ]),
      floatingActionButton: list != null && _canEdit
          ? FloatingActionButton.extended(
              key: const ValueKey('printer-add'),
              onPressed: () => _edit(),
              backgroundColor: const Color(0xFFB9F04F),
              foregroundColor: kInk,
              icon: const Icon(LucideIcons.plus),
              label: Text(tr('Add printer'), style: inter(14.5, 800)),
            )
          : null,
    );
  }
}

/// Add or change a printer: its name, what it prints, how it connects (and its address), paper or label size, auto-cut,
/// and whether it is the default for its job.
class PrinterFormScreen extends StatefulWidget {
  const PrinterFormScreen({super.key, required this.api, this.printer, this.restaurant = false});
  final DevicesApi api;
  final StorePrinter? printer;
  final bool restaurant;
  @override
  State<PrinterFormScreen> createState() => _PrinterFormScreenState();
}

class _PrinterFormScreenState extends State<PrinterFormScreen> {
  StorePrinter? get _p => widget.printer;
  late final _name = TextEditingController(text: _p?.name ?? '');
  late final _address = TextEditingController(text: _p?.address ?? '');
  late final _model = TextEditingController(text: _p?.model ?? '');
  late String _type = _p?.type ?? 'receipt';
  late String _connection = _p?.connection ?? 'bluetooth';
  late int _paper = _p?.paperMm ?? 80;
  late String _label = (_p?.labelSize.isNotEmpty ?? false) ? _p!.labelSize : '50x25';
  late bool _cut = _p?.autoCut ?? true;
  late bool _default = _p?.isDefault ?? false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _address, _model]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return setState(() => _error = tr('Give the printer a name, like Counter printer.'));
    if (_connection == 'lan' && !RegExp(r'^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{2,5})?$').hasMatch(_address.text.trim())) {
      return setState(() => _error = tr('Enter the printer’s IP address, like 192.168.1.50 (it is on the printer’s self-test slip).'));
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.save({
        'id': _p?.id,
        'name': _name.text.trim(),
        'printer_type': _type,
        'connection': _connection,
        'address': _address.text.trim(),
        if (_type == 'label') 'label_size': _label else 'paper_mm': _paper,
        'auto_cut': _cut,
        'is_default': _default,
        'model': _model.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is PartnerApiException ? e.message : tr('Could not save. Check your connection and try again.');
        });
      }
    }
  }

  Widget _label_(String t) => Padding(padding: const EdgeInsets.only(top: 16, bottom: 6), child: Text(tr(t), style: inter(12.5, 700, color: kMuted)));

  Widget _chips<T>(List<(T, String)> options, T value, ValueChanged<T> onPick, String keyPrefix) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (v, label) in options)
          ChoiceChip(
            key: ValueKey('$keyPrefix-$v'),
            label: Text(tr(label), style: inter(13, value == v ? 800 : 600)),
            selected: value == v,
            showCheckmark: false,
            selectedColor: const Color(0xFFD2F64B),
            backgroundColor: Colors.white,
            side: BorderSide(color: value == v ? const Color(0xFFB9E33A) : const Color(0xFFE2E4DE)),
            onSelected: (_) => setState(() => onPick(v)),
          ),
      ]);

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: tr(hint),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFD9DBD5))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFD9DBD5))),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          AppHeader(title: tr(_p == null ? 'Add printer' : 'Edit printer'), onBack: () => Navigator.of(context).maybePop()),
          Expanded(
            child: ListView(key: const ValueKey('printer-form'), padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              _label_('Name'),
              TextField(key: const ValueKey('printer-name'), controller: _name, maxLength: 40, style: inter(15, 600), decoration: _dec('For example Counter printer')),
              _label_('What it prints'),
              _chips([('receipt', 'Receipts'), ('label', 'Barcode labels'), if (widget.restaurant || _type == 'kot') ('kot', 'Kitchen (KOT)')], _type, (v) => _type = v, 'printer-type'),
              _label_('How it connects'),
              _chips([for (final e in _conn.entries) (e.key, e.value)], _connection, (v) => _connection = v, 'printer-conn'),
              if (_connection == 'lan' || _connection == 'bluetooth') ...[
                _label_(_connection == 'lan' ? 'IP address' : 'Printer’s Bluetooth name (optional)'),
                TextField(
                  key: const ValueKey('printer-address'),
                  controller: _address,
                  keyboardType: _connection == 'lan' ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
                  style: inter(15, 600),
                  decoration: _dec(_connection == 'lan' ? '192.168.1.50' : 'For example RPP02N'),
                ),
              ],
              _label_('Model (optional)'),
              TextField(key: const ValueKey('printer-model'), controller: _model, maxLength: 40, style: inter(15, 600), decoration: _dec('For example Epson TM-T82, TSC TE244')),
              if (_type == 'label') ...[
                _label_('Label size (mm)'),
                _chips([for (final l in _labels) (l, l.replaceAll('x', ' × '))], _label, (v) => _label = v, 'printer-label'),
              ] else ...[
                _label_('Paper width'),
                _chips([(58, '58 mm (2 inch)'), (80, '80 mm (3 inch)')], _paper, (v) => _paper = v, 'printer-paper'),
              ],
              const SizedBox(height: 8),
              if (_type != 'label')
                SwitchListTile(key: const ValueKey('printer-cut'), contentPadding: EdgeInsets.zero, value: _cut, onChanged: (v) => setState(() => _cut = v), title: Text(tr('Auto cut the paper'), style: inter(14, 600))),
              SwitchListTile(
                key: const ValueKey('printer-default'),
                contentPadding: EdgeInsets.zero,
                value: _default,
                onChanged: (v) => setState(() => _default = v),
                title: Text(tr(switch (_type) { 'label' => 'Default for labels', 'kot' => 'Default for the kitchen', _ => 'Default for receipts' }), style: inter(14, 600)),
                subtitle: Text(tr('The first printer for a job is its default.'), style: inter(12, 500, color: kMuted)),
              ),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const ValueKey('printer-error'), style: inter(13, 600, color: _red))),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('printer-save'),
                onPressed: _busy ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: kPrimary, minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                child: Text(_busy ? '…' : tr('Save printer'), style: inter(15.5, 700, color: Colors.white)),
              ),
            ]),
          ),
        ]),
      );
}
