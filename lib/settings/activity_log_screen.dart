import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../orders/order_widgets.dart' show OrdersTopBar;
import '../ui/theme.dart';
import 'settings_api.dart';

/// Settings → Activity log (founder, 28 Oct 2026): the operational timeline that used to sit on each table's order page, for every order of
/// the business, newest first and grouped by day (`rst_activity_log`, 0614). Each line says when, what happened, and on which bill and table.
class ActivityLogScreen extends StatefulWidget {
  const ActivityLogScreen({super.key, required this.env});
  final SettingsEnv env;

  @override
  State<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends State<ActivityLogScreen> {
  final _entries = <Map<String, dynamic>>[];
  bool _loading = true, _more = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// First page, or the next older page when [older].
  Future<void> _load({bool older = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.env.api.activityLog(before: older && _entries.isNotEmpty ? _entries.last['at'] as String? : null);
      final got = ((r['entries'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>());
      if (!mounted) return;
      setState(() {
        if (!older) _entries.clear();
        _entries.addAll(got);
        _more = r['more'] == true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    String? day;
    for (final e in _entries) {
      final at = DateTime.tryParse('${e['at']}')?.toLocal();
      final d = at == null ? '' : _day(at);
      if (d != day) {
        day = d;
        rows.add(Padding(padding: const EdgeInsets.fromLTRB(4, 14, 4, 8), child: Text(d.toUpperCase(), style: inter(13, 700, color: kMuted))));
      }
      rows.add(_Entry(e, at));
    }
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: 'Activity log', onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
              ...rows,
              if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2.4))),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(children: [
                    Text(_error!, textAlign: TextAlign.center, style: inter(14.5, 500, color: kError)),
                    TextButton(onPressed: () => _load(older: _entries.isNotEmpty), child: const Text('Try again')),
                  ]),
                ),
              if (!_loading && _error == null && _entries.isEmpty)
                Padding(padding: const EdgeInsets.all(32), child: Center(child: Text('No activity yet. Orders, KOTs and payments show here.', textAlign: TextAlign.center, style: inter(15, 400, color: kMuted)))),
              if (!_loading && _error == null && _more)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: OutlinedButton(key: const ValueKey('activity-more'), onPressed: () => _load(older: true), child: Text('Show older', style: inter(14.5, 700, color: kInk))),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

String _day(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day), that = DateTime(d.year, d.month, d.day);
  if (that == today) return 'Today';
  if (that == today.subtract(const Duration(days: 1))) return 'Yesterday';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${m[d.month - 1]} ${d.year}';
}

String _time(DateTime d) => '${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';

/// One line of the log: an icon for the kind of event, what happened, the time, and the bill / table it belongs to.
class _Entry extends StatelessWidget {
  const _Entry(this.e, this.at);
  final Map<String, dynamic> e;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final kind = '${e['kind'] ?? ''}';
    final (icon, color) = switch (kind) {
      'placed' || 'items_added' || 'accepted' => (LucideIcons.receipt, const Color(0xFF2563EB)),
      'paid' || 'bill_part_paid' => (LucideIcons.indianRupee, const Color(0xFF15803D)),
      _ when kind.startsWith('kot') => (LucideIcons.chefHat, const Color(0xFFC2410C)),
      _ when kind.contains('cancel') => (LucideIcons.circleX, kError),
      _ => (LucideIcons.activity, kMuted),
    };
    final table = e['table_label'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFECEDE8))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 34, height: 34, decoration: BoxDecoration(color: color.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)), child: Icon(icon, size: 17, color: color)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${e['message'] ?? ''}', style: inter(15, 600)),
            const SizedBox(height: 3),
            Text(
              [if ((e['display_no'] ?? '') != '') 'Bill ${e['display_no']}', if (table != null && table.isNotEmpty) 'Table $table'].join(' · '),
              style: inter(13, 500, color: kMuted),
            ),
          ]),
        ),
        if (at != null) Text(_time(at!), style: inter(13, 600, color: kMuted)),
      ]),
    );
  }
}
