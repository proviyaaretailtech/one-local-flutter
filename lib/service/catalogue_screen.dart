import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_menu.dart';
import 'service_widgets.dart';

const _typeChips = [
  ('', 'All types'),
  ('appointment', 'Appointment'),
  ('event', 'Event'),
  ('on_location', 'On-location'),
  ('on_demand', 'Instant/On-demand'),
  ('package', 'Package'),
  ('membership', 'Membership'),
];

IconData serviceTypeIcon(String type) => switch (type) {
      'event' => LucideIcons.circleDot,
      'on_location' => LucideIcons.house,
      'on_demand' => LucideIcons.clock,
      'package' => LucideIcons.squareDot,
      'membership' => LucideIcons.star,
      _ => LucideIcons.scissors,
    };

String fulfilmentLabel(String f) => switch (f) {
      'event' => 'Event · Group session at our place',
      'on_location' => 'On-location · We go to the customer',
      'on_demand' => 'On-demand · Starts right away',
      _ => 'Appointment · Customer visits us',
    };

/// Figma 83 "Service Catalogue": services, packages and memberships with search and category / type / status filters. Counts and labels are the server's.
class ServiceCatalogueScreen extends StatefulWidget {
  const ServiceCatalogueScreen({super.key, required this.api, this.business = '', this.onNavigate});
  final ServiceApi api;
  final String business;
  final ValueChanged<String>? onNavigate;
  @override
  State<ServiceCatalogueScreen> createState() => _ServiceCatalogueScreenState();
}

class _ServiceCatalogueScreenState extends State<ServiceCatalogueScreen> {
  ServiceListData? _d;
  String? _error;
  String _q = '', _cat = '', _type = '', _status = '';
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final d = await widget.api.serviceList(q: _q, category: _cat.isEmpty ? null : _cat, type: _type.isEmpty ? null : _type, status: _status.isEmpty ? null : _status);
      if (mounted && mine == _seq) setState(() { _d = d; _error = null; });
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.toString());
    }
  }

  Future<void> _open(SvcData s) async {
    final type = s.s('type');
    if (type == 'package' || type == 'membership') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => serviceScreen(type == 'package' ? 'packages' : 'memberships', widget.api, business: widget.business, onNavigate: widget.onNavigate)));
    } else {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceDetailScreen(api: widget.api, id: s.s('id'), business: widget.business, onNavigate: widget.onNavigate)));
    }
    if (mounted) _load();
  }

  Future<void> _more(SvcData s) async {
    final type = s.s('type');
    final plan = type == 'package' || type == 'membership';
    final pick = await showOrderSheet<String>(context, title: s.s('name'), body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LightCta(label: plan ? 'Open ${type == 'package' ? 'packages' : 'memberships'}' : 'View details', onPressed: () => Navigator.pop(ctx, 'open')),
          if (!plan) ...[
            const SizedBox(height: 8),
            LightCta(label: 'Edit service', onPressed: () => Navigator.pop(ctx, 'edit')),
            const SizedBox(height: 8),
            LightCta(key: const ValueKey('toggle-status'), label: s.s('status') == 'active' ? 'Pause bookings' : 'Take bookings again', onPressed: () => Navigator.pop(ctx, 'toggle')),
          ],
        ]));
    if (!mounted || pick == null) return;
    if (pick == 'open') return _open(s);
    try {
      final d = await widget.api.serviceDetail(s.s('id'));
      if (!mounted) return;
      if (pick == 'edit') {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceEditScreen(api: widget.api, detail: d, business: widget.business)));
      } else {
        await widget.api.saveService({...serviceFields(d), 'is_bookable': !d.active}, key: ServiceApi.newKey());
        if (mounted) showToast(context, d.active ? '${d.name} is paused.' : '${d.name} takes bookings again.');
      }
    } catch (e) {
      if (mounted) showToast(context, e is ServiceApiException ? e.message : e.toString());
    }
    if (mounted) _load();
  }

  Future<void> _add() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceEditScreen(api: widget.api, business: widget.business)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return ServicePage(
      title: 'Service Catalogue',
      subtitle: d == null ? '' : '${d.total} ${d.total == 1 ? 'service' : 'services'} · ${_type.isEmpty ? 'All fulfilment models' : _typeChips.firstWhere((t) => t.$1 == _type).$2}',
      business: widget.business,
      onMenu: () => showServiceMenu(context, widget.api, business: widget.business, onNavigate: widget.onNavigate, current: 'catalogue'),
      onNavigate: widget.onNavigate,
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: d == null
          ? null
          : [
              SvcSearch(hint: 'Search service name or code...', fieldKey: const ValueKey('catalogue-search'), onChanged: (v) {
                _q = v;
                _load();
              }),
              const SizedBox(height: 14),
              SvcChips(options: [('', 'All'), for (final c in d.categories) (c, c)], selected: _cat, onSelect: (v) {
                _cat = v;
                _load();
              }),
              SvcChips(options: _typeChips, selected: _type, onSelect: (v) {
                _type = v;
                _load();
              }),
              SvcChips(options: [('', 'All statuses'), ('active', 'Active ${d.count('active')}'), ('paused', 'Paused ${d.count('paused')}'), if (d.count('draft') > 0) ('draft', 'Draft ${d.count('draft')}')],
                  selected: _status, onSelect: (v) {
                _status = v;
                _load();
              }),
              const SizedBox(height: 6),
              SvcSectionHead('Services', count: '${d.shown} total'),
              if (d.services.isEmpty) OrderCardBox(child: Text(d.total == 0 ? 'No services yet. Tap Add service to create the first one.' : 'Nothing matches these filters.', style: inter(14, 400, color: kMuted))),
              for (final s in d.services) _row(s),
              const SizedBox(height: 6),
              DarkCta(label: '+ Add service', onPressed: _add),
            ],
    );
  }

  Widget _row(SvcData s) {
    final active = s.s('status') == 'active';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _open(s),
        child: OrderCardBox(
          radius: 18,
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
          child: Row(children: [
            Container(width: 72, height: 72, decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(14)), child: Icon(serviceTypeIcon(s.s('type')), size: 30, color: kInk)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.s('name'), style: inter(17, 700)),
                const SizedBox(height: 4),
                Text(s.s('subtitle'), style: inter(13.5, 400, color: kMuted)),
                const SizedBox(height: 4),
                Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: active ? kLink : kMuted, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Flexible(child: Text('${s.s('status_label')} · ${s.s('type_label')}', style: inter(13.5, 500, color: active ? kLink : kMuted))),
                ]),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(s.s('price_label'), style: inter(18, 800, color: kLink)),
              const SizedBox(height: 6),
              Text(s.s('length_label'), style: inter(13.5, 400, color: kMuted)),
            ]),
            IconButton(key: ValueKey('more-${s.s('id')}'), tooltip: 'More', onPressed: () => _more(s), icon: const Icon(LucideIcons.ellipsisVertical, size: 20, color: kMuted)),
          ]),
        ),
      ),
    );
  }
}

/// The fields of a saved service, ready to send back with a change.
Map<String, Object?> serviceFields(ServiceDetail d) => {
      'id': d.id,
      'name': d.name,
      'price': d.price,
      'category': d.s('category'),
      'code': d.so('code'),
      'fulfilment': d.fulfilment,
      'kind': d.s('kind'),
      'duration_min': d.i('duration_min'),
      'buffer_min': d.i('buffer_min'),
      'capacity': d.i('capacity'),
      'staff_required': d.s('staff_required'),
      'min_notice_min': d.i('min_notice_min'),
      'grace_min': d.i('grace_min'),
      'description': d.so('description'),
      'checklist': d.checklist,
      'is_bookable': d.active,
    };

/// Figma 84 "Service Detail": the service, how it is delivered, its add-ons and booking rules. Every value is the server's.
class ServiceDetailScreen extends StatefulWidget {
  const ServiceDetailScreen({super.key, required this.api, required this.id, this.business = '', this.onNavigate});
  final ServiceApi api;
  final String id, business;
  final ValueChanged<String>? onNavigate;
  @override
  State<ServiceDetailScreen> createState() => _ServiceDetailScreenState();
}

class _ServiceDetailScreenState extends State<ServiceDetailScreen> {
  ServiceDetail? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.serviceDetail(widget.id);
      if (mounted) setState(() { _d = d; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String _hours(int min) => min == 0 ? 'No minimum notice' : (min % 60 == 0 ? 'Book at least ${min ~/ 60} ${min == 60 ? 'hour' : 'hours'} ahead' : 'Book at least $min minutes ahead');

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return ServicePage(
      title: 'Service Detail',
      subtitle: d == null ? '' : [if ((d.so('code') ?? '').isNotEmpty) d.s('code'), d.s('category'), 'Updated ${d.s('updated_label')}'].join(' · '),
      business: widget.business,
      onNavigate: widget.onNavigate,
      error: _error,
      onRetry: _load,
      onRefresh: _load,
      body: d == null
          ? null
          : [
              SvcCard(title: d.name, children: [
                Align(alignment: Alignment.centerLeft, child: svcStatus(d.active ? 'Active' : 'Paused', d.active ? 'good' : 'info')),
                if ((d.so('description') ?? '').isNotEmpty) ...[const SizedBox(height: 12), Text(d.s('description'), style: inter(15, 400, color: kMuted, height: 1.45))],
                const SizedBox(height: 8),
                SvcKV('Price', d.n('gst_pct') > 0 ? '${svcRupees(d.price)} ${d.b('prices_include_tax') ? 'incl.' : '+'} ${d.n('gst_pct').toStringAsFixed(d.n('gst_pct') % 1 == 0 ? 0 : 1)}% GST' : svcRupees(d.price)),
                SvcKV('Duration', '${d.i('duration_min')} minutes'),
              ]),
              SvcCard(title: 'Delivery & resources', children: [
                SvcKV('Fulfilment', fulfilmentLabel(d.fulfilment)),
                SvcKV('Location', d.locations.isEmpty ? 'No provider yet' : d.locations.join(' · ')),
                SvcKV('Capacity', '${d.i('capacity')} ${d.i('capacity') == 1 ? 'customer' : 'customers'} per slot'),
                if (d.s('staff_required').isNotEmpty) SvcKV('Staff required', d.s('staff_required')),
                SvcKV('Eligible staff', d.staff.isEmpty ? 'Nobody yet' : d.staff.map((x) => x.s('name')).join(' · ')),
              ]),
              if (d.addons.isNotEmpty)
                SvcCard(title: 'Optional add-ons', children: [
                  for (final a in d.addons) SvcLine('${a.s('name')} · +${a.i('duration_min')} min', qty: '1×', amount: svcRupees(a.n('price'))),
                ]),
              SvcCard(title: 'Booking rules', children: [
                SvcKV('Notice', _hours(d.i('min_notice_min'))),
                SvcKV('Buffer', d.i('buffer_min') == 0 ? 'No buffer' : '${d.i('buffer_min')} min after each appointment'),
                SvcKV('Deposit', d.n('deposit') > 0 ? '${svcRupees(d.n('deposit'))} at booking' : 'No deposit'),
                SvcKV('Cancellation', 'Free until ${d.i('free_cancel_hours')} hours before'),
                SvcKV('Late arrival', '${d.i('grace_min')}-minute grace period'),
              ]),
              if (d.fulfilment == 'on_location')
                const SvcInfo(title: 'On-location job', text: 'The provider travels to the customer. The address is taken at booking and arrival is verified with the customer.')
              else
                SvcInfo(title: '${d.fulfilment == 'event' ? 'Event' : d.fulfilment == 'on_demand' ? 'On-demand' : 'Appointment'} only', text: 'Customers visit the studio. No travel or dispatch is needed.'),
              if (d.canEdit)
                DarkCta(
                  label: 'Edit service',
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceEditScreen(api: widget.api, detail: d, business: widget.business)));
                    if (mounted) _load();
                  },
                ),
            ],
    );
  }
}

/// Add or edit a service (behind "+ Add service" and "Edit service"). Sends only what was typed; the server checks and prices.
class ServiceEditScreen extends StatefulWidget {
  const ServiceEditScreen({super.key, required this.api, this.detail, this.business = ''});
  final ServiceApi api;
  final ServiceDetail? detail;
  final String business;
  @override
  State<ServiceEditScreen> createState() => _ServiceEditScreenState();
}

class _ServiceEditScreenState extends State<ServiceEditScreen> {
  late final ServiceDetail? d = widget.detail;
  late final _name = TextEditingController(text: d?.name ?? '');
  late final _price = TextEditingController(text: d == null ? '' : d!.price.toString());
  late final _category = TextEditingController(text: d?.s('category') ?? '');
  late final _duration = TextEditingController(text: d == null ? '30' : '${d!.i('duration_min')}');
  late final _buffer = TextEditingController(text: d == null ? '0' : '${d!.i('buffer_min')}');
  late final _notice = TextEditingController(text: d == null ? '0' : '${d!.i('min_notice_min')}');
  late final _grace = TextEditingController(text: d == null ? '10' : '${d!.i('grace_min')}');
  late final _capacity = TextEditingController(text: d == null ? '1' : '${d!.i('capacity')}');
  late final _staffReq = TextEditingController(text: d?.s('staff_required') ?? '');
  late final _desc = TextEditingController(text: d?.so('description') ?? '');
  late final _checklist = TextEditingController(text: d?.checklist.join('\n') ?? '');
  late String _fulfilment = d?.fulfilment ?? 'appointment';
  late bool _addon = d?.s('kind') == 'addon';
  String? _key;
  bool _busy = false;

  Future<void> _save() async {
    final price = num.tryParse(_price.text.trim());
    if (_name.text.trim().length < 2 || price == null) {
      showToast(context, 'Enter the name and the price.');
      return;
    }
    setState(() => _busy = true);
    _key ??= ServiceApi.newKey();
    try {
      final saved = await widget.api.saveService({
        if (d != null) ...serviceFields(d!),
        'name': _name.text.trim(),
        'price': price,
        'category': _category.text.trim().isEmpty ? 'General' : _category.text.trim(),
        'fulfilment': _fulfilment,
        'kind': _addon ? 'addon' : 'service',
        'duration_min': int.tryParse(_duration.text.trim()) ?? 30,
        'buffer_min': int.tryParse(_buffer.text.trim()) ?? 0,
        'min_notice_min': int.tryParse(_notice.text.trim()) ?? 0,
        'grace_min': int.tryParse(_grace.text.trim()) ?? 10,
        'capacity': int.tryParse(_capacity.text.trim()) ?? 1,
        'staff_required': _staffReq.text.trim(),
        'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        'checklist': _checklist.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      }, key: _key!);
      if (!mounted) return;
      showToast(context, '${saved.name} saved.');
      Navigator.of(context).pop(saved);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.status < 500) _key = null;
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _f(String label, TextEditingController c, {TextInputType keyboard = TextInputType.text, int lines = 1, String hint = ''}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(13, 600, color: kMuted)),
          const SizedBox(height: 6),
          TextField(key: ValueKey('field-$label'), controller: c, keyboardType: keyboard, minLines: lines, maxLines: lines, decoration: InputDecoration(hintText: hint), onChanged: (_) => _key = null),
        ]),
      );

  @override
  Widget build(BuildContext context) => ServicePage(
        title: d == null ? 'Add service' : 'Edit service',
        subtitle: d == null ? 'Name, price and how it is booked' : '${d!.s('code')} · ${d!.name}',
        business: widget.business,
        body: [
          SvcCard(children: [
            _f('Name', _name, hint: 'Precision haircut'),
            _f('Price (₹, before GST)', _price, keyboard: TextInputType.number),
            _f('Category', _category, hint: 'Grooming'),
            _f('Description', _desc, lines: 3),
          ]),
          SvcCard(title: 'Fulfilment', children: [
            SvcChips(options: const [('appointment', 'Appointment'), ('event', 'Event'), ('on_location', 'On-location'), ('on_demand', 'On-demand')], selected: _fulfilment, onSelect: (v) => setState(() {
                  _fulfilment = v;
                  _key = null;
                })),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Add-on to another service', style: inter(14.5, 500)),
              value: _addon,
              onChanged: (v) => setState(() {
                _addon = v;
                _key = null;
              }),
            ),
          ]),
          SvcCard(title: 'Booking rules', children: [
            _f('Duration (minutes)', _duration, keyboard: TextInputType.number),
            _f('Buffer after (minutes)', _buffer, keyboard: TextInputType.number),
            _f('Notice (minutes ahead)', _notice, keyboard: TextInputType.number),
            _f('Late arrival grace (minutes)', _grace, keyboard: TextInputType.number),
            _f('Capacity per slot', _capacity, keyboard: TextInputType.number),
            _f('Staff required', _staffReq, hint: '1 certified hair stylist'),
            _f('Job checklist (one step per line)', _checklist, lines: 4),
          ]),
          DarkCta(label: 'Save service', busy: _busy, onPressed: _busy ? null : _save),
        ],
      );
}
