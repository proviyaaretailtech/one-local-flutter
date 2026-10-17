import 'package:flutter/material.dart';

import '../auth/partner_api.dart';
import '../ui/theme.dart';
import 'inventory_api.dart';
import 'inventory_dashboard.dart';
import 'inventory_widgets.dart';

/// The open document of one stock screen (receipt, adjustment, transfer or audit) and the three things a person does to it:
/// save the draft, run an action, start a new one. The server holds the truth; this only keeps the last answer, the retry keys and a busy flag.
class DocFlow {
  DocFlow(this.env, this.type);
  final InvEnv env;
  final String type;

  InvDocument? doc;
  Facts? options;
  String? error;
  bool busy = false;

  // One key per intent (one tap), kept until that intent succeeds, so a retried tap never doubles.
  String? _createKey;
  final _actKeys = <String, String>{};

  List<Facts> history = const [];

  /// Loads the options, the document [id] — or the newest open one of this type — and the list of documents.
  Future<void> load({String? id, List<String> open = const ['draft']}) async {
    try {
      options ??= await env.api.options();
      history = await env.api.documents(type, limit: 20);
      final openRow = id ?? history.where((d) => open.contains(d.s('status'))).map((d) => d.s('id')).firstOrNull;
      doc = openRow == null ? null : await env.api.document(openRow);
      error = null;
    } catch (e) {
      error = e.toString();
    }
  }

  Future<void> open(String id) async {
    doc = await env.api.document(id);
  }

  /// Creates the draft (first save) or saves the existing one, keeping the person's edits.
  Future<InvDocument> save({Map<String, Object?> fields = const {}, List<DraftLine>? lines}) async {
    final d = doc;
    if (d == null) {
      _createKey ??= InventoryApi.newKey();
      final made = await env.api.createDraft(type, fields: fields, lines: lines, key: _createKey!);
      _createKey = null;
      doc = made;
      return made;
    }
    doc = await env.api.saveDraft(d.id, version: d.version, fields: fields, lines: lines);
    return doc!;
  }

  /// Runs [action] on the saved document. The same tap on the same version retries with the same key.
  Future<InvDocument> act(String action, {String? note}) async {
    final d = doc!;
    final k = _actKeys.putIfAbsent('${d.id}:$action:${d.version}', InventoryApi.newKey);
    final r = await env.api.act(d.id, action, version: d.version, note: note, key: k);
    _actKeys.remove('${d.id}:$action:${d.version}');
    doc = r;
    return r;
  }

  void startNew() {
    doc = null;
    _createKey = null;
  }

  /// Runs [job] with the busy flag and shows a refusal as a toast. Returns whether it worked.
  Future<bool> run(BuildContext context, VoidCallback rebuild, Future<void> Function() job, {String? done}) async {
    busy = true;
    rebuild();
    try {
      await job();
      error = null;
      if (done != null && context.mounted) showToast(context, done);
      return true;
    } on PartnerApiException catch (e) {
      if (context.mounted) showToast(context, e.message);
      if (e is InventoryApiException && e.stale && doc != null) {
        try {
          doc = await env.api.document(doc!.id);
        } catch (_) {}
      }
      return false;
    } catch (_) {
      if (context.mounted) showToast(context, 'Could not reach the server. Check your connection and try again.');
      return false;
    } finally {
      busy = false;
      rebuild();
    }
  }
}

/// "Status tabs" row for a document screen.
List<Widget> docEmpty(String text, {String? action, VoidCallback? onAction}) => [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: inter(14, 400, color: kMuted, height: 1.45)),
        if (action != null) ...[const SizedBox(height: 12), InvPrimary(action, onPressed: onAction)],
      ])),
    ];

/// A line of the document history ("RCV-099 · Completed").
class DocHistoryCard extends StatelessWidget {
  const DocHistoryCard({super.key, required this.row, this.subtitle, this.trailing, this.onTap, this.action});
  final Facts row;
  final String? subtitle, trailing, action;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InvCard(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(row.s('doc_no'), style: inter(16, 700))),
            InvDotChip.doc(row.s('doc_type'), row.s('status')),
          ]),
          if (subtitle != null) ...[const SizedBox(height: 6), Text(subtitle!, style: inter(13.5, 400, color: kMuted))],
          if (trailing != null || action != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: Text(trailing ?? '', style: inter(13, 400, color: kMuted))),
              if (action != null) Text(action!, style: inter(13.5, 700, color: kLink)),
            ]),
          ],
        ]),
      );
}
