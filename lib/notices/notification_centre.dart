import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'notices_api.dart';
import 'notices_widgets.dart';
import '../ui/i18n.dart';

/// Figma "Notification Centre": filter chips, "Mark all as read", rows grouped Today / Earlier. Read state lives in the database, per person.
class NotificationCentre extends StatefulWidget {
  const NotificationCentre({
    super.key,
    required this.api,
    this.onUnread,
    this.now,
  });
  final NoticesApi api;
  final ValueChanged<int>? onUnread;
  final DateTime Function()? now;
  @override
  State<NotificationCentre> createState() => _NotificationCentreState();
}

class _NotificationCentreState extends State<NotificationCentre> {
  static const _chips = [
    (null, 'All'),
    ('orders', 'Orders'),
    ('payments', 'Payments'),
    ('inventory', 'Inventory'),
    ('account', 'Account'),
  ];
  String? _cat;
  Facts? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.notices(category: _cat);
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
      widget.onUnread?.call(d.n('unread').toInt());
    } catch (e) {
      if (mounted) setState(() => _error = noticeError(e));
    }
  }

  Future<void> _markAll() async {
    try {
      await widget.api.markNoticesRead(all: true, category: _cat);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, noticeError(e));
    }
  }

  Future<void> _open(Facts n) async {
    if (n.b('is_read')) return;
    try {
      await widget.api.markNoticesRead(ids: [n.s('id')]);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, noticeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = (widget.now ?? DateTime.now)();
    return NoticeLoad<Facts>(
      data: _data,
      error: _error,
      onRetry: () {
        setState(() => _error = null);
        _load();
      },
      builder: (d) {
        final items = d.l('items');
        final today = items
            .where((n) => _isToday(n.t('created_at'), now))
            .toList();
        final earlier = items
            .where((n) => !_isToday(n.t('created_at'), now))
            .toList();
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text(tr('Notification Centre'), style: inter(26, 700)),
              const SizedBox(height: 6),
              Text(
                'Orders, payments and updates for your store.',
                style: inter(14.5, 400, color: kMuted),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in _chips)
                    Semantics(
                      selected: _cat == c.$1,
                      child: SmallPill(
                        c.$2,
                        bg: _cat == c.$1 ? kChipGreen : Colors.white,
                        fg: _cat == c.$1 ? kGreenText : kMuted,
                        border: _cat == c.$1 ? const Color(0xFF3DB800) : kLine,
                        onTap: () {
                          setState(() {
                            _cat = c.$1;
                            _data = null;
                          });
                          _load();
                        },
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              if (items.isEmpty)
                OrderCardBox(
                  child: Text(
                    'Nothing here yet. New orders, payments and stock alerts will show up as they happen.',
                    style: inter(14.5, 400, color: kMuted, height: 1.4),
                  ),
                )
              else ...[
                if (today.isNotEmpty)
                  _group('Today', today, now, showMarkAll: d.n('unread') > 0),
                if (earlier.isNotEmpty)
                  _group(
                    'Earlier',
                    earlier,
                    now,
                    showMarkAll: today.isEmpty && d.n('unread') > 0,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  bool _isToday(DateTime? t, DateTime now) =>
      t != null &&
      t.year == now.year &&
      t.month == now.month &&
      t.day == now.day;

  Widget _group(
    String title,
    List<Facts> rows,
    DateTime now, {
    required bool showMarkAll,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Row(
          children: [
            Expanded(child: Text(title, style: inter(17, 700))),
            if (showMarkAll)
              InkWell(
                onTap: _markAll,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(tr('Mark all as read'), style: inter(14, 700)),
                ),
              ),
          ],
        ),
      ),
      for (final n in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _row(n, now),
        ),
    ],
  );

  Widget _row(Facts n, DateTime now) {
    final st = kindStyle(n.s('kind'));
    final unread = !n.b('is_read');
    final when = n.t('created_at');
    return Semantics(
      button: true,
      label: '${n.s('title')}. ${n.s('body')}${unread ? '. Unread' : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _open(n),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: unread ? Colors.white : const Color(0xFFFAFAF7),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFECEDE8)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: st.bg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(st.icon, size: 21, color: st.fg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(n.s('title'), style: inter(15.5, 700)),
                        ),
                        if (unread)
                          const Padding(
                            padding: EdgeInsets.only(left: 6, right: 4),
                            child: UnreadDot(),
                          ),
                        if (when != null)
                          Text(
                            noticeTime(when, now),
                            style: inter(
                              12.5,
                              400,
                              color: unread ? const Color(0xFF3DB800) : kMuted,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      n.s('body'),
                      style: inter(14, 400, color: kMuted, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
