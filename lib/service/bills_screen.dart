import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../devices/bill_receipt.dart';
import '../devices/print_service.dart';
import '../home/home_nav.dart';
import '../orders/order_widgets.dart';
import '../sell/cart_customer.dart';
import '../ui/theme.dart';
import '../ui/wallet.dart';
import '../ui/whatsapp.dart';
import 'service_api.dart';
import 'service_widgets.dart';
import 'step_form.dart';
import 'job_screens.dart';
import 'visit_receipt.dart' show visitNote;
import 'visit_screens.dart';

// The Bill tab (2 Nov 2026), the same for every kind of service: every bill (from a booking or made here) with what is due and paid; one
// bill with its lines, totals and payments, to collect, send on WhatsApp (the public bill link) or print; and New bill: a customer, services
// from the catalogue with quantities, a discount. Every amount is the server's (svc_bill_list, svc_bill_view, svc_invoice_create, svc_invoice_pay).

String _method(String m) => switch (m) { 'upi' => 'UPI', 'card' => 'Card', 'cash' => 'Cash', _ => m };

/// A bill's wallet colours (founder, 2 Nov 2026, as in the store POS): due red, part paid orange, paid green, cancelled grey.
List<Color> billWalletColors(String status) => switch (status) {
      'paid' => WalletColors.green,
      'part_paid' => WalletColors.orange,
      'cancelled' => WalletColors.slate,
      _ => WalletColors.red,
    };

Widget _walletPill(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: inter(11.5, 700, color: Colors.white)),
    );

/// One bill as a white card with its colour as an accent (founder, 2 Nov 2026: "red accents or their respective colours, instead of full
/// red"): a stripe down the left, the status pill and what is due in the colour; number and what for, the customer and where it came from,
/// the date and the total.
class BillAccentCard extends StatelessWidget {
  const BillAccentCard(this.b, {super.key, required this.onTap, required this.accent});
  final BillView b;
  final VoidCallback onTap;
  final Color accent;

  Widget _pill(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: inter(11, 700, color: fg)),
      );

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.white,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kLine)),
          child: InkWell(
            onTap: onTap,
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(width: 5, color: accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('${b.displayNo} · ${b.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700))),
                        const SizedBox(width: 8),
                        _pill(b.statusLabel, accent.withValues(alpha: 0.12), accent),
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        Expanded(child: Text(b.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 500, color: kMuted))),
                        _pill(b.fromBooking ? 'Booking ${b.booking.s('display_no')}' : b.fromJob ? 'Job ${b.job.s('display_no')}' : 'Bill', const Color(0xFFF1F2F4), kInk),
                      ]),
                      const SizedBox(height: 8),
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Expanded(child: Text(b.dateLabel, style: inter(11.5, 400, color: kMuted))),
                        if (b.due > 0 && b.status != 'cancelled') ...[
                          Text('Due ', style: inter(12, 500, color: kMuted)),
                          Text(svcRupees(b.due), style: inter(13, 800, color: accent)),
                          const SizedBox(width: 10),
                        ],
                        Text(svcRupees(b.total), style: inter(17, 800)),
                      ]),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}

/// One bill in a list: a white card in its pile's colour, or its own status colour in a search.
Widget billWalletCard(BillView b, VoidCallback onTap, {List<Color>? colors}) =>
    BillAccentCard(b, key: ValueKey('bill-${b.id}'), onTap: onTap, accent: (colors ?? billWalletColors(b.status)).first);

/// The tab's first screen: what is due now and paid this month, Due · Paid · All, search, and the bills.
class BillsScreen extends StatefulWidget {
  const BillsScreen({super.key, this.api, this.onNavigate, this.openUrl, this.printer, this.filter});
  final ServiceApi? api;
  final ValueChanged<String>? onNavigate;
  final Future<bool> Function(Uri url)? openUrl;

  /// The pile to open on: due, today, paid or all; null shows every pile (the dashboard's Money tile opens Taken today, 2 Nov 2026).
  final String? filter;
  final Future<void> Function(BuildContext context, BillReceipt bill)? printer;
  @override
  State<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends State<BillsScreen> {
  late final ServiceApi _api = widget.api ?? ServiceApi();

  /// The open pile (due, today or paid); null shows every pile, one below the other (founder, 2 Nov 2026).
  late String? _pile = widget.filter;
  String _q = '';
  BillListData? _data;
  String? _error;
  int _seq = 0;

  // (filter, name, what it holds, icon, colours), in the order the business needs them
  static const _piles = [
    ('due', 'Due', 'Waiting for payment', LucideIcons.hourglass, WalletColors.red),
    ('today', 'Taken today', 'Money taken today', LucideIcons.banknote, WalletColors.green),
    ('paid', 'Paid', 'Fully paid', LucideIcons.circleCheck, WalletColors.blue),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The piles need the counts and amounts only (any filter answers them); an open pile or a search needs its bills.
  Future<void> _load() async {
    final mine = ++_seq;
    setState(() => _error = null);
    try {
      final d = await _api.bills(filter: _pile ?? (_q.trim().isEmpty ? 'due' : 'all'), q: _q);
      if (mounted && mine == _seq) setState(() => _data = d);
    } on ServiceApiException catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && mine == _seq) setState(() => _error = 'Could not load bills. Check the connection and try again.');
    }
  }

  void _openPile(String? pile) {
    if (pile == _pile) return;
    _pile = pile;
    _load();
  }

  Future<void> _open(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BillDetailScreen(api: _api, id: id, onNavigate: widget.onNavigate, openUrl: widget.openUrl, printer: widget.printer)));
    if (mounted) _load();
  }

  Future<void> _new() async {
    final made = await Navigator.of(context).push<BillView>(MaterialPageRoute(builder: (_) => NewBillScreen(api: _api)));
    if (made != null && mounted) {
      _load();
      _open(made.id);
    }
  }

  /// A pile's line under its name: how many bills and how much.
  String _pileNote(BillListData d, String pile) {
    String bills(int n) => '$n ${n == 1 ? 'bill' : 'bills'}';
    return switch (pile) {
      'due' => '${bills(d.count('due'))} · ${svcRupees(d.dueAmount)} due',
      'today' => '${bills(d.count('today'))} · ${svcRupees(d.paidToday)} taken',
      'paid' => '${bills(d.count('paid'))} · ${svcRupees(d.paidThisMonth)} this month',
      _ => bills(d.count('all')),
    };
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final searching = _q.trim().isNotEmpty;
    final open = _piles.where((p) => p.$1 == _pile).firstOrNull;
    return ServicePage(
      title: 'Bills',
      subtitle: 'Every bill, from bookings, jobs and made here',
      onMenu: HomeNav.openMenu == null ? null : () => HomeNav.openMenu!(context),
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: d == null
          ? null
          : [
              // create first, where it is seen without scrolling (founder, 2 Nov 2026)
              SvcTopButton('+ New bill', key: const ValueKey('new-bill'), onTap: _new),
              const SizedBox(height: 10),
              SvcSearch(hint: 'Search bill, customer or phone', fieldKey: const ValueKey('bill-search'), onChanged: (v) {
                _q = v;
                _load();
              }),
              const SizedBox(height: 12),
              if (open == null && !searching)
                // every pile, one below the other, each in its colour (founder, 2 Nov 2026, as the store's online orders wallet)
                for (final p in _piles) _pileCard(d, p)
              else ...[
                // the open pile on top (tap it to go back to every pile), then its bills in the pile's colour
                if (open != null) _pileCard(d, open, isOpen: true),
                if (open == null)
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Search results', style: inter(15, 700))),
                if (d.bills.isEmpty)
                  OrderCardBox(child: Text(switch (_pile) { 'due' => 'Nothing is due. Every bill is paid.', 'today' => 'No money taken today yet.', _ => 'No bills here.' }, style: inter(14, 400, color: kMuted))),
                for (final b in d.bills) billWalletCard(b, () => _open(b.id), colors: open?.$5),
              ],
            ],
    );
  }

  /// One pile: the edges of the bills behind peek above it; its name, what it holds, how many and how much. Tapping a closed pile opens
  /// it; tapping the open pile goes back to every pile.
  Widget _pileCard(BillListData d, (String, String, String, IconData, List<Color>) p, {bool isOpen = false}) {
    final (id, name, means, icon, colors) = p;
    final n = d.count(id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: WalletPile(
        key: ValueKey('pile-$id'),
        colors: colors,
        behind: isOpen ? 0 : (n - 1).clamp(0, 2),
        onTap: () => _openPile(isOpen ? null : id),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), shape: BoxShape.circle),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              onWallet(name, size: 16, weight: 700, alpha: 1),
              const SizedBox(height: 2),
              onWallet(_pileNote(d, id), size: 12.5),
              if (!isOpen) onWallet(means, size: 11.5, alpha: 0.75),
            ]),
          ),
          Text('$n', style: inter(24, 800, color: Colors.white)),
          const SizedBox(width: 6),
          Icon(isOpen ? LucideIcons.chevronUp : LucideIcons.chevronRight, size: 18, color: Colors.white),
        ]),
      ),
    );
  }
}

/// One bill: what it is for, lines, totals, payments; Collect (a bill made here), Open booking (a booking's bill), Send by WhatsApp, Print.
class BillDetailScreen extends StatefulWidget {
  const BillDetailScreen({super.key, required this.api, required this.id, this.onNavigate, this.openUrl, this.printer});
  final ServiceApi api;
  final String id;
  final ValueChanged<String>? onNavigate;
  final Future<bool> Function(Uri url)? openUrl;
  final Future<void> Function(BuildContext context, BillReceipt bill)? printer;
  @override
  State<BillDetailScreen> createState() => _BillDetailScreenState();
}

class _BillDetailScreenState extends State<BillDetailScreen> {
  BillView? _b;
  String? _error, _key;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await widget.api.billView(widget.id);
      if (mounted) setState(() => (_b = b, _error = null));
    } on ServiceApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the bill. Check the connection and try again.');
    }
  }

  Future<void> _collect() async {
    final b = _b!;
    final pay = await pickPayment(context, title: 'Collect ${svcRupees(b.due)}', amount: b.due);
    if (pay == null || !mounted) return;
    setState(() => _busy = true);
    _key ??= ServiceApi.newKey();
    try {
      final r = await widget.api.payBill(b.id, method: pay.$1, tendered: pay.$2, key: _key!);
      _key = null;
      if (!mounted) return;
      setState(() => _b = r);
      showToast(context, r.change > 0 ? '${svcRupees(b.due)} collected · give back ${svcRupees(r.change)}' : '${svcRupees(b.due)} collected.');
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.status < 500) _key = null;
    } catch (_) {
      if (mounted) showToast(context, 'Could not reach the server. Try again: you will not be charged twice.'); // keep the key
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _whatsapp() async {
    final b = _b!;
    var phone = b.customerPhone.replaceAll(RegExp(r'\D'), ''), name = b.customer;
    if (phone.length < 10) {
      final r = await askCartCustomer(context, name: name, title: 'Customer\'s WhatsApp number');
      if (r == null || !mounted) return;
      name = r.$1.trim();
      phone = r.$2.replaceAll(RegExp(r'\D'), '');
      if (phone.length < 10) return showToast(context, 'Add the customer\'s mobile number first.');
    }
    try {
      final link = await widget.api.billLink(b.id);
      final opened = await (widget.openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(
          whatsAppLink(phone, visitNote(business: HomeNav.storeName ?? 'us', name: name, link: link)));
      if (!opened && mounted) showToast(context, 'Could not open WhatsApp.');
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not make the bill link. Check the connection and try again.');
    }
  }

  BillReceipt _receipt(BillView b) => BillReceipt(
        store: HomeNav.storeName ?? '',
        billNo: b.displayNo,
        when: b.dateLabel,
        customer: b.customer,
        phone: b.customerPhone,
        payment: b.payments.map((p) => _method(p.s('method'))).toSet().join(' + '),
        lines: [for (final l in b.lines) (name: l.s('name'), qty: l.n('qty'), amount: l.n('amount'))],
        subtotal: b.subtotal,
        gst: b.gst,
        gstPct: b.gstPct,
        discount: b.discount,
        roundOff: b.roundOff,
        total: b.total,
        paid: b.paid,
      );

  @override
  Widget build(BuildContext context) {
    final b = _b;
    return ServicePage(
      title: b == null ? 'Bill' : 'Bill ${b.displayNo}',
      subtitle: b == null ? '' : b.dateLabel,
      error: _error,
      onRetry: _load,
      body: b == null ? null : _body(b),
    );
  }

  List<Widget> _body(BillView b) {
    final pct = b.gstPct.toStringAsFixed(b.gstPct % 1 == 0 ? 0 : 1);
    return [
      // the bill as a wallet pass (as in the store POS, after Google Wallet): what for, who, and the amount, in the bill's colour
      WalletCard(
        key: const ValueKey('bill-pass'),
        colors: billWalletColors(b.status),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: onWallet(b.title, size: 17, weight: 700, alpha: 1, maxLines: 2)),
            const SizedBox(width: 8),
            _walletPill(b.statusLabel),
          ]),
          const SizedBox(height: 6),
          onWallet([b.customer, if (b.customerPhone.isNotEmpty) svcPhone(b.customerPhone)].join(' · '), size: 13.5),
          if (b.address.isNotEmpty) ...[const SizedBox(height: 2), onWallet(b.address, size: 13, alpha: 0.8, maxLines: 2)],
          const SizedBox(height: 18),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: onWallet('Total', size: 12, alpha: 0.8)),
            Text(svcRupees(b.total), style: inter(28, 800, color: Colors.white)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: onWallet('Paid ${svcRupees(b.paid)}', size: 12.5)),
            if (b.due > 0 && b.status != 'cancelled') onWallet('Due ${svcRupees(b.due)}', size: 12.5, weight: 700, alpha: 1),
          ]),
        ]),
      ),
      const SizedBox(height: 10),
      SvcCard(title: 'Services', children: [for (final l in b.lines) SvcLine(l.s('name'), qty: '${l.n('qty')}×', amount: svcRupees(l.n('amount')))]),
      SvcCard(children: [
        KeyValue('Subtotal', svcRupees(b.subtotal), size: 14),
        if (b.discount > 0) KeyValue('Discount', '−${svcRupees(b.discount)}', size: 14, valueColor: kLink),
        if (b.gstPct > 0) KeyValue('GST ($pct%)', svcRupees(b.gst), size: 14),
        if (b.roundOff != 0) KeyValue('Round off', svcRupees(b.roundOff), size: 14),
        const Divider(height: 20, color: kLine),
        Row(children: [Expanded(child: Text('Total', style: inter(16, 700))), Text(svcRupees(b.total), style: inter(24, 800, color: kLink))]),
        const SizedBox(height: 8),
        KeyValue('Paid', svcRupees(b.paid), size: 14),
        KeyValue('Due', svcRupees(b.due), size: 14, valueColor: b.due > 0 ? kBadText : kInk),
      ]),
      if (b.payments.isNotEmpty)
        SvcCard(title: 'Payments', children: [for (final p in b.payments) SvcKV('${_method(p.s('method'))} · ${p.s('at_label')}', svcRupees(p.n('amount')))]),
      if (b.message.isNotEmpty) SvcCard(title: 'Message', children: [Text(b.message, style: inter(14, 400))]),
      const SizedBox(height: 4),
      if (b.canCollect) DarkCta(label: 'Collect ${svcRupees(b.due)}', busy: _busy, onPressed: _busy ? null : _collect),
      if (b.canOpenBooking && b.due > 0) ...[
        Text('This bill is from booking ${b.booking.s('display_no')}. Take payment from the booking, so the visit is closed too.', style: inter(13.5, 400, color: kMuted)),
        const SizedBox(height: 10),
      ],
      if (b.fromJob)
        LightCta(
          key: const ValueKey('open-job'),
          label: 'Open job ${b.job.s('display_no')}',
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => JobDetailScreen(api: widget.api, id: b.job.s('id'), onNavigate: widget.onNavigate)));
            if (mounted) _load();
          },
        ),
      if (b.canOpenBooking)
        LightCta(
          key: const ValueKey('open-booking'),
          label: 'Open booking ${b.booking.s('display_no')}',
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AppointmentDetailScreen(api: widget.api, id: b.booking.s('id'), onNavigate: widget.onNavigate)));
            if (mounted) _load();
          },
        ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: LightCta(key: const ValueKey('bill-whatsapp'), label: 'Send by WhatsApp', onPressed: _whatsapp)),
        const SizedBox(width: 10),
        Expanded(child: LightCta(key: const ValueKey('bill-print'), label: 'Print', onPressed: () => (widget.printer ?? printBill)(context, _receipt(b)))),
      ]),
    ];
  }
}

/// New bill: who it is for, services from the catalogue with quantities, a discount in rupees or percent, a message. Saved unpaid; the bill
/// then opens to collect or send. Tax is added by the server.
class NewBillScreen extends StatefulWidget {
  const NewBillScreen({super.key, required this.api});
  final ServiceApi api;
  @override
  State<NewBillScreen> createState() => _NewBillScreenState();
}

class _NewBillScreenState extends State<NewBillScreen> {
  final _name = TextEditingController(), _phone = TextEditingController(), _address = TextEditingController();
  final _title = TextEditingController(), _message = TextEditingController(), _discount = TextEditingController();
  bool _percent = false;
  Catalogue? _catalogue;
  String? _error, _key;
  bool _busy = false;
  final _qty = <String, int>{}; // service id -> quantity
  int _step = 0; // in steps, as every Service POS form (founder, 4 Nov 2026)
  static const _steps = ['Billed to', 'Services', 'Discount', 'Message'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _title, _message, _discount]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = await widget.api.catalogue();
      if (mounted) setState(() => (_catalogue = c, _error = null));
    } on ServiceApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load your services. Check the connection and try again.');
    }
  }

  List<ServiceOption> get _services => _catalogue?.services ?? const [];

  num get _gross => _services.fold<num>(0, (s, o) => s + o.price * (_qty[o.id] ?? 0));

  num get _off {
    final v = num.tryParse(_discount.text.trim()) ?? 0;
    return _percent ? (_gross * v / 100) : v;
  }

  /// What [step] is missing, or null. Next checks its own step; Save checks every step and goes back to the first one short (4 Nov 2026).
  String? _missing(int step) {
    final phone = _phone.text.replaceAll(RegExp(r'\D'), '');
    final d = num.tryParse(_discount.text.trim());
    return switch (step) {
      0 when _name.text.trim().isEmpty => 'Enter the customer\'s name.',
      0 when phone.isNotEmpty && phone.length < 10 => 'Enter a 10-digit mobile number.',
      1 when !_services.any((o) => (_qty[o.id] ?? 0) > 0) => 'Add at least one service.',
      2 when _discount.text.trim().isNotEmpty && (d == null || d < 0 || (_percent && d > 100)) => 'Check the discount.',
      2 when _off > _gross => 'The discount is more than the bill.',
      _ => null,
    };
  }

  bool _canAdvance(int step) {
    final m = _missing(step);
    if (m != null) showToast(context, m);
    return m == null;
  }

  Future<void> _save() async {
    for (var i = 0; i < _steps.length; i++) {
      final m = _missing(i);
      if (m == null) continue;
      if (i != _step) setState(() => _step = i);
      return showToast(context, m);
    }
    final name = _name.text.trim();
    final phone = _phone.text.replaceAll(RegExp(r'\D'), '');
    final lines = [for (final o in _services) if ((_qty[o.id] ?? 0) > 0) {'menu_item_id': o.id, 'qty': _qty[o.id]}];
    final d = num.tryParse(_discount.text.trim());
    setState(() => _busy = true);
    _key ??= ServiceApi.newKey();
    try {
      final b = await widget.api.createBill(
        key: _key!,
        customerName: name,
        customerPhone: phone,
        address: _address.text,
        title: _title.text,
        message: _message.text,
        lines: lines,
        discount: !_percent && (d ?? 0) > 0 ? d : null,
        discountPct: _percent && (d ?? 0) > 0 ? d : null,
      );
      if (mounted) Navigator.of(context).pop(b);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.status < 500) _key = null;
    } catch (_) {
      if (mounted) showToast(context, 'Could not reach the server. Try again: the bill will not be made twice.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String label, TextEditingController c, String key, {TextInputType? keyboard, int lines = 1, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          key: ValueKey(key),
          controller: c,
          keyboardType: keyboard,
          inputFormatters: numberOnly(keyboard),
          minLines: lines,
          maxLines: lines,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: label, hintText: hint, filled: true, fillColor: Colors.white, isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine))),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // the catalogue loading or failed: the plain page with its spinner or Try again; then the bill in steps (4 Nov 2026)
    if (_catalogue == null) return ServicePage(title: 'New bill', subtitle: 'For work not booked in the calendar', error: _error, onRetry: _load);
    final last = _step == _steps.length - 1;
    return StepFormPage(
      title: 'New bill',
      keyPrefix: 'bill',
      steps: _steps,
      step: _step,
      onStep: (i) => setState(() => _step = i),
      canAdvance: _canAdvance,
      lastLine: 'Last step: save the bill',
      body: _stepBody(),
      // the running total above Next on every step, so a quantity or discount shows what it does at once
      above: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_off > 0) ...[KeyValue('Services', svcRupees(_gross), size: 14), KeyValue('Discount', '−${svcRupees(_off)}', size: 14, valueColor: kLink)],
        Row(children: [
          Expanded(child: Text('Before tax', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(16, 700))),
          Text(svcRupees((_gross - _off).clamp(0, double.infinity)), style: inter(22, 800)),
        ]),
        if (last) ...[const SizedBox(height: 4), Text('Tax, if any, is added when the bill is saved.', style: inter(12.5, 400, color: kMuted))],
      ]),
      finish: DarkCta(label: 'Save bill', busy: _busy, onPressed: _busy ? null : _save),
    );
  }

  List<Widget> _stepBody() => switch (_step) {
        0 => [
            Text('For work not booked in the calendar', style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 10),
            SvcCard(title: 'Billed to', children: [
              _field('Customer name', _name, 'bill-name'),
              _field('Mobile number', _phone, 'bill-phone', keyboard: TextInputType.phone),
              _field('Address (optional)', _address, 'bill-address'),
            ]),
          ],
        1 => [
            SvcCard(title: 'Services', children: [
              _field('Title (optional)', _title, 'bill-title', hint: 'For services done'),
              if (_services.isEmpty) Text('Add services in Catalogue first.', style: inter(14, 400, color: kMuted)),
              for (final o in _services) _serviceRow(o),
            ]),
          ],
        2 => [
            SvcCard(title: 'Discount', children: [
              Wrap(spacing: 8, children: [
                ModeChip('₹ off', key: const ValueKey('disc-rupees'), selected: !_percent, onTap: () => setState(() => _percent = false)),
                ModeChip('% off', key: const ValueKey('disc-percent'), selected: _percent, onTap: () => setState(() => _percent = true)),
              ]),
              const SizedBox(height: 10),
              _field(_percent ? 'Discount (%)' : 'Discount (₹)', _discount, 'bill-discount', keyboard: TextInputType.number),
            ]),
          ],
        _ => [SvcCard(title: 'Message to the customer', children: [_field('Message (optional)', _message, 'bill-message', lines: 3, hint: 'Thank you for your business.')])],
      };

  Widget _serviceRow(ServiceOption o) {
    final q = _qty[o.id] ?? 0;
    return Container(
      key: ValueKey('svc-${o.id}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(o.name, style: inter(14.5, 600)),
            Text(svcRupees(o.price), style: inter(13, 400, color: kMuted)),
          ]),
        ),
        IconButton(key: ValueKey('less-${o.id}'), onPressed: q == 0 ? null : () => setState(() => _qty[o.id] = q - 1), icon: const Icon(LucideIcons.minus, size: 18)),
        SizedBox(width: 24, child: Text('$q', textAlign: TextAlign.center, style: inter(15, 700))),
        IconButton(key: ValueKey('more-${o.id}'), onPressed: q >= 99 ? null : () => setState(() => _qty[o.id] = q + 1), icon: const Icon(LucideIcons.plus, size: 18)),
      ]),
    );
  }
}
