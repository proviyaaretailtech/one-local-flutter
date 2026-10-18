import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../home/home_widgets.dart';
import '../service/service_widgets.dart' show svcRupees;
import '../ui/theme.dart';
import 'restaurant_api.dart';

const _notReported = 'Not reported';

/// The home screen of a restaurant: the same shell as the store and service dashboards (navy band with three figures, then cards),
/// drawn from `rst_dashboard`. A figure the database cannot supply is drawn as "Not reported", never as zero.
class RestaurantHomeBody extends StatefulWidget {
  const RestaurantHomeBody({
    super.key,
    required this.api,
    required this.personName,
    required this.onMenu,
    this.onInsights,
  });
  final RestaurantApi api;
  final String personName;
  final VoidCallback onMenu;
  final VoidCallback? onInsights;
  @override
  State<RestaurantHomeBody> createState() => _RestaurantHomeBodyState();
}

class _RestaurantHomeBodyState extends State<RestaurantHomeBody> {
  String? _location;
  late Future<RestaurantDashboardData> _f = widget.api.dashboard();

  Future<void> _reload() async {
    final next = widget.api.dashboard(locationId: _location);
    setState(() {
      _f = next;
    });
    try {
      await next;
    } catch (_) {
      // drawn by the builder
    }
  }

  String _initials() {
    final parts = widget.personName
        .trim()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '·';
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : ''))
        .toUpperCase();
  }

  Future<void> _pickOutlet(RestaurantDashboardData d) async {
    if (d.outlets.length < 2) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kPadX, 24, kPadX, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Show data for', style: inter(15, 600)),
              const SizedBox(height: 8),
              for (final o in d.outlets)
                ListTile(
                  key: ValueKey('outlet-${o['id']}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('${o['name']}', style: inter(14, 500)),
                  trailing: o['id'] == d.locationId
                      ? const Icon(LucideIcons.check, size: 18, color: kLink)
                      : null,
                  onTap: () => Navigator.pop(ctx, '${o['id']}'),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _location = picked;
    _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<RestaurantDashboardData>(
    future: _f,
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done)
        return const Center(child: CircularProgressIndicator(color: kLink));
      if (snap.hasError) {
        final msg = snap.error is RestaurantApiException
            ? (snap.error as RestaurantApiException).message
            : 'Could not load the dashboard. Check the connection and try again.';
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(msg, textAlign: TextAlign.center, style: inter(14, 500)),
                const SizedBox(height: 12),
                LimeOnDarkButton(label: 'Try again', onPressed: _reload),
              ],
            ),
          ),
        );
      }
      return RefreshIndicator(
        color: kLink,
        onRefresh: _reload,
        child: _content(snap.data!),
      );
    },
  );

  Widget _tile(String label, String value, String chip, {bool good = true}) =>
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: kNavyTile,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: inter(9, 700, color: const Color(0xFF9CA3AF)),
            ),
            const SizedBox(height: 4),
            Text(value, style: inter(18, 800, color: Colors.white)),
            const SizedBox(height: 4),
            Text(
              chip,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: inter(9, 600, color: good ? kLime : kAmber),
            ),
          ],
        ),
      );

  Widget _count(String label, String value, Color dot) => Column(
    children: [
      Text(value, style: inter(20, 800)),
      const SizedBox(height: 2),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Dot(dot),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: inter(10, 500, color: kMuted),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _link(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    String? note,
  }) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kLine),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: kNavy),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: inter(11, 600),
          ),
          if (note != null) Text(note, style: inter(9, 500, color: kMuted)),
        ],
      ),
    ),
  );

  Widget _chart(List<Map<String, dynamic>> days) {
    final top = days.fold<num>(
      0,
      (m, e) =>
          e['sales'] is num && (e['sales'] as num) > m ? e['sales'] as num : m,
    );
    return SizedBox(
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final e in days)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      key: ValueKey('bar-${e['date']}'),
                      height: top > 0
                          ? 4 + 60 * ((e['sales'] as num) / top)
                          : 4,
                      decoration: BoxDecoration(
                        color: (e['sales'] as num) > 0 ? kNavy : kLine,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('${e['label']}', style: inter(9, 500, color: kMuted)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _content(RestaurantDashboardData d) {
    final kot = d.kot, tb = d.tables, low = d.ingredientsLow, ol = d.onelocal;
    final pending = kot == null ? null : kot.i('new') + kot.i('in_progress');
    return ListView(
      padding: const EdgeInsets.only(bottom: 132),
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Semantics(
                button: true,
                label: 'Menu',
                child: InkWell(
                  key: const ValueKey('home-menu'),
                  customBorder: const CircleBorder(),
                  onTap: widget.onMenu,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: kBg,
                      shape: BoxShape.circle,
                      border: Border.all(color: kLine),
                    ),
                    child: const Icon(
                      LucideIcons.menu,
                      size: 18,
                      color: kMuted,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kLime,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_initials(), style: inter(10, 700, color: kNavy)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text('OneLocal', style: inter(24, 800, height: 1.1)),
        ),
        Container(
          color: kNavy,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                key: const ValueKey('outlet-filter'),
                onTap: () => _pickOutlet(d),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        d.locationName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: inter(12, 700, color: Colors.white),
                      ),
                    ),
                    if (d.outlets.length > 1) ...[
                      const Icon(
                        LucideIcons.chevronDown,
                        size: 14,
                        color: Color(0xFFD1D5DB),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      d.dateLabel,
                      style: inter(10, 400, color: const Color(0xFFD1D5DB)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _tile(
                      'ORDERS LIVE',
                      '${d.orders.i('live')}',
                      '${d.orders.i('today')} today',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _tile(
                      'KOT PENDING',
                      pending == null ? '—' : '$pending',
                      pending == null
                          ? _notReported
                          : '${kot!.i('delayed')} delayed',
                      good: pending != null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _tile(
                      'SALES TODAY',
                      svcRupees(d.sales.n('today')),
                      '${d.sales.i('paid_bills')} bills paid',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(
                'Kitchen status',
                badge: GreyTag(
                  kot == null
                      ? _notReported
                      : '${kot.i('in_progress')} cooking',
                  dot: kot != null && kot.i('in_progress') > 0
                      ? kGreenDot
                      : kMuted,
                ),
              ),
              const SizedBox(height: 12),
              HomeCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (kot == null)
                      const EmptyNote(
                        'Not reported: your role cannot see the kitchen display.',
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: _count('New', '${kot.i('new')}', kRed),
                          ),
                          Expanded(
                            child: _count(
                              'Cooking',
                              '${kot.i('in_progress')}',
                              kAmber,
                            ),
                          ),
                          Expanded(
                            child: _count(
                              'Ready',
                              '${kot.i('ready')}',
                              kGreenDot,
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 10),
                    LimeOnDarkButton(
                      label: 'Open kitchen display',
                      onPressed: () => HomeNav.go(
                        context,
                        HomeNav.kitchen,
                        'The kitchen display',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SectionHeader(
                'Tables',
                badge: GreyTag(
                  tb == null ? _notReported : '${tb.i('all')} tables',
                ),
                action: 'Floor',
                onAction: () => HomeNav.go(context, HomeNav.tables, 'Tables'),
              ),
              const SizedBox(height: 12),
              HomeCard(
                child: tb == null
                    ? const EmptyNote(
                        'Not reported: your role cannot see the floor.',
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: _count(
                              'Available',
                              '${tb.i('available')}',
                              kGreenDot,
                            ),
                          ),
                          Expanded(
                            child: _count(
                              'Occupied',
                              '${tb.i('occupied')}',
                              kRed,
                            ),
                          ),
                          Expanded(
                            child: _count(
                              'Reserved',
                              '${tb.i('reserved')}',
                              kAmber,
                            ),
                          ),
                          Expanded(
                            child: _count(
                              'Cleaning',
                              '${tb.i('cleaning')}',
                              kMuted,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 20),
              SectionHeader(
                'Today',
                badge: GreyTag(d.dateLabel.split(',').first.toUpperCase()),
              ),
              const SizedBox(height: 12),
              HomeCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SALES TODAY', style: inter(10, 700, color: kMuted)),
                    const SizedBox(height: 4),
                    Text(svcRupees(d.sales.n('today')), style: inter(20, 800)),
                    const SizedBox(height: 4),
                    Text(
                      '${d.sales.i('paid_bills')} bills paid${d.sales.n('refunds') > 0 ? ' · ${svcRupees(d.sales.n('refunds'))} refunded' : ''}',
                      style: inter(10.5, 400, color: kMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              HomeCard(
                onTap: () =>
                    HomeNav.go(context, HomeNav.lowStock, 'Restocking'),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Ingredients low', style: inter(12.5, 700)),
                    ),
                    if (low == null)
                      Text(
                        _notReported,
                        style: inter(11, 600, color: kAmberInk),
                      )
                    else
                      Text(
                        '${low.i('critical')} critical · ${low.i('low')} low',
                        style: inter(
                          11,
                          600,
                          color: low.i('critical') > 0 ? kRedInk : kMuted,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              HomeCard(
                onTap: () =>
                    HomeNav.go(context, HomeNav.orders, 'Online orders'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ONELOCAL ORDERS',
                      style: inter(10, 700, color: kMuted),
                    ),
                    const SizedBox(height: 4),
                    if (ol == null)
                      Text(
                        _notReported,
                        style: inter(12, 600, color: kAmberInk),
                      )
                    else ...[
                      Text(
                        '${ol.i('open')} open · ${ol.i('today')} today',
                        style: inter(14, 700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${svcRupees(ol.n('sales_today'))} today · all outlets of the business',
                        style: inter(10.5, 400, color: kMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SectionHeader(
                'Last 7 days',
                action: 'Sales analytics',
                onAction: widget.onInsights,
              ),
              const SizedBox(height: 12),
              HomeCard(
                child: d.last7.isEmpty
                    ? const EmptyNote('No sales in the last 7 days.')
                    : _chart(d.last7),
              ),
              const SizedBox(height: 20),
              SectionHeader(
                'Quick links',
                action: 'Show all',
                onAction: widget.onMenu,
              ),
              const SizedBox(height: 12),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.25,
                children: [
                  _link(
                    LucideIcons.history,
                    'Order history',
                    () => HomeNav.go(
                      context,
                      HomeNav.orderHistory,
                      'Order history',
                    ),
                  ),
                  _link(
                    LucideIcons.messageSquareWarning,
                    'Complaints',
                    () => HomeNav.go(context, HomeNav.complaints, 'Complaints'),
                    note: d.notReported.contains('complaints')
                        ? _notReported
                        : null,
                  ),
                  _link(
                    LucideIcons.star,
                    'Reviews',
                    () => HomeNav.go(context, HomeNav.reviews, 'Reviews'),
                    note: d.notReported.contains('reviews')
                        ? _notReported
                        : null,
                  ),
                  _link(
                    LucideIcons.settings,
                    'Settings',
                    () => HomeNav.go(context, HomeNav.setup, 'Settings'),
                  ),
                  _link(
                    LucideIcons.store,
                    'Outlet info',
                    () => HomeNav.go(context, HomeNav.setup, 'Outlet info'),
                  ),
                  _link(LucideIcons.layoutGrid, 'Show all', widget.onMenu),
                ],
              ),
              const SizedBox(height: 20),
              Center(
                child: InkWell(
                  onTap: () => HomeNav.go(context, HomeNav.support, 'Support'),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      'Need help? Contact support',
                      style: inter(11, 600),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
