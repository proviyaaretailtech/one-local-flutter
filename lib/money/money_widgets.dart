import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/rpc_client.dart';
import '../inventory/inventory_widgets.dart' show InvTopBar, InvBottomNav, InvCard, InvDotChip, InvInput, InvLabel, InvPickBox, InvPrimary, InvSecondary, InvTiles, pickOne, kAmberText, kAmberBgH, kRedText, kRedBgH, kGreyBg, kLimeH, kNavyH, kCardLine, kPostedText, kGreenIconBg;
import '../orders/order_widgets.dart' show Kick;
import '../states/state_kit.dart' show InfoBox;
import '../ui/theme.dart';
import 'money_api.dart';
import 'money_env.dart';

export '../inventory/inventory_widgets.dart' show InvCard, InvTiles, InvStatTile, InvPrimary, InvSecondary, InvLabel, InvInput, InvPickBox, pickOne;

/// What a screen's body builder gets: the filters (change them with [set]) and a way to reload.
class MoneyCtx {
  MoneyCtx(this.context, this.env, this.q, this._set, this._reload);
  final BuildContext context;
  final MoneyEnv env;
  final Map<String, dynamic> q;
  final void Function(Map<String, dynamic>) _set;
  final Future<void> Function() _reload;

  /// Changes filters and reloads from page one.
  void set(Map<String, dynamic> changes) => _set(changes);
  Future<void> reload() => _reload();
  MoneyApi get api => env.api;
}

/// One money screen: top bar, title, section switcher, the server's answer drawn by [body], the floating bar with Money active.
/// Loading, error (with retry) and pull-to-refresh are the same everywhere.
class MoneyScreen extends StatefulWidget {
  const MoneyScreen({super.key, required this.env, required this.screen, required this.title, required this.load, required this.body, this.defaults = const {}, this.subtitle, this.switcher = true});
  final MoneyEnv env;
  final String screen, title;
  final String? subtitle;
  final bool switcher;
  final Future<Facts> Function(Map<String, dynamic> q) load;
  final List<Widget> Function(MoneyCtx c, Facts data) body;
  final Map<String, dynamic> defaults;

  @override
  State<MoneyScreen> createState() => _MoneyScreenState();
}

class _MoneyScreenState extends State<MoneyScreen> {
  late final Map<String, dynamic> q = {...widget.defaults};
  Facts? data;
  String? error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    try {
      final d = await widget.load(q);
      if (!mounted || gen != _gen) return;
      setState(() {
        data = d;
        error = null;
      });
    } on RpcException catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() => error = e.message);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() => error = 'Could not reach the server. Check your connection and try again.');
    }
  }

  void _set(Map<String, dynamic> changes) {
    setState(() {
      q.addAll(changes);
      if (!changes.containsKey('page_size')) q.remove('page_size');
      error = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final env = widget.env;
    final ctx = MoneyCtx(context, env, q, _set, _load);
    final sw = env.switcher;
    final idx = sw.indexWhere((s) => s.$1 == widget.screen);
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        InvTopBar(onItems: env.onItems ?? () => env.tab(context, 'item'), onBell: env.onBell ?? () => env.later(context, 'Notifications')),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(14, 16, 14, 24), children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text(widget.title, style: inter(23, 700))),
                  if (widget.subtitle != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.subtitle!, style: inter(13.5, 400, color: kMuted))),
                ]),
              ),
              if (widget.switcher) _Switcher(env: env, current: widget.screen, index: idx, total: sw.length),
              if (data != null) ...widget.body(ctx, data!) else if (error != null) _ErrorBox(error!, _load) else const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk))),
            ]),
          ),
        ),
      ]),
      bottomNavigationBar: InvBottomNav(active: 'money', onTap: (id) => env.tab(context, id)),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox(this.message, this.onRetry);
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => InvCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Could not load this', style: inter(15, 600)),
          const SizedBox(height: 6),
          Text(message, style: inter(13, 400, color: kMuted)),
          const SizedBox(height: 10),
          InvSecondary('Try again', onPressed: onRetry),
        ]),
      );
}

/// "Money / Payments  2/10": opens a list of the screens this person may open.
class _Switcher extends StatelessWidget {
  const _Switcher({required this.env, required this.current, required this.index, required this.total});
  final MoneyEnv env;
  final String current;
  final int index, total;
  @override
  Widget build(BuildContext context) {
    final list = env.switcher;
    final title = list.firstWhere((s) => s.$1 == current, orElse: () => (current, current)).$2;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        Expanded(
          child: Semantics(
            button: true,
            label: 'Switch money screen',
            child: InkWell(
              key: const ValueKey('money-switcher'),
              borderRadius: BorderRadius.circular(999),
              onTap: () async {
                final k = await pickOne<String>(context, 'Money', [for (final s in list) (s.$1, s.$2, null)], current: current);
                if (k != null && k != current && context.mounted) env.open(context, k);
              },
              child: Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(color: kNavyH, borderRadius: BorderRadius.circular(999)),
                child: Row(children: [
                  Expanded(child: ExcludeSemantics(child: Text('Money / $title', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15, 500, color: Colors.white)))),
                  const Icon(LucideIcons.chevronDown, size: 16, color: Colors.white),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
          child: Text('${index < 0 ? 1 : index + 1}/$total', style: inter(14, 500, color: kMuted)),
        ),
      ]),
    );
  }
}

/// Filter pill; the active one is lime. A [menu] chip (it opens a list or a date picker) reads like a dropdown field, as in Figma's
/// Invoices, Transactions, Cashbook and Expenses: label on the left, an optional [icon] before it, a chevron on the right.
class MoneyChip extends StatelessWidget {
  const MoneyChip(this.label, {super.key, this.active = false, required this.onTap, this.menu = false, this.icon});
  final String label;
  final bool active, menu;
  final IconData? icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final text = Text(label, textAlign: menu ? TextAlign.left : TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, active ? 700 : 500));
    return Semantics(
      button: true,
      selected: active,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: EdgeInsets.symmetric(horizontal: menu ? 12 : 14, vertical: 10),
          alignment: menu ? Alignment.centerLeft : Alignment.center,
          decoration: BoxDecoration(color: active ? kLimeH : Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: active ? kLimeH : kLine)),
          child: menu
              ? Row(children: [
                  if (icon != null) ...[Icon(icon, size: 16, color: kInk), const SizedBox(width: 8)],
                  Expanded(child: text),
                  const SizedBox(width: 4),
                  const Icon(LucideIcons.chevronDown, size: 16, color: kInk),
                ])
              : text,
        ),
      ),
    );
  }
}

/// Three chips in a row (dates, kind, status), equal width.
class MoneyChips extends StatelessWidget {
  const MoneyChips(this.chips, {super.key});
  final List<MoneyChip> chips;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(children: [for (var i = 0; i < chips.length; i++) ...[if (i > 0) const SizedBox(width: 8), Expanded(child: chips[i])]]),
      );
}

/// Picks one of [options] (value, label) for a chip and calls [then] with it.
Future<void> chooseFor(BuildContext context, String title, List<(String, String)> options, String current, void Function(String) then) async {
  final v = await pickOne<String>(context, title, [for (final o in options) (o.$1, o.$2, null)], current: current);
  if (v != null) then(v);
}

const periods = [('today', 'Today'), ('week', 'This week'), ('month', 'This month'), ('all', 'All time')];
String periodLabel(String p) => periods.firstWhere((e) => e.$1 == p, orElse: () => ('week', 'This week')).$2;

/// "Payments trend" style section heading with a right-hand count pill.
class MoneyHeading extends StatelessWidget {
  const MoneyHeading(this.title, {super.key, this.pill});
  final String title;
  final String? pill;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 10),
        child: Row(children: [
          Expanded(child: Semantics(header: true, child: Text(title, style: inter(18, 700)))),
          if (pill != null) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: kLine)), child: Text(pill!, style: inter(12.5, 500, color: kMuted))),
        ]),
      );
}

/// Grey explanation under a list.
class MoneyFootnote extends StatelessWidget {
  const MoneyFootnote(this.lines, {super.key});
  final List<String> lines;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 12),
        child: Text(lines.join('\n'), style: inter(12.5, 400, color: kMuted, height: 1.45)),
      );
}

/// A tile with a value, a caption and an optional green sub-line ("₹45,511.05 / Received / 114 successful payments").
class MoneyTile extends StatelessWidget {
  const MoneyTile(this.label, this.value, {super.key, this.sub, this.subColor = kPostedText, this.valueColor = kInk});
  final String label, value;
  final String? sub;
  final Color subColor, valueColor;
  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 92),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kCardLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 400, color: kMuted)),
          const SizedBox(height: 6),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, maxLines: 1, style: inter(24, 700, color: valueColor))),
          if (sub != null) ...[const SizedBox(height: 4), Text(sub!, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(12, 400, color: subColor))],
        ]),
      );
}

/// Status label and colours for every status the server sends (one place, so the screens agree).
(String, Color, Color) statusLook(String status) => switch (status) {
      'paid' => ('Paid', kGreenIconBg, kPostedText),
      'refunded' => ('Refunded', kGreenIconBg, kPostedText),
      'settled' => ('Settled', kGreenIconBg, kPostedText),
      'posted' => ('Posted', kGreenIconBg, kPostedText),
      'approved' => ('Approved', kGreenIconBg, kPostedText),
      'recorded' => ('Recorded', kGreyBg, kMuted),
      'ready' => ('Ready', kGreenIconBg, kPostedText),
      'pending' => ('Pending', kAmberBgH, kAmberText),
      'queued' => ('Queued', kAmberBgH, kAmberText),
      'review' => ('Review', kAmberBgH, kAmberText),
      'partial' => ('Partially Paid', kAmberBgH, kAmberText),
      'failed' => ('Failed', kRedBgH, kRedText),
      'rejected' => ('Rejected', kRedBgH, kRedText),
      'overdue' => ('Overdue', kRedBgH, kRedText),
      'voided' => ('Voided', kGreyBg, kMuted),
      'disputed' => ('Disputed', kRedBgH, kRedText),
      _ => (status.isEmpty ? '' : status[0].toUpperCase() + status.substring(1), kGreyBg, kMuted),
    };

class MoneyStatus extends StatelessWidget {
  const MoneyStatus(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final (t, bg, fg) = statusLook(status);
    return InvDotChip(t, bg: bg, fg: fg);
  }
}

/// A list card: bold heading and amount on one line, a muted line and a status chip on the next.
/// [trailing] sits at the end of that second line (a chip, or a small action such as Void) so the card stays two lines tall.
class MoneyRow extends StatelessWidget {
  const MoneyRow({super.key, required this.title, required this.amount, required this.sub, this.status, this.amountColor = kInk, this.onTap, this.extra, this.trailing});
  final String title, amount, sub;
  final String? status;
  final Color amountColor;
  final VoidCallback? onTap;
  final Widget? extra, trailing;
  @override
  Widget build(BuildContext context) => InvCard(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(title, style: inter(15.5, 700))),
            const SizedBox(width: 8),
            Text(amount, style: inter(15.5, 700, color: amountColor)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Text(sub, style: inter(13, 400, color: kMuted))),
            if (status != null) MoneyStatus(status!),
            if (trailing != null) ...[if (status != null) const SizedBox(width: 8), trailing!],
          ]),
          if (extra != null) ...[const SizedBox(height: 8), extra!],
        ]),
      );
}

/// A small text action for the end of a [MoneyRow]'s second line ("Void"): a padded tap target that does not make the card taller.
class MoneyAction extends StatelessWidget {
  const MoneyAction(this.label, {super.key, required this.onTap, this.color = kInk});
  final String label;
  final VoidCallback onTap;
  final Color color;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Text(label, style: inter(13, 600, color: color))),
        ),
      );
}

/// Dark full-width button with lime text at the bottom of a list ("Export payments").
class MoneyCta extends StatelessWidget {
  const MoneyCta(this.label, {super.key, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(top: 8), child: InvPrimary(label, onPressed: onPressed, busy: busy));
}

/// Copies the CSV of a report to the clipboard (there is no file or share package in the app; PDF output is not built).
Future<void> exportCsv(BuildContext context, MoneyApi api, String report, Map<String, dynamic> window) async {
  try {
    final r = await api.reportRows(report, window);
    await Clipboard.setData(ClipboardData(text: csvOf(r)));
    final n = ((r.raw['rows'] as List?) ?? const []).length;
    if (context.mounted) showToast(context, n == 0 ? 'Nothing to export for this period.' : 'CSV copied: ${r.s('title')}, $n rows.');
  } on RpcException catch (e) {
    if (context.mounted) showToast(context, e.message);
  } catch (_) {
    if (context.mounted) showToast(context, 'Could not export. Check your connection and try again.');
  }
}

// ---------------------------------------------------------------- forms

enum FieldKind { text, amount, signedAmount, pick }

class FormFieldSpec {
  const FormFieldSpec(this.key, this.label, {this.kind = FieldKind.text, this.options = const [], this.initial = '', this.hint, this.optional = false});
  final String key, label;
  final FieldKind kind;
  final List<(String, String)> options;
  final String initial;
  final String? hint;
  final bool optional;
}

/// A bottom-sheet form. [onSubmit] gets the values (amounts already in paise under `amount_minor`) and ONE idempotency key per opening of the
/// sheet, so tapping again after a failure is a retry of the same intent. The sheet stays open and shows the server's sentence when it fails.
/// Returns true when the server accepted it.
Future<bool> showMoneyForm(BuildContext context, {required String title, required String action, required List<FormFieldSpec> fields, required Future<void> Function(Map<String, dynamic> values, String key) onSubmit, String? note}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => _MoneyForm(title: title, action: action, fields: fields, onSubmit: onSubmit, note: note),
  );
  return ok == true;
}

class _MoneyForm extends StatefulWidget {
  const _MoneyForm({required this.title, required this.action, required this.fields, required this.onSubmit, this.note});
  final String title, action;
  final String? note;
  final List<FormFieldSpec> fields;
  final Future<void> Function(Map<String, dynamic>, String) onSubmit;
  @override
  State<_MoneyForm> createState() => _MoneyFormState();
}

class _MoneyFormState extends State<_MoneyForm> {
  late final Map<String, TextEditingController> c = {for (final f in widget.fields) f.key: TextEditingController(text: f.initial)};
  final String key = MoneyApi.newKey();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _go() async {
    final v = <String, dynamic>{};
    for (final f in widget.fields) {
      final t = c[f.key]!.text.trim();
      if (t.isEmpty) {
        if (f.optional) continue;
        setState(() => error = 'Fill in ${f.label.toLowerCase()}.');
        return;
      }
      if (f.kind == FieldKind.amount || f.kind == FieldKind.signedAmount) {
        final p = parseRupees(t.replaceAll(RegExp(r'^[+−-]'), ''));
        if (p == null) {
          setState(() => error = 'Enter ${f.label.toLowerCase()} as rupees, for example 250 or 250.50.');
          return;
        }
        v[f.key == 'amount' ? 'amount_minor' : f.key] = (t.startsWith('-') || t.startsWith('−')) ? -p : p;
      } else {
        v[f.key] = t;
      }
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onSubmit(v, key);
      if (mounted) Navigator.pop(context, true);
    } on RpcException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Could not reach the server. Tap again to retry; it will not be recorded twice.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.title, style: inter(18, 700)),
            if (widget.note != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(widget.note!, style: inter(13, 400, color: kMuted))),
            for (final f in widget.fields) ...[
              InvLabel(f.label),
              if (f.kind == FieldKind.pick)
                InvPickBox(
                  value: f.options.firstWhere((o) => o.$1 == c[f.key]!.text, orElse: () => (c[f.key]!.text, c[f.key]!.text.isEmpty ? 'Choose' : c[f.key]!.text)).$2,
                  onTap: () async {
                    final v = await pickOne<String>(context, f.label, [for (final o in f.options) (o.$1, o.$2, null)], current: c[f.key]!.text);
                    if (v != null) setState(() => c[f.key]!.text = v);
                  },
                )
              else
                InvInput(controller: c[f.key]!, number: f.kind == FieldKind.amount, hint: f.hint ?? f.label, label: f.label),
            ],
            if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: inter(13, 500, color: kError))),
            const SizedBox(height: 14),
            InvPrimary(widget.action, busy: busy, onPressed: _go),
          ]),
        ),
      );
}

/// Asks for a short reason (3+ characters) and runs [run] with it; shows the server's sentence on failure. Returns true when it worked.
Future<bool> askReason(BuildContext context, {required String title, required String action, required Future<void> Function(String note, String key) run, String hint = 'Reason'}) =>
    showMoneyForm(context, title: title, action: action, fields: [FormFieldSpec('note', hint)], onSubmit: (v, key) => run(v['note'] as String, key));

/// Small caption above a group ("Cash entries").
class MoneyKick extends StatelessWidget {
  const MoneyKick(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 6, top: 4), child: Kick(text));
}

/// A grey notice when a list is empty.
class MoneyEmpty extends StatelessWidget {
  const MoneyEmpty(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 10), child: InfoBox(lines: [text]));
}

/// "Show more" under a paged list: asks for a larger page (the server caps it at 50).
class MoneyMore extends StatelessWidget {
  const MoneyMore({super.key, required this.shown, required this.total, required this.ctx});
  final int shown, total;
  final MoneyCtx ctx;
  @override
  Widget build(BuildContext context) {
    if (shown >= total) return const SizedBox.shrink();
    final size = ((ctx.q['page_size'] as int?) ?? 20);
    if (size >= 50) return Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Showing the latest 50. Narrow the dates to see older records.', style: inter(12.5, 400, color: kMuted)));
    return InvSecondary('Show more', onPressed: () => ctx.set({'page_size': 50}));
  }
}

/// The two-tile row used at the top of most screens.
/// Two tiles side by side, always the same height (one wrapping its sub-line no longer makes the pair uneven).
Widget tiles2(Widget a, Widget b) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: a), const SizedBox(width: 9), Expanded(child: b)])),
    );

/// "upi" -> "UPI", "cash" -> "Cash".
String methodLabel(String? m) => switch (m) { null || '' => '', 'upi' => 'UPI', _ => m[0].toUpperCase() + m.substring(1) };

/// Green for money in, red for money out.
Color flowColor(num minor) => minor < 0 ? kRedText : kPostedText;
