import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/item_photo.dart';
import '../auth/partner_api.dart' show PartnerApiException;
import '../media/media_api.dart' show PoolPhoto;
import '../orders/order_widgets.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_menu.dart';
import 'service_media.dart';
import 'service_widgets.dart';
import 'inventory_pane.dart';
import 'service_form.dart';
import 'service_parts.dart' show listingCategories;
import 'templates_pane.dart';

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

/// A service's photo (founder, 2 Nov 2026: "add photo options"), or its type's icon when it has none or the photo cannot load.
Widget servicePhoto(String? url, String type, {double size = 72}) {
  final icon = Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(14)),
    child: Icon(serviceTypeIcon(type), size: size * 0.42, color: kInk),
  );
  if (url == null || url.isEmpty) return icon;
  return ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: Image.network(url, key: const ValueKey('service-photo'), width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => icon),
  );
}

String fulfilmentLabel(String f) => switch (f) {
      'event' => 'Event · Group session at our place',
      'on_location' => 'On-location · We go to the customer',
      'on_demand' => 'On-demand · Starts right away',
      _ => 'Appointment · Customer visits us',
    };

/// What can be added: a service (the one form, founder 3 Nov 2026: "just one form, one common form"; a template can fill it), then
/// packages and memberships.
/// (founder, 4 Nov 2026: "keep it as it was" — the categories — "and only add one tab, add existing templates")
final _addKinds = [
  for (final c in listingCategories) (c.key, c.name, 'Books: ${c.books[0].toLowerCase()}${c.books.substring(1)}', c.icon),
  ('templates', 'Add from existing templates', 'Pick a template you saved; it fills the form', LucideIcons.clipboardList),
  ('package', 'Package', 'A bundle of services at one price', serviceTypeIcon('package')),
  ('membership', 'Membership', 'A monthly or yearly plan', serviceTypeIcon('membership')),
];

/// The service catalogue (founder's design, 3 Nov 2026): two tabs, Services and Inventory. Services has + Add service, search, a Filter
/// sheet for the type, and status / category chips; Inventory has the team, places, tools, materials and items in care. Counts and labels are the server's.
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
  int? _alerts; // things to do in Inventory, told by the pane
  final _pane = GlobalKey<InventoryPaneState>();
  final _templates = GlobalKey<TemplatesPaneState>();
  String? _error;
  String _q = '', _cat = '', _type = '', _status = '';
  // which way the list slides in after a chip or tab is tapped (1: from the right), and a count that replays it (founder, 4 Nov 2026)
  int _slide = 0, _slides = 0, _chipAt = 0, _paneDir = 1;
  String _tab = 'services';
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
      if (mounted && mine == _seq) {
        setState(() {
          _d = d;
          _error = null;
          if (_slide != 0) _slides++;
        });
      }
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.toString());
    }
  }

  Future<void> _refresh() async => switch (_tab) {
        'services' => _load(),
        'templates' => _templates.currentState?.reload(),
        _ => _pane.currentState?.reload(),
      };

  /// A template's "Use for a new service": the one form, filled from it.
  Future<void> _useTemplate(ServiceTemplate t) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ServiceFormScreen(api: widget.api, template: t, business: widget.business)));
    if (saved == true && mounted) {
      _templates.currentState?.reload();
      _load();
    }
  }

  static const _tabOrder = ['services', 'templates', 'inventory'];
  void _setTab(String tab) => setState(() {
        _paneDir = _tabOrder.indexOf(tab) >= _tabOrder.indexOf(_tab) ? 1 : -1;
        _tab = tab;
      });

  Future<void> _open(SvcData s) async {
    final type = s.s('type');
    if (type == 'package' || type == 'membership') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => serviceScreen(type == 'package' ? 'packages' : 'memberships', widget.api, business: widget.business, onNavigate: widget.onNavigate)));
    } else {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceDetailScreen(api: widget.api, id: s.s('id'), business: widget.business, onNavigate: widget.onNavigate)));
    }
    if (mounted) _load();
  }

  /// The row's actions, in a small frosted box beside its ⋮ ([from]).
  Future<void> _more(BuildContext from, SvcData s) async {
    final type = s.s('type');
    final plan = type == 'package' || type == 'membership';
    final pick = await showActionBox<String>(from, title: s.s('name'), actions: [
      ('open', plan ? 'Open ${type == 'package' ? 'packages' : 'memberships'}' : 'View details', null),
      if (!plan) ...[
        ('edit', 'Edit service', null),
        ('toggle', s.s('status') == 'active' ? 'Pause bookings' : 'Take bookings again', const ValueKey('toggle-status')),
      ],
    ]);
    if (!mounted || pick == null) return;
    if (pick == 'open') return _open(s);
    try {
      final d = await widget.api.serviceDetail(s.s('id'));
      if (!mounted) return;
      if (pick == 'edit') {
        await editService(context, widget.api, d, business: widget.business);
      } else {
        await widget.api.saveService({...serviceFields(d), 'is_bookable': !d.active}, key: ServiceApi.newKey());
        if (mounted) showToast(context, d.active ? '${d.name} is paused.' : '${d.name} takes bookings again.');
      }
    } catch (e) {
      if (mounted) showToast(context, e is ServiceApiException ? e.message : e.toString());
    }
    if (mounted) _load();
  }

  /// The Filter button: the type of service, in a sheet (status and category are the chips under it).
  Widget _filterButton() => InkWell(
        key: const ValueKey('catalogue-filters'),
        borderRadius: BorderRadius.circular(999),
        onTap: _pickType,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _type.isNotEmpty ? kChipGreen : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _type.isNotEmpty ? kLink : const Color(0xFFD9DBD3)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(LucideIcons.slidersHorizontal, size: 18, color: kInk),
            const SizedBox(width: 6),
            Text(_type.isNotEmpty ? 'Filter · 1' : 'Filter', style: inter(14, 600)),
          ]),
        ),
      );

  Future<void> _pickType() async {
    var type = _type;
    final applied = await showOrderSheet<bool>(context, title: 'Type of service', body: (ctx) => StatefulBuilder(
          builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SvcChips(options: _typeChips, selected: type, onSelect: (v) => set(() => type = v)),
            const SizedBox(height: 8),
            DarkCta(label: 'Show services', onPressed: () => Navigator.pop(ctx, true)),
            const SizedBox(height: 8),
            LightCta(label: 'Clear filter', onPressed: () => set(() => type = '')),
          ]),
        ));
    if (applied != true || !mounted) return;
    _type = type;
    _load();
  }

  /// All · Active · Paused · Draft, then the categories: one row that scrolls sideways (the design's chips).
  Widget _chips(ServiceListData d) {
    var at = 0;
    Widget chip(String key, String label, bool on, VoidCallback tap) {
      final i = at++;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Builder(
          builder: (ctx) => ModeChip(label, key: ValueKey('chip-$key'), selected: on, onTap: () {
            // the tapped chip glides towards the middle of the row; the list slides in from its side
            Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 360), curve: Curves.easeOutCubic);
            _slide = i >= _chipAt ? 1 : -1;
            _chipAt = i;
            tap();
          }),
        ),
      );
    }

    void set(String status, String cat) {
      _status = status;
      _cat = cat;
      _load();
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(children: [
        chip('all', 'All', _status.isEmpty && _cat.isEmpty, () => set('', '')),
        for (final (v, l) in [('active', 'Active'), ('paused', 'Paused'), ('draft', 'Draft')])
          if (v == 'active' || d.count(v) > 0 || _status == v) chip(v, '$l ${d.count(v)}', _status == v, () => set(_status == v ? '' : v, _cat)),
        for (final c in d.categories) chip('cat-$c', c, _cat == c, () => set(_status, _cat == c ? '' : c)),
      ]),
    );
  }

  Future<void> _add() async {
    final kind = await showOrderSheet<String>(context, title: 'What are you adding?', body: (ctx) => ConstrainedBox(
        // nine rows: the list scrolls on a short screen
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.72),
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Pick what you are adding, or start from a template you saved.', style: inter(13.5, 400, color: kMuted)),
          const SizedBox(height: 12),
          for (final (v, n, line, icon) in _addKinds)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                key: ValueKey('add-kind-$v'),
                borderRadius: BorderRadius.circular(14),
                onTap: () => Navigator.pop(ctx, v),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
                  child: Row(children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, size: 20, color: kGreenText),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(n, style: inter(15, 700)),
                        const SizedBox(height: 2),
                        Text(line, style: inter(13, 400, color: kMuted)),
                      ]),
                    ),
                    const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
                  ]),
                ),
              ),
            ),
        ]))));
    if (kind == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => switch (kind) {
              'package' || 'membership' => serviceScreen(kind == 'package' ? 'packages' : 'memberships', widget.api, business: widget.business, onNavigate: widget.onNavigate),
              'templates' => TemplatePickScreen(api: widget.api, business: widget.business),
              _ => ServiceFormScreen(api: widget.api, business: widget.business, category: kind),
            }));
    if (mounted) _load();
  }

  /// Services · Templates · Inventory; the white highlight slides to the picked tab (the store's segmented tabs).
  Widget _tabs(ServiceListData d) {
    final tabs = [('services', 'Services', '${d.total}'), ('templates', 'Templates', ''), ('inventory', 'Costing', (_alerts ?? 0) == 0 ? '' : '$_alerts')];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: kInfoGreyBg, borderRadius: BorderRadius.circular(14)),
      child: SlidingTabs(
        count: tabs.length,
        height: 38,
        selected: tabs.indexWhere((t) => t.$1 == _tab),
        onSelect: (i) => _setTab(tabs[i].$1),
        keyOf: (i) => ValueKey('tab-${tabs[i].$1}'),
        highlight: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 1))]),
        ),
        // three tabs on a phone: the label shrinks a little rather than spill over (founder, 4 Nov 2026); Inventory's number is what needs
        // doing, in amber
        builder: (_, i, on) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(tabs[i].$2, style: inter(14.5, on ? 700 : 500, color: on ? kInk : kMuted)),
              if (tabs[i].$3.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  key: ValueKey('tab-count-${tabs[i].$1}'),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: tabs[i].$1 == 'inventory' ? const Color(0xFFFFF1D6) : on ? kChipGreen : Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(tabs[i].$3, style: inter(11.5, 700, color: tabs[i].$1 == 'inventory' ? const Color(0xFF7A4E00) : on ? kGreenText : kMuted)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return ServicePage(
      title: 'Service catalogue',
      subtitle: d == null ? '' : '${d.total} ${d.total == 1 ? 'service' : 'services'}${_type.isEmpty ? '' : ' · ${_typeChips.firstWhere((t) => t.$1 == _type).$2}'}',
      business: widget.business,
      onMenu: () => showServiceMenu(context, widget.api, business: widget.business, onNavigate: widget.onNavigate, current: 'catalogue'),
      onNavigate: widget.onNavigate,
      onRefresh: _refresh,
      error: _error,
      onRetry: _load,
      body: d == null
          ? null
          : [
              _tabs(d),
              const SizedBox(height: 14),
              // Services · Templates · Inventory: the new pane slides in from the side of the tab tapped, the old one slides out the other way
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                transitionBuilder: (child, a) {
                  final incoming = child.key == ValueKey('pane-$_tab');
                  final from = Offset((incoming ? 0.25 : -0.25) * _paneDir, 0);
                  return FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(a), child: child));
                },
                child: KeyedSubtree(key: ValueKey('pane-$_tab'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _tab == 'services' ? _services(d) : _tab == 'templates' ? [TemplatesPane(key: _templates, api: widget.api, onUse: _useTemplate)] : [InventoryPane(key: _pane, api: widget.api, business: widget.business, onNavigate: widget.onNavigate, onAlerts: (n) => setState(() => _alerts = n))])),
              ),
            ],
    );
  }

  List<Widget> _services(ServiceListData d) => [
        // + Add service first, where it is seen without scrolling (founder, 2 Nov 2026)
        Material(
          color: kChipGreen,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: const ValueKey('add-service'),
            borderRadius: BorderRadius.circular(14),
            onTap: _add,
            child: Container(
              height: 50,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: kLink, width: 1.5)),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(LucideIcons.plus, size: 20, color: kGreenText),
                const SizedBox(width: 8),
                Text('Add service', style: inter(15, 800, color: kGreenText)),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: SvcSearch(hint: 'Search services', fieldKey: const ValueKey('catalogue-search'), onChanged: (v) {
              _q = v;
              _load();
            }),
          ),
          const SizedBox(width: 8),
          _filterButton(),
        ]),
        const SizedBox(height: 10),
        _chips(d),
        const SizedBox(height: 12),
        if (d.services.isEmpty)
          OrderCardBox(child: Text(d.total == 0 ? 'No services yet. Tap Add service to create the first one.' : 'No services in this filter.', style: inter(14, 400, color: kMuted))),
        for (var i = 0; i < d.services.length; i++)
          _slides == 0
              ? Entrance(key: ValueKey('in-${d.services[i].s('id')}'), index: i, child: _row(d.services[i]))
              : SlideIn(key: ValueKey('slide-$_slides-${d.services[i].s('id')}'), dir: _slide, index: i, child: _row(d.services[i])),
      ];

  Widget _pill(String label, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: inter(11.5, 700, color: fg)),
      );

  Widget _row(SvcData s) {
    final status = s.s('status');
    final (bg, fg) = switch (status) {
      'active' => (kChipGreen, kGreenText),
      'draft' => (const Color(0xFFFFF1D6), const Color(0xFF7A4E00)),
      _ => (kInfoGreyBg, kMuted),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(s),
        child: OrderCardBox(
          radius: 16,
          padding: const EdgeInsets.fromLTRB(12, 12, 2, 12),
          child: Row(children: [
            servicePhoto(s.so('image_url'), s.s('type'), size: 64),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.s('name'), style: inter(15.5, 700)),
                const SizedBox(height: 2),
                Text(s.s('subtitle'), style: inter(13, 400, color: kMuted)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  _pill(s.s('type_label'), kInfoGreyBg, kInk),
                  _pill(s.s('status_label'), bg, fg),
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(s.s('price_label'), style: inter(16, 800, color: kGreenText)),
              const SizedBox(height: 4),
              Text(s.s('length_label'), style: inter(12.5, 400, color: kMuted)),
            ]),
            Builder(builder: (from) => IconButton(key: ValueKey('more-${s.s('id')}'), tooltip: 'More', onPressed: () => _more(from, s), icon: const Icon(LucideIcons.ellipsisVertical, size: 20, color: kMuted))),
          ]),
        ),
      ),
    );
  }
}

/// The fields of a saved service, ready to send back with a change.
/// "Edit service" (from the list's menu and from the service's page): the same form as Add service, filled with everything already
/// saved (founder, 4 Nov 2026: "it should look similar to making a service form but all the existing details filled").
Future<void> editService(BuildContext context, ServiceApi api, ServiceDetail d, {String business = ''}) async {
  final l = await api.listingView(serviceId: d.id);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ServiceFormScreen(api: api, detail: d, listing: {...l.listing, if (l.category != null) 'category': l.category}, business: business)));
}

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
                if ((d.so('image_url') ?? '').isNotEmpty) ...[
                  ClipRRect(borderRadius: BorderRadius.circular(14), child: AspectRatio(aspectRatio: 16 / 9, child: Image.network(d.s('image_url'), fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()))),
                  const SizedBox(height: 10),
                ],
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
                    try {
                      await editService(context, widget.api, d, business: widget.business);
                    } catch (e) {
                      if (context.mounted) showToast(context, e is ServiceApiException ? e.message : e.toString());
                    }
                    if (mounted) _load();
                  },
                ),
            ],
    );
  }
}

/// Add or edit a service (behind "+ Add service" and "Edit service"). Sends only what was typed; the server checks and prices.
class ServiceEditScreen extends StatefulWidget {
  const ServiceEditScreen({super.key, required this.api, this.detail, this.business = '', this.photos = const DeviceItemPhotos(), this.media, this.fulfilment = 'appointment'});
  final ServiceApi api;
  final ServiceDetail? detail;
  final String business;

  /// The store's photo tools (camera, gallery, AI background removal, upload); tests pass a fake.
  final ItemPhotoService photos;

  /// Standard media (approved service photos); tests pass a fake.
  final ServiceMediaApi? media;

  /// How a new service is delivered, picked in "What are you adding?" (3 Nov 2026).
  final String fulfilment;
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
  late String _fulfilment = d?.fulfilment ?? widget.fulfilment;
  late bool _addon = d?.s('kind') == 'addon';
  String? _key;
  bool _busy = false;

  // the photo (founder, 2 Nov 2026): a new one waits here until the service is saved; the saved one shows until it is replaced or taken off
  ItemPhoto? _photo;
  PoolPhoto? _standard; // a standard photo chosen from Standard media (2 Nov 2026), put on the service when it is saved
  late final ServiceMediaApi _media = widget.media ?? ServiceMediaApi();
  late final String? _savedUrl = d?.so('image_url');
  bool _dropSaved = false;
  bool _cutting = false;

  Future<void> _getStandard() async {
    final p = await pickServiceStandardPhoto(context, _media, serviceId: d?.id, serviceName: _name.text.trim());
    if (p != null && mounted) {
      setState(() {
        _standard = p;
        _photo = null;
      });
    }
  }

  Future<void> _getPhoto(bool camera) async {
    try {
      final p = camera ? await widget.photos.capture(context) : await widget.photos.pick();
      if (p != null && mounted) {
        setState(() {
          _photo = p;
          _standard = null;
        });
      }
    } on ItemPhotoUnavailable catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the photo. Try again.');
    }
  }

  Future<void> _cutOut() async {
    final p = _photo;
    if (p == null || _cutting) return;
    setState(() => _cutting = true);
    try {
      final done = await widget.photos.removeBackground(p, bgColor: 'FFFFFF');
      if (mounted) setState(() => _photo = done);
    } on ItemPhotoUnavailable catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'The background could not be removed right now.');
    } finally {
      if (mounted) setState(() => _cutting = false);
    }
  }

  void _clearPhoto() => setState(() {
        if (_photo != null || _standard != null) {
          _photo = null;
          _standard = null;
        } else {
          _dropSaved = true;
        }
      });

  /// After the service is saved: the new photo goes on it, or the saved one comes off. A photo problem does not undo the save.
  Future<String?> _savePhoto(String id) async {
    try {
      if (_photo != null) {
        await widget.photos.attach(id, _photo!);
      } else if (_standard != null) {
        await _media.use(_standard!.id, id);
      } else if (_dropSaved && (_savedUrl ?? '').isNotEmpty) {
        await widget.photos.remove(id);
      }
      return null;
    } on ItemPhotoUnavailable catch (e) {
      return e.message;
    } on PartnerApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'The photo did not save. Try again from Edit service.';
    }
  }

  Widget _photoCard() {
    final shown = _photo != null || _standard != null || (!_dropSaved && (_savedUrl ?? '').isNotEmpty);
    Widget button(String label, IconData icon, String key, VoidCallback? onTap) => OutlinedButton.icon(
          key: ValueKey(key),
          onPressed: onTap,
          icon: Icon(icon, size: 16),
          label: Text(label, style: inter(13, 600)),
          style: OutlinedButton.styleFrom(foregroundColor: kInk, side: const BorderSide(color: kLine), visualDensity: VisualDensity.compact, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        );
    return SvcCard(title: 'Photo', children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          key: const ValueKey('photo-preview'),
          width: 96,
          height: 96,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(14)),
          child: _photo != null
              ? Image.memory(_photo!.bytes, fit: BoxFit.cover)
              : _standard != null
                  ? Image.network(_standard!.imageUrl, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.imageOff, color: kMuted))
                  : shown
                  ? Image.network(_savedUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.imageOff, color: kMuted))
                  : const Icon(LucideIcons.imagePlus, size: 30, color: kInk),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(shown ? 'Customers see this photo on the service.' : 'Add a photo so customers see the service.', style: inter(12.5, 400, color: kMuted)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              button('Camera', LucideIcons.camera, 'photo-camera', () => _getPhoto(true)),
              button('Gallery', LucideIcons.image, 'photo-gallery', () => _getPhoto(false)),
              button('Standard', LucideIcons.images, 'photo-standard', _getStandard),
              if (_photo != null && !_photo!.backgroundRemoved)
                button(_cutting ? 'Removing…' : 'Remove background', LucideIcons.wandSparkles, 'photo-cutout', _cutting ? null : _cutOut),
              if (shown) button('Remove', LucideIcons.trash2, 'photo-remove', _clearPhoto),
            ]),
          ]),
        ),
      ]),
    ]);
  }

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
      final photoProblem = await _savePhoto(saved.id);
      if (!mounted) return;
      showToast(context, photoProblem == null ? '${saved.name} saved.' : '${saved.name} saved. $photoProblem');
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
          TextField(key: ValueKey('field-$label'), controller: c, keyboardType: keyboard, inputFormatters: numberOnly(keyboard), minLines: lines, maxLines: lines, decoration: InputDecoration(hintText: hint), onChanged: (_) => _key = null),
        ]),
      );

  @override
  Widget build(BuildContext context) => ServicePage(
        title: d == null ? 'Add service' : 'Edit service',
        subtitle: d == null ? 'Name, price and how it is booked' : '${d!.s('code')} · ${d!.name}',
        business: widget.business,
        body: [
          _photoCard(),
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
            // a plain row: a SwitchListTile inside the white card trips Flutter's ink assertion
            Row(children: [
              Expanded(child: Text('Add-on to another service', style: inter(14.5, 500))),
              Switch(
                key: const ValueKey('addon-switch'),
                value: _addon,
                onChanged: (v) => setState(() {
                  _addon = v;
                  _key = null;
                }),
              ),
            ]),
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
