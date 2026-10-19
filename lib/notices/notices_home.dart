import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'announcement_centre.dart';
import 'compose_screen.dart';
import 'feedback_screen.dart';
import 'notices_api.dart';
import 'notices_widgets.dart';
import 'notification_centre.dart';

/// Section N home: "Notification Centre" and "Announcement Centre" tabs (Figma), plus a "Customers" tab for messages and feedback.
class NoticesHome extends StatefulWidget {
  const NoticesHome({super.key, this.api, this.initialTab = 0, this.onBack});
  final NoticesApi? api;
  final int initialTab;
  final VoidCallback? onBack;

  static Route<void> route({NoticesApi? api, int initialTab = 0}) =>
      MaterialPageRoute(
        settings: const RouteSettings(name: 'notices'),
        builder: (_) => NoticesHome(api: api, initialTab: initialTab),
      );

  @override
  State<NoticesHome> createState() => _NoticesHomeState();
}

class _NoticesHomeState extends State<NoticesHome>
    with SingleTickerProviderStateMixin {
  late final NoticesApi _api = widget.api ?? NoticesApi();
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.initialTab,
  );
  int _noticeUnread = 0, _announceUnread = 0;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Widget _tab(String label, int unread) => Tab(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (unread > 0) ...[const SizedBox(width: 6), const UnreadDot()],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OrdersTopBar(
          title: 'OneLocal',
          onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
        ),
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: kGreenText,
          unselectedLabelColor: kMuted,
          indicatorColor: const Color(0xFF3DB800),
          labelStyle: inter(15, 700),
          unselectedLabelStyle: inter(15, 600, color: kMuted),
          tabs: [
            _tab('Notification Centre', _noticeUnread),
            _tab('Announcement Centre', _announceUnread),
            const Tab(text: 'Customers'),
          ],
        ),
        const Divider(height: 1, color: kLine),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              NotificationCentre(
                api: _api,
                onUnread: (n) => setState(() => _noticeUnread = n),
              ),
              AnnouncementCentre(
                api: _api,
                onUnread: (n) => setState(() => _announceUnread = n),
              ),
              _CustomersTab(api: _api),
            ],
          ),
        ),
      ],
    ),
  );
}

class _CustomersTab extends StatefulWidget {
  const _CustomersTab({required this.api});
  final NoticesApi api;
  @override
  State<_CustomersTab> createState() => _CustomersTabState();
}

class _CustomersTabState extends State<_CustomersTab> {
  List<Facts>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await widget.api.campaigns();
      if (!mounted) return;
      setState(() {
        _items = l;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = noticeError(e));
    }
  }

  Future<void> _cancel(Facts c) async {
    try {
      await widget.api.cancel(c.s('id'));
      await _load();
    } catch (e) {
      if (mounted) showToast(context, noticeError(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
    children: [
      Text('Customer communication', style: inter(26, 700)),
      const SizedBox(height: 6),
      Text(
        'Message your customers and answer their feedback. Messages are recorded and queued; nothing is sent from the app.',
        style: inter(14.5, 400, color: kMuted, height: 1.4),
      ),
      const SizedBox(height: 16),
      DarkCta(
        label: 'Message customers',
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ComposeScreen(api: widget.api)),
          );
          _load();
        },
      ),
      const SizedBox(height: 10),
      LightCta(
        label: 'Customer feedback',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => FeedbackScreen(api: widget.api)),
        ),
      ),
      const SizedBox(height: 22),
      Text('Recent messages', style: inter(17, 700)),
      const SizedBox(height: 10),
      if (_error != null)
        OrderCardBox(
          child: Text(_error!, style: inter(14, 400, color: kMuted)),
        )
      else if (_items == null)
        const Center(child: CircularProgressIndicator(strokeWidth: 2))
      else if (_items!.isEmpty)
        OrderCardBox(
          child: Text(
            'No messages yet.',
            style: inter(14.5, 400, color: kMuted),
          ),
        )
      else
        for (final c in _items!)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OrderCardBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(c.s('name'), style: inter(15.5, 700)),
                      ),
                      DotChip(c.s('status')),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${c.s('channel')} · ${c.s('segment_name')} · ${c.n('audience_count').toInt()} customers',
                    style: inter(13.5, 400, color: kMuted),
                  ),
                  if (c.s('status') == 'queued' || c.s('status') == 'scheduled')
                    Align(
                      alignment: Alignment.centerRight,
                      child: SmallPill('Cancel', onTap: () => _cancel(c)),
                    ),
                ],
              ),
            ),
          ),
    ],
  );
}
