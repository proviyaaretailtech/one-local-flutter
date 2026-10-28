import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';

// Store Money, minimal (founder, 28 Oct 2026, from the restaurant POS money tab): three accounts (cash drawer, UPI, bank) that sales feed on
// their own; one Record transaction for everything else (money in, money out, transfer); the cash register with Close day; and dues.

/// The store money calls (`smoney_*`, C:\onelocal\hosted_store_money_2026-10-28.sql).
class StoreMoneyApi {
  StoreMoneyApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;
  static final _rand = Random.secure();
  static String newKey() => 'sm-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    try {
      return await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null), key);
    } on RpcException catch (e) {
      throw PartnerApiException(e.status, e.message);
    }
  }

  Future<Map<String, dynamic>> home() => _call('smoney_home', {});
  Future<List<Map<String, dynamic>>> entries({String? from, String? to, String direction = 'all', String q = ''}) async =>
      ((await _call('smoney_entries', {'from': from, 'to': to, 'direction': direction, 'q': q.trim().isEmpty ? null : q.trim()}))['entries'] as List? ?? const [])
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
  Future<Map<String, dynamic>> record(Map<String, Object?> body, {required String key}) => _call('smoney_record', body, key: key);
  Future<Map<String, dynamic>> voidEntry(String id, String reason) => _call('smoney_void', {'id': id, 'reason': reason});
  Future<Map<String, dynamic>> register({String? day}) => _call('smoney_register', {'day': day});
  Future<Map<String, dynamic>> closeDay(int countedMinor, {String? day}) => _call('smoney_close_day', {'counted_minor': countedMinor, 'day': day});
  Future<Map<String, dynamic>> dues() => _call('smoney_dues', {});
}

String rs(num? minor) {
  final v = (minor ?? 0).round();
  final neg = v < 0;
  final abs = v.abs();
  final rupees = abs ~/ 100, paise = abs % 100;
  final d = rupees.toString();
  final grouped = d.length <= 3 ? d : '${d.substring(0, d.length - 3).replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+$)'), (m) => '${m[1]},')},${d.substring(d.length - 3)}';
  return '${neg ? '-' : ''}₹$grouped${paise == 0 ? '' : '.${paise.toString().padLeft(2, '0')}'}';
}

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _dm(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  return d == null ? '' : '${d.day.toString().padLeft(2, '0')} ${_mon[d.month - 1]}';
}

const _green = Color(0xFF15803D), _red = Color(0xFFC62828);
const _accountNames = {'cash': 'Cash drawer', 'upi': 'UPI', 'bank': 'Bank'};
const _accountIcons = {'cash': LucideIcons.wallet, 'upi': LucideIcons.smartphone, 'bank': LucideIcons.landmark};

/// What each kind of transaction is called, and which way the money goes.
const kMoneyIn = [('sale', 'Sale collection'), ('due_received', 'Customer paid due'), ('other_income', 'Other income'), ('owner_in', 'Owner added money')];
const kMoneyOut = [('expense', 'Expense'), ('supplier_payment', 'Supplier payment'), ('salary', 'Salary / wages'), ('owner_out', 'Owner took money'), ('refund', 'Refund to customer')];
const kExpenseHeads = ['Rent', 'Electricity', 'Transport', 'Packaging', 'Repairs', 'Tea & snacks', 'Other'];
String kindWord(String k) => switch (k) {
      'sales' => 'Sales',
      'transfer_in' || 'transfer_out' => 'Transfer',
      'cash_difference' => 'Cash difference at close',
      _ => [...kMoneyIn, ...kMoneyOut].where((e) => e.$1 == k).map((e) => e.$2).firstOrNull ?? k,
    };

/// The store's Money tab: today, the accounts with Record transaction, the week in and out, then Transactions | Cash register | Dues.
class StoreMoneyScreen extends StatefulWidget {
  const StoreMoneyScreen({super.key, this.api, this.today});
  final StoreMoneyApi? api;

  /// Tests fix "today".
  final DateTime? today;
  @override
  State<StoreMoneyScreen> createState() => _StoreMoneyScreenState();
}

class _StoreMoneyScreenState extends State<StoreMoneyScreen> {
  late final StoreMoneyApi _api = widget.api ?? StoreMoneyApi();
  Map<String, dynamic>? _home;
  String? _error;
  String _part = 'transactions';
  int _reload = 0; // bumps the section below after a change

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final h = await _api.home();
      if (mounted) {
        setState(() {
          _home = h;
          _error = null;
          _reload++;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load money. Check your connection.'));
    }
  }

  Future<void> _record({String? kind, Map<String, dynamic>? bill, String? party}) async {
    final saved = await showRecordTransaction(context, _api, kind: kind, bill: bill, party: party);
    if (saved && mounted) _load();
  }

  Widget _tile(String label, num? v, IconData icon, {Color? color, String? key}) => Container(
        key: key == null ? null : ValueKey(key),
        width: 158,
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 15, color: color ?? kMuted),
            const SizedBox(width: 6),
            Expanded(child: Text(tr(label).toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 700, color: kMuted))),
          ]),
          const SizedBox(height: 8),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(rs(v), style: inter(19, 800, color: color ?? kInk))),
        ]),
      );

  Widget _balanceCard(Map<String, dynamic> h) {
    final accounts = (h['accounts'] as List? ?? const []).cast<Map>();
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFFEFFAE3), Colors.white], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFCDEFAA)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('TOTAL BALANCE'), style: inter(11, 700, color: kMuted)),
        const SizedBox(height: 4),
        FittedBox(fit: BoxFit.scaleDown, child: Text(rs(h['total_minor'] as num?), key: const ValueKey('money-total'), style: inter(32, 800))),
        const SizedBox(height: 12),
        Row(children: [
          for (final (i, a) in accounts.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Container(
                key: ValueKey('account-${a['key']}'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(_accountIcons[a['key']] ?? LucideIcons.wallet, size: 14, color: kMuted),
                    const SizedBox(width: 5),
                    Expanded(child: Text(tr('${a['name']}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 600, color: kMuted))),
                  ]),
                  const SizedBox(height: 4),
                  FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(rs(a['balance_minor'] as num?), style: inter(15, 800))),
                ]),
              ),
            ),
          ],
        ]),
        if (h['can_record'] == true) ...[
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('record-transaction'),
              onPressed: () => _record(),
              icon: const Icon(LucideIcons.plus, size: 18, color: kInk),
              label: Text(tr('Record transaction'), style: inter(15.5, 700)),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF7ED321), padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            ),
          ),
        ],
      ]),
    );
  }

  /// Money in and out over the last 7 days, side-by-side bars.
  Widget _week(Map<String, dynamic> h) {
    final days = (h['week'] as List? ?? const []).cast<Map>();
    final top = days.fold<num>(1, (m, d) => max(m, max((d['in_minor'] as num? ?? 0), (d['out_minor'] as num? ?? 0))));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Money in vs out'), style: inter(15, 700)),
        Text(tr('Last 7 days, every account.'), style: inter(12, 400, color: kMuted)),
        const SizedBox(height: 12),
        SizedBox(
          height: 120,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final d in days)
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    for (final (k, c) in const [('in_minor', Color(0xFF6BD100)), ('out_minor', Color(0xFFE23B6A))])
                      Container(
                        width: 9,
                        height: max(2, 92 * (d[k] as num? ?? 0) / top).toDouble(),
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
                      ),
                  ]),
                  const SizedBox(height: 6),
                  Text(_dm('${d['day']}').split(' ').first, style: inter(10.5, 600, color: kMuted)),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Row(children: [
          for (final (label, c) in const [('In', Color(0xFF6BD100)), ('Out', Color(0xFFE23B6A))]) ...[
            Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 5),
            Text(tr(label), style: inter(12, 600, color: kMuted)),
            const SizedBox(width: 14),
          ],
        ]),
      ]),
    );
  }

  Widget _parts() => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: const Color(0xFFE9EAEE), borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          for (final (id, label) in const [('transactions', 'Transactions'), ('register', 'Cash register'), ('dues', 'Dues')])
            Expanded(
              child: GestureDetector(
                key: ValueKey('money-part-$id'),
                onTap: () => setState(() => _part = id),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(color: _part == id ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                  child: Text(tr(label), textAlign: TextAlign.center, style: inter(13.5, 700, color: _part == id ? kInk : kMuted)),
                ),
              ),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final h = _home;
    final today = (h?['today'] as Map?) ?? const {};
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr('Money'), onBack: Navigator.of(context).canPop() ? () => Navigator.of(context).maybePop() : null),
        Expanded(
          child: _error != null && h == null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))))
              : h == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(key: const ValueKey('store-money'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            _tile("Today's money in", today['in_minor'] as num?, LucideIcons.arrowDownLeft, color: _green, key: 'tile-in'),
                            _tile("Today's money out", today['out_minor'] as num?, LucideIcons.arrowUpRight, color: _red, key: 'tile-out'),
                            _tile('Net today', today['net_minor'] as num?, LucideIcons.activity, key: 'tile-net'),
                            _tile('Customers owe you', h['customer_dues_minor'] as num?, LucideIcons.users, key: 'tile-customer-dues'),
                            _tile('You owe suppliers', h['supplier_dues_minor'] as num?, LucideIcons.truck, key: 'tile-supplier-dues'),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        _balanceCard(h),
                        const SizedBox(height: 12),
                        _week(h),
                        const SizedBox(height: 16),
                        _parts(),
                        const SizedBox(height: 12),
                        switch (_part) {
                          'register' => _RegisterPart(key: ValueKey('register-$_reload'), api: _api, canRecord: h['can_record'] == true, onChanged: _load),
                          'dues' => _DuesPart(key: ValueKey('dues-$_reload'), api: _api, onPay: (kind, bill, party) => _record(kind: kind, bill: bill, party: party)),
                          _ => _TransactionsPart(key: ValueKey('txns-$_reload'), api: _api, canVoid: h['can_void'] == true, onChanged: _load, today: widget.today),
                        },
                      ]),
                    ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------------------------- transactions
class _TransactionsPart extends StatefulWidget {
  const _TransactionsPart({super.key, required this.api, required this.canVoid, required this.onChanged, this.today});
  final StoreMoneyApi api;
  final bool canVoid;
  final VoidCallback onChanged;
  final DateTime? today;
  @override
  State<_TransactionsPart> createState() => _TransactionsPartState();
}

class _TransactionsPartState extends State<_TransactionsPart> {
  String _dir = 'all';
  String _range = 'month';
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _rows;
  String? _error;

  DateTime get _today {
    final t = widget.today ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  (DateTime, DateTime) get _dates => switch (_range) {
        'today' => (_today, _today),
        'week' => (_today.subtract(Duration(days: _today.weekday - 1)), _today),
        _ => (DateTime(_today.year, _today.month, 1), _today),
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final (from, to) = _dates;
    try {
      final r = await widget.api.entries(from: _iso(from), to: _iso(to), direction: _dir, q: _q.text);
      if (mounted) {
        setState(() {
          _rows = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load transactions.'));
    }
  }

  Future<void> _void(Map<String, dynamic> e) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${tr('Cancel')} ${e['no']}?', style: inter(18, 700)),
        content: TextField(key: const ValueKey('void-reason'), controller: reason, decoration: InputDecoration(labelText: tr('Why?'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Keep'), style: inter(14, 600))),
          TextButton(key: const ValueKey('void-confirm'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Cancel entry'), style: inter(14, 700, color: _red))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.api.voidEntry('${e['id']}', reason.text.trim());
      if (mounted) widget.onChanged();
    } catch (err) {
      if (mounted) showToast(context, err is PartnerApiException ? err.message : tr('Could not cancel it. Try again.'));
    }
  }

  void _csv() {
    final rows = _rows ?? const [];
    final lines = ['Date,No,Kind,Account,In/Out,Amount,Party,Category,Reference,Note,Status'];
    String q(Object? v) => '"${'${v ?? ''}'.replaceAll('"', '""')}"';
    for (final r in rows) {
      lines.add([r['date'], r['no'], kindWord('${r['kind']}'), _accountNames[r['account']] ?? r['account'], r['direction'], ((r['amount_minor'] as num? ?? 0) / 100).toStringAsFixed(2),
        r['party'], r['category'], r['reference'], r['note'], r['status']].map(q).join(','));
    }
    final text = lines.join('\n');
    Clipboard.setData(ClipboardData(text: text));
    showToast(context, '${rows.length} ${tr('transactions copied as CSV. Paste into Excel or Sheets.')}');
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (id, label) in const [('today', 'Today'), ('week', 'This week'), ('month', 'This month')])
          ChoiceChip(
            key: ValueKey('txn-range-$id'),
            label: Text(tr(label), style: inter(12.5, 600)),
            selected: _range == id,
            onSelected: (_) {
              setState(() => _range = id);
              _load();
            },
          ),
        for (final (id, label) in const [('all', 'All'), ('in', 'Money in'), ('out', 'Money out')])
          ChoiceChip(
            key: ValueKey('txn-dir-$id'),
            label: Text(tr(label), style: inter(12.5, 600)),
            selected: _dir == id,
            onSelected: (_) {
              setState(() => _dir = id);
              _load();
            },
          ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('txn-search'),
            controller: _q,
            onChanged: (_) => _load(),
            style: inter(14, 500),
            decoration: InputDecoration(
              isDense: true,
              hintText: tr('Search party, category, reference'),
              prefixIcon: const Icon(LucideIcons.search, size: 18),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(key: const ValueKey('txn-csv'), tooltip: tr('Copy as CSV'), onPressed: rows == null ? null : _csv, icon: const Icon(LucideIcons.download, size: 18)),
      ]),
      const SizedBox(height: 10),
      if (_error != null && rows == null)
        Text(_error!, style: inter(13.5, 500, color: kMuted))
      else if (rows == null)
        const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
      else if (rows.isEmpty)
        Padding(padding: const EdgeInsets.all(20), child: Text(tr('Nothing recorded in these dates.'), textAlign: TextAlign.center, style: inter(13.5, 500, color: kMuted)))
      else
        for (final r in rows) _row(r),
    ]);
  }

  Widget _row(Map<String, dynamic> r) {
    final isIn = r['direction'] == 'in';
    final isVoid = r['status'] == 'void';
    final auto = r['auto'] == true;
    final details = [
      _dm('${r['date']}'),
      _accountNames[r['account']] ?? '${r['account']}',
      if ('${r['category'] ?? ''}'.isNotEmpty) '${r['category']}',
      if ('${r['party'] ?? ''}'.isNotEmpty) '${r['party']}',
      if ('${r['reference'] ?? ''}'.isNotEmpty) '${r['reference']}',
      if (r['no'] != null) '${r['no']}',
    ].join(' · ');
    return Container(
      key: ValueKey('txn-${r['id'] ?? '${r['date']}-${r['account']}'}'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onLongPress: (!auto && !isVoid && widget.canVoid) ? () => _void(r) : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: isIn ? const Color(0xFFE8F7EC) : const Color(0xFFFDECEC), borderRadius: BorderRadius.circular(10)),
                child: Icon(isIn ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight, size: 18, color: isIn ? _green : _red),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr(kindWord('${r['kind']}')), style: inter(14, 700, color: isVoid ? kMuted : kInk).copyWith(decoration: isVoid ? TextDecoration.lineThrough : null)),
                  Text(details, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
                  if (isVoid) Text('${tr('Cancelled')}: ${r['void_reason'] ?? ''}', style: inter(11.5, 600, color: _red)),
                ]),
              ),
              Text('${isIn ? '+' : '−'}${rs(r['amount_minor'] as num?)}', style: inter(15, 800, color: isVoid ? kMuted : (isIn ? _green : _red))),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------------------------- cash register
class _RegisterPart extends StatefulWidget {
  const _RegisterPart({super.key, required this.api, required this.canRecord, required this.onChanged});
  final StoreMoneyApi api;
  final bool canRecord;
  final VoidCallback onChanged;
  @override
  State<_RegisterPart> createState() => _RegisterPartState();
}

class _RegisterPartState extends State<_RegisterPart> {
  Map<String, dynamic>? _r;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.register();
      if (mounted) {
        setState(() {
          _r = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load the cash register.'));
    }
  }

  Future<void> _close() async {
    final c = TextEditingController();
    final counted = await showDialog<num>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Close day'), style: inter(18, 700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tr('Should be in the drawer')}: ${rs(_r?['expected_minor'] as num?)}', style: inter(14, 600)),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('close-counted'),
            controller: c,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(labelText: tr('Cash you counted'), prefixText: '₹ '),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Not now'), style: inter(14, 600))),
          TextButton(key: const ValueKey('close-confirm'), onPressed: () => Navigator.pop(ctx, num.tryParse(c.text.trim())), child: Text(tr('Close day'), style: inter(14, 700))),
        ],
      ),
    );
    if (counted == null || !mounted) return;
    try {
      final r = await widget.api.closeDay((counted * 100).round());
      if (!mounted) return;
      setState(() => _r = r);
      final diff = ((r['closed'] as Map?)?['difference_minor'] as num?) ?? 0;
      showToast(context, diff == 0 ? tr('Day closed. The cash matches.') : '${tr('Day closed.')} ${diff > 0 ? tr('Extra') : tr('Short')} ${rs(diff.abs())}.');
      widget.onChanged();
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not close the day. Try again.'));
    }
  }

  Widget _kv(String k, num? v, {bool bold = false, Color? color, String sign = ''}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(tr(k), style: inter(14, bold ? 700 : 500, color: bold ? kInk : kMuted))),
          Text('$sign${rs(v)}', style: inter(bold ? 18 : 14.5, bold ? 800 : 700, color: color ?? kInk)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (_error != null && r == null) return Text(_error!, style: inter(13.5, 500, color: kMuted));
    if (r == null) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
    final closed = r['closed'] as Map?;
    return Container(
      key: const ValueKey('cash-register'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${tr('Cash drawer')} · ${_dm('${r['day']}')}', style: inter(15.5, 800)),
        const SizedBox(height: 8),
        _kv('Opening cash', r['opening_minor'] as num?),
        _kv('Cash sales', r['sales_minor'] as num?, sign: '+ ', color: _green),
        _kv('Other cash in', r['cash_in_minor'] as num?, sign: '+ ', color: _green),
        _kv('Cash refunds', r['refunds_minor'] as num?, sign: '− ', color: _red),
        _kv('Cash paid out', r['cash_out_minor'] as num?, sign: '− ', color: _red),
        const Divider(height: 20),
        _kv('Should be in the drawer', r['expected_minor'] as num?, bold: true),
        const SizedBox(height: 10),
        if (closed != null)
          Container(
            key: const ValueKey('day-closed'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(12)),
            child: Text(
              '${tr('Closed by')} ${closed['by'] ?? ''} · ${tr('counted')} ${rs(closed['counted_minor'] as num?)}'
              '${(closed['difference_minor'] as num? ?? 0) == 0 ? ' · ${tr('matched')}' : ' · ${(closed['difference_minor'] as num) > 0 ? tr('extra') : tr('short')} ${rs((closed['difference_minor'] as num).abs())}'}',
              style: inter(13.5, 600),
            ),
          )
        else if (widget.canRecord)
          FilledButton(
            key: const ValueKey('close-day'),
            onPressed: _close,
            style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: Text(tr('Close day · count the cash'), style: inter(15, 700, color: Colors.white)),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------------------------- dues
class _DuesPart extends StatefulWidget {
  const _DuesPart({super.key, required this.api, required this.onPay});
  final StoreMoneyApi api;
  final void Function(String kind, Map<String, dynamic>? bill, String? party) onPay;
  @override
  State<_DuesPart> createState() => _DuesPartState();
}

class _DuesPartState extends State<_DuesPart> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.dues();
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load dues.'));
    }
  }

  Widget _card(String title, String sub, num? due, String action, VoidCallback onTap, Key key) => Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: inter(14.5, 700)),
              if (sub.isNotEmpty) Text(sub, style: inter(12, 400, color: kMuted)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(rs(due), style: inter(15, 800)),
            TextButton(onPressed: onTap, style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero), child: Text(tr(action), style: inter(13, 700, color: kLink))),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (_error != null && d == null) return Text(_error!, style: inter(13.5, 500, color: kMuted));
    if (d == null) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
    final customers = (d['customers'] as List? ?? const []).cast<Map>();
    final suppliers = (d['suppliers'] as List? ?? const []).cast<Map>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Customers who owe you'), style: inter(15, 800)),
      const SizedBox(height: 6),
      if (customers.isEmpty)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(tr('Nobody owes you right now.'), style: inter(13, 500, color: kMuted)))
      else
        for (final c in customers)
          _card('${c['party']}', '', c['due_minor'] as num?, 'Got paid', () => widget.onPay('due_received', null, '${c['party']}'), ValueKey('due-customer-${c['party']}')),
      const SizedBox(height: 10),
      Text(tr('Supplier bills to pay'), style: inter(15, 800)),
      const SizedBox(height: 6),
      if (suppliers.isEmpty)
        Text(tr('No unpaid supplier bills.'), style: inter(13, 500, color: kMuted))
      else
        for (final s in suppliers)
          _card(
            '${s['supplier']}',
            [if ('${s['invoice_no'] ?? ''}'.isNotEmpty) '${tr('Invoice')} ${s['invoice_no']}', if (s['invoice_date'] != null) _dm('${s['invoice_date']}'),
              if ((s['paid_minor'] as num? ?? 0) > 0) '${tr('paid')} ${rs(s['paid_minor'] as num?)}'].join(' · '),
            s['due_minor'] as num?,
            'Pay',
            () => widget.onPay('supplier_payment', s.cast<String, dynamic>(), null),
            ValueKey('due-bill-${s['receipt_document_id']}'),
          ),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------------------------- record
/// Record transaction (the restaurant POS's form, slimmed): Money in / Money out / Transfer, the kind, amount, date, account; the
/// category for an expense or income; party, reference and note. Tax, source, status and owner are left out.
Future<bool> showRecordTransaction(BuildContext context, StoreMoneyApi api, {String? kind, Map<String, dynamic>? bill, String? party}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _RecordSheet(api: api, kind: kind, bill: bill, party: party),
    ) ??
    false;

class _RecordSheet extends StatefulWidget {
  const _RecordSheet({required this.api, this.kind, this.bill, this.party});
  final StoreMoneyApi api;
  final String? kind, party;
  final Map<String, dynamic>? bill;
  @override
  State<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<_RecordSheet> {
  late String _dir = kMoneyOut.any((e) => e.$1 == widget.kind) ? 'out' : widget.kind == null ? 'out' : 'in';
  late String _kind = widget.kind ?? 'expense';
  String _account = 'cash', _to = 'bank';
  String? _category;
  DateTime _date = DateTime.now();
  late final _amount = TextEditingController(text: widget.bill == null ? '' : (((widget.bill!['due_minor'] as num?) ?? 0) / 100).toStringAsFixed(2).replaceAll('.00', ''));
  late final _party = TextEditingController(text: widget.party ?? (widget.bill?['supplier'] as String?) ?? '');
  final _ref = TextEditingController(), _note = TextEditingController();
  final _key = StoreMoneyApi.newKey();
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_amount, _party, _ref, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  List<(String, String)> get _kinds => _dir == 'in' ? kMoneyIn : kMoneyOut;
  bool get _needsCategory => _kind == 'expense' || _kind == 'other_income';
  bool get _needsParty => _kind == 'due_received' || _kind == 'supplier_payment';

  Future<void> _save() async {
    final amt = num.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) return showToast(context, tr('Enter the amount.'));
    if (_dir != 'transfer' && _needsParty && _party.text.trim().isEmpty && widget.bill == null) return showToast(context, tr('Say who paid or who was paid.'));
    setState(() => _busy = true);
    try {
      await widget.api.record({
        'kind': _dir == 'transfer' ? 'transfer' : _kind,
        'account': _account,
        if (_dir == 'transfer') 'to_account': _to,
        'amount_minor': (amt * 100).round(),
        'entry_date': _iso(_date),
        if (_dir != 'transfer' && _needsCategory) 'category': _category ?? '',
        if (_dir != 'transfer') 'party': _party.text.trim(),
        'reference': _ref.text.trim(),
        'note': _note.text.trim(),
        if (widget.bill != null) 'bill_receipt_id': widget.bill!['receipt_document_id'],
      }, key: _key);
      if (!mounted) return;
      showToast(context, tr('Saved.'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not save. Check your connection and try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _dec(String label, {String? prefix}) => InputDecoration(
        isDense: true,
        labelText: tr(label),
        prefixText: prefix,
        filled: true,
        fillColor: kBg,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
      );

  Widget _accounts(String value, ValueChanged<String> on, String prefix) => Wrap(spacing: 6, children: [
        for (final e in _accountNames.entries)
          ChoiceChip(
            key: ValueKey('$prefix-${e.key}'),
            avatar: Icon(_accountIcons[e.key], size: 15),
            label: Text(tr(e.value), style: inter(12.5, 600)),
            selected: value == e.key,
            onSelected: (_) => on(e.key),
          ),
      ]);

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(key: const ValueKey('record-sheet'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr(widget.bill != null ? 'Pay supplier bill' : 'Record transaction'), style: inter(19, 800)),
            const SizedBox(height: 12),
            if (widget.bill == null)
              SegmentedButton<String>(
                key: const ValueKey('record-direction'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'in', label: Text(tr('Money in'), style: inter(13, 700))),
                  ButtonSegment(value: 'out', label: Text(tr('Money out'), style: inter(13, 700))),
                  ButtonSegment(value: 'transfer', label: Text(tr('Transfer'), style: inter(13, 700))),
                ],
                selected: {_dir},
                onSelectionChanged: (s) => setState(() {
                  _dir = s.first;
                  if (_dir != 'transfer') _kind = _kinds.first.$1;
                }),
              ),
            if (_dir != 'transfer' && widget.bill == null) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final (id, label) in _kinds)
                  ChoiceChip(key: ValueKey('record-kind-$id'), label: Text(tr(label), style: inter(12.5, 600)), selected: _kind == id, onSelected: (_) => setState(() => _kind = id)),
              ]),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('record-amount'),
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  style: inter(18, 700),
                  decoration: _dec('Amount', prefix: '₹ '),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  key: const ValueKey('record-date'),
                  onTap: () async {
                    final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime.now().subtract(const Duration(days: 365)), lastDate: DateTime.now());
                    if (d != null) setState(() => _date = d);
                  },
                  child: InputDecorator(decoration: _dec('Date'), child: Text(_dm(_iso(_date)), style: inter(15, 600))),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Text(tr(_dir == 'transfer' ? 'From' : _dir == 'in' ? 'Into' : 'Paid from'), style: inter(12.5, 700, color: kMuted)),
            const SizedBox(height: 4),
            _accounts(_account, (v) => setState(() => _account = v), 'record-account'),
            if (_dir == 'transfer') ...[
              const SizedBox(height: 8),
              Text(tr('To'), style: inter(12.5, 700, color: kMuted)),
              const SizedBox(height: 4),
              _accounts(_to, (v) => setState(() => _to = v), 'record-to'),
            ],
            if (_dir != 'transfer' && _needsCategory) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const ValueKey('record-category'),
                initialValue: _category,
                isExpanded: true,
                decoration: _dec(_kind == 'expense' ? 'Expense head' : 'Income head (optional)'),
                items: [for (final h in kExpenseHeads) DropdownMenuItem(value: h, child: Text(tr(h), style: inter(14, 600)))],
                onChanged: (v) => setState(() => _category = v),
              ),
            ],
            if (_dir != 'transfer') ...[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('record-party'),
                controller: _party,
                style: inter(14.5, 600),
                decoration: _dec(_kind == 'due_received' ? 'Customer' : _kind == 'supplier_payment' ? 'Supplier' : 'Party (optional)'),
              ),
            ],
            const SizedBox(height: 10),
            TextField(key: const ValueKey('record-ref'), controller: _ref, style: inter(14.5, 600), decoration: _dec('Reference no. (optional)').copyWith(hintText: tr('UTR / invoice / UPI ref'))),
            const SizedBox(height: 10),
            TextField(controller: _note, maxLines: 2, style: inter(14, 500), decoration: _dec('Note (optional)')),
            const SizedBox(height: 14),
            FilledButton(
              key: const ValueKey('record-save'),
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: Text(_busy ? '…' : tr('Save entry'), style: inter(15.5, 700, color: Colors.white)),
            ),
          ]),
        ),
      );
}
