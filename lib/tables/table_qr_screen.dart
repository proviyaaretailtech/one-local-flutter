import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'guest_orders.dart' show askText;
import 'table_qr_api.dart';
import 'table_widgets.dart';

/// Hands a finished PDF to the phone: print it, or share it (WhatsApp, mail, files). Swappable for tests.
typedef QrPdfOut = Future<void> Function(Uint8List pdf, String fileName);

Future<void> _printPdf(Uint8List pdf, String name) => Printing.layoutPdf(onLayout: (_) async => pdf, name: name);
Future<void> _sharePdf(Uint8List pdf, String name) => Printing.sharePdf(bytes: pdf, filename: name);

/// "Table QR codes" (from the Tables screen and the restaurant's More page; ported from the VINII app's Table QR codes screen):
/// every table of the store with its code, by area. A table manager issues a code, prints or shares it, switches it off, or replaces it
/// (asked for by typing the table's name, because the printed code stops working). Floor staff see which tables have a working code.
/// The database decides who may do what (0560); the screen draws `can` and the codes it is given.
class TableQrScreen extends StatefulWidget {
  const TableQrScreen({super.key, required this.env, this.onPrint, this.onShare, this.linkBase});
  final TablesEnv env;
  final QrPdfOut? onPrint;
  final QrPdfOut? onShare;

  /// Overrides the guest web address for the printed link (tests).
  final String? linkBase;
  @override
  State<TableQrScreen> createState() => _TableQrScreenState();
}

class _TableQrScreenState extends State<TableQrScreen> {
  Facts? _d;
  String? _error;
  final _busy = <String>{};

  TableQrApi get _api => widget.env.qrApi;
  String? get _loc => widget.env.api.locationId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.list(_loc);
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

  void _put(Facts t) {
    final d = _d;
    if (d == null) return;
    final tables = [for (final x in d.l('tables')) x.s('id') == t.s('id') ? Facts({...x.raw, ...t.raw}) : x];
    setState(() => _d = Facts({...d.raw, 'tables': [for (final x in tables) x.raw]}));
  }

  Future<void> _run(String tableId, Future<Facts> Function() job, String done) async {
    if (_busy.contains(tableId)) return;
    setState(() => _busy.add(tableId));
    try {
      final t = await job();
      _put(t);
      if (mounted) showToast(context, done);
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
    if (mounted) setState(() => _busy.remove(tableId));
  }

  String _link(Facts t) => TableQrApi.linkFor(t.s('code'), base: widget.linkBase);

  Future<Uint8List> _pdf(Facts t) async {
    final doc = pw.Document(title: 'Table ${t.s('label')} QR code');
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a6,
      build: (_) => pw.Center(
        child: pw.Column(mainAxisSize: pw.MainAxisSize.min, children: [
          pw.Text('Table ${t.s('label')}', style: pw.TextStyle(fontSize: 28, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Text('Scan to see the menu and order', style: const pw.TextStyle(fontSize: 12)),
          pw.SizedBox(height: 14),
          pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: _link(t), width: 190, height: 190),
          pw.SizedBox(height: 10),
          pw.Text('No app or sign-in needed', style: const pw.TextStyle(fontSize: 10)),
        ]),
      ),
    ));
    return doc.save();
  }

  Future<void> _out(Facts t, {required bool share}) async {
    try {
      final bytes = await _pdf(t);
      await (share ? (widget.onShare ?? _sharePdf) : (widget.onPrint ?? _printPdf))(bytes, 'table-${t.s('label')}-qr.pdf');
    } catch (e) {
      if (mounted) showToast(context, 'Could not ${share ? 'share' : 'print'} the code on this phone.');
    }
  }

  Future<void> _replace(Facts t) async {
    final label = t.s('label');
    final typed = await askText(
      context,
      dialogKey: const ValueKey('replace-dialog'),
      fieldKey: const ValueKey('replace-name'),
      confirmKey: const ValueKey('replace-confirm'),
      title: 'Replace the code of $label?',
      body: 'The printed code on this table stops working at once and guests at the table must scan the new one. Type $label to confirm.',
      hint: label,
      confirm: 'Replace code',
      valid: (v) => v.trim().toLowerCase() == label.trim().toLowerCase(),
    );
    if (typed == null) return;
    await _run(t.s('id'), () => _api.issue(_loc, t.s('id'), replace: true, confirmLabel: typed), 'New code for $label. Print it and put it on the table.');
  }

  Future<void> _showCode(Facts t) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => SafeArea(
        child: Padding(
          key: const ValueKey('qr-sheet'),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Table ${t.s('label')}', style: inter(24, 700)),
            Text(t.b('enabled') ? 'Guests scan this to see the menu and order.' : 'This code is switched off: a scan says it is not in use.', style: inter(14, 400, color: kMuted)),
            const SizedBox(height: 14),
            Center(
              child: Opacity(
                opacity: t.b('enabled') ? 1 : 0.35,
                child: QrImageView(key: const ValueKey('qr-image'), data: _link(t), size: 220, backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(_link(t), key: const ValueKey('qr-link'), textAlign: TextAlign.center, style: inter(11.5, 400, color: kMuted)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: LimeButton('Print', key: const ValueKey('qr-print'), icon: LucideIcons.printer, height: 52, onPressed: () => _out(t, share: false))),
              const SizedBox(width: 10),
              Expanded(child: OutlineButtonT('Share', key: const ValueKey('qr-share'), icon: LucideIcons.share2, dark: true, height: 52, onPressed: () => _out(t, share: true))),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final can = d?.m('can');
    final manage = can?.b('issue') ?? false;
    final tables = d?.l('tables') ?? const <Facts>[];
    final groups = <String, List<Facts>>{};
    for (final t in tables) {
      (groups[(t.so('area_name') ?? '').isEmpty ? 'Other tables' : t.s('area_name')] ??= []).add(t);
    }
    final counts = d?.m('counts');
    return TablesPage(
      env: widget.env,
      title: 'Table QR codes',
      subtitle: counts == null ? ' ' : '${counts.n('on').toInt()} of ${counts.n('all').toInt()} tables have a working code',
      back: true,
      nav: false,
      onRefresh: _load,
      children: [
        if (d == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (d != null && !manage)
          Container(
            key: const ValueKey('qr-staff-note'),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(14)),
            child: Text('A table manager issues, prints and replaces the codes.', style: inter(14, 500, color: kInk)),
          ),
        if (d != null && tables.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Center(child: Text('No tables set up for this store yet.', style: inter(15, 400, color: kMuted)))),
        for (final MapEntry(key: area, value: list) in groups.entries) ...[
          Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 8), child: Text(area.toUpperCase(), style: inter(13, 700, color: kMuted))),
          for (final t in list) _row(t, manage),
        ],
      ],
    );
  }

  Widget _row(Facts t, bool manage) {
    final id = t.s('id');
    final has = t.b('has_code');
    final on = has && t.b('enabled');
    final busy = _busy.contains(id);
    final (word, bg, fg) = !has ? ('No code', kGreyBg, kMuted) : on ? ('Working', kAvailBg, kAvailText) : ('Switched off', kRedSoft, kRedText);
    return Container(
      key: ValueKey('qr-row-$id'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Table ${t.s('label')}', style: inter(17, 700)),
            const SizedBox(height: 4),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
                child: Text(word, key: ValueKey('qr-state-$id'), style: inter(12.5, 600, color: fg)),
              ),
              const SizedBox(width: 8),
              Text(pax(t.n('seats')), style: inter(12.5, 400, color: kMuted)),
            ]),
          ]),
        ),
        if (busy) const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kInk))),
        if (!busy && manage && !has)
          TextButton.icon(
            key: ValueKey('qr-issue-$id'),
            onPressed: () => _run(id, () => _api.issue(_loc, id), 'Code ready for ${t.s('label')}.'),
            icon: const Icon(LucideIcons.qrCode, size: 18, color: kInk),
            label: Text('Issue code', style: inter(14, 600)),
          ),
        if (!busy && manage && has) ...[
          IconButton(key: ValueKey('qr-show-$id'), tooltip: 'Show, print or share', onPressed: () => _showCode(t), icon: const Icon(LucideIcons.qrCode, color: kInk)),
          Switch(
            key: ValueKey('qr-switch-$id'),
            value: on,
            activeThumbColor: kLimeBtn,
            onChanged: (v) => _run(id, () => _api.setEnabled(_loc, id, v), v ? 'Code of ${t.s('label')} switched on.' : 'Code of ${t.s('label')} switched off.'),
          ),
          PopupMenuButton<String>(
            key: ValueKey('qr-more-$id'),
            tooltip: 'More',
            onSelected: (_) => _replace(t),
            itemBuilder: (_) => [const PopupMenuItem(value: 'replace', child: Text('Replace code…'))],
          ),
        ],
      ]),
    );
  }
}
