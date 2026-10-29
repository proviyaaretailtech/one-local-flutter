import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart' show rupees;
import '../ui/mobile_input.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_widgets.dart';

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
String _dateLabel(DateTime d) => '${_days[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]} ${d.year}';
String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Figma "Appointment Booking". Choices only; the price, GST, advance, free times and the booking itself all come from the server.
/// Pops the new [AppointmentView] when the booking is made.
class ServiceBookingScreen extends StatefulWidget {
  const ServiceBookingScreen({super.key, this.api, this.date, this.business = '', this.location = '', this.initials});
  final ServiceApi? api;
  final DateTime? date;
  final String business, location;
  final String? initials;
  @override
  State<ServiceBookingScreen> createState() => _ServiceBookingScreenState();
}

class _ServiceBookingScreenState extends State<ServiceBookingScreen> {
  late final ServiceApi _api = widget.api ?? ServiceApi();
  late DateTime _date = widget.date ?? DateTime.now();
  Catalogue? _cat;
  String? _error;
  String _name = '', _phone = '';
  ServiceOption? _service;
  final _addons = <String>{};
  ProviderOption? _provider;
  Map<String, dynamic>? _slot;
  Map<String, dynamic>? _resource;
  ServiceQuote? _quote;
  String? _quoteError;
  bool _policyShown = true;
  bool _busy = false;
  String _address = '', _access = '';
  List<EntitlementView> _ents = const [];
  EntitlementView? _ent;
  String? _key; // one key per booking intent: kept for a retry, dropped when anything the person chose changes
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _loadCatalogue();
  }

  Future<void> _loadCatalogue() async {
    try {
      final c = await _api.catalogue();
      if (mounted) setState(() => _cat = c);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _changed() {
    _key = null;
    setState(() {});
  }

  Future<void> _requote() async {
    final s = _service;
    if (s == null) return;
    final mine = ++_seq;
    try {
      final q = await _api.quote(serviceId: s.id, addonIds: _addons.toList(), staffId: _provider?.id);
      if (!mounted || mine != _seq) return;
      setState(() {
        _quote = q;
        _quoteError = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _quoteError = e.toString());
    }
  }

  Future<void> _pickCustomer() async {
    final name = TextEditingController(text: _name), phone = TextEditingController(text: _phone);
    final ok = await showOrderSheet<bool>(context, title: 'Customer', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(key: const ValueKey('customer-name'), controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Customer name')),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('customer-phone'),
            controller: phone,
            keyboardType: TextInputType.phone,
            inputFormatters: mobileFormatters,
            decoration: const InputDecoration(hintText: 'Mobile number', prefixText: kMobilePrefix),
          ),
          const SizedBox(height: 16),
          DarkCta(label: 'Done', onPressed: () => Navigator.pop(ctx, true)),
        ]));
    if (ok != true) return;
    _name = name.text.trim();
    _phone = phone.text.replaceAll(RegExp(r'\D'), '');
    if (_phone.length > 10 && _phone.startsWith('91')) _phone = _phone.substring(2);
    _ent = null;
    _ents = const [];
    _changed();
    if (_phone.length == 10) {
      try {
        final e = await _api.entitlementsFor(_phone);
        if (mounted) setState(() => _ents = e);
      } catch (_) {
        // the booking still works without a package; the server checks any package again
      }
    }
  }

  Future<void> _pickEntitlement() async {
    final picked = await showOrderSheet<String>(context, title: 'Package or membership', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(contentPadding: EdgeInsets.zero, title: Text('Do not use one', style: inter(15, _ent == null ? 700 : 500)), onTap: () => Navigator.pop(ctx, '')),
          for (final e in _ents)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.name, style: inter(15, e.id == _ent?.id ? 700 : 500)),
              subtitle: Text(e.credits.map((c) => '${c.s('name')} ${c.i('left')} left').join(' · '), style: inter(12.5, 400, color: kMuted)),
              onTap: () => Navigator.pop(ctx, e.id),
            ),
        ]));
    if (picked == null) return;
    _ent = picked.isEmpty ? null : _ents.firstWhere((e) => e.id == picked);
    _changed();
  }

  Future<void> _pickAddress() async {
    final a = await askText(context, 'Customer address', initial: _address, hint: 'Flat, building, area, PIN', lines: 2);
    if (a == null || !mounted) return;
    final acc = await askText(context, 'Access (optional)', initial: _access, hint: 'Gate 2 · Lift available', action: 'Done');
    _address = a;
    _access = acc ?? '';
    _changed();
  }

  Future<void> _pickService() async {
    final c = _cat;
    if (c == null) return;
    final picked = await showOrderSheet<ServiceOption>(context, title: 'Service', body: (ctx) {
      if (c.services.isEmpty) return Text('No services take bookings yet.', style: inter(14, 400, color: kMuted));
      return ListView(shrinkWrap: true, children: [
        for (final s in c.services)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.name, style: inter(15, s.id == _service?.id ? 700 : 500)),
            subtitle: Text('${s.durationMin} min', style: inter(12.5, 400, color: kMuted)),
            trailing: Text(rupees(s.price), style: inter(14, 700)),
            onTap: () => Navigator.pop(ctx, s),
          ),
      ]);
    });
    if (picked == null) return;
    _service = picked;
    _addons.clear();
    if (_provider != null && !picked.staffIds.contains(_provider!.id)) _provider = null;
    _slot = null;
    _quote = null;
    _changed();
    _requote();
  }

  Future<void> _pickProvider() async {
    final c = _cat, s = _service;
    if (c == null) return;
    if (s == null) {
      showToast(context, 'Choose a service first.');
      return;
    }
    final list = c.providers.where((p) => s.staffIds.contains(p.id)).toList();
    final picked = await showOrderSheet<ProviderOption>(context, title: 'Provider', body: (ctx) {
      if (list.isEmpty) return Text('No provider performs this service yet.', style: inter(14, 400, color: kMuted));
      return ListView(shrinkWrap: true, children: [
        for (final p in list)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(p.name, style: inter(15, p.id == _provider?.id ? 700 : 500)),
            subtitle: p.title.isEmpty ? null : Text(p.title, style: inter(12.5, 400, color: kMuted)),
            onTap: () => Navigator.pop(ctx, p),
          ),
      ]);
    });
    if (picked == null) return;
    _provider = picked;
    _slot = null;
    _resource = null;
    _changed();
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final picked = await showDatePicker(context: context, initialDate: _date.isBefore(today) ? today : _date, firstDate: DateTime(today.year, today.month, today.day), lastDate: today.add(const Duration(days: 120)));
    if (picked == null) return;
    _date = picked;
    _slot = null;
    _changed();
  }

  Future<void> _pickTime() async {
    final s = _service, p = _provider;
    if (s == null || p == null) {
      showToast(context, 'Choose a service and a provider first.');
      return;
    }
    final picked = await showOrderSheet<Map<String, dynamic>>(context, title: 'Time', body: (ctx) => _SlotList(api: _api, date: _iso(_date), service: s, addonIds: _addons.toList(), provider: p));
    if (picked == null) return;
    _slot = picked;
    _changed();
  }

  Future<void> _pickResource() async {
    final list = _cat?.resources ?? const [];
    if (list.isEmpty) return;
    final picked = await showOrderSheet<Map<String, dynamic>>(context, title: 'Chair or room', body: (ctx) => ListView(shrinkWrap: true, children: [
          ListTile(contentPadding: EdgeInsets.zero, title: Text('No chair or room', style: inter(15, 400)), onTap: () => Navigator.pop(ctx, <String, dynamic>{})),
          for (final r in list) ListTile(contentPadding: EdgeInsets.zero, title: Text('${r['name']}', style: inter(15, 500)), onTap: () => Navigator.pop(ctx, r)),
        ]));
    if (picked == null) return;
    _resource = picked.isEmpty ? null : picked;
    _changed();
  }

  bool get _ready => _name.isNotEmpty && _service != null && _provider != null && _slot != null && _quote != null;

  Future<void> _confirm() async {
    if (!_ready) {
      showToast(context, _name.isEmpty ? 'Add the customer first.' : (_service == null ? 'Choose a service.' : (_provider == null ? 'Choose a provider.' : 'Choose a date and time.')));
      return;
    }
    if (_service!.fulfilment == 'on_location' && _address.trim().isEmpty) {
      showToast(context, 'Add the customer\'s address for an on-location job.');
      return;
    }
    if (_phone.isNotEmpty && _phone.length != 10) {
      showToast(context, 'Enter a 10-digit mobile number.');
      return;
    }
    final q = _quote!;
    String? method;
    if (q.deposit > 0 && _ent == null) {
      final choice = await showOrderSheet<String>(context, title: 'Advance ${rupees(q.deposit)}', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (id, label) in const [('cash', 'Cash'), ('card', 'Card'), ('upi', 'UPI / QR')]) ...[LightCta(label: 'Take $label', onPressed: () => Navigator.pop(ctx, id)), const SizedBox(height: 8)],
            UnderLink('Collect the advance later', onTap: () => Navigator.pop(ctx, 'later')),
          ]));
      if (choice == null) return;
      method = choice == 'later' ? null : choice;
    }
    setState(() => _busy = true);
    _key ??= ServiceApi.newKey();
    try {
      final booked = await _api.book(
        key: _key!,
        customerName: _name,
        customerPhone: _phone,
        serviceId: _service!.id,
        addonIds: _addons.toList(),
        staffId: _provider!.id,
        resourceId: _resource?['id'] as String?,
        startsAt: '${_slot!['starts_at']}',
        depositMethod: method,
        entitlementId: _ent?.id,
        serviceAddress: _address,
        accessNote: _access,
      );
      if (!mounted) return;
      showToast(context, '${booked.displayNo} booked.');
      if (booked.arrivalCode != null) {
        await showOrderSheet<void>(context, title: 'Arrival code ${booked.arrivalCode}', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Share this code with ${booked.customer}. The provider asks for it on arrival. It is shown only now.', style: inter(14, 400, color: kMuted, height: 1.4)),
              const SizedBox(height: 14),
              DarkCta(label: 'Done', onPressed: () => Navigator.pop(ctx)),
            ]));
        if (!mounted) return;
      }
      Navigator.of(context).pop(booked);
    } on ServiceApiException catch (e) {
      if (mounted) {
        showToast(context, e.message);
        if (e.status == 409) _slot = null; // the time was taken: choose again
        if (e.status < 500) _key = null; // a refusal is final; after a server fault the same key is kept so the retry cannot book twice
      }
    } catch (e) {
      if (mounted) showToast(context, e.toString()); // keep the key: a retry of the same tap must not book twice
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _quote;
    final s = _service;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        ServiceTopBar(business: widget.business, initials: widget.initials, onBack: () => Navigator.maybePop(context)),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 16), children: [
            Text('Appointment Booking', style: inter(30, 700, height: 1.15)),
            const SizedBox(height: 8),
            Text(s?.fulfilment == 'on_location' ? 'New job · Provider visits the customer' : 'New appointment · Customer visits the studio', style: inter(13.5, 400, color: kMuted)),
            if (_error != null) ...[const SizedBox(height: 16), OrderCardBox(child: Text(_error!, style: inter(13.5, 500)))],
            const SizedBox(height: 22),
            _heading('Customer & service'),
            _field('Customer', _name.isEmpty ? 'Add customer' : (_phone.isEmpty ? _name : '$_name · +91 $_phone'), _name.isEmpty, _pickCustomer, key: 'customer'),
            _field('Service', s == null ? 'Choose a service' : '${s.name} · ${rupees(s.price)} · ${s.durationMin} min', s == null, _pickService, key: 'service'),
            if (_ents.isNotEmpty) _field('Package', _ent == null ? 'Do not use a package' : _ent!.name, _ent == null, _pickEntitlement, key: 'package'),
            _field('Provider', _provider == null ? 'Choose a provider' : (_provider!.title.isEmpty ? _provider!.name : '${_provider!.name} · ${_provider!.title}'), _provider == null, _pickProvider, key: 'provider'),
            const SizedBox(height: 6),
            _heading('Schedule & location'),
            _field('Date', _dateLabel(_date), false, _pickDate, key: 'date'),
            _field('Time', _slot == null ? 'Choose a time' : '${_slot!['range_label']}', _slot == null, _pickTime, key: 'time'),
            if (s?.fulfilment == 'on_location')
              _field('Customer address', _address.isEmpty ? 'Add the address' : [_address, if (_access.isNotEmpty) _access].join(' · '), _address.isEmpty, _pickAddress, key: 'address')
            else
              _field('Business location', _locationText(), false, (_cat?.resources.isEmpty ?? true) ? null : _pickResource, key: 'location'),
            if (_ent != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${_ent!.name} credit is applied when the booking is made; the advance is then taken only on what is left.', style: inter(12.5, 400, color: kMuted))),
            if (s != null && s.addons.isNotEmpty) ...[const SizedBox(height: 4), _addonsCard(s, q)],
            if (q != null) ...[const SizedBox(height: 14), _summary(q)] else if (_quoteError != null) ...[const SizedBox(height: 14), OrderCardBox(child: Text(_quoteError!, style: inter(13.5, 500)))],
            if (_policyShown) ...[const SizedBox(height: 14), _policy(q?.freeCancelHours ?? _cat?.freeCancelHours ?? 12, q?.deposit ?? _cat?.deposit ?? 0)],
            const SizedBox(height: 16),
            DarkCta(label: q == null ? 'Confirm booking' : (q.deposit > 0 ? 'Confirm booking · ${rupees(q.deposit)} advance' : 'Confirm booking'), busy: _busy, onPressed: _confirm),
          ]),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => id == 'bill' ? null : Navigator.of(context).maybePop()),
      ]),
    );
  }

  String _locationText() {
    final parts = [if (widget.location.isNotEmpty) widget.location, if (_resource != null) '${_resource!['name']}'];
    return parts.isEmpty ? 'Studio' : parts.join(' · ');
  }

  Widget _heading(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(children: [
          Expanded(child: Text(t, style: inter(17, 700))),
          Container(width: 28, height: 28, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: kLine))),
        ]),
      );

  Widget _field(String label, String value, bool placeholder, VoidCallback? onTap, {required String key}) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(14.5, 700)),
          const SizedBox(height: 8),
          Semantics(
            button: onTap != null,
            label: '$label: $value',
            child: InkWell(
              key: ValueKey('field-$key'),
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: Container(
                height: 54,
                width: double.infinity,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(color: const Color(0xFFF7F8F6), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFE3E8E3))),
                child: ExcludeSemantics(child: Text(value, overflow: TextOverflow.ellipsis, style: inter(15, 400, color: placeholder ? kMuted : kInk))),
              ),
            ),
          ),
        ]),
      );

  Widget _addonsCard(ServiceOption s, ServiceQuote? q) => OrderCardBox(
        radius: 18,
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Add-ons', style: inter(17, 700)),
          const SizedBox(height: 12),
          for (final a in s.addons)
            InkWell(
              onTap: () {
                final id = '${a['id']}';
                _addons.contains(id) ? _addons.remove(id) : _addons.add(id);
                _slot = null;
                _changed();
                _requote();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(color: _addons.contains('${a['id']}') ? kCheck : Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: _addons.contains('${a['id']}') ? kCheck : kLine, width: 1.5)),
                    child: _addons.contains('${a['id']}') ? const Icon(LucideIcons.check, size: 16, color: kInk) : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text('${a['name']} · ${rupees(num.tryParse('${a['price']}') ?? 0)} · +${a['duration_min']} min', style: inter(14.5, 400))),
                ]),
              ),
            ),
          if (q != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              SizedBox(width: 130, child: Text('Total duration', style: inter(13.5, 400, color: kMuted))),
              Expanded(child: Text('${q.durationMin} min + ${q.bufferMin} min buffer', style: inter(14.5, 600))),
            ]),
          ],
        ]),
      );

  Widget _summary(ServiceQuote q) => OrderCardBox(
        radius: 18,
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Payment summary', style: inter(17, 700)),
          const SizedBox(height: 10),
          for (final l in q.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                const Dot(),
                const SizedBox(width: 8),
                Expanded(child: Text('${l['name']}', style: inter(14, 500))),
                Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: kLimeSoft, borderRadius: BorderRadius.circular(999)), child: Text('${l['qty']}×', style: inter(11, 700, color: kGreenText))),
                const SizedBox(width: 16),
                Text(rupees(num.tryParse('${l['amount']}') ?? 0), style: inter(14, 700)),
              ]),
            ),
          const SizedBox(height: 8),
          _line('Subtotal', rupees(q.subtotal)),
          _line('GST · ${q.gstPct == q.gstPct.roundToDouble() ? q.gstPct.toInt() : q.gstPct}%', rupees(q.gst)),
          if (q.roundOff != 0) _line('Round off', rupees(q.roundOff)),
          if (q.deposit > 0) ...[_line('Advance now', rupees(q.deposit)), _line('Due at studio', rupees(q.dueAtStudio))],
          const Divider(height: 22, color: kLine),
          Row(children: [
            Expanded(child: Text('Total', style: inter(14.5, 700))),
            Text(rupees(q.total), style: inter(22, 800)),
          ]),
        ]),
      );

  Widget _line(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 130, child: Text(k, style: inter(13.5, 400, color: kMuted))),
          Text(v, style: inter(14.5, 700)),
        ]),
      );

  Widget _policy(int hours, num deposit) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0xFFF0F6FF), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF93C5FD))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(LucideIcons.info, size: 20, color: Color(0xFF3B82F6)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Cancellation policy', style: inter(14.5, 600)),
              const SizedBox(height: 4),
              Text(deposit > 0 ? 'Free until $hours hours before. Later cancellations forfeit the ${rupees(deposit)} deposit.' : 'Free until $hours hours before.', style: inter(12.5, 400, color: kMuted, height: 1.4)),
            ]),
          ),
          Semantics(button: true, label: 'Dismiss', child: InkWell(key: const ValueKey('dismiss-policy'), onTap: () => setState(() => _policyShown = false), child: const Icon(LucideIcons.x, size: 18, color: kMuted))),
        ]),
      );
}

/// Dot used in the payment summary.
class Dot extends StatelessWidget {
  const Dot({super.key});
  @override
  Widget build(BuildContext context) => Container(width: 6, height: 6, decoration: const BoxDecoration(color: kLink, shape: BoxShape.circle));
}

/// Free start times of one provider on one day, from the server. Returns the slot tapped.
class _SlotList extends StatefulWidget {
  const _SlotList({required this.api, required this.date, required this.service, required this.addonIds, required this.provider});
  final ServiceApi api;
  final String date;
  final ServiceOption service;
  final List<String> addonIds;
  final ProviderOption provider;
  @override
  State<_SlotList> createState() => _SlotListState();
}

class _SlotListState extends State<_SlotList> {
  List<SlotProvider>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.slots(date: widget.date, serviceId: widget.service.id, addonIds: widget.addonIds, staffId: widget.provider.id).then((d) {
      if (mounted) setState(() => _data = d);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!, style: inter(14, 400, color: kMuted));
    final d = _data;
    if (d == null) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: kGreenText)));
    final slots = d.expand((p) => p.slots).toList();
    if (slots.isEmpty) return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text('No free time that day. Try another date.', style: inter(14, 400, color: kMuted)));
    return SingleChildScrollView(
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in slots) SmallPill('${s['label']}', onTap: () => Navigator.pop(context, s)),
      ]),
    );
  }
}
