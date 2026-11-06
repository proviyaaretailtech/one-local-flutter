import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart' show rupees;
import '../ui/mobile_input.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_widgets.dart';
import 'step_form.dart';

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
  // a listing booked by the court (5 Nov 2026): which court, which part (null: the full court); the times reload after a clash
  String? _unit, _part;
  int _timesEpoch = 0;
  ServiceQuote? _quote;
  String? _quoteError;
  bool _policyShown = true;
  bool _busy = false;
  String _address = '', _access = '';
  // who is coming (4 Nov 2026): asked when the listing has rules or limits about it, or prices per person
  final Map<String, int> _who = {'women': 0, 'men': 0, 'seniors': 0, 'teens': 0, 'kids': 0, 'under8': 0};
  String? _group;
  static const _whoRows = [
    ('women', 'Women', '18 to 59'),
    ('men', 'Men', '18 to 59'),
    ('seniors', 'Seniors', '60 and above'),
    ('teens', 'Teens', '12 to 17'),
    ('kids', 'Children', '8 to 11'),
    ('under8', 'Children', 'under 8'),
  ];

  int get _people => _who.values.fold(0, (a, b) => a + b);

  /// Who is coming, as the server reads it; null until anyone is added.
  Map<String, Object?>? get _party => _people == 0
      ? null
      : {
          'group': ?_group,
          'guests': [
            for (var i = 0; i < _who['women']!; i++) {'g': 'woman', 'a': '18_59'},
            for (var i = 0; i < _who['men']!; i++) {'g': 'man', 'a': '18_59'},
            for (var i = 0; i < _who['seniors']!; i++) {'g': 'any', 'a': '60_plus'},
            for (var i = 0; i < _who['teens']!; i++) {'g': 'any', 'a': '12_17'},
            for (var i = 0; i < _who['kids']!; i++) {'g': 'any', 'a': '8_11'},
            for (var i = 0; i < _who['under8']!; i++) {'g': 'any', 'a': 'under_8'},
          ],
        };
  List<EntitlementView> _ents = const [];
  EntitlementView? _ent;
  String? _key; // one key per booking intent: kept for a retry, dropped when anything the person chose changes
  int _seq = 0;
  int _step = 0;

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
      final q = await _api.quote(serviceId: s.id, addonIds: _addons.toList(), staffId: _provider?.id, party: _party, startsAt: _slot == null ? null : '${_slot!['starts_at']}', unit: _unit, part: _part);
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
    if (picked.byUnit || (_provider != null && !picked.staffIds.contains(_provider!.id))) _provider = null;
    _slot = null;
    _unit = null;
    _part = null;
    if (picked.byUnit) _resource = null;
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
    _requote(); // the provider is now chosen after the add-ons (steps, 4 Nov 2026): price again with them
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
    _requote(); // the time can change the price (peak, weekend) and which rules fit
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

  bool get _ready => _name.isNotEmpty && _service != null && (_provider != null || _service!.byUnit) && _slot != null && _quote != null;

  /// A court's time was tapped: the court stays if it is free then, else the first free one. The price follows.
  void _pickUnitTime(Map<String, dynamic> slot) {
    final free = ((slot['units'] as List?) ?? const []).map((e) => '$e').toList();
    _slot = slot;
    if (!free.contains(_unit)) _unit = free.firstOrNull;
    _changed();
    _requote();
  }

  void _pickPart(String? part) {
    _part = part;
    _slot = null;
    _unit = null;
    _changed();
    _requote();
  }

  Future<void> _confirm() async {
    // something missing on an earlier step: open that step, then say what (4 Nov 2026)
    for (var i = 0; i < 3; i++) {
      final why = _missing(i);
      if (why == null) continue;
      setState(() => _step = i);
      showToast(context, why);
      return;
    }
    if (!_ready) {
      showToast(context, 'The price is still loading. Try again.');
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
        staffId: _provider?.id,
        resourceId: _resource?['id'] as String?,
        unit: _unit,
        part: _part,
        startsAt: '${_slot!['starts_at']}',
        depositMethod: method,
        entitlementId: _ent?.id,
        serviceAddress: _address,
        accessNote: _access,
        party: _party,
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
        if (e.status == 409) {
          _slot = null; // the time was taken: choose again on the Time step
          _unit = null;
          _timesEpoch++;
          _step = 2;
        }
        if (e.status < 500) _key = null; // a refusal is final; after a server fault the same key is kept so the retry cannot book twice
      }
    } catch (e) {
      if (mounted) showToast(context, e.toString()); // keep the key: a retry of the same tap must not book twice
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // The booking in steps like every Service POS form (founder, 4 Nov 2026): who, what, when, then the server's price and Confirm.
  static const _steps = ['Customer', 'Service', 'Time', 'Review and book'];

  /// Why Next must wait on [step], or null when it can go on. The same checks as Confirm, step by step.
  String? _missing(int step) => switch (step) {
        0 => _name.isEmpty ? 'Add the customer first.' : (_phone.isNotEmpty && _phone.length != 10 ? 'Enter a 10-digit mobile number.' : null),
        1 => _service == null
            ? 'Choose a service.'
            : (_quote?.partyAsks == true && _people == 0 ? 'Say who is coming.' : _quote?.notAllowed),
        2 => _service?.byUnit == true
            ? (_slot == null ? 'Choose a date and time.' : (_unit == null ? 'Choose a ${_service!.unitWord}.' : null))
            : _provider == null
            ? 'Choose a provider.'
            : (_slot == null ? 'Choose a date and time.' : (_service?.fulfilment == 'on_location' && _address.trim().isEmpty ? 'Add the customer\'s address for an on-location job.' : null)),
        _ => null,
      };

  bool _canAdvance(int step) {
    final why = _missing(step);
    if (why != null) showToast(context, why);
    return why == null;
  }

  @override
  Widget build(BuildContext context) {
    final q = _quote;
    return StepFormPage(
      title: widget.business.isEmpty ? 'New booking' : 'New booking · ${widget.business}',
      keyPrefix: 'book',
      steps: _steps,
      step: _step,
      onStep: (i) => setState(() => _step = i),
      canAdvance: _canAdvance,
      lastLine: 'Last step: review and book',
      body: _stepBody(),
      above: q == null
          ? null
          : Row(children: [
              Expanded(child: Text(q.deposit > 0 ? 'Advance ${rupees(q.deposit)} · rest at the studio' : 'Pay at the studio', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 500, color: kMuted))),
              const SizedBox(width: 8),
              Text(rupees(q.total), key: const ValueKey('book-total'), style: inter(18, 800)),
            ]),
      finish: DarkCta(key: const ValueKey('book-confirm'), label: q == null ? 'Confirm booking' : (q.deposit > 0 ? 'Confirm booking · ${rupees(q.deposit)} advance' : 'Confirm booking'), busy: _busy, onPressed: _confirm),
    );
  }

  List<Widget> _stepBody() {
    final q = _quote;
    final s = _service;
    return switch (_step) {
      0 => [
          Text(s?.fulfilment == 'on_location' ? 'New job · Provider visits the customer' : 'New appointment · Customer visits the studio', style: inter(13.5, 400, color: kMuted)),
          if (_error != null) ...[const SizedBox(height: 16), OrderCardBox(child: Text(_error!, style: inter(13.5, 500)))],
          const SizedBox(height: 18),
          _field('Customer', _name.isEmpty ? 'Add customer' : (_phone.isEmpty ? _name : '$_name · +91 $_phone'), _name.isEmpty, _pickCustomer, key: 'customer'),
        ],
      1 => [
          const SizedBox(height: 10),
          _field('Service', s == null ? 'Choose a service' : '${s.name} · ${rupees(s.price)} · ${s.durationMin} min', s == null, _pickService, key: 'service'),
          if (_ents.isNotEmpty) _field('Package', _ent == null ? 'Do not use a package' : _ent!.name, _ent == null, _pickEntitlement, key: 'package'),
          if (_ent != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${_ent!.name} credit is applied when the booking is made; the advance is then taken only on what is left.', style: inter(12.5, 400, color: kMuted))),
          if (s != null && s.parts.isNotEmpty) ...[const SizedBox(height: 4), _partCard(s)],
          if (s != null && s.addons.isNotEmpty) ...[const SizedBox(height: 4), _addonsCard(s, q)],
          if (q != null && q.partyAsks) ...[const SizedBox(height: 4), _whoCard(q)],
        ],
      2 when s?.byUnit == true => [
          const SizedBox(height: 10),
          _field('Date', _dateLabel(_date), false, _pickDate, key: 'date'),
          _UnitTimes(
            key: ValueKey('unit-times-${s!.id}-${_iso(_date)}-$_part-$_timesEpoch'),
            api: _api,
            date: _iso(_date),
            service: s,
            addonIds: _addons.toList(),
            part: _part,
            slot: _slot,
            unit: _unit,
            onTime: _pickUnitTime,
            onUnit: (u) {
              _unit = u;
              _changed();
              _requote();
            },
          ),
          const SizedBox(height: 12),
          _field('Business location', _locationText(), false, null, key: 'location'),
        ],
      2 => [
          const SizedBox(height: 10),
          _field('Provider', _provider == null ? 'Choose a provider' : (_provider!.title.isEmpty ? _provider!.name : '${_provider!.name} · ${_provider!.title}'), _provider == null, _pickProvider, key: 'provider'),
          _field('Date', _dateLabel(_date), false, _pickDate, key: 'date'),
          _field('Time', _slot == null ? 'Choose a time' : '${_slot!['range_label']}', _slot == null, _pickTime, key: 'time'),
          if (s?.fulfilment == 'on_location')
            _field('Customer address', _address.isEmpty ? 'Add the address' : [_address, if (_access.isNotEmpty) _access].join(' · '), _address.isEmpty, _pickAddress, key: 'address')
          else
            _field('Business location', _locationText(), false, (_cat?.resources.isEmpty ?? true) ? null : _pickResource, key: 'location'),
        ],
      _ => [
          const SizedBox(height: 10),
          _recap(),
          if (q?.notAllowed != null) ...[const SizedBox(height: 10), _refusal(q!.notAllowed!)],
          if (q?.needsApproval != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('Needs your approval: ${q!.needsApproval}. It is noted on the booking.', style: inter(12.5, 500, color: kMuted))),
          if (q != null) ...[const SizedBox(height: 14), _summary(q)] else if (_quoteError != null) ...[const SizedBox(height: 14), OrderCardBox(child: Text(_quoteError!, style: inter(13.5, 500)))],
          if (_policyShown) ...[const SizedBox(height: 14), _policy(q?.freeCancelHours ?? _cat?.freeCancelHours ?? 12, q?.deposit ?? _cat?.deposit ?? 0)],
        ],
    };
  }

  /// Full court or a named part, right on the page; the part's own price, else the listing's.
  Widget _partCard(ServiceOption s) {
    Widget chip(String? part, String label, num price) => ChoiceChip(
          key: ValueKey('book-part-${part ?? 'full'}'),
          label: Text('$label · ${rupees(price)}'),
          selected: _part == part,
          showCheckmark: false,
          labelStyle: inter(13, 600, color: _part == part ? kGreenText : kInk),
          selectedColor: kChipGreen,
          backgroundColor: Colors.white,
          side: BorderSide(color: _part == part ? kGreenText : kLine),
          onSelected: (_) => _pickPart(part),
        );
    return OrderCardBox(
      key: const ValueKey('book-parts'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('What they are booking', style: inter(15, 700)),
        Text('The full ${s.unitWord} blocks every part.', style: inter(12.5, 400, color: kMuted)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          chip(null, 'Full ${s.unitWord}', s.price),
          for (final p in s.parts) chip('${p['name']}', '${p['name']}', num.tryParse('${p['price']}') ?? s.price),
        ]),
      ]),
    );
  }

  /// Who is coming (4 Nov 2026): a count for each kind of guest and the group type; the price and the rules follow it.
  Widget _whoCard(ServiceQuote q) => OrderCardBox(
        key: const ValueKey('book-who'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Who is coming', style: inter(15, 700)),
          Text('This listing prices or limits by who comes.', style: inter(12.5, 400, color: kMuted)),
          const SizedBox(height: 8),
          for (final (k, label, line) in _whoRows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text.rich(TextSpan(children: [TextSpan(text: label, style: inter(14, 600)), TextSpan(text: '  $line', style: inter(12, 400, color: kMuted))]))),
                IconButton(
                  key: ValueKey('who-$k-less'),
                  visualDensity: VisualDensity.compact,
                  onPressed: _who[k]! == 0 ? null : () => setState(() { _who[k] = _who[k]! - 1; _key = null; _requote(); }),
                  icon: const Icon(Icons.remove_circle_outline, size: 22),
                ),
                SizedBox(width: 24, child: Text('${_who[k]}', key: ValueKey('who-$k'), textAlign: TextAlign.center, style: inter(15, 700))),
                IconButton(
                  key: ValueKey('who-$k-more'),
                  visualDensity: VisualDensity.compact,
                  onPressed: _people >= 200 ? null : () => setState(() { _who[k] = _who[k]! + 1; _key = null; _requote(); }),
                  icon: const Icon(Icons.add_circle_outline, size: 22, color: kGreenText),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final gtype in const ['Single', 'Couple', 'Family', 'Group'])
              ChoiceChip(
                key: ValueKey('who-group-$gtype'),
                label: Text(gtype),
                selected: _group == gtype,
                showCheckmark: false,
                labelStyle: inter(12.5, 600, color: _group == gtype ? kGreenText : kInk),
                selectedColor: kChipGreen,
                backgroundColor: Colors.white,
                side: BorderSide(color: _group == gtype ? kGreenText : kLine),
                onSelected: (on) => setState(() { _group = on ? gtype : null; _key = null; _requote(); }),
              ),
          ]),
          if (q.notAllowed != null) ...[const SizedBox(height: 10), _refusal(q.notAllowed!)],
        ]),
      );

  /// The listing's own reason this party cannot book.
  Widget _refusal(String why) => Container(
        key: const ValueKey('book-not-allowed'),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFFFDECEA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Icon(Icons.block, size: 18, color: kError),
          const SizedBox(width: 8),
          Expanded(child: Text(why, style: inter(13.5, 600, color: kError))),
        ]),
      );

  /// What was chosen on the steps before, one line each; a line opens its step again.
  Widget _recap() {
    final s = _service, p = _provider;
    final rows = [
      ('Customer', _name.isEmpty ? '-' : (_phone.isEmpty ? _name : '$_name · +91 $_phone'), 0),
      ('Service', s == null ? '-' : [s.name, if (_ent != null) _ent!.name].join(' · '), 1),
      if (s?.byUnit == true) ('Booked', [_unit ?? '-', if (_part != null) _part!].join(' · '), 2) else ('Provider', p?.name ?? '-', 2),
      ('When', '${_dateLabel(_date)}${_slot == null ? '' : ' · ${_slot!['range_label']}'}', 2),
      if (s?.fulfilment == 'on_location') ('Address', _address.isEmpty ? '-' : _address, 2) else ('Location', _locationText(), 2),
    ];
    return OrderCardBox(
      radius: 18,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Booking', style: inter(17, 700)),
        const SizedBox(height: 6),
        for (final (k, v, step) in rows)
          InkWell(
            onTap: () => setState(() => _step = step),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 90, child: Text(k, style: inter(13.5, 400, color: kMuted))),
                Expanded(child: Text(v, style: inter(14, 600))),
              ]),
            ),
          ),
      ]),
    );
  }

  String _locationText() {
    final parts = [if (widget.location.isNotEmpty) widget.location, if (_resource != null) '${_resource!['name']}'];
    return parts.isEmpty ? 'Studio' : parts.join(' · ');
  }

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
                child: ExcludeSemantics(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15, 400, color: placeholder ? kMuted : kInk))),
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
          if (q.gstPct > 0) _line('GST · ${q.gstPct == q.gstPct.roundToDouble() ? q.gstPct.toInt() : q.gstPct}%', rupees(q.gst)),
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

/// A court's free times on one day, right on the page (no sheet): grouped under the listing's time bands, then the courts free at the time tapped,
/// each its own card with its setting, surface and grade.
class _UnitTimes extends StatefulWidget {
  const _UnitTimes({super.key, required this.api, required this.date, required this.service, required this.addonIds, required this.part, required this.slot, required this.unit, required this.onTime, required this.onUnit});
  final ServiceApi api;
  final String date;
  final ServiceOption service;
  final List<String> addonIds;
  final String? part, unit;
  final Map<String, dynamic>? slot;
  final ValueChanged<Map<String, dynamic>> onTime;
  final ValueChanged<String> onUnit;
  @override
  State<_UnitTimes> createState() => _UnitTimesState();
}

class _UnitTimesState extends State<_UnitTimes> {
  List<Map<String, dynamic>>? _slots;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.slots(date: widget.date, serviceId: widget.service.id, addonIds: widget.addonIds, part: widget.part).then((d) {
      if (mounted) setState(() => _slots = d.expand((p) => p.slots).toList());
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!, style: inter(14, 400, color: kMuted));
    final all = _slots;
    if (all == null) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: kGreenText)));
    final word = widget.service.unitWord;
    if (all.isEmpty) return Text('No $word is free that day. Try another date.', key: const ValueKey('unit-times-none'), style: inter(14, 400, color: kMuted));
    final bands = <String, List<Map<String, dynamic>>>{};
    for (final s in all) {
      bands.putIfAbsent('${s['band'] ?? ''}', () => []).add(s);
    }
    final at = widget.slot?['starts_at'];
    final free = ((widget.slot?['units'] as List?) ?? const []).map((e) => '$e').toSet();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Time', style: inter(14.5, 700)),
      for (final b in bands.entries) ...[
        if (b.key.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(b.key, style: inter(12.5, 600, color: kMuted))),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in b.value)
            ChoiceChip(
              key: ValueKey('unit-time-${s['label']}'),
              label: Text('${s['label']}'),
              selected: s['starts_at'] == at,
              showCheckmark: false,
              labelStyle: inter(13, 600, color: s['starts_at'] == at ? kGreenText : kInk),
              selectedColor: kChipGreen,
              backgroundColor: Colors.white,
              side: BorderSide(color: s['starts_at'] == at ? kGreenText : kLine),
              onSelected: (_) => widget.onTime(s),
            ),
        ]),
      ],
      if (widget.slot != null) ...[
        const SizedBox(height: 14),
        Text('${word[0].toUpperCase()}${word.substring(1)} · free at ${widget.slot!['label']}', style: inter(14.5, 700)),
        const SizedBox(height: 6),
        for (final u in widget.service.units.where((u) => free.contains('${u['name']}')))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InkWell(
              key: ValueKey('unit-${u['name']}'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => widget.onUnit('${u['name']}'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: widget.unit == u['name'] ? kChipGreen : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: widget.unit == u['name'] ? kGreenText : kLine),
                ),
                child: Row(children: [
                  Text('${u['name']}', style: inter(14, 700)),
                  const SizedBox(width: 10),
                  Expanded(child: Text([for (final k in const ['setting', 'surface', 'grade']) if (u[k] != null) '${u[k]}'].join(' · '), textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 400, color: kMuted))),
                ]),
              ),
            ),
          ),
      ],
    ]);
  }
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
