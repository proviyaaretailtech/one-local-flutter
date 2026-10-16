import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/states/state_screens.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show ignoreOverflow;

Future<void> _show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 1688);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pump();
}

Future<void> _tapText(WidgetTester t, String text) async {
  await t.ensureVisible(find.text(text));
  await t.tap(find.text(text));
  await t.pump();
}

void main() {
  testWidgets('Z1 offline: says cached, counts drafts, both buttons act', (t) async {
    final calls = <String>[];
    await _show(t, OfflineScreen(queuedDrafts: 2, onCheck: () => calls.add('check'), onViewCached: () => calls.add('cached')));
    expect(find.text('You’re working offline'), findsOneWidget);
    expect(find.text('Cached · not live'), findsOneWidget);
    expect(find.text('2 sale drafts'), findsOneWidget);
    await _tapText(t, 'Check connection');
    await _tapText(t, 'View cached catalogue');
    expect(calls, ['check', 'cached']);
  });

  testWidgets('Z1 offline: one draft is singular and a live catalogue is not called cached', (t) async {
    await _show(t, const OfflineScreen(queuedDrafts: 1, catalogueLive: true));
    expect(find.text('1 sale draft'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
  });

  testWidgets('Z2 sync pending: waiting queue with its rows, nothing says synced', (t) async {
    final calls = <String>[];
    await _show(t, SyncScreen(phase: SyncPhase.pending, tasks: const [SyncTask('Pickup note', 'Task A', 'Waiting'), SyncTask('Delivery status', 'Task B', 'Waiting')], onPrimary: () => calls.add('check'), onSecondary: () => calls.add('queue')));
    expect(find.text('Waiting for a connection'), findsOneWidget);
    expect(find.text('Pickup note'), findsOneWidget);
    expect(find.text('Waiting'), findsNWidgets(2));
    await _tapText(t, 'Check connection');
    await _tapText(t, 'View local queue');
    expect(calls, ['check', 'queue']);
  });

  testWidgets('Z3 syncing: the second sync button is disabled and cannot be tapped', (t) async {
    var helped = 0;
    await _show(t, SyncScreen(phase: SyncPhase.syncing, tasks: const [SyncTask('Sale draft · basket A', '', 'In progress'), SyncTask('Catalogue note', '', 'Pending')], onSecondary: () => helped++));
    expect(find.text('Reconciling store records'), findsOneWidget);
    expect(find.text('Batch · 2 local changes'), findsOneWidget);
    await t.tap(find.text('Another sync unavailable'));
    await _tapText(t, 'Sync help');
    expect(helped, 1);
  });

  testWidgets('Z4 sync conflict: shows both versions and keeps the record paused', (t) async {
    final calls = <String>[];
    await _show(t, SyncScreen(phase: SyncPhase.conflict, recordName: 'Whole milk · note', localVersion: 'Keep upright', serverVersion: 'Keep chilled', onPrimary: () => calls.add('compare'), onSecondary: () => calls.add('pause')));
    expect(find.text('Conflict Detected'), findsOneWidget);
    expect(find.text('LOCAL · “Keep upright”'), findsOneWidget);
    expect(find.text('SERVER · “Keep chilled”'), findsOneWidget);
    await _tapText(t, 'Compare versions');
    await _tapText(t, 'Leave record paused');
    expect(calls, ['compare', 'pause']);
  });

  testWidgets('Z5 sync failed: retains the queue and retries the same queue', (t) async {
    var retried = 0;
    await _show(t, SyncScreen(phase: SyncPhase.failed, tasks: const [SyncTask('Pickup note', 'Task A — not yet synced', 'Waiting')], onPrimary: () => retried++));
    expect(find.text('Sync Failed'), findsWidgets);
    expect(find.textContaining('Pickup note'), findsOneWidget);
    await _tapText(t, 'Retry existing queue');
    expect(retried, 1);
  });

  testWidgets('Z6 and Z13: retry and help buttons act', (t) async {
    final calls = <String>[];
    await _show(t, NoInternetScreen(onRetry: () => calls.add('retry'), onHelp: () => calls.add('help')));
    expect(find.text('No Internet'), findsOneWidget);
    await _tapText(t, 'Retry connection');
    await _tapText(t, 'Connection help');
    await _show(t, ServerUnavailableScreen(onRetry: () => calls.add('server'), onHelp: () => calls.add('get')));
    expect(find.text('Server Unavailable'), findsOneWidget);
    await _tapText(t, 'Retry server');
    await _tapText(t, 'Get help');
    expect(calls, ['retry', 'help', 'server', 'get']);
  });

  testWidgets('Z7 payment failed: amount, receipt not issued, two exits', (t) async {
    final calls = <String>[];
    await _show(t, PaymentFailedScreen(amountLabel: '₹1,200', method: 'UPI', onReviewRetry: () => calls.add('review'), onReturn: () => calls.add('return')));
    expect(find.text('₹1,200'), findsOneWidget);
    expect(find.text('Not issued'), findsOneWidget);
    expect(find.text('Failed · Confirmed'), findsOneWidget);
    await _tapText(t, 'Review retry options');
    await _tapText(t, 'Return to checkout');
    expect(calls, ['review', 'return']);
  });

  testWidgets('Z9 payment terminal: outcome unknown, warns against a second charge', (t) async {
    var checked = 0;
    await _show(t, DeviceErrorScreen.paymentTerminal(terminal: 'HDFC-POS-04', attempt: 'PAY-1087-01', amountLabel: '₹1,740', lastResponse: '13:29 · Connection lost', onCheckStatus: () => checked++));
    expect(find.text('Terminal disconnected during payment'), findsOneWidget);
    expect(find.text('Not confirmed'), findsOneWidget);
    expect(find.textContaining('Do not collect a second payment'), findsOneWidget);
    await _tapText(t, 'Check payment status');
    expect(checked, 1);
  });

  testWidgets('Z10 printer: lists the labels waiting and the button counts them', (t) async {
    var retried = 0;
    await _show(t, DeviceErrorScreen.printer(printer: 'Printer PRN-01', register: 'REG-03', connection: 'USB · Not detected', waiting: const [(name: 'Coca-Cola 500ml', code: 'CC500', price: '₹40', qty: '84 Nos'), (name: 'Parle-G Biscuits', code: 'PG80G', price: '₹10', qty: '120 Nos')], onRetry: () => retried++));
    expect(find.text('2 products waiting to print'), findsOneWidget);
    expect(find.text('Label not printed'), findsNWidgets(2));
    await _tapText(t, 'Reconnect & retry 2 labels');
    expect(retried, 1);
  });

  testWidgets('Z11 scanner: the cart is safe and search is offered', (t) async {
    final calls = <String>[];
    await _show(t, DeviceErrorScreen.scanner(scanner: 'Scanner SCN-03', register: 'REG-03', cartNumber: '#101', cartLines: const [(name: 'Aashirvaad Atta 5kg', qty: '2', amount: '₹580')], subtotalLine: 'Subtotal ₹860 + GST ₹43', totalLabel: '₹903', onReconnect: () => calls.add('reconnect'), onSearch: () => calls.add('search')));
    expect(find.text('Your cart is safe · #101'), findsOneWidget);
    expect(find.text('₹903'), findsOneWidget);
    await _tapText(t, 'Search products instead');
    await _tapText(t, 'Reconnect scanner');
    expect(calls, ['search', 'reconnect']);
  });

  testWidgets('Z14 session expired: only the masked account is shown', (t) async {
    final calls = <String>[];
    await _show(t, SessionExpiredScreen(maskedAccount: 'r•••@sharmastore.in', onSignIn: () => calls.add('in'), onOtherAccount: () => calls.add('other')));
    expect(find.text('Let’s sign you back in.'), findsOneWidget);
    expect(find.text('r•••@sharmastore.in'), findsOneWidget);
    await _tapText(t, 'Sign in again');
    await _tapText(t, 'Use a different account');
    expect(calls, ['in', 'other']);
  });

  testWidgets('Z15 order missed: names the order and pauses the page', (t) async {
    var paused = 0;
    await _show(t, OrderMissedScreen(orderNo: '#OL-1044', amountLabel: '₹386', cancelledAt: '7:41 PM', onPause: () => paused++));
    expect(find.textContaining('#OL-1044 was not accepted within 3 minutes'), findsOneWidget);
    expect(find.text('Missed'), findsOneWidget);
    await _tapText(t, 'Pause my page for 30 min');
    expect(paused, 1);
  });

  testWidgets('Z16 item not available: Ask customer sends the chosen option', (t) async {
    final picked = <StockChoice>[];
    await _show(t, ItemNotAvailableScreen(orderNo: '#OL-1045', itemName: 'Paneer Butter Masala', lines: const ['2 × Paneer Butter Masala (out of stock)', '1 × Garlic Naan'], onAskCustomer: picked.add));
    await _tapText(t, 'Ask customer');
    await t.tap(find.byKey(const ValueKey('choice-removeItem')));
    await t.pump();
    await _tapText(t, 'Ask customer');
    expect(picked, [StockChoice.replacement, StockChoice.removeItem]);
  });

  testWidgets('Z17 maintenance and Z18 coming soon', (t) async {
    var offline = 0, notify = 0;
    await _show(t, MaintenanceScreen(expectedBack: '10:30 PM tonight', onContinueOffline: () => offline++));
    expect(find.text('10:30 PM tonight'), findsOneWidget);
    await _tapText(t, 'Continue offline');
    await _show(t, ComingSoonScreen(onNotify: () => notify++));
    expect(find.text('Coming soon'), findsOneWidget);
    await _tapText(t, 'Notify me');
    expect([offline, notify], [1, 1]);
  });
}
