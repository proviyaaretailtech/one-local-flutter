import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/widgets.dart' as pw;

import '../auth/partner_api.dart';
import '../home/home_nav.dart';
import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'label_pdf.dart';
import 'labels_screens.dart' show printLabelPdf, shareLabelPdf;
import 'stock_env.dart';
import 'stock_kit.dart';
import '../ui/i18n.dart';

/// After a receipt note is matched and received (founder, 26 Oct 2026): a small question first, not the labels screen straight away.
/// "Print labels" opens [LotLabelsScreen] for that lot; "Not now" leaves it (Labels on the receipt note's card opens it later).
Future<void> offerLotLabels(BuildContext context, String receiptId) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      title: Text(tr('Print labels for this lot?'), style: inter(18, 800)),
      content: Text(tr('System Code labels for the products that came in. Products with their own barcode are skipped.'), style: inter(14, 400, color: kMuted, height: 1.4)),
      actions: [
        TextButton(key: const ValueKey('labels-offer-no'), onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Not now'), style: inter(14, 700, color: kMuted))),
        FilledButton(
          key: const ValueKey('labels-offer-yes'),
          style: FilledButton.styleFrom(backgroundColor: kLimeH, foregroundColor: kInk),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Print labels'), style: inter(14, 700)),
        ),
      ],
    ),
  );
  if (yes == true && context.mounted) HomeNav.stockPage?.call(context, StockPage.lotLabels, itemId: receiptId);
}

/// Lot labels (founder, 26 Oct 2026): labels for the whole lot in one go. A label is the product's System Code (barcode, name, price);
/// products that already carry their own barcode are skipped, since it scans already. Every other product that came in is listed with
/// as many labels as good units arrived (damaged ones get none); the person turns a product off or changes its count, sees the total,
/// and prints once.
class LotLabelsScreen extends StatefulWidget {
  const LotLabelsScreen({super.key, required this.env, required this.receiptId});
  final StockEnv env;
  final String receiptId;
  @override
  State<LotLabelsScreen> createState() => _LotLabelsScreenState();
}

/// One product of the lot: what its label shows, how many arrived good, and the person's choice.
class LotLabel {
  LotLabel({required this.itemId, required this.name, required this.good, this.label, this.problem}) : copies = good.round();
  final String itemId, name;
  final num good;
  final LabelData? label; // null when the product has no shop price (then it cannot get a label)
  final String? problem;
  bool on = true;
  int copies;
  bool get printable => label != null && on && copies > 0;
}

class _LotLabelsScreenState extends State<LotLabelsScreen> {
  StockEnv get env => widget.env;
  InvDocument? _doc;
  List<LotLabel>? _lines;
  String? _error;
  var _size = LabelSize.product;
  bool _busy = false;

  static const _sizes = [LabelSize.product, LabelSize.small, LabelSize.medium];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.document(widget.receiptId);
      final lines = <LotLabel>[];
      for (final l in d.lines) {
        final item = l.m('item');
        final good = l.n('qty') - l.n('rejected_qty');
        if (good <= 0) continue;
        try {
          final c = await env.catalogue.lookup(item.s('sku'));
          final barcode = (c.barcode ?? item.s('barcode')).trim();
          final line = LotLabel(
            itemId: item.s('id'),
            name: c.name.isEmpty ? item.s('name') : c.name,
            good: good,
            label: LabelData(
              name: c.name.isEmpty ? item.s('name') : c.name,
              priceMinor: c.priceMinor,
              mrpMinor: c.mrpMinor,
              code: c.sku, // the label is the System Code
              systemCode: c.sku,
              unit: c.sellingUnit,
              store: HomeNav.storeName ?? '',
              category: c.category,
            ),
            problem: barcode.isEmpty ? null : 'Has its own barcode, so it needs no label.',
          );
          if (barcode.isNotEmpty) line.on = false; // pre-mapped: skipped, can still be turned on
          lines.add(line);
        } catch (_) {
          lines.add(LotLabel(itemId: item.s('id'), name: item.s('name'), good: good, problem: 'Not sold in the shop, so it has no price for a label.')..on = false);
        }
      }
      if (!mounted) return;
      setState(() {
        _doc = d;
        _lines = lines;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : 'Could not open this receipt note.');
    }
  }

  int get _total => (_lines ?? const <LotLabel>[]).where((l) => l.printable).fold(0, (n, l) => n + l.copies);

  Future<void> _out(Future<void> Function(Uint8List, String) send) async {
    final batch = [for (final l in _lines ?? const <LotLabel>[]) if (l.printable) (l.label!, l.copies)];
    if (batch.isEmpty) return showToast(context, 'Turn on at least one product.');
    setState(() => _busy = true);
    try {
      pw.Font? font;
      try {
        font = pw.Font.ttf(await rootBundle.load('fonts/Inter.ttf'));
      } catch (_) {}
      final pdf = await buildLabelsPdf(batch, size: _size, font: font, bold: font);
      await send(pdf, 'lot-labels-${_doc?.number ?? 'receipt'}.pdf');
      if (mounted) showToast(context, '$_total label${_total == 1 ? '' : 's'} sent to the print screen.');
    } catch (_) {
      if (mounted) showToast(context, 'The labels could not be made. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    return StockScaffold(
      env: env,
      title: tr('Lot labels'),
      line: _doc == null ? null : '${_doc!.number}${_doc!.s('supplier_name').isEmpty ? '' : ' · ${_doc!.s('supplier_name')}'}',
      onRefresh: _load,
      bottom: lines == null || lines.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(children: [
                Expanded(
                  child: InvPrimary(_total == 0 ? tr('Print labels') : '${tr('Print')} $_total ${tr(_total == 1 ? 'label' : 'labels')}',
                      key: const ValueKey('lot-print'), busy: _busy, onPressed: _busy ? null : () => _out(printLabelPdf)),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('lot-share'),
                  tooltip: tr('Share PDF'),
                  onPressed: _busy ? null : () => _out(shareLabelPdf),
                  icon: const Icon(LucideIcons.share2, size: 20),
                ),
              ]),
            ),
      children: [
        if (_error != null && lines == null)
          StockEmpty(tr('Could not open this receipt note'), _error!, icon: LucideIcons.cloudOff, action: tr('Try again'), onAction: _load)
        else if (lines == null)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else if (lines.isEmpty)
          StockEmpty(tr('Nothing to label'), tr('No good units came in with this receipt note.'), icon: LucideIcons.tag)
        else ...[
          // the sticker size, one tap
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final s in _sizes) ...[
                ChoiceChip(
                  key: ValueKey('lot-size-${s.name}'),
                  label: Text(s.short.isEmpty ? '50 × 30 mm' : s.short, style: inter(13, _size == s ? 700 : 500)),
                  selected: _size == s,
                  showCheckmark: false,
                  selectedColor: kLimeH,
                  backgroundColor: Colors.white,
                  side: BorderSide(color: _size == s ? kLimeH : kCardLine),
                  onSelected: (_) => setState(() => _size = s),
                ),
                const SizedBox(width: 6),
              ],
            ]),
          ),
          const SizedBox(height: 10),
          Text(tr('One label per good unit. Turn off what does not need one, or change the count.'), style: inter(12.5, 400, color: kMuted, height: 1.35)),
          const SizedBox(height: 8),
          for (final l in lines) _row(l),
        ],
      ],
    );
  }

  Widget _row(LotLabel l) => InvCard(
        key: ValueKey('lot-line-${l.itemId}'),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(14.5, 700, color: l.on ? kInk : kMuted)),
              Text(
                [if (l.problem != null) tr(l.problem!), if (l.label != null) '${qty(l.good)} ${tr('received')} · ${labelMoney(l.label!.priceMinor)} · ${l.label!.systemCode}'].join('\n'),
                style: inter(12.5, 400, color: l.problem != null ? kAmberText : kMuted),
              ),
              if (l.label != null && l.on) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: 210,
                  child: InvStepper(
                    key: ValueKey('lot-count-${l.itemId}'),
                    value: l.copies,
                    min: 0,
                    label: 'labels for ${l.name}',
                    onChanged: (v) => setState(() => l.copies = v.round().clamp(0, 999)),
                  ),
                ),
              ],
            ]),
          ),
          Switch(
            key: ValueKey('lot-on-${l.itemId}'),
            value: l.on,
            activeTrackColor: kLimeH,
            onChanged: l.label == null ? null : (v) => setState(() => l.on = v),
          ),
        ]),
      );
}
