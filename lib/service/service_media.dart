import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/rpc_client.dart';
import '../auth/partner_api.dart' show PartnerApiException;
import '../media/media_api.dart' show PoolPhoto;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'catalogue_screen.dart' show servicePhoto;
import 'service_widgets.dart';

// Media for services (founder, 2 Nov 2026: "a standard media manager just like store POS"). The store's media pool, for services: the
// business's own service photos are its own; it may offer one to OneLocal; a photo OneLocal approves becomes a standard photo that other
// businesses of the same kind of service can put on theirs. Kinds where a stock photo would mislead (events and portfolio work, health,
// professional advice) keep their own photos only. Data: svc_media_* (C:\onelocal\hosted_service_media_2026-11-02.sql); OneLocal reviews
// service photos in the same queue as product photos.

/// One of the business's services, with its photo and where that photo stands in the pool.
class ServicePhotoRow {
  ServicePhotoRow(this.raw);
  final Map<String, dynamic> raw;
  String get serviceId => '${raw['service_id']}';
  String get name => '${raw['name'] ?? ''}';
  String get category => '${raw['category'] ?? ''}';
  String get type => '${raw['type'] ?? ''}';
  String? get imageUrl => raw['image_url'] as String?;
  bool get own => raw['own'] == true;
  bool get fromStandard => raw['from_standard'] == true;
  PoolPhoto? get pool => raw['pool'] is Map ? PoolPhoto((raw['pool'] as Map).cast<String, dynamic>()) : null;
  bool get canOffer => own && (pool == null || pool!.status == 'rejected' || pool!.status == 'withdrawn');
}

class ServiceMediaPool {
  ServiceMediaPool(this.raw);
  final Map<String, dynamic> raw;
  String get kind => '${raw['kind'] ?? ''}';
  bool get standardOk => raw['standard_ok'] == true;
  bool get canEdit => raw['can_edit'] == true;
  int count(String k) => (((raw['counts'] as Map?) ?? const {})[k] as num? ?? 0).toInt();
  List<ServicePhotoRow> _rows(String k) => ((raw[k] as List?) ?? const []).map((e) => ServicePhotoRow((e as Map).cast<String, dynamic>())).toList();
  List<ServicePhotoRow> get items => _rows('items');
  List<ServicePhotoRow> get withoutPhoto => _rows('without_photo');
}

class ServiceStandard {
  ServiceStandard(this.raw);
  final Map<String, dynamic> raw;
  String get kind => '${raw['kind'] ?? ''}';
  bool get standardOk => raw['standard_ok'] == true;
  String get filter => '${raw['filter'] ?? 'all'}';
  int get total => (raw['total'] as num? ?? 0).toInt();
  List<PoolPhoto> get items => ((raw['items'] as List?) ?? const []).map((e) => PoolPhoto((e as Map).cast<String, dynamic>())).toList();
  List<({String kind, int count})> get kinds =>
      [for (final k in ((raw['kinds'] as List?) ?? const []).cast<Map>()) (kind: '${k['kind']}', count: (k['count'] as num? ?? 0).toInt())];
}

class ServiceMediaApi {
  ServiceMediaApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<ServiceMediaPool> pool({String q = ''}) async => ServiceMediaPool(await _rpc.callMap('svc_media_pool', {if (q.trim().isNotEmpty) 'q': q.trim()}));
  Future<PoolPhoto> offer(String serviceId) async => PoolPhoto(await _rpc.callMap('svc_media_offer', {'service_id': serviceId}));
  Future<PoolPhoto> withdraw(String poolId) async => PoolPhoto(await _rpc.callMap('svc_media_withdraw', {'pool_id': poolId}));

  /// Standard photos: [kind] null = this business's kind, 'all' = every kind; with [serviceId], the best matches for that service first.
  Future<ServiceStandard> standard({String q = '', String? kind, String? serviceId}) async => ServiceStandard(await _rpc.callMap('svc_media_standard', {
        if (q.trim().isNotEmpty) 'q': q.trim(),
        'kind': ?kind,
        'service_id': ?serviceId,
      }));

  /// Puts a standard photo on one of the business's services; answers its link.
  Future<String> use(String poolId, String serviceId) async => '${(await _rpc.callMap('svc_media_use', {'pool_id': poolId, 'service_id': serviceId}))['image_url']}';
}

String _err(Object e, String fallback) => e is PartnerApiException ? e.message : fallback;

Widget _chip(String text, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 700, color: fg)),
    );

Widget _photo(String url) => Container(
      decoration: BoxDecoration(color: const Color(0xFFF3F4F1), borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Image.network(url, fit: BoxFit.cover, width: double.infinity, errorBuilder: (_, _, _) => const Center(child: Icon(LucideIcons.imageOff, color: kMuted, size: 20))),
    );

/// The note for a kind of service that keeps its own photos.
String ownOnlyNote(String kind) => '${kind.isEmpty ? 'Your kind of service' : kind} shows your own work, so your photos stay yours and standard photos are not used.';

/// Media (service side menu): My photos and Standard media.
class ServiceMediaScreen extends StatefulWidget {
  const ServiceMediaScreen({super.key, this.api});
  final ServiceMediaApi? api;
  @override
  State<ServiceMediaScreen> createState() => _ServiceMediaScreenState();
}

class _ServiceMediaScreenState extends State<ServiceMediaScreen> {
  late final ServiceMediaApi _api = widget.api ?? ServiceMediaApi();
  String _tab = 'mine';
  ServiceMediaPool? _pool;
  ServiceStandard? _std;
  String? _kind; // the Standard tab's kind: null = this business's, 'all' = every kind
  String _q = '';
  String? _error, _busy;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() => _error = null);
    try {
      if (_tab == 'mine') {
        final p = await _api.pool(q: _q);
        if (mounted && mine == _seq) setState(() => _pool = p);
      } else {
        final s = await _api.standard(q: _q, kind: _kind);
        if (mounted && mine == _seq) setState(() => _std = s);
      }
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = _err(e, 'Could not load photos. Check the connection and try again.'));
    }
  }

  Future<void> _act(String id, Future<Object> Function() f, String done) async {
    setState(() => _busy = id);
    try {
      await f();
      if (mounted) showToast(context, done);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not save. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _offer(ServicePhotoRow s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Offer this photo to OneLocal?', style: inter(17, 700)),
        content: Text('OneLocal checks it. Once approved it becomes a standard photo, and other businesses of your kind can use it on the same service. You can take it back any time.',
            style: inter(14, 400, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(key: const ValueKey('offer-confirm'), onPressed: () => Navigator.pop(c, true), child: const Text('Offer it')),
        ],
      ),
    );
    if (ok == true && mounted) await _act(s.serviceId, () => _api.offer(s.serviceId), 'Offered. OneLocal will review it.');
  }

  /// A standard photo for a service without one (My photos), or a service for a standard photo (Standard media).
  Future<void> _useOn(String serviceId, String serviceName) async {
    final chosen = await pickServiceStandardPhoto(context, _api, serviceId: serviceId, serviceName: serviceName);
    if (chosen != null && mounted) await _act(serviceId, () => _api.use(chosen.id, serviceId), 'Photo put on $serviceName.');
  }

  Future<void> _useStandard(PoolPhoto p) async {
    final pool = _pool ?? await _api.pool();
    if (!mounted) return;
    final all = [...pool.withoutPhoto, ...pool.items];
    final service = await showOrderSheet<ServicePhotoRow>(context, title: 'Use on which service?', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
          if (all.isEmpty) Text('No service yet. Add one in the catalogue.', style: inter(14, 400, color: kMuted)),
          for (final s in all)
            ListTile(
              key: ValueKey('use-on-${s.serviceId}'),
              contentPadding: EdgeInsets.zero,
              leading: servicePhoto(s.imageUrl, s.type, size: 40),
              title: Text(s.name, style: inter(14.5, 600)),
              subtitle: Text(s.imageUrl == null ? 'No photo yet' : 'Replaces its photo', style: inter(12, 400, color: kMuted)),
              onTap: () => Navigator.pop(ctx, s),
            ),
        ]));
    if (service != null && mounted) await _act(p.id, () => _api.use(p.id, service.serviceId), 'Photo put on ${service.name}.');
  }

  @override
  Widget build(BuildContext context) {
    final body = _tab == 'mine' ? (_pool == null ? null : _mine(_pool!)) : (_std == null ? null : _standard(_std!));
    return ServicePage(
      title: 'Media',
      subtitle: 'Photos on your services, and standard photos',
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: [
        Row(children: [
          for (final (id, label) in const [('mine', 'My photos'), ('standard', 'Standard media')])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ModeChip(label, key: ValueKey('media-tab-$id'), selected: _tab == id, onTap: () {
                if (_tab == id) return;
                setState(() => _tab = id);
                _load();
              }),
            ),
        ]),
        const SizedBox(height: 10),
        SvcSearch(hint: _tab == 'mine' ? 'Search your services' : 'Search standard photos', fieldKey: const ValueKey('media-search'), onChanged: (v) {
          _q = v;
          _load();
        }),
        const SizedBox(height: 10),
        if (body == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5))) else ...body,
      ],
    );
  }

  // ------------------------------------------------------------------------------------------------ My photos
  List<Widget> _mine(ServiceMediaPool p) => [
        Text(
          p.standardOk
              ? 'Your service photos. Offer your own to OneLocal: once approved, other businesses of your kind can use them. Nothing is shared unless you offer it.'
              : ownOnlyNote(p.kind),
          key: const ValueKey('media-note'),
          style: inter(12.5, 500, color: kMuted, height: 1.35),
        ),
        const SizedBox(height: 6),
        Text('${p.count('photos')} photos · ${p.count('offered')} waiting · ${p.count('approved')} standard', key: const ValueKey('media-counts'), style: inter(12.5, 700)),
        const SizedBox(height: 10),
        if (p.items.isEmpty) OrderCardBox(child: Text('No service has a photo yet. Add one on the service, or use a standard photo below.', style: inter(13.5, 400, color: kMuted))),
        if (p.items.isNotEmpty) _grid([for (final s in p.items) _mineTile(s, p)]),
        if (p.withoutPhoto.isNotEmpty) ...[
          const SizedBox(height: 14),
          SvcSectionHead('Without a photo', count: '${p.withoutPhoto.length}'),
          for (final s in p.withoutPhoto)
            Container(
              key: ValueKey('nophoto-${s.serviceId}'),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
              child: Row(children: [
                servicePhoto(null, s.type, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 700)),
                    if (s.category.isNotEmpty) Text(s.category, style: inter(12, 400, color: kMuted)),
                  ]),
                ),
                if (_busy == s.serviceId)
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                else if (p.standardOk && p.canEdit)
                  TextButton(key: ValueKey('standard-for-${s.serviceId}'), onPressed: () => _useOn(s.serviceId, s.name), child: Text('Standard photo', style: inter(13, 700, color: kGreenText))),
              ]),
            ),
        ],
      ];

  Widget _grid(List<Widget> tiles) => LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
      });

  Widget _mineTile(ServicePhotoRow s, ServiceMediaPool p) => Container(
        key: ValueKey('mine-${s.serviceId}'),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(aspectRatio: 4 / 3, child: _photo(s.imageUrl ?? '')),
          const SizedBox(height: 6),
          Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 700)),
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerLeft, child: _status(s)),
          if (s.pool?.status == 'rejected' && (s.pool!.note ?? '').isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 3), child: Text(s.pool!.note!, maxLines: 2, style: inter(11, 500, color: kBadText))),
          SizedBox(height: 32, child: Align(alignment: Alignment.centerLeft, child: _action(s, p))),
        ]),
      );

  Widget _status(ServicePhotoRow s) => s.pool != null
      ? switch (s.pool!.status) {
          'approved' => _chip(s.pool!.uses > 0 ? 'Standard · used by ${s.pool!.uses}' : 'Standard photo', kChipGreen, kGreenText),
          'submitted' => _chip('Waiting for review', const Color(0xFFFFF4E0), const Color(0xFFB45309)),
          'rejected' => _chip('Not approved', kBadBg, kBadText),
          _ => _chip('Taken back', const Color(0xFFF3F4F1), kMuted),
        }
      : s.fromStandard
          ? _chip('From standard media', kChipGreen, kGreenText)
          : _chip('Only your business', const Color(0xFFF3F4F1), kMuted);

  Widget _action(ServicePhotoRow s, ServiceMediaPool p) {
    if (_busy == s.serviceId) return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    if (!p.canEdit || !p.standardOk) return const SizedBox.shrink();
    if (s.canOffer) {
      return TextButton(
        key: ValueKey('offer-${s.serviceId}'),
        style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
        onPressed: () => _offer(s),
        child: Text(s.pool == null ? 'Offer to OneLocal' : 'Offer again', style: inter(13, 800, color: kGreenText)),
      );
    }
    if (s.pool != null && (s.pool!.status == 'submitted' || s.pool!.status == 'approved')) {
      return TextButton(
        key: ValueKey('withdraw-${s.serviceId}'),
        style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
        onPressed: () => _act(s.serviceId, () => _api.withdraw(s.pool!.id), 'Taken back. Businesses already using it keep it.'),
        child: Text('Take back', style: inter(13, 700, color: kMuted)),
      );
    }
    return const SizedBox.shrink();
  }

  // ------------------------------------------------------------------------------------------------ Standard media
  List<Widget> _standard(ServiceStandard s) {
    if (!s.standardOk) return [OrderCardBox(key: const ValueKey('media-own-only'), child: Text(ownOnlyNote(s.kind), style: inter(13.5, 400, color: kMuted)))];
    final mineKind = _kind == null;
    return [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ModeChip('${s.kind} (yours)', key: const ValueKey('kind-mine'), selected: mineKind, onTap: () => _pickKind(null)),
          ),
          Padding(padding: const EdgeInsets.only(right: 6), child: ModeChip('All kinds · ${s.total}', key: const ValueKey('kind-all'), selected: _kind == 'all', onTap: () => _pickKind('all'))),
          for (final k in s.kinds.where((k) => k.kind != s.kind))
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ModeChip('${k.kind} · ${k.count}', key: ValueKey('kind-${k.kind}'), selected: _kind == k.kind, onTap: () => _pickKind(k.kind)),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      Text('Approved by OneLocal. Tap a photo to put it on one of your services.', style: inter(12.5, 500, color: kMuted)),
      const SizedBox(height: 10),
      if (s.items.isEmpty)
        OrderCardBox(
          key: const ValueKey('standard-empty'),
          child: Text(_q.isNotEmpty ? 'No standard photo matches "$_q".' : 'No standard photos here yet. They appear as businesses offer theirs and OneLocal approves them.',
              style: inter(13.5, 400, color: kMuted)),
        )
      else
        _grid([
          for (final p in s.items)
            InkWell(
              key: ValueKey('standard-${p.id}'),
              borderRadius: BorderRadius.circular(14),
              onTap: _busy == p.id ? null : () => _useStandard(p),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  AspectRatio(aspectRatio: 4 / 3, child: _photo(p.imageUrl)),
                  const SizedBox(height: 6),
                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 700)),
                  Text([if ((p.productCategory ?? '').isNotEmpty) p.productCategory!, if (p.uses > 0) 'used by ${p.uses}'].join(' · '),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
                ]),
              ),
            ),
        ]),
    ];
  }

  void _pickKind(String? k) {
    setState(() => _kind = k);
    _load();
  }
}

/// A standard photo for one service, best matches first (every kind, the business's own kind ranked up). Null when closed.
Future<PoolPhoto?> pickServiceStandardPhoto(BuildContext context, ServiceMediaApi api, {String? serviceId, required String serviceName}) =>
    showOrderSheet<PoolPhoto>(context, title: 'Standard photos', body: (ctx) => _StandardPicker(api: api, serviceId: serviceId, serviceName: serviceName));

class _StandardPicker extends StatefulWidget {
  const _StandardPicker({required this.api, required this.serviceId, required this.serviceName});
  final ServiceMediaApi api;
  final String? serviceId;
  final String serviceName;
  @override
  State<_StandardPicker> createState() => _StandardPickerState();
}

class _StandardPickerState extends State<_StandardPicker> {
  ServiceStandard? _s;
  String? _error;
  late String _q = widget.serviceId == null ? widget.serviceName : '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.api.standard(q: _q, kind: 'all', serviceId: widget.serviceId);
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load standard photos.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (_error != null) return Text(_error!, style: inter(14, 400, color: kMuted));
    if (s == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)));
    if (!s.standardOk) return Text(ownOnlyNote(s.kind), style: inter(14, 400, color: kMuted));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SvcSearch(hint: 'Search standard photos', fieldKey: const ValueKey('standard-search'), onChanged: (v) {
        _q = v;
        _load();
      }),
      const SizedBox(height: 10),
      if (s.items.isEmpty)
        Padding(padding: const EdgeInsets.all(12), child: Text('No standard photo for ${widget.serviceName.isEmpty ? 'this' : '"${widget.serviceName}"'} yet.', style: inter(13.5, 400, color: kMuted)))
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.78,
            children: [
              for (final p in s.items)
                InkWell(
                  key: ValueKey('pick-${p.id}'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(context, p),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: _photo(p.imageUrl)),
                    const SizedBox(height: 4),
                    Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 600)),
                  ]),
                ),
            ],
          ),
        ),
    ]);
  }
}
