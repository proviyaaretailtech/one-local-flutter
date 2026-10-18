import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../home/home_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_widgets.dart' show svcRupees, svcStatus;
import 'visit_screens.dart';

/// The home screen of a service business: the same shell as the store and restaurant dashboards (navy band with three figures, then cards),
/// drawn from `svc_dashboard`. Every number is the server's; a card with nothing to show says so.
class ServiceHomeBody extends StatefulWidget {
  const ServiceHomeBody({super.key, required this.api, required this.personName, required this.onMenu, this.onInsights});
  final ServiceApi api;
  final String personName;
  final VoidCallback onMenu;
  final VoidCallback? onInsights;
  @override
  State<ServiceHomeBody> createState() => _ServiceHomeBodyState();
}

class _ServiceHomeBodyState extends State<ServiceHomeBody> {
  late Future<ServiceDashboardData> _f = widget.api.dashboard();

  Future<void> _reload() async {
    final next = widget.api.dashboard();
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
    final parts = widget.personName.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return '·';
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ServiceDashboardData>(
        future: _f,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator(color: kLink));
          if (snap.hasError) {
            final msg = snap.error is ServiceApiException ? (snap.error as ServiceApiException).message : 'Could not load the dashboard. Check the connection and try again.';
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(msg, textAlign: TextAlign.center, style: inter(14, 500)),
                  const SizedBox(height: 12),
                  LimeOnDarkButton(label: 'Try again', onPressed: _reload),
                ]),
              ),
            );
          }
          return RefreshIndicator(color: kLink, onRefresh: _reload, child: _content(snap.data!));
        },
      );

  Widget _tile(String label, String value, String chip) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: kNavyTile, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(9, 700, color: const Color(0xFF9CA3AF))),
          const SizedBox(height: 4),
          Text(value, style: inter(18, 800, color: Colors.white)),
          const SizedBox(height: 4),
          Text(chip, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(9, 600, color: kLime)),
        ]),
      );

  Widget _content(ServiceDashboardData d) {
    final t = d.today, a = d.attention, p = d.providers;
    final attention = <(String, int, VoidCallback?)>[
      ('Advances waiting', a.i('advances_waiting'), null),
      ('Visits to bill', a.i('to_bill'), null),
      ('No-shows to decide', a.i('no_show_to_decide'), null),
    ].where((e) => e.$2 > 0).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 132),
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(children: [
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
                  decoration: BoxDecoration(color: kBg, shape: BoxShape.circle, border: Border.all(color: kLine)),
                  child: const Icon(LucideIcons.menu, size: 18, color: kMuted),
                ),
              ),
            ),
            const Spacer(),
            Container(width: 32, height: 32, alignment: Alignment.center, decoration: BoxDecoration(color: kLime, borderRadius: BorderRadius.circular(8)), child: Text(_initials(), style: inter(10, 700, color: kNavy))),
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: Text('OneLocal', style: inter(24, 800, height: 1.1))),
        Container(
          color: kNavy,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Dot(d.closed == null ? kLime : kRed),
              const SizedBox(width: 8),
              Text(d.closed == null ? 'Open today' : 'Closed today', style: inter(12, 700, color: d.closed == null ? kLime : Colors.white)),
              const SizedBox(width: 12),
              Expanded(child: Text('${d.locationName} · ${d.dateLabel}', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10, 400, color: const Color(0xFFD1D5DB)))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _tile('VISITS · TODAY', '${t.i('visits')}', '${t.i('completed')} done · ${t.i('upcoming')} to come')),
              const SizedBox(width: 8),
              Expanded(child: _tile('MONEY · TODAY', svcRupees(d.money.n('today')), '${svcRupees(d.money.n('month'))} this month')),
              const SizedBox(width: 8),
              Expanded(child: _tile('FREE SLOTS', '${d.availableSlots}', '${p.i('available')} providers free')),
            ]),
            const SizedBox(height: 10),
            Material(
              color: const Color(0xFF0E1F12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Color(0xFF2F4F1F))),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => HomeNav.go(context, HomeNav.service, 'Appointments'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('OPERATIONS · TODAY', style: inter(10, 700, color: kLime)),
                        const SizedBox(height: 2),
                        Text('${t.i('in_progress')} in progress · ${t.i('no_show')} no-show · ${t.i('cancelled')} cancelled', style: inter(10.5, 400, color: const Color(0xFFD1D5DB))),
                      ]),
                    ),
                    Text('Calendar', style: inter(10, 500, color: kMuted)),
                  ]),
                ),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (d.closed != null) ...[
              HomeCard(padding: const EdgeInsets.all(12), child: Text('Closed today: ${d.closed}', style: inter(12, 600, color: kAmberInk))),
              const SizedBox(height: 16),
            ],
            if (attention.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: kAmberBg, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFDE68A))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Needs attention', style: inter(13, 700, color: kAmberInk)),
                  const SizedBox(height: 6),
                  for (final e in attention) Text('${e.$1}: ${e.$2}', style: inter(11, 500, color: kAmberInk, height: 1.5)),
                  const SizedBox(height: 8),
                  LimeOnDarkButton(label: 'Open the calendar', onPressed: () => HomeNav.go(context, HomeNav.service, 'Appointments')),
                ]),
              ),
              const SizedBox(height: 20),
            ],
            SectionHeader('Next visits', badge: GreyTag('${t.i('upcoming') + t.i('in_progress')} to come', dot: t.i('in_progress') > 0 ? kGreenDot : kMuted), action: 'Calendar', onAction: () => HomeNav.go(context, HomeNav.service, 'Appointments')),
            const SizedBox(height: 12),
            if (d.nextUp.isEmpty)
              const HomeCard(child: EmptyNote('No visits waiting. Tap Calendar to book one.'))
            else
              for (final v in d.nextUp) ...[_visit(v), const SizedBox(height: 8)],
            const SizedBox(height: 12),
            SectionHeader('Providers', action: 'Staff', onAction: () => HomeNav.go(context, HomeNav.service, 'Staff')),
            const SizedBox(height: 12),
            HomeCard(
              child: Row(children: [
                Expanded(child: _count('Available', p.i('available'), kGreenDot)),
                Expanded(child: _count('On a job', p.i('on_job'), kAmber)),
                Expanded(child: _count('Off duty', p.i('off_duty'), kMuted)),
              ]),
            ),
            const SizedBox(height: 20),
            SectionHeader('This month', badge: GreyTag('${d.month.i('completed')} completed'), action: 'History', onAction: widget.onInsights),
            const SizedBox(height: 12),
            HomeCard(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('MONEY · MONTH', style: inter(10, 700, color: kMuted)),
                const SizedBox(height: 4),
                Text(svcRupees(d.money.n('month')), style: inter(20, 800)),
                const SizedBox(height: 4),
                Text('${d.month.i('completed')} completed · ${d.month.i('no_show')} no-show · ${d.month.i('cancelled')} cancelled', style: inter(10.5, 400, color: kMuted)),
              ]),
            ),
            const SizedBox(height: 8),
            HomeCard(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('TOP SERVICES · MONTH', style: inter(10, 700, color: kMuted)),
                const SizedBox(height: 6),
                if (d.topServices.isEmpty) const EmptyNote('No completed visits this month yet.'),
                for (final s in d.topServices)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(child: Text(s.s('name'), style: inter(11.5, 600))),
                      Text('${s.i('count')} · ${svcRupees(s.n('revenue'))}', style: inter(11, 500, color: kMuted)),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            HomeCard(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: _count('Active packages', d.plans.i('packages_active'), kGreenDot)),
                Expanded(child: _count('Members', d.plans.i('members'), kGreenDot)),
                Expanded(child: _count('Sold this month', d.plans.i('sold_this_month'), kGreenDot)),
              ]),
            ),
            const SizedBox(height: 20),
            Center(
              child: InkWell(
                onTap: () => HomeNav.go(context, HomeNav.support, 'Support'),
                child: Padding(padding: const EdgeInsets.all(4), child: Text('Need help? Contact support', style: inter(11, 600))),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _count(String label, int n, Color dot) => Column(children: [
        Text('$n', style: inter(20, 800)),
        const SizedBox(height: 2),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [Dot(dot), const SizedBox(width: 6), Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10, 500, color: kMuted)))]),
      ]);

  Widget _visit(AppointmentView v) => HomeCard(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AppointmentDetailScreen(api: widget.api, id: v.id)));
          if (mounted) _reload();
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${v.timeLabel} · ${v.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 700))),
            const SizedBox(width: 8),
            svcStatus(v.statusLabel, v.tone),
          ]),
          const SizedBox(height: 4),
          Text('${v.customer} · ${v.provider}', style: inter(11, 400, color: kMuted)),
        ]),
      );
}
