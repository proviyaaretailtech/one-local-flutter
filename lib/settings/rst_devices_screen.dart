
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../api/rpc_client.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../tables/rst_print_direct.dart' show printsDirect, sendToPrinter, escPosTestSlip, DirectPrintException;
import '../tables/table_widgets.dart' show sayError, kLimeBtn;
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';

/// The restaurant's printers through `POST /rpc/<rst_devices_list | rst_printer_save | rst_printer_delete | rst_printer_tested>` (0638).
class RstDevicesApi {
  RstDevicesApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;
  Future<Facts> _call(String fn, Map<String, Object?> args) async => Facts(await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null)));

  Future<Facts> list() => _call('rst_devices_list', {});
  Future<Facts> save(Map<String, Object?> printer) => _call('rst_printer_save', printer);
  Future<Facts> delete(String id) => _call('rst_printer_delete', {'id': id});
  Future<Facts> tested(String id) => _call('rst_printer_tested', {'id': id});
}

const _kinds = [('receipt', 'Receipts', 'Bills for customers', LucideIcons.receiptText), ('kot', 'Kitchen (KOT)', 'Kitchen tickets for each station', LucideIcons.chefHat),
  ('label', 'Barcode labels', 'Barcode and price labels', LucideIcons.barcode)];
const _sections = {'receipt': 'Receipt printers', 'kot': 'Kitchen printers (KOT)', 'label': 'Barcode label printers'};
const _connections = [('lan', 'Network (Wi-Fi / LAN)'), ('bluetooth', 'Bluetooth'), ('usb', 'USB'), ('system', "Phone's print service")];
const _labelSizes = ['38x25', '50x25', '50x30', '75x50', '100x50'];
String _connName(String c) => _connections.firstWhere((x) => x.$1 == c, orElse: () => (c, c)).$2;

/// Settings → Devices for a restaurant (founder, 1 Nov 2026, like the store's): the printers for receipts, kitchen tickets (KOT) and
/// barcode labels, how each connects, its paper or label size, copies, and which is the default for its job. Test print sends a test
/// page through the phone's print system and marks the printer tested; a kitchen printer added here can be chosen for a kitchen station.
/// Sends a test page to the print dialog; true when it was printed (or sent), false when the dialog was cancelled. Tests replace it.
Future<bool> Function(Uint8List pdf, String name) printTestPagePdf = (pdf, name) => Printing.layoutPdf(onLayout: (_) async => pdf, name: name);

class RstDevicesScreen extends StatefulWidget {
  const RstDevicesScreen({super.key, this.api});
  final RstDevicesApi? api;
  static Route<void> route() => MaterialPageRoute(builder: (_) => const RstDevicesScreen());
  @override
  State<RstDevicesScreen> createState() => _RstDevicesScreenState();
}

class _RstDevicesScreenState extends State<RstDevicesScreen> {
  late final RstDevicesApi _api = widget.api ?? RstDevicesApi();
  Facts? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.list();
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  Future<void> _open({Facts? printer, String? kind}) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => RstPrinterFormScreen(api: _api, printer: printer, kind: kind)));
    if (saved == true && mounted) _load();
  }

  /// Test print (founder, 3 Nov 2026: it marked a printer tested even when the print dialog was cancelled): a cancelled dialog marks
  /// nothing, and the printer is marked tested only when the person says the test page came out (a browser cannot tell).
  Future<void> _test(Facts p) async {
    try {
      // 4 Nov 2026: a USB or network receipt/kitchen printer gets the slip straight away (Android's print screen cannot find them)
      if (p.s('type') != 'label' && printsDirect(p)) {
        await sendToPrinter(p, escPosTestSlip(p));
      } else {
        final sent = await printTestPagePdf(await printerTestPage(p), 'Test ${p.s('name')}.pdf');
        if (!mounted) return;
        if (!sent) return showToast(context, tr('Not printed. The printer is not marked as tested.'));
      }
      if (!mounted) return;
      final yes = await showOlDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('Did the test page print?'), style: inter(18, 800)),
          content: Text(tr('Check the paper from {name}.').replaceAll('{name}', p.s('name')), style: inter(14, 500, color: kMuted)),
          actions: [
            TextButton(key: const ValueKey('test-printed-no'), onPressed: () => Navigator.pop(c, false), child: Text(tr('No'), style: inter(14, 600))),
            TextButton(key: const ValueKey('test-printed-yes'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Yes, it printed'), style: inter(14, 800))),
          ],
        ),
      );
      if (!mounted) return;
      if (yes != true) return showToast(context, tr('Not marked as tested. Check the printer and its connection, then try again.'));
      await _api.tested(p.s('id'));
      if (mounted) showToast(context, tr('Marked as tested.'));
      _load();
    } catch (e) {
      if (mounted) showToast(context, e is DirectPrintException ? tr(e.message) : sayError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final printers = d?.l('printers') ?? const <Facts>[];
    Widget chip(String key, String text, {Color? color}) => Container(
          key: ValueKey(key),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: kLine)),
          child: Text(text, style: inter(13.5, 700, color: color ?? kInk)),
        );
    return Scaffold(
      backgroundColor: kBg,
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('devices-add'),
        backgroundColor: kLimeBtn,
        foregroundColor: kInk,
        onPressed: () => _open(),
        icon: const Icon(LucideIcons.plus),
        label: Text(tr('Add printer'), style: inter(15.5, 800)),
      ),
      body: Column(children: [
        AppHeader(title: tr('Devices'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
              Text(tr('Printers for receipts, the kitchen and barcode labels.'), style: inter(14.5, 500, color: kMuted)),
              const SizedBox(height: 10),
              if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, key: const ValueKey('devices-error'), style: inter(14, 500, color: kError))),
              if (d == null && _error == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(color: kInk))),
              if (d != null) ...[
                Row(children: [
                  chip('devices-count', '${d.n('count')} ${tr(d.n('count') == 1 ? 'printer' : 'printers')}'),
                  const SizedBox(width: 8),
                  chip('devices-tested', '${d.n('tested')} ${tr('tested OK')}', color: const Color(0xFF15803D)),
                ]),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFFF1FBE6), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFCDEFA8))),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(LucideIcons.info, size: 17, color: Color(0xFF3F8A12)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          tr("USB and network (Wi-Fi / LAN) printers print straight from the app: plug the USB printer in (an OTG adapter on a phone) and allow access when Android asks. Bluetooth printers print through the phone's print service, which needs the printer maker's print app. A kitchen printer added here can be picked for a kitchen station in Kitchen setup."),
                          style: inter(13, 500, color: const Color(0xFF2F6B0E), height: 1.4)),
                    ),
                  ]),
                ),
                for (final (i, (kind, _, sub, icon)) in _kinds.indexed)
                  Entrance(
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Icon(icon, size: 19, color: kInk),
                          const SizedBox(width: 8),
                          Expanded(child: Text(tr(_sections[kind]!), style: inter(16, 800))),
                        ]),
                        Padding(padding: const EdgeInsets.only(left: 27), child: Text(tr(sub), style: inter(13, 500, color: kMuted))),
                        const SizedBox(height: 6),
                        if (printers.where((p) => p.s('type') == kind).isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 27, top: 4),
                            child: Text(tr(kind == 'label' ? 'None yet. Labels print through the print dialog until you add one.' : 'None yet.'),
                                key: ValueKey('devices-none-$kind'), style: inter(13.5, 500, color: kMuted)),
                          ),
                        for (final p in printers.where((p) => p.s('type') == kind)) _row(p),
                      ]),
                    ),
                  ),
              ],
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _row(Facts p) {
    final details = [
      _connName(p.s('connection')),
      if (p.s('address').isNotEmpty) p.s('address'),
      if (p.s('model').isNotEmpty) p.s('model'),
      p.s('type') == 'label' ? '${p.s('label_size').replaceAll('x', ' × ')} mm' : '${p.n('paper_mm')} mm',
      if (p.n('copies') > 1) '${p.n('copies')} copies',
      if (p.ls('stations').isNotEmpty) p.ls('stations').join(', '),
    ].join(' · ');
    return Padding(
      key: ValueKey('printer-${p.s('id')}'),
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kLine)),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
        onTap: () => _open(printer: p),
        title: Row(children: [
          Flexible(child: Text(p.s('name'), overflow: TextOverflow.ellipsis, style: inter(15.5, 700))),
          if (p.b('is_default')) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFF1FBE6), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFCDEFA8))),
              child: Text(tr('Default'), style: inter(11, 800, color: const Color(0xFF3F8A12))),
            ),
          ],
        ]),
        subtitle: Text(
          '$details\n${p.so('tested_at') == null ? tr('Not tested yet') : tr('Tested OK')}',
          style: inter(12.5, 500, color: p.so('tested_at') == null ? kMuted : const Color(0xFF15803D)),
        ),
        isThreeLine: true,
        trailing: TextButton(key: ValueKey('printer-test-${p.s('id')}'), onPressed: () => _test(p), child: Text(tr('Test print'), style: inter(13.5, 800, color: kInk))),
        ),
      ),
    );
  }
}

/// A one-page test print: the printer's name, its job and settings, in the size it prints.
Future<Uint8List> printerTestPage(Facts p) async {
  final doc = pw.Document();
  final format = p.s('type') == 'label'
      ? () {
          final parts = p.s('label_size').split('x').map((e) => double.tryParse(e) ?? 50).toList();
          return PdfPageFormat(parts[0] * PdfPageFormat.mm, (parts.length > 1 ? parts[1] : 25) * PdfPageFormat.mm, marginAll: 2 * PdfPageFormat.mm);
        }()
      : (p.n('paper_mm') == 58 ? PdfPageFormat.roll57 : PdfPageFormat.roll80);
  final mono = pw.Font.courier(), bold = pw.Font.courierBold();
  doc.addPage(pw.Page(
    pageFormat: format,
    margin: const pw.EdgeInsets.all(6),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
      pw.Text('TEST PRINT', style: pw.TextStyle(font: bold, fontSize: p.s('type') == 'label' ? 8 : 12)),
      pw.Text(p.s('name'), style: pw.TextStyle(font: mono, fontSize: 8)),
      if (p.s('type') != 'label') ...[
        pw.SizedBox(height: 4),
        pw.Text('${p.s('type') == 'kot' ? 'Kitchen tickets' : 'Receipts'} · ${p.n('paper_mm')} mm', style: pw.TextStyle(font: mono, fontSize: 8)),
        pw.Text('-' * (p.n('paper_mm') == 58 ? 30 : 42), style: pw.TextStyle(font: mono, fontSize: 8)),
        pw.Text('OneLocal Partner', style: pw.TextStyle(font: mono, fontSize: 8)),
      ],
    ]),
  ));
  return doc.save();
}

/// Add or change a printer: name, what it prints, how it connects (and its IP address or Bluetooth name), model, paper width or label
/// size, copies, auto cut, default for its job; Delete for a saved one.
class RstPrinterFormScreen extends StatefulWidget {
  const RstPrinterFormScreen({super.key, required this.api, this.printer, this.kind});
  final RstDevicesApi api;
  final Facts? printer;
  final String? kind;
  @override
  State<RstPrinterFormScreen> createState() => _RstPrinterFormScreenState();
}

class _RstPrinterFormScreenState extends State<RstPrinterFormScreen> {
  late final Facts? _p = widget.printer;
  late String _type = _p?.s('type') ?? widget.kind ?? 'receipt';
  late String _conn = _p?.s('connection') ?? 'bluetooth';
  late int _paper = (_p?.n('paper_mm') ?? 80).toInt();
  late String _label = (_p?.so('label_size') ?? '50x25');
  late int _copies = (_p?.n('copies') ?? 1).toInt();
  late bool _cut = _p?.raw['auto_cut'] != false;
  late bool _default = _p?.b('is_default') ?? false;
  late final _name = TextEditingController(text: _p?.s('name') ?? ''), _address = TextEditingController(text: _p?.s('address') ?? ''),
      _model = TextEditingController(text: _p?.s('model') ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return setState(() => _error = tr('Give the printer a name.'));
    if (_conn == 'lan' && _address.text.trim().isEmpty) return setState(() => _error = tr("Enter the printer's IP address, like 192.168.1.50."));
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.save({
        'id': _p?.s('id'), 'name': _name.text.trim(), 'type': _type, 'connection': _conn,
        'address': _conn == 'lan' || _conn == 'bluetooth' ? _address.text.trim() : null, 'model': _model.text.trim(),
        'paper_mm': _type == 'label' ? null : _paper, 'label_size': _type == 'label' ? _label : null, 'copies': _copies,
        'auto_cut': _type == 'label' ? null : _cut, 'is_default': _default,
      });
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

  Future<void> _delete() async {
    final yes = await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Delete this printer?'), style: inter(18, 800)),
        content: Text(tr('Kitchen stations that print to it stop printing until you pick another.'), style: inter(14, 500)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
          TextButton(key: const ValueKey('printer-delete-yes'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Delete'), style: inter(14, 800, color: kError))),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.api.delete(_p!.s('id'));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  Widget _label0(String t) => Padding(padding: const EdgeInsets.only(top: 16, bottom: 6), child: Text(tr(t), style: inter(13.5, 600, color: kMuted)));

  Widget _pills<T>(List<(T, String)> options, T value, ValueChanged<T> onPick, String keyPrefix) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (v, label) in options)
          ChoiceChip(
            key: ValueKey('$keyPrefix-$v'),
            label: Text(tr(label), style: inter(14, 700)),
            selected: v == value,
            showCheckmark: false,
            selectedColor: const Color(0xFFD9F99D),
            backgroundColor: Colors.white,
            side: BorderSide(color: v == value ? const Color(0xFFB5E550) : kLine),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            onSelected: (_) => setState(() => onPick(v)),
          ),
      ]);

  InputDecoration _field(String hint) => InputDecoration(
        hintText: tr(hint),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
      );

  @override
  Widget build(BuildContext context) {
    final job = switch (_type) { 'kot' => 'kitchen tickets', 'label' => 'labels', _ => 'receipts' };
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr(_p == null ? 'Add printer' : 'Edit printer'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _label0('Name'),
            TextField(key: const ValueKey('printer-name'), controller: _name, maxLength: 40, decoration: _field('For example Counter printer')),
            _label0('What it prints'),
            _pills<String>([for (final k in _kinds) (k.$1, k.$2)], _type, (v) => _type = v, 'printer-type'),
            _label0('How it connects'),
            _pills<String>(_connections, _conn, (v) => _conn = v, 'printer-conn'),
            if (_conn == 'lan') ...[
              _label0("Printer's IP address"),
              TextField(
                key: const ValueKey('printer-address'),
                controller: _address,
                keyboardType: TextInputType.url,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.:]'))],
                decoration: _field('For example 192.168.1.50'),
              ),
            ],
            if (_conn == 'bluetooth') ...[
              _label0("Printer's Bluetooth name (optional)"),
              TextField(key: const ValueKey('printer-address'), controller: _address, decoration: _field('For example RPP02N')),
            ],
            _label0('Model (optional)'),
            TextField(key: const ValueKey('printer-model'), controller: _model, maxLength: 40, decoration: _field('For example Epson TM-T82, TSC TE244')),
            if (_type == 'label') ...[
              _label0('Label size (mm)'),
              _pills<String>([for (final s in _labelSizes) (s, s.replaceAll('x', ' × '))], _label, (v) => _label = v, 'printer-label'),
            ] else ...[
              _label0('Paper width'),
              _pills<int>(const [(58, '58 mm (2 inch)'), (80, '80 mm (3 inch)')], _paper, (v) => _paper = v, 'printer-paper'),
            ],
            _label0('Copies'),
            Row(children: [
              IconButton.filledTonal(key: const ValueKey('printer-copies-less'), onPressed: _copies > 1 ? () => setState(() => _copies--) : null, icon: const Icon(LucideIcons.minus)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: Text('$_copies', key: const ValueKey('printer-copies'), style: inter(18, 800))),
              IconButton.filledTonal(key: const ValueKey('printer-copies-more'), onPressed: _copies < 5 ? () => setState(() => _copies++) : null, icon: const Icon(LucideIcons.plus)),
            ]),
            const SizedBox(height: 8),
            if (_type != 'label')
              SwitchListTile(
                key: const ValueKey('printer-cut'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Auto cut the paper'), style: inter(15, 600)),
                value: _cut,
                onChanged: (v) => setState(() => _cut = v),
              ),
            SwitchListTile(
              key: const ValueKey('printer-default'),
              contentPadding: EdgeInsets.zero,
              title: Text('${tr('Default for')} ${tr(job)}', style: inter(15, 600)),
              subtitle: Text(tr('The first printer for a job is its default.'), style: inter(12.5, 400, color: kMuted)),
              value: _default,
              onChanged: (v) => setState(() => _default = v),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, key: const ValueKey('printer-error'), style: inter(14, 500, color: kError))),
            const SizedBox(height: 14),
            SizedBox(
              height: 54,
              child: FilledButton(
                key: const ValueKey('printer-save'),
                style: FilledButton.styleFrom(backgroundColor: kPrimary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(tr('Save printer'), style: inter(16, 800, color: Colors.white)),
              ),
            ),
            if (_p != null)
              TextButton(key: const ValueKey('printer-delete'), onPressed: _busy ? null : _delete, child: Text(tr('Delete printer'), style: inter(14.5, 700, color: kError))),
          ])),
        ),
      ]),
    );
  }
}
