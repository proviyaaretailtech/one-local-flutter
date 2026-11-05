import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/money/store_money.dart';
import 'package:vinii_pos/ui/theme.dart';

// Store Money's Close day is the one close (0665): it warns about unpaid bills, refuses an unreadable count, can be reopened, and a drawer that does not
// hold what the last day ended with is entered exactly.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

class Fake {
  final calls = <String, Map<String, dynamic>>{};
  bool closed = false, counted = false;
  Map<String, dynamic> register() => {
        'day': '2026-11-05', 'opening_minor': 100000, 'sales_minor': 50000, 'cash_in_minor': 0, 'refunds_minor': 0, 'cash_out_minor': 0,
        'expected_minor': counted ? 145000 : 150000,
        'open_bills': {'count': 2, 'due_minor': 170300},
        'can_count_opening': !closed && !counted,
        'can_reopen': closed,
        'reopens': const [],
        'opening_count': counted ? {'counted_minor': 95000, 'difference_minor': -5000} : null,
        'closed': closed ? {'counted_minor': 150000, 'expected_minor': 150000, 'difference_minor': 0, 'by': 'Owner', 'at': '2026-11-05T10:00:00Z'} : null,
      };
  late final api = StoreMoneyApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    final fn = r.url.path.split('/').last;
    calls[fn] = r.body.isEmpty ? {} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
    switch (fn) {
      case 'smoney_home':
        return ok({'today': {'in_minor': 0, 'out_minor': 0, 'net_minor': 0}, 'accounts': const [], 'total_minor': 0, 'week': const [], 'can_record': true, 'can_void': true, 'shop': const {}});
      case 'smoney_close_day':
        closed = true;
        return ok(register());
      case 'smoney_reopen_day':
        closed = false;
        return ok(register());
      case 'smoney_opening_count':
        counted = true;
        return ok(register());
      default:
        return ok(register());
    }
  }));
}

Future<void> show(WidgetTester t, Fake f) async {
  t.view.physicalSize = const Size(900, 2200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: StoreMoneyScreen(api: f.api, plan: 'pos_only')));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Close day says what is still unpaid and will not take an unreadable count', (t) async {
    final f = Fake();
    await show(t, f);
    await tapKey(t, 'close-day');
    expect(find.byKey(const ValueKey('close-open-bills')), findsOneWidget);
    expect(find.textContaining('2 bills are still unpaid'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('close-counted')), '1.2.3');
    await tapKey(t, 'close-confirm');
    expect(find.text('Enter the cash you counted, like 1250.50.'), findsOneWidget);
    expect(f.calls.containsKey('smoney_close_day'), isFalse);
    await t.enterText(find.byKey(const ValueKey('close-counted')), '1500');
    await tapKey(t, 'close-confirm');
    expect(f.calls['smoney_close_day'], containsPair('counted_minor', 150000));
    expect(find.byKey(const ValueKey('day-closed')), findsOneWidget);
  });

  testWidgets('a closed day can be reopened with a reason, and Close day is back', (t) async {
    final f = Fake()..closed = true;
    await show(t, f);
    expect(find.byKey(const ValueKey('close-day')), findsNothing);
    await tapKey(t, 'reopen-day');
    await t.enterText(find.byKey(const ValueKey('reopen-reason')), 'Late customer');
    await tapKey(t, 'reopen-confirm');
    expect(f.calls['smoney_reopen_day'], containsPair('reason', 'Late customer'));
    expect(find.byKey(const ValueKey('close-day')), findsOneWidget);
    expect(find.byKey(const ValueKey('reopen-day')), findsNothing);
  });

  testWidgets('a drawer that differs from the last day end is entered exactly, and the shortage shows', (t) async {
    final f = Fake();
    await show(t, f);
    await tapKey(t, 'count-opening');
    expect(find.textContaining('Last day ended with'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('opening-counted')), '950');
    await tapKey(t, 'opening-confirm');
    expect(f.calls['smoney_opening_count'], containsPair('counted_minor', 95000));
    expect(find.text('Shortage at opening'), findsOneWidget);
    expect(find.byKey(const ValueKey('count-opening')), findsNothing);
  });
}
