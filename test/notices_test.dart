import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/notices/announcement_centre.dart';
import 'package:vinii_pos/notices/compose_screen.dart';
import 'package:vinii_pos/notices/feedback_screen.dart';
import 'package:vinii_pos/notices/notices_api.dart';
import 'package:vinii_pos/notices/notices_home.dart';
import 'package:vinii_pos/notices/notification_centre.dart';
import 'package:vinii_pos/orders/order_widgets.dart' show SmallPill;

// Answers shaped like the real database functions of migration 0460 (database/tests/460_customer_communication.sql).
final now = DateTime(2026, 10, 17, 11, 0);
String iso(DateTime t) => t.toUtc().toIso8601String();

Map<String, dynamic> notice(
  String id,
  String cat,
  String kind,
  String title,
  String body,
  DateTime at, {
  bool read = false,
}) => {
  'id': id,
  'category': cat,
  'kind': kind,
  'title': title,
  'body': body,
  'created_at': iso(at),
  'is_read': read,
};

Map<String, dynamic> noticeList({bool firstRead = false}) => {
  'unread': firstRead ? 3 : 4,
  'counts': {
    'all': 5,
    'orders': 3,
    'payments': 1,
    'inventory': 1,
    'account': 0,
  },
  'items': [
    notice(
      'n1',
      'orders',
      'order_confirmed',
      'Order confirmed',
      '#1048 · 3 items, ₹480',
      DateTime(2026, 10, 17, 10, 42),
      read: firstRead,
    ),
    notice(
      'n2',
      'payments',
      'payment_received',
      'Payment received',
      '₹480 received for order #1048',
      DateTime(2026, 10, 17, 10, 41),
    ),
    notice(
      'n3',
      'inventory',
      'low_stock',
      'Low-stock alert',
      'Amul Butter 500g · Only 2 left',
      DateTime(2026, 10, 17, 10, 15),
    ),
    notice(
      'n4',
      'orders',
      'order_delivered',
      'Order delivered',
      '#1046 delivered to your customer',
      DateTime(2026, 10, 16, 18, 30),
      read: true,
    ),
    notice(
      'n5',
      'orders',
      'order_cancelled',
      'Order cancelled',
      '#1045 was cancelled',
      DateTime(2026, 10, 8, 9, 30),
      read: true,
    ),
  ],
};

final announcements = {
  'unread': 2,
  'important': [
    {
      'id': 'a1',
      'category': 'maintenance',
      'title': 'Planned maintenance tonight',
      'body': 'Online payments will pause from 11:00–11:15 PM.',
      'important': true,
      'published_at': iso(DateTime(2026, 10, 9)),
      'is_read': false,
    },
  ],
  'latest': [
    {
      'id': 'a2',
      'category': 'new_feature',
      'title': 'A simpler receipt preview',
      'body': 'Review item quantities and tax.',
      'important': false,
      'published_at': iso(DateTime(2026, 10, 9)),
      'is_read': false,
    },
    {
      'id': 'a3',
      'category': 'policy_update',
      'title': 'Keep your store details current',
      'body': 'Check bank and GST details.',
      'important': false,
      'published_at': iso(DateTime(2026, 10, 8)),
      'is_read': true,
    },
  ],
};

final options = {
  'segments': [
    {'id': 'seg1', 'name': 'VIPs', 'description': '', 'in_segment': 3},
    {'id': 'all', 'name': 'All customers', 'description': '', 'in_segment': 4},
  ],
  'channels': ['whatsapp', 'sms', 'email', 'push'],
  'can_send': true,
  'can_respond': true,
  'sends_for_real': false,
  'note': 'Messages are recorded and queued. Nothing is sent from the app.',
};

http.Response ok(Object b) => http.Response(
  jsonEncode(b),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
http.Response err(int s, String d, [String? code]) => http.Response(
  jsonEncode({'detail': d, 'code': ?code}),
  s,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class Fake {
  Fake([this.custom]);
  final http.Response? Function(
    String fn,
    Map<String, dynamic> a,
    http.Request r,
  )?
  custom;
  final requests = <http.Request>[];
  bool read1 = false;
  late final api = NoticesApi(
    baseUrl: 'http://n.test',
    accessToken: () => 'tok',
    client: MockClient((r) async {
      requests.add(r);
      final fn = r.url.path.split('/').last;
      final a = jsonDecode(r.body) as Map<String, dynamic>;
      final c = custom?.call(fn, a, r);
      if (c != null) return c;
      switch (fn) {
        case 'notice_list':
          return ok(noticeList(firstRead: read1));
        case 'notice_mark_read':
          read1 = true;
          return ok({'marked': 1});
        case 'announce_list':
          return ok(announcements);
        case 'announce_mark_read':
          return ok({'marked': 1});
        case 'comm_options':
          return ok(options);
        case 'comm_audience':
          return ok({'in_segment': 3, 'reachable': 2, 'without_consent': 1});
        case 'comm_queue':
          return ok({
            'id': 'c1',
            'status': 'queued',
            'channel': a['channel'],
            'audience_count': 2,
            'status_note': 'Recorded and queued. Nothing has been sent yet.',
          });
        case 'comm_list':
          return ok({
            'items': [
              {
                'id': 'c1',
                'name': 'Festive offer',
                'channel': 'sms',
                'segment_name': 'VIPs',
                'status': 'queued',
                'audience_count': 2,
              },
            ],
          });
        case 'comm_cancel':
          return ok({'id': 'c1', 'status': 'cancelled'});
        case 'comm_feedback_list':
          return ok({
            'summary': {
              'total': 2,
              'average': 3.5,
              'new': 1,
              'acknowledged': 0,
              'resolved': 1,
            },
            'can_respond': true,
            'items': [
              {
                'id': 'f1',
                'customer_name': 'Asha',
                'rating': 5,
                'comment': 'Lovely',
                'status': 'new',
                'response': '',
              },
              {
                'id': 'f2',
                'customer_name': 'Bhim',
                'rating': 2,
                'comment': 'Slow',
                'status': 'resolved',
                'response': 'Sorry',
              },
            ],
          });
        case 'comm_feedback_respond':
          return ok({'id': a['id'], 'status': a['status']});
      }
      return err(404, 'not found: $fn');
    }),
  );
}

void tall(WidgetTester t) {
  t.view.physicalSize = const Size(800, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Widget host(Widget child) => MaterialApp(
  home: child,
  theme: ThemeData(fontFamily: 'Inter'),
);

void main() {
  setUp(HomeNav.reset);

  testWidgets(
    'notification centre: grouped rows, chips, unread count, same text as the Figma',
    (t) async {
      final f = Fake();
      int unread = -1;
      await t.pumpWidget(
        host(
          Scaffold(
            body: NotificationCentre(
              api: f.api,
              now: () => now,
              onUnread: (n) => unread = n,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Notification Centre'), findsOneWidget);
      for (final s in [
        'Today',
        'Earlier',
        'Mark all as read',
        'Order confirmed',
        '#1048 · 3 items, ₹480',
        'Low-stock alert',
        'Order cancelled',
        'Orders',
        'Payments',
        'Inventory',
        'Account',
      ]) {
        expect(find.text(s), findsWidgets, reason: s);
      }
      expect(find.text('10:42 AM'), findsOneWidget);
      expect(find.text('Yesterday · 6:30 PM'), findsOneWidget);
      expect(find.text('8 Oct · 9:30 AM'), findsOneWidget);
      expect(unread, 4);
    },
  );

  testWidgets(
    'notification centre: tapping an unread row marks it read on the server and reloads',
    (t) async {
      final f = Fake();
      int unread = -1;
      await t.pumpWidget(
        host(
          Scaffold(
            body: NotificationCentre(
              api: f.api,
              now: () => now,
              onUnread: (n) => unread = n,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Order confirmed'));
      await t.pumpAndSettle();
      final mark = f.requests.firstWhere(
        (r) => r.url.path.endsWith('notice_mark_read'),
      );
      expect(jsonDecode(mark.body), {
        'ids': ['n1'],
      });
      expect(unread, 3);
    },
  );

  testWidgets(
    'notification centre: filter chip asks the server for that category; mark all read sends all',
    (t) async {
      final f = Fake();
      await t.pumpWidget(
        host(
          Scaffold(
            body: NotificationCentre(api: f.api, now: () => now),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(SmallPill, 'Payments'));
      await t.pumpAndSettle();
      expect(jsonDecode(f.requests.last.body)['category'], 'payments');
      await t.tap(find.text('Mark all as read'));
      await t.pumpAndSettle();
      final m = f.requests.lastWhere(
        (r) => r.url.path.endsWith('notice_mark_read'),
      );
      expect(jsonDecode(m.body), {'all': true, 'category': 'payments'});
    },
  );

  testWidgets(
    'notification centre: a server refusal shows its sentence with a retry',
    (t) async {
      final f = Fake(
        (fn, a, r) => fn == 'notice_list'
            ? err(403, 'Sign in to a business first.', 'forbidden')
            : null,
      );
      await t.pumpWidget(
        host(
          Scaffold(
            body: NotificationCentre(api: f.api, now: () => now),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Sign in to a business first.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    },
  );

  testWidgets(
    'announcement centre: important card, latest cards, unread pill, mark read on tap',
    (t) async {
      final f = Fake();
      await t.pumpWidget(host(Scaffold(body: AnnouncementCentre(api: f.api))));
      await t.pumpAndSettle();
      for (final s in [
        'Announcement Centre',
        'Important announcements',
        '2 unread',
        'Latest from OneLocal',
        'Maintenance',
        'Planned maintenance tonight',
        'New feature',
        'Policy update',
        '9 Oct 2026',
        "You're up to date with OneLocal announcements.",
      ]) {
        expect(find.text(s), findsWidgets, reason: s);
      }
      await t.tap(find.text('A simpler receipt preview'));
      await t.pumpAndSettle();
      expect(
        jsonDecode(
          f.requests
              .firstWhere((r) => r.url.path.endsWith('announce_mark_read'))
              .body,
        ),
        {'id': 'a2'},
      );
    },
  );

  testWidgets(
    'home: three tabs, switching works, customers tab lists queued messages and can cancel',
    (t) async {
      final f = Fake();
      await t.pumpWidget(host(NoticesHome(api: f.api)));
      await t.pumpAndSettle();
      expect(find.text('Notification Centre'), findsWidgets);
      await t.tap(find.text('Announcement Centre').first);
      await t.pumpAndSettle();
      expect(
        find.text('Official news and updates from OneLocal.'),
        findsOneWidget,
      );
      await t.tap(find.text('Customers'));
      await t.pumpAndSettle();
      expect(find.text('Festive offer'), findsOneWidget);
      await t.tap(find.widgetWithText(SmallPill, 'Cancel'));
      await t.pumpAndSettle();
      expect(
        f.requests.any(
          (r) =>
              r.url.path.endsWith('comm_cancel') &&
              jsonDecode(r.body)['id'] == 'c1',
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'compose: shows the live audience, queues once with an idempotency key and says nothing was sent',
    (t) async {
      tall(t);
      final f = Fake();
      await t.pumpWidget(host(ComposeScreen(api: f.api)));
      await t.pumpAndSettle();
      expect(
        find.textContaining('2 customers have agreed to hear from you'),
        findsOneWidget,
      );
      expect(find.textContaining('1 in this group have not'), findsOneWidget);
      await t.tap(find.widgetWithText(SmallPill, 'WhatsApp'));
      await t.pumpAndSettle();
      expect(jsonDecode(f.requests.last.body), {
        'segment': 'all',
        'channel': 'whatsapp',
      });
      final send = find.text('Queue message');
      await t.tap(send);
      await t.pump();
      expect(
        f.requests.where((r) => r.url.path.endsWith('comm_queue')),
        isEmpty,
        reason: 'empty message cannot be queued',
      );
      await t.enterText(find.byType(TextField).last, '20% off this weekend');
      await t.pump();
      await t.tap(find.text('Queue message'));
      await t.pumpAndSettle();
      final q = f.requests.singleWhere(
        (r) => r.url.path.endsWith('comm_queue'),
      );
      expect(jsonDecode(q.body), {
        'channel': 'whatsapp',
        'segment': 'all',
        'message': '20% off this weekend',
      });
      expect(q.headers['Idempotency-Key'], startsWith('msg-'));
      expect(find.text('Message queued'), findsOneWidget);
      expect(find.textContaining('Nothing has been sent'), findsOneWidget);
    },
  );

  testWidgets(
    'compose: a role that cannot send cannot press the button; the server sentence is shown on refusal',
    (t) async {
      tall(t);
      final f = Fake(
        (fn, a, r) =>
            fn == 'comm_options' ? ok({...options, 'can_send': false}) : null,
      );
      await t.pumpWidget(host(ComposeScreen(api: f.api)));
      await t.pumpAndSettle();
      expect(
        find.textContaining('can read customer messages but not queue them'),
        findsOneWidget,
      );
      await t.enterText(find.byType(TextField).last, 'hello');
      await t.pump();
      await t.tap(find.text('Queue message'));
      await t.pump();
      expect(
        f.requests.where((r) => r.url.path.endsWith('comm_queue')),
        isEmpty,
      );

      final g = Fake(
        (fn, a, r) => fn == 'comm_queue'
            ? err(
                422,
                'Nobody in this group has agreed to hear from you on this channel.',
                'no_audience',
              )
            : null,
      );
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(host(ComposeScreen(api: g.api)));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, 'hello');
      await t.pump();
      await t.tap(find.text('Queue message'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('Nobody in this group'), findsOneWidget);
    },
  );

  testWidgets(
    'feedback: summary, status chips, resolve with a reply goes to the server',
    (t) async {
      final f = Fake();
      await t.pumpWidget(host(FeedbackScreen(api: f.api)));
      await t.pumpAndSettle();
      expect(find.text('3.5'), findsOneWidget);
      expect(find.text('Asha'), findsOneWidget);
      await t.tap(find.widgetWithText(SmallPill, 'Resolve').first);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, 'Thank you');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final r = f.requests.lastWhere(
        (x) => x.url.path.endsWith('comm_feedback_respond'),
      );
      expect(jsonDecode(r.body), {
        'id': 'f1',
        'status': 'resolved',
        'response': 'Thank you',
      });
    },
  );

  test('times read like the Figma', () {
    expect(noticeTime(DateTime(2026, 10, 17, 0, 5), now), '12:05 AM');
    expect(noticeTime(DateTime(2026, 10, 17, 21, 0), now), '9:00 PM');
    expect(
      noticeTime(DateTime(2026, 10, 16, 18, 30), now),
      'Yesterday · 6:30 PM',
    );
    expect(noticeTime(DateTime(2026, 10, 8, 11, 0), now), '8 Oct · 11:00 AM');
    expect(noticeDate(DateTime(2026, 10, 9)), '9 Oct 2026');
    expect(noticeError(const RpcException(403, 'No.', null)), 'No.');
    expect(noticeError(Exception('x')), contains('Could not reach the server'));
  });

  test('wiring: the control centre bell and the reviews / complaints buttons lead to section N', () {
    installRoutes();
    expect(HomeNav.notifications, isNotNull);
    expect(HomeNav.reviews, isNotNull);
    expect(HomeNav.complaints, isNotNull);
  });
}
