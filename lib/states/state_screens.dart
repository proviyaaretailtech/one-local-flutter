import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_widgets.dart' show kStoreTabs;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'state_kit.dart';

// Section Z screens (assets/figma_ref_q). Each one is told what happened and what its buttons do; none reads or writes data.
// Wording follows the Figma frames. Frames Z2 and Z5 draw a Tasks / Route / Updates / Help tab bar that belongs to another app, so every state here uses the store tab bar (Money, Item, Bill, Online order, Stock).

/// One line of a sync queue ("Pickup note", "Task A · device-local update", "Waiting").
class SyncTask {
  const SyncTask(this.title, this.detail, this.status);
  final String title, detail, status;
}

/// Z1 Offline POS. The cashier may keep working on cached data; nothing online is promised.
class OfflineScreen extends StatelessWidget {
  const OfflineScreen({super.key, required this.queuedDrafts, this.catalogueLive = false, this.onCheck, this.onViewCached, this.onTab});
  final int queuedDrafts;
  final bool catalogueLive;
  final VoidCallback? onCheck, onViewCached;
  final ValueChanged<String>? onTab;

  @override
  Widget build(BuildContext context) => StateFrame(
        title: 'Offline Mode',
        tabs: kStoreTabs,
        onTab: onTab,
        children: [
          StatusCard(
            icon: LucideIcons.wifiOff,
            tone: StateTone.warn,
            title: 'You’re working offline',
            body: 'Browse cached items and edit sale drafts on this device. Online payments and live stock checks are unavailable.',
            extra: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(14)),
              child: Column(children: [
                KeyValue('Catalogue', catalogueLive ? 'Live' : 'Cached · not live', size: 14),
                KeyValue('Local queue', '$queuedDrafts sale ${queuedDrafts == 1 ? 'draft' : 'drafts'}', size: 14),
              ]),
            ),
            primaryLabel: 'Check connection',
            onPrimary: onCheck,
            secondaryLabel: 'View cached catalogue',
            onSecondary: onViewCached,
          ),
          const SizedBox(height: 12),
          const OrderCardBox(
            padding: EdgeInsets.all(16),
            child: _Safe(),
          ),
        ],
      );
}

class _Safe extends StatelessWidget {
  const _Safe();
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Safe work on this device', style: inter(14.5, 700)),
        const SizedBox(height: 6),
        Text('Drafts are not completed sales. Review stock and payment eligibility after reconnecting.', style: inter(15, 400, color: kMuted, height: 1.4)),
      ]);
}

enum SyncPhase { pending, syncing, failed, conflict }

/// Z2 Sync pending, Z3 Syncing, Z4 Sync conflict, Z5 Sync failed. The queue rows come from the caller; this screen never starts or retries a sync by itself.
class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key, required this.phase, this.tasks = const [], this.localVersion, this.serverVersion, this.recordName, this.onPrimary, this.onSecondary, this.onTab});
  final SyncPhase phase;
  final List<SyncTask> tasks;

  /// Conflict only: the two differing values and what they belong to ("Whole milk · note").
  final String? localVersion, serverVersion, recordName;
  final VoidCallback? onPrimary, onSecondary;
  final ValueChanged<String>? onTab;

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case SyncPhase.pending:
        return StateFrame(
          title: 'Sync Pending',
          tabs: kStoreTabs,
          onTab: onTab,
          bottom: _Foot(
            hint: 'Keep working with cached tasks. Do not recreate pending updates or treat them as server-confirmed.',
            primary: 'Check connection',
            onPrimary: onPrimary,
            secondary: 'View local queue',
            onSecondary: onSecondary,
          ),
          children: [
            StatusCard(
              icon: LucideIcons.clock,
              tone: StateTone.warn,
              chip: 'Waiting · not started',
              title: 'Waiting for a connection',
              body: 'The queue is ready, but reconciliation has not started. Your device is currently offline.',
            ),
            const SizedBox(height: 12),
            _Queue(heading: 'Waiting queue', tasks: tasks, showDetail: true),
          ],
        );
      case SyncPhase.syncing:
        return StateFrame(
          title: 'Syncing',
          tabs: kStoreTabs,
          onTab: onTab,
          bottom: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Wait for this sync result. Do not start another sync or resubmit these changes.', style: inter(13.5, 400, color: kMuted, height: 1.4)),
            const SizedBox(height: 12),
            const DarkCta(label: 'Another sync unavailable', onPressed: null),
            const SizedBox(height: 10),
            LightCta(label: 'Sync help', onPressed: onSecondary),
          ]),
          children: [
            StatusCard(
              icon: LucideIcons.refreshCw,
              tone: StateTone.warn,
              busy: true,
              chip: 'Sync in progress',
              title: 'Reconciling store records',
              body: 'OneLocal POS is reconciling this queue. Updates are not yet confirmed as synchronized.',
            ),
            const SizedBox(height: 12),
            _Queue(heading: 'Batch · ${tasks.length} local ${tasks.length == 1 ? 'change' : 'changes'}', tasks: tasks, showDetail: false),
          ],
        );
      case SyncPhase.failed:
        return StateFrame(
          title: 'Sync Failed',
          tabs: kStoreTabs,
          onTab: onTab,
          centered: true,
          children: [
            StatusCard(
              icon: LucideIcons.wifi,
              title: 'Sync Failed',
              body: 'The connection timed out before this batch could be confirmed. Pending changes remain in the local queue.',
              info: InfoBox(title: 'Retained queue', lines: [for (final t in tasks) '${t.title} · ${t.detail}', '', 'Check connectivity, then retry this queue. Do not recreate the same updates.']),
              primaryLabel: 'Retry existing queue',
              onPrimary: onPrimary,
              secondaryLabel: 'Sync help',
              onSecondary: onSecondary,
            ),
          ],
        );
      case SyncPhase.conflict:
        return StateFrame(
          title: 'Sync Conflict',
          tabs: kStoreTabs,
          onTab: onTab,
          children: [
            StatusCard(
              icon: LucideIcons.refreshCwOff,
              title: 'Conflict Detected',
              body: 'Sync is paused for this record. Local and server versions differ; neither has been merged.',
              info: InfoBox(title: recordName, lines: [
                if (localVersion != null) 'LOCAL · “$localVersion”',
                if (serverVersion != null) 'SERVER · “$serverVersion”',
                '',
                'Both versions are retained for review. An authorized editor must resolve this record before its sync resumes.',
              ]),
              primaryLabel: 'Compare versions',
              onPrimary: onPrimary,
              secondaryLabel: 'Leave record paused',
              onSecondary: onSecondary,
            ),
          ],
        );
    }
  }
}

class _Queue extends StatelessWidget {
  const _Queue({required this.heading, required this.tasks, required this.showDetail});
  final String heading;
  final List<SyncTask> tasks;
  final bool showDetail;

  @override
  Widget build(BuildContext context) => OrderCardBox(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(heading, style: inter(14.5, 700)),
          const SizedBox(height: 10),
          for (final t in tasks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.title, style: inter(showDetail ? 16 : 14.5, showDetail ? 600 : 500, color: t.status == 'Pending' ? kMuted : kInk)),
                    if (showDetail) Text(t.detail, style: inter(13.5, 400, color: kMuted)),
                  ]),
                ),
                Text(t.status, style: inter(13.5, 500, color: t.status == 'In progress' ? const Color(0xFF92400E) : kMuted)),
              ]),
            ),
        ]),
      );
}

class _Foot extends StatelessWidget {
  const _Foot({required this.hint, required this.primary, required this.secondary, this.onPrimary, this.onSecondary});
  final String hint, primary, secondary;
  final VoidCallback? onPrimary, onSecondary;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(hint, style: inter(13.5, 400, color: kMuted, height: 1.4)),
        const SizedBox(height: 12),
        DarkCta(label: primary, onPressed: onPrimary),
        const SizedBox(height: 10),
        LightCta(label: secondary, onPressed: onSecondary),
      ]);
}

/// Z6 No internet.
class NoInternetScreen extends StatelessWidget {
  const NoInternetScreen({super.key, this.onRetry, this.onHelp, this.onTab});
  final VoidCallback? onRetry, onHelp;
  final ValueChanged<String>? onTab;

  @override
  Widget build(BuildContext context) => StateFrame(
        title: 'Network',
        tabs: kStoreTabs,
        onTab: onTab,
        centered: true,
        children: [
          StatusCard(
            icon: LucideIcons.wifiOff,
            title: 'No Internet',
            body: 'Your device is offline. OneLocal cannot connect to online services.',
            info: const InfoBox(title: 'What to do', lines: ['Turn on Wi-Fi or mobile data, then check your connection before retrying.']),
            primaryLabel: 'Retry connection',
            onPrimary: onRetry,
            secondaryLabel: 'Connection help',
            onSecondary: onHelp,
          ),
        ],
      );
}

/// Z13 Server unavailable.
class ServerUnavailableScreen extends StatelessWidget {
  const ServerUnavailableScreen({super.key, this.onRetry, this.onHelp, this.onTab});
  final VoidCallback? onRetry, onHelp;
  final ValueChanged<String>? onTab;

  @override
  Widget build(BuildContext context) => StateFrame(
        title: 'Network',
        tabs: kStoreTabs,
        onTab: onTab,
        centered: true,
        children: [
          StatusCard(
            icon: LucideIcons.serverOff,
            title: 'Server Unavailable',
            body: 'OneLocal’s server is not responding. This part of the store cannot load.',
            info: const InfoBox(title: 'What to do', lines: ['Try reaching the server again. If it remains unavailable, report the issue through Help.']),
            primaryLabel: 'Retry server',
            onPrimary: onRetry,
            secondaryLabel: 'Get help',
            onSecondary: onHelp,
          ),
        ],
      );
}

/// Z7 Payment failed: the provider confirmed the attempt did not go through, so nothing was charged and no receipt exists.
class PaymentFailedScreen extends StatelessWidget {
  const PaymentFailedScreen({super.key, required this.amountLabel, required this.method, this.detail, this.onReviewRetry, this.onReturn, this.onTab});
  final String amountLabel, method;

  /// The provider's own words, when it gave any.
  final String? detail;
  final VoidCallback? onReviewRetry, onReturn;
  final ValueChanged<String>? onTab;

  @override
  Widget build(BuildContext context) => StateFrame(
        title: 'Checkout',
        onTab: onTab,
        bottom: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('This attempt is definitely unsuccessful. If you see a debit, check the payment record before retrying.', style: inter(13.5, 400, color: kMuted, height: 1.4)),
          const SizedBox(height: 12),
          DarkCta(label: 'Review retry options', onPressed: onReviewRetry),
          const SizedBox(height: 10),
          LightCta(label: 'Return to checkout', onPressed: onReturn),
        ]),
        children: [
          Text('Payment Failed', style: inter(28, 700)),
          const SizedBox(height: 14),
          OrderCardBox(
            radius: 20,
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 46, height: 46, decoration: const BoxDecoration(color: Color(0xFFFEE2E2), shape: BoxShape.circle), child: const Icon(LucideIcons.circleX, size: 22, color: Color(0xFFDC2626))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const DotChip('Failed · Confirmed', bg: Color(0xFFFEE2E2), fg: Color(0xFFDC2626)),
                  const SizedBox(height: 8),
                  Text('Payment did not complete', style: inter(16, 700)),
                  const SizedBox(height: 6),
                  Text(detail ?? 'The provider confirmed that this $method attempt was unsuccessful. This is not a pending result.', style: inter(14, 400, color: kMuted, height: 1.4)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          OrderCardBox(
            radius: 20,
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Attempt result', style: inter(15, 700)),
              const SizedBox(height: 10),
              Row(children: [Text('Requested amount', style: inter(14, 400, color: kMuted)), const Spacer(), Text(amountLabel, style: inter(22, 800))]),
              KeyValue('Method', method, size: 14),
              KeyValue('Result', 'Unsuccessful', size: 14),
              KeyValue('Receipt', 'Not issued', size: 14),
            ]),
          ),
        ],
      );
}

/// Z9 payment device, Z10 printer and Z11 scanner: a hardware problem. The sale or the print job is kept; nothing is retried by itself.
class DeviceErrorScreen extends StatelessWidget {
  const DeviceErrorScreen({
    super.key,
    required this.title,
    this.subtitle,
    required this.bannerTitle,
    required this.bannerBody,
    required this.deviceName,
    this.statusLabel = 'Disconnected',
    this.rows = const [],
    this.guidance,
    this.below = const [],
    required this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.footnote,
    this.onTab,
  });
  final String title, bannerTitle, bannerBody, deviceName, statusLabel, primaryLabel;
  final String? subtitle, guidance, secondaryLabel, footnote;
  final List<MapEntry<String, String>> rows;

  /// Cards under the device card (products waiting to print, the cart that is still safe).
  final List<Widget> below;
  final VoidCallback? onPrimary, onSecondary;
  final ValueChanged<String>? onTab;

  /// Z9: the terminal dropped mid-payment, so the outcome is unknown and a second charge must not be taken.
  factory DeviceErrorScreen.paymentTerminal({
    required String terminal,
    required String attempt,
    required String amountLabel,
    String? lastResponse,
    String? checkout,
    VoidCallback? onCheckStatus,
    VoidCallback? onHelp,
  }) =>
      DeviceErrorScreen(
        title: 'Payment device offline',
        subtitle: checkout,
        bannerTitle: 'Terminal disconnected during payment',
        bannerBody: 'The outcome is unknown. A disconnected device does not mean the payment failed.',
        deviceName: terminal,
        rows: [
          MapEntry('Payment attempt', attempt),
          MapEntry('Amount requested', amountLabel),
          if (lastResponse != null) MapEntry('Last response', lastResponse),
          const MapEntry('Payment status', 'Not confirmed'),
        ],
        below: const [
          WireCard(title: 'Check before you charge again', lines: [
            '1. Check the existing attempt. Reconnect the terminal and check the attempt with the payment provider.',
            '2. Follow the confirmed outcome. Paid: complete the sale and issue a receipt. Failed or reversed: choose a tender and retry.',
            '3. Still uncertain? Keep this sale pending and ask a supervisor. Do not collect a second payment.',
          ]),
        ],
        primaryLabel: 'Check payment status',
        onPrimary: onCheckStatus,
        secondaryLabel: 'Connection help',
        onSecondary: onHelp,
        footnote: 'Do not retry or switch tender until this attempt is confirmed.',
      );

  /// Z10: label printer unavailable, with the products still waiting to print.
  factory DeviceErrorScreen.printer({
    required String printer,
    required String register,
    required List<({String name, String code, String price, String qty})> waiting,
    String? connection,
    String? lastPrinted,
    VoidCallback? onRetry,
    VoidCallback? onSettings,
  }) =>
      DeviceErrorScreen(
        title: 'Printer unavailable',
        subtitle: register,
        bannerTitle: 'Label printer disconnected',
        bannerBody: 'No shelf labels were printed. This is a printer connection issue.',
        deviceName: printer,
        statusLabel: 'Unavailable',
        rows: [if (connection != null) MapEntry('Connection', connection), if (lastPrinted != null) MapEntry('Last printed', lastPrinted)],
        guidance: 'Check the cable and power. Reconnect the printer, then try printing again.',
        below: [
          Text('${waiting.length} ${waiting.length == 1 ? 'product' : 'products'} waiting to print', style: inter(15, 700)),
          for (final w in waiting)
            OrderCardBox(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(w.name, style: inter(15, 700)),
                    Text(w.code, style: inter(12.5, 400, color: kMuted)),
                    Text('Label not printed', style: inter(12.5, 400, color: const Color(0xFFDC2626))),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(w.price, style: inter(16, 700)), Text(w.qty, style: inter(12.5, 400, color: kMuted))]),
              ]),
            ),
        ],
        primaryLabel: 'Reconnect & retry ${waiting.length} ${waiting.length == 1 ? 'label' : 'labels'}',
        onPrimary: onRetry,
        secondaryLabel: 'Printer settings',
        onSecondary: onSettings,
      );

  /// Z11: barcode scanner unavailable; the cart stays safe and the cashier can search by hand.
  factory DeviceErrorScreen.scanner({
    required String scanner,
    required String register,
    required String cartNumber,
    required List<({String name, String qty, String amount})> cartLines,
    required String subtotalLine,
    required String totalLabel,
    String? connection,
    String? lastConnected,
    VoidCallback? onReconnect,
    VoidCallback? onSearch,
  }) =>
      DeviceErrorScreen(
        title: 'Scanner unavailable',
        subtitle: register,
        bannerTitle: 'Barcode scanner disconnected',
        bannerBody: 'No barcode was read. This is a scanner connection issue, not an unknown product.',
        deviceName: scanner,
        statusLabel: 'Unavailable',
        rows: [if (connection != null) MapEntry('Connection', connection), if (lastConnected != null) MapEntry('Last connected', lastConnected)],
        guidance: 'Check the cable and power. Reconnect the scanner, then try scanning again.',
        below: [
          OrderCardBox(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your cart is safe · $cartNumber', style: inter(15, 700)),
              const SizedBox(height: 8),
              for (final l in cartLines) Row(children: [Expanded(child: Text(l.name, style: inter(14, 400, color: kMuted))), Text('${l.qty}×  ${l.amount}', style: inter(13.5, 600))]),
              const Divider(height: 22),
              Row(children: [Expanded(child: Text(subtotalLine, style: inter(13.5, 500, color: kMuted))), Text(totalLabel, style: inter(22, 800))]),
            ]),
          ),
          Text('You can keep selling with product search. No item was added or removed by the scanner error.', style: inter(13.5, 400, color: kMuted, height: 1.4)),
        ],
        primaryLabel: 'Reconnect scanner',
        onPrimary: onReconnect,
        secondaryLabel: 'Search products instead',
        onSecondary: onSearch,
      );

  @override
  Widget build(BuildContext context) => StateFrame(
        title: title,
        onTab: onTab,
        bottom: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DarkCta(label: primaryLabel, onPressed: onPrimary),
          if (secondaryLabel != null) ...[const SizedBox(height: 10), LightCta(label: secondaryLabel!, onPressed: onSecondary)],
          if (footnote != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(footnote!, textAlign: TextAlign.center, style: inter(12.5, 400, color: kMuted))),
        ]),
        children: [
          if (subtitle != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(subtitle!, style: inter(14, 400, color: kMuted))),
          AlertBanner(title: bannerTitle, body: bannerBody),
          const SizedBox(height: 12),
          OrderCardBox(
            radius: 20,
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(deviceName, style: inter(17, 700)),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: DotChip(statusLabel, bg: const Color(0xFFFEE2E2), fg: const Color(0xFFDC2626))),
              const SizedBox(height: 8),
              for (final r in rows) KeyValue(r.key, r.value, size: 14),
              if (guidance != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(guidance!, style: inter(14, 400, color: kMuted, height: 1.4))),
            ]),
          ),
          for (final b in below) Padding(padding: const EdgeInsets.only(top: 12), child: b),
        ],
      );
}

/// Z15 Order missed: nobody accepted the order in time, so it was cancelled and the customer refunded.
class OrderMissedScreen extends StatelessWidget {
  const OrderMissedScreen({super.key, required this.orderNo, required this.amountLabel, required this.cancelledAt, this.onPause, this.onBack});
  final String orderNo, amountLabel, cancelledAt;
  final VoidCallback? onPause, onBack;

  @override
  Widget build(BuildContext context) => WirePage(
        title: 'Order missed',
        lead: 'Order $orderNo was not accepted within 3 minutes, so it was cancelled and the customer refunded.',
        cards: [
          WireCard(title: '$orderNo · $amountLabel', chip: 'Missed', chipBg: const Color(0xFFFEE2E2), chipFg: const Color(0xFFB91C1C), lines: ['Auto-cancelled $cancelledAt · refund started']),
          const WireCard(title: 'Avoid missed orders', lines: ['Keep the app open with sound on, or pause the page when busy.']),
        ],
        primaryLabel: 'Pause my page for 30 min',
        onPrimary: onPause,
        secondaryLabel: 'Back to orders',
        onSecondary: onBack,
        onBack: onBack,
      );
}

enum StockChoice { replacement, removeItem, rejectOrder }

/// Z16 Item not available: a customer ordered something that is out of stock. The three choices are offered; the caller acts on the one picked.
class ItemNotAvailableScreen extends StatefulWidget {
  const ItemNotAvailableScreen({super.key, required this.orderNo, required this.itemName, required this.lines, this.onAskCustomer, this.onMarkUnavailable, this.onBack});
  final String orderNo, itemName;

  /// "2 × Paneer Butter Masala (out of stock)", "1 × Garlic Naan".
  final List<String> lines;
  final ValueChanged<StockChoice>? onAskCustomer;
  final VoidCallback? onMarkUnavailable, onBack;

  @override
  State<ItemNotAvailableScreen> createState() => _ItemNotAvailableState();
}

class _ItemNotAvailableState extends State<ItemNotAvailableScreen> {
  StockChoice _choice = StockChoice.replacement;

  static const _labels = {
    StockChoice.replacement: 'Offer a replacement',
    StockChoice.removeItem: 'Remove item and part-refund',
    StockChoice.rejectOrder: 'Reject order',
  };

  @override
  Widget build(BuildContext context) => WirePage(
        title: 'Item not available',
        lead: 'A customer ordered ${widget.itemName}, which is out of stock.',
        cards: [
          WireCard(title: widget.orderNo, chip: 'Action needed', lines: widget.lines),
          OrderCardBox(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Choose', style: inter(17, 700)),
              for (final c in StockChoice.values)
                InkWell(
                  key: ValueKey('choice-${c.name}'),
                  onTap: () => setState(() => _choice = c),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Icon(_choice == c ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 20, color: _choice == c ? kInk : kMuted),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_labels[c]!, style: inter(14.5, 500))),
                    ]),
                  ),
                ),
            ]),
          ),
        ],
        primaryLabel: 'Ask customer',
        onPrimary: widget.onAskCustomer == null ? null : () => widget.onAskCustomer!(_choice),
        secondaryLabel: 'Mark item unavailable',
        onSecondary: widget.onMarkUnavailable,
        onBack: widget.onBack,
      );
}

/// Z17 Maintenance: planned downtime. The POS keeps working offline and sales sync afterwards.
class MaintenanceScreen extends StatelessWidget {
  const MaintenanceScreen({super.key, required this.expectedBack, this.stillWorks = 'POS sales · cash · receipts (offline)', this.onContinueOffline, this.onBack});
  final String expectedBack, stillWorks;
  final VoidCallback? onContinueOffline, onBack;

  @override
  Widget build(BuildContext context) => WirePage(
        title: 'We’ll be right back',
        lead: 'OneLocal is being updated. Your POS keeps working offline; sales sync when we are back.',
        cards: [
          WireCard(title: 'Expected back', chip: 'Planned', chipBg: const Color(0xFFE0E7FF), chipFg: const Color(0xFF3730A3), lines: [expectedBack]),
          WireCard(title: 'Still works', lines: [stillWorks]),
        ],
        primaryLabel: 'Continue offline',
        onPrimary: onContinueOffline,
        onBack: onBack,
      );
}

/// Z18 Service businesses are not available yet.
class ComingSoonScreen extends StatelessWidget {
  const ComingSoonScreen({super.key, this.onNotify, this.onChooseAnother, this.onBack});
  final VoidCallback? onNotify, onChooseAnother, onBack;

  @override
  Widget build(BuildContext context) => WirePage(
        title: 'Service businesses',
        lead: 'Salons, repairs, cleaning and other services.',
        cards: const [
          WireCard(title: 'Coming soon', chip: 'Soon', lines: ['Appointments, staff availability, packages and memberships are on the way.']),
          WireCard(title: 'Meanwhile', lines: ['Register as a Store to sell products now, or leave your details and we will call you.']),
        ],
        primaryLabel: 'Notify me',
        onPrimary: onNotify,
        secondaryLabel: 'Choose another business type',
        onSecondary: onChooseAnother,
        onBack: onBack,
      );
}

/// Z14 Session expired: sign back in. Only a masked account hint is shown, never the full address.
class SessionExpiredScreen extends StatelessWidget {
  const SessionExpiredScreen({super.key, this.maskedAccount, this.onSignIn, this.onOtherAccount, this.onHelp});
  final String? maskedAccount;
  final VoidCallback? onSignIn, onOtherAccount, onHelp;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [const BrandLogo(), const Spacer(), InkWell(onTap: onHelp, child: Text('Help', style: inter(16, 600, color: kLink)))]),
              const SizedBox(height: 36),
              Text('SESSION · TIMEOUT', style: inter(13, 700, color: kLink).copyWith(letterSpacing: 0.4)),
              const SizedBox(height: 14),
              Container(width: 56, height: 56, decoration: const BoxDecoration(color: kNote, shape: BoxShape.circle), child: const Icon(LucideIcons.clock, size: 26, color: kLink)),
              const SizedBox(height: 24),
              Text('Let’s sign you back in.', style: inter(32, 700, height: 1.15)),
              const SizedBox(height: 12),
              Text('Your session timed out after a period of inactivity. Sign in again to access your store.', style: inter(17, 400, color: kMuted, height: 1.4)),
              const SizedBox(height: 22),
              if (maskedAccount != null)
                OrderCardBox(
                  radius: 16,
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Last signed-in account', style: inter(13, 400, color: kMuted)),
                    const SizedBox(height: 2),
                    Text(maskedAccount!, style: inter(17, 600)),
                  ]),
                ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(16)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(LucideIcons.rotateCw, size: 20, color: kLink),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Check where you left off', style: inter(15, 700)),
                      const SizedBox(height: 3),
                      Text('Once signed in, review your last activity. Any unsaved edits may need to be entered again.', style: inter(13.5, 400, color: kMuted, height: 1.4)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 32),
              PrimaryAction(label: 'Sign in again', onPressed: onSignIn),
              const SizedBox(height: 18),
              Center(child: InkWell(onTap: onOtherAccount, child: Text('Use a different account', style: inter(16, 600, color: kLink)))),
              const SizedBox(height: 14),
              Center(child: Text('Need help? Contact support', style: inter(14, 400, color: kMuted))),
            ]),
          ),
        ),
      );
}
