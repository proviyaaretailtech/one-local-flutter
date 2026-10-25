import 'package:flutter/material.dart';

import '../auth/partner_api.dart';
import '../catalogue/catalogue_api.dart';
import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'stock_env.dart';
import 'stock_kit.dart';

/// Titles the damage screens give their adjustment documents, so each screen finds its own (older ones said "Write-off").
const damageTitle = 'Damaged stock';
const throwAwayTitles = {'Throw away', 'Write-off'};

/// Every stock item of the store (the list is paged at 50; a shop has a few hundred at most).
Future<List<Facts>> loadAllStock(InventoryApi api, {String filter = 'all'}) async {
  final out = <Facts>[];
  for (var page = 1; page <= 10; page++) {
    final r = await api.stock(filter: filter, page: page, pageSize: 50);
    out.addAll(r.l('items'));
    if (out.length >= r.n('total') || r.l('items').length < 50) break;
  }
  return out;
}

/// The adjustment documents in [statuses] whose title is one of [titles], opened in full (lines, allowed actions, who raised them).
Future<List<InvDocument>> loadAdjustments(InventoryApi api, Set<String> titles, List<String> statuses, {int limit = 20}) async {
  final rows = await api.documents('adjustment', statuses: statuses, limit: limit);
  final mine = rows.where((r) => titles.contains(r.s('title'))).toList();
  return [for (final r in mine) await api.document(r.s('id'))];
}

/// A server refusal in plain words ("You cannot approve an adjustment you raised").
String problem(Object e) => e is PartnerApiException ? e.message : 'Could not reach the server. Check your connection and try again.';

/// Where the units are taken from: a place (shelf, backroom, quarantine), and the batch when the product has batches.
class StockPlace {
  const StockPlace({required this.binId, required this.name, required this.onHand, this.lotId, this.lotCode});
  final String binId, name;
  final num onHand;
  final String? lotId, lotCode;
  String get label => lotCode == null ? name : '$name · batch $lotCode';
}

/// The places of one item, from inv_stock_detail: batches first (they carry their place), then places without a batch.
/// [quarantine] true lists only the held-apart (damaged) places, false only the sellable ones.
List<StockPlace> placesOf(Facts detail, {required bool quarantine}) {
  bool keep(String zone) => (zone == 'quarantine') == quarantine;
  final lots = detail.l('lots').where((l) => keep(l.s('zone')) && l.n('on_hand') > 0).toList();
  return [
    for (final l in lots) StockPlace(binId: l.s('bin_id'), name: l.s('bin_name'), onHand: l.n('on_hand'), lotId: l.s('id'), lotCode: l.s('lot_code')),
    for (final b in detail.l('bins').where((b) => keep(b.s('zone')) && b.n('on_hand') > 0 && !lots.any((l) => l.s('bin_id') == b.s('id'))))
      StockPlace(binId: b.s('id'), name: b.s('name'), onHand: b.n('on_hand')),
  ];
}

/// One line of a document, in words: "2 pc of Coca-Cola 500ml".
String lineWords(Facts l) => '${qty(l.n('qty'))} ${l.m('item').s('unit').isEmpty ? 'units' : l.m('item').s('unit')} of ${l.m('item').s('name')}';

/// A document waiting for approval: what, why, who raised it, and Approve / Send back for a person who may approve.
class PendingCard extends StatelessWidget {
  const PendingCard({super.key, required this.doc, required this.meId, required this.verb, required this.onApprove, required this.onSendBack, this.busy = false, this.onItem});
  final InvDocument doc;
  final String? meId;
  final String verb; // "Approve" / "Approve throw-away"
  final VoidCallback onApprove, onSendBack;
  final bool busy;
  final void Function(String itemId)? onItem;

  @override
  Widget build(BuildContext context) {
    final raisedBy = doc.mo('created_by');
    final mine = raisedBy != null && raisedBy.s('id') == meId;
    return InvCard(
      key: ValueKey('pending-${doc.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InvCardHead(doc.number, subtitle: doc.lines.map(lineWords).join(', '), chip: const StockStatusChip('low', label: 'Waiting')),
        for (final l in doc.lines)
          if (onItem != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => onItem!(l.m('item').s('id')),
                style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                child: Text('Open ${l.m('item').s('name')}', style: inter(13, 600, color: kLink)),
              ),
            ),
        StockRow('Reason', doc.s('reason').isEmpty ? '—' : doc.s('reason')),
        if (doc.s('note').isNotEmpty) StockRow('Note', doc.s('note')),
        StockRow('Raised by', raisedBy?.s('name') ?? '—'),
        if (doc.t('submitted_at') != null) StockRow('Sent', stamp(doc.t('submitted_at')!)),
        const SizedBox(height: 8),
        if (mine && !doc.can('approve'))
          Text('You raised this, so someone else with approval rights has to approve it.', style: inter(13, 400, color: kMuted, height: 1.4))
        else if (!doc.can('approve'))
          Text('Waiting for an owner or manager to approve it.', style: inter(13, 400, color: kMuted, height: 1.4)),
        if (doc.can('approve')) InvPrimary(verb, busy: busy, onPressed: busy ? null : onApprove),
        if (doc.can('reject')) InvSecondary('Send back', onPressed: busy ? null : onSendBack),
      ]),
    );
  }
}

/// "Throw away 2 units?" — says it cannot be undone, and the money lost when the product's cost is known. True when confirmed.
Future<bool> confirmThrowAway(BuildContext context, {required String what, int? lossMinor}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      title: Text('Throw away $what?', style: inter(18, 700)),
      content: Text(
        'This removes them from your stock for good${lossMinor == null ? '' : ' and records about ${inr(lossMinor)} as lost'}. It cannot be undone.',
        style: inter(14, 400, color: kMuted, height: 1.4),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Keep them', style: inter(14, 600))),
        FilledButton(
          key: const ValueKey('confirm-throw-away'),
          style: FilledButton.styleFrom(backgroundColor: kRedText),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Throw away', style: inter(14, 700, color: Colors.white)),
        ),
      ],
    ),
  );
  return r == true;
}

/// "Move 2 units off the shelf?" before approving a damage record. True when confirmed.
Future<bool> confirmDamage(BuildContext context, String what) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      title: Text('Approve damage?', style: inter(18, 700)),
      content: Text('$what will be held apart as damaged and can no longer be sold.', style: inter(14, 400, color: kMuted, height: 1.4)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Not now', style: inter(14, 600))),
        FilledButton(
          key: const ValueKey('confirm-damage'),
          style: FilledButton.styleFrom(backgroundColor: kInk),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Approve', style: inter(14, 700, color: kLimeH)),
        ),
      ],
    ),
  );
  return r == true;
}

/// "₹60" / "₹60.50" from paise.
String inr(int minor) => minor % 100 == 0 ? '₹${minor ~/ 100}' : '₹${(minor / 100).toStringAsFixed(2)}';

/// The cost of [n] units of the item with this System Code, when the catalogue knows its cost; null otherwise.
Future<int?> lossOf(CatalogueApi catalogue, String systemCode, num n) async {
  try {
    final c = await catalogue.lookup(systemCode);
    return c.costMinor == null ? null : (c.costMinor! * n).round();
  } catch (_) {
    return null;
  }
}

/// Opens an item's stock page.
void openItem(BuildContext context, StockEnv env, String itemId) => env.open(context, StockPage.item, itemId: itemId);
