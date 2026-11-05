import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/service/service_reports.dart';
import 'package:vinii_pos/ui/xlsx.dart';

import 'service_screens_test.dart' show FakeRpc, show;

// Service reports (founder, 4 Nov 2026): the restaurant's Reports, counted and worded for a service business.

Map<String, dynamic> _answer(Map<String, dynamic> b) => {
      'kind': b['kind'],
      'from': b['from'],
      'to': b['to'],
      ...switch (b['kind']) {
        'sales' => {
            'totals': {'bills': 7, 'gross_minor': 500000, 'discount_minor': 10000, 'net_minor': 490000, 'gst_minor': 3750, 'total_minor': 493800, 'average_minor': 70000,
              'refunds_minor': 20000, 'refunds': 1, 'collected_minor': 773800},
            'previous': {'bills': 5, 'net_minor': 392000},
            'days': [
              {'day': '2026-11-01', 'bills': 3, 'net_minor': 200000},
              {'day': '2026-11-02', 'bills': 4, 'net_minor': 290000},
            ],
            'bills': [
              {'order_id': 'o1', 'no': 'P-00037', 'customer': 'Suresh Patil', 'when': '2 Nov, 3:41 pm', 'total_minor': 180000, 'methods': 'upi'},
            ],
          },
        'services' => {
            'total_minor': 500000,
            'qty': 9,
            'services': [
              {'name': 'Haircut (women)', 'category': 'Hair', 'qty': 4, 'revenue_minor': 240000, 'bills': 4, 'share_pct': 48.0},
            ],
            'unsold': [
              {'name': 'Manicure', 'category': 'Nails'},
            ],
          },
        'staff' => {
            'staff': [
              {'name': 'Meera Iyer', 'title': 'Consultant', 'bookings': 9, 'completed': 6, 'minutes': 705, 'no_show': 0, 'cancelled': 1, 'revenue_minor': 525000},
            ],
          },
        'bookings' => {'total': 30, 'completed': 16, 'upcoming': 10, 'cancelled': 2, 'no_show': 2, 'no_show_pct': 11.1, 'online': 12, 'offline': 18, 'job_visits': 5, 'days': []},
        'dues' => {
            'total_minor': 60000,
            'bills': 1,
            'list': [
              {'no': 'P-00035', 'customer': 'Amit Shah', 'phone': '9000000302', 'since': '2 Nov', 'days': 2, 'due_minor': 60000},
            ],
          },
        _ => {'total_minor': 0, 'methods': [], 'list': [], 'bookings': [], 'refunds': [], 'categories': [], 'unsold': []},
      },
    };

FakeRpc _fake() => FakeRpc({'svc_report': _answer});

void main() {
  testWidgets('Reports: the groups and their reports, in service words', (t) async {
    await show(t, ServiceReportsScreen(api: _fake().api));
    for (final s in ['Reports', 'SALES', 'BOOKINGS', 'PAYMENTS', 'AUDIT', 'Sales summary', 'Service-wise sales', 'Category-wise sales', 'Bookings & no-shows',
      'Staff performance', 'Payment mode', 'Customers who owe', 'Discounts', 'Cancellations & refunds']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    expect(find.textContaining('dish'), findsNothing, reason: 'no restaurant words');
  });

  testWidgets('Sales summary: this month by default, the figures and the change on the period before; a period chip asks again', (t) async {
    final f = _fake();
    await show(t, ServiceReportsScreen(api: f.api, today: DateTime(2026, 11, 4)));
    await t.tap(find.byKey(const ValueKey('reports-open-sales')));
    await t.pumpAndSettle();
    expect(f.of('svc_report').single.$2, {'kind': 'sales', 'from': '2026-11-01', 'to': '2026-11-04'});
    for (final s in ['Net sales', '₹4,900', '↑ 25% on the period before', 'Bills', '7', 'Average bill', '₹700', 'Collected', '₹7,738', 'Refunds', '₹200',
      'Day by day', 'P-00037 · Suresh Patil', '₹1,800']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await t.tap(find.byKey(const ValueKey('period-week')));
    await t.pumpAndSettle();
    expect(f.of('svc_report').last.$2, {'kind': 'sales', 'from': '2026-10-29', 'to': '2026-11-04'});
    await t.tap(find.byKey(const ValueKey('period-last')));
    await t.pumpAndSettle();
    expect(f.of('svc_report').last.$2, {'kind': 'sales', 'from': '2026-10-01', 'to': '2026-10-31'});
  });

  testWidgets('Service-wise, staff, bookings and dues read like a service business', (t) async {
    final f = _fake();
    for (final (kind, texts) in [
      ('services', ['Every service', 'Haircut (women)', 'Hair · 4 sold · 4 bills', 'Not sold in this period', 'Manicure']),
      ('staff', ['Meera Iyer · Consultant', '9 bookings · 6 completed · 11.8 hrs · 0 no-shows · 1 cancelled', '₹5,250']),
      ('bookings', ['Bookings', '30', '12 online · 18 offline', 'No-shows', '11.1% of visits due', 'Job visits']),
      ('dues', ['Owed to you', '₹600', 'Amit Shah · P-00035', '+91 90000 00302 · since 2 Nov · 2 days']),
    ]) {
      await show(t, ServiceReportScreen(key: ValueKey(kind), kind: kind, api: f.api, today: DateTime(2026, 11, 4)));
      for (final s in texts) {
        expect(find.text(s), findsWidgets, reason: '$kind: $s');
      }
    }
  });

  testWidgets('Excel exports the report\'s table', (t) async {
    Uint8List? file;
    String? name;
    saveReportFile = (bytes, n) async {
      file = bytes;
      name = n;
    };
    await show(t, ServiceReportScreen(kind: 'services', api: _fake().api, today: DateTime(2026, 11, 4)));
    await t.tap(find.byKey(const ValueKey('report-export')));
    await t.pumpAndSettle();
    expect(name, 'service-wise-sales-2026-11-01-to-2026-11-04.xlsx');
    final rows = readXlsx(file!);
    expect(rows.first, ['Service', 'Category', 'Sold', 'Revenue (₹)', 'Bills', 'Share %']);
    expect(rows[1].take(3).toList(), ['Haircut (women)', 'Hair', '4']);
  });
}
