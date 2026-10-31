import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../barcodes/barcodes_api.dart';
import '../orders/order_widgets.dart';
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'media_api.dart';

/// Side menu → Product photos (founder, 30 Oct 2026). My photos is the Store Media Pool: the store's item photos, each of its own ones can be
/// offered to OneLocal. Standard photos is the Standard Data pool: photos OneLocal approved, which any store may put on its items. Review is
/// for OneLocal only (platform admins): the Master Media Pool grouped by store category, then brand / product category, to approve or reject.
class ProductPhotosScreen extends StatefulWidget {
  const ProductPhotosScreen({super.key, this.api, this.items});
  final MediaApi? api;

  /// Where the store's items are listed (for "Use on an item"). Tests pass a fake.
  final BarcodesApi? items;
  static Route<void> route({MediaApi? api, BarcodesApi? items}) => MaterialPageRoute(builder: (_) => ProductPhotosScreen(api: api, items: items));
  @override
  State<ProductPhotosScreen> createState() => _ProductPhotosScreenState();
}

String _err(Object e, String fallback) => e is PartnerApiException ? e.message : fallback;

Widget _thumb(String url, {double size = 56}) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: const Color(0xFFF3F4F1), borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Image.network(url, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(LucideIcons.imageOff, color: kMuted, size: 20)),
    );

Widget _chip(String text, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(text, style: inter(11.5, 700, color: fg)),
    );

Widget _statusChip(PoolPhoto p) => switch (p.status) {
      'approved' => _chip(tr(p.statusLabel), kChipGreen, kGreenText),
      'submitted' => _chip(tr(p.statusLabel), kWarnBg, kWarnText),
      'rejected' => _chip(tr(p.statusLabel), const Color(0xFFFDECEC), const Color(0xFFC62828)),
      _ => _chip(tr(p.statusLabel), const Color(0xFFF3F4F1), kMuted),
    };

class _ProductPhotosScreenState extends State<ProductPhotosScreen> {
  late final MediaApi api = widget.api ?? MediaApi();
  String _tab = 'mine';
  bool _admin = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          AppHeader(title: tr('Product photos'), back: true),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(children: [
              for (final (id, label) in [('mine', 'My photos'), ('standard', 'Standard photos'), if (_admin) ('review', 'Review')])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    key: ValueKey('photos-tab-$id'),
                    selected: _tab == id,
                    showCheckmark: false,
                    selectedColor: kInk,
                    labelStyle: inter(13, 700, color: _tab == id ? kLime : kInk),
                    label: Text(tr(label)),
                    onSelected: (_) => setState(() => _tab = id),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: switch (_tab) {
              'standard' => _Standard(api: api, items: widget.items ?? BarcodesApi()),
              'review' => _Review(api: api),
              _ => _Mine(api: api, onAdmin: (a) {
                  if (a != _admin && mounted) setState(() => _admin = a);
                }),
            },
          ),
        ]),
      );
}

// ---------------------------------------------------------------- My photos: the Store Media Pool

class _Mine extends StatefulWidget {
  const _Mine({required this.api, required this.onAdmin});
  final MediaApi api;
  final ValueChanged<bool> onAdmin;
  @override
  State<_Mine> createState() => _MineState();
}

class _MineState extends State<_Mine> {
  List<StorePhoto> _items = const [];
  Map<String, int> _counts = const {};
  bool _loading = true;
  String? _error, _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await widget.api.storePool();
      if (!mounted) return;
      setState(() {
        _items = r.items;
        _counts = r.counts;
      });
      widget.onAdmin(r.isAdmin);
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load your photos.'));
    } finally {
      if (mounted) setState(() => _loading = false);
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

  Future<void> _offer(StorePhoto s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Offer this photo to OneLocal?')),
        content: Text(tr('OneLocal checks it. Once approved it joins the Standard pool, and other stores across India can use it on the same product. You can take it back any time.')),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Not now'))), FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Offer it')))],
      ),
    );
    if (ok == true && mounted) await _act(s.itemId, () => widget.api.offer(s.itemId), 'Offered. OneLocal will review it.');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    if (_error != null) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        Text(tr('Your store\'s product photos. Offer your own to OneLocal: once approved, other stores can use them. Nothing is shared unless you offer it.'),
            style: inter(13, 500, color: kMuted, height: 1.35)),
        const SizedBox(height: 8),
        Text('${_counts['photos'] ?? 0} photos · ${_counts['offered'] ?? 0} waiting · ${_counts['approved'] ?? 0} in the Standard pool', key: const ValueKey('photos-counts'), style: inter(12.5, 700)),
        const SizedBox(height: 10),
        if (_items.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text(tr('No item has a photo yet. Add photos on your products.'), textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))),
        for (final s in _items) ...[
          Container(
            key: ValueKey('mine-${s.itemId}'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              _thumb(s.imageUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700)),
                  const SizedBox(height: 4),
                  if (s.pool != null) _statusChip(s.pool!)
                  else if (s.fromStandard) _chip(tr('From the Standard pool'), kChipGreen, kGreenText)
                  else if (!s.own) _chip(tr('Not taken by your store'), const Color(0xFFF3F4F1), kMuted)
                  else _chip(tr('Only your store'), const Color(0xFFF3F4F1), kMuted),
                  if (s.pool?.status == 'rejected' && (s.pool!.note ?? '').isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 4), child: Text(s.pool!.note!, style: inter(12, 500, color: const Color(0xFFC62828)))),
                  if (s.pool?.status == 'approved' && s.pool!.uses > 0)
                    Padding(padding: const EdgeInsets.only(top: 4), child: Text('Used by ${s.pool!.uses} ${s.pool!.uses == 1 ? 'store' : 'stores'}', style: inter(12, 500, color: kMuted))),
                ]),
              ),
              if (_busy == s.itemId)
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
              else if (s.canOffer)
                TextButton(key: ValueKey('offer-${s.itemId}'), onPressed: () => _offer(s), child: Text(tr(s.pool == null ? 'Offer' : 'Offer again'), style: inter(13.5, 800, color: kGreenText)))
              else if (s.pool != null && (s.pool!.status == 'submitted' || s.pool!.status == 'approved'))
                TextButton(
                  key: ValueKey('withdraw-${s.itemId}'),
                  onPressed: () => _act(s.itemId, () => widget.api.withdraw(s.pool!.id), 'Taken back. Stores already using it keep it.'),
                  child: Text(tr('Take back'), style: inter(13, 700, color: kMuted)),
                ),
            ]),
          ),
          const SizedBox(height: 8),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- Standard photos: the Standard Data pool

class _Standard extends StatefulWidget {
  const _Standard({required this.api, required this.items});
  final MediaApi api;
  final BarcodesApi items;
  @override
  State<_Standard> createState() => _StandardState();
}

class _StandardState extends State<_Standard> {
  final _q = TextEditingController();
  Timer? _wait;
  List<PoolPhoto> _photos = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await widget.api.standard(q: _q.text);
      if (mounted) setState(() => _photos = r);
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not load the Standard photos.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _useOn(PoolPhoto p) async {
    final item = await showModalBottomSheet<BcItem>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _ItemPicker(api: widget.items, hint: p.name),
    );
    if (item == null || !mounted) return;
    try {
      await widget.api.use(p.id, item.id);
      if (mounted) showToast(context, 'Photo put on ${item.name}.');
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not use the photo. Try again.'));
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            key: const ValueKey('standard-search'),
            controller: _q,
            decoration: InputDecoration(prefixIcon: const Icon(LucideIcons.search, size: 18), hintText: tr('Search product, brand or barcode')),
            onChanged: (_) {
              _wait?.cancel();
              _wait = Timer(const Duration(milliseconds: 300), _load);
            },
          ),
        ),
        Expanded(
          child: _loading && _photos.isEmpty
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _photos.isEmpty
                  ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(tr('No approved photos match yet.'), style: inter(14, 500, color: kMuted))))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: _photos.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, n) {
                        final p = _photos[n];
                        return Container(
                          key: ValueKey('standard-${p.id}'),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                          child: Row(children: [
                            _thumb(p.imageUrl, size: 64),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(14.5, 700)),
                                if (p.group.isNotEmpty) Text(p.group, style: inter(12, 500, color: kMuted)),
                                Text('${p.storeCategory} · used by ${p.uses}', style: inter(11.5, 500, color: kMuted)),
                              ]),
                            ),
                            TextButton(key: ValueKey('use-${p.id}'), onPressed: () => _useOn(p), child: Text(tr('Use'), style: inter(13.5, 800, color: kGreenText))),
                          ]),
                        );
                      },
                    ),
        ),
      ]);
}

/// Which of the store's items gets the photo.
class _ItemPicker extends StatefulWidget {
  const _ItemPicker({required this.api, required this.hint});
  final BarcodesApi api;
  final String hint;
  @override
  State<_ItemPicker> createState() => _ItemPickerState();
}

class _ItemPickerState extends State<_ItemPicker> {
  final _q = TextEditingController();
  List<BcItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.list(tab: 'all', q: _q.text);
      if (mounted) setState(() => _items = r.items);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Put it on which item?'), style: inter(18, 700)),
            Text(widget.hint, style: inter(13, 500, color: kMuted)),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('photo-item-search'),
              controller: _q,
              decoration: InputDecoration(prefixIcon: const Icon(LucideIcons.search, size: 18), hintText: tr('Search your items')),
              onChanged: (_) => _load(),
            ),
            Expanded(
              child: ListView(children: [
                for (final i in _items)
                  ListTile(
                    key: ValueKey('photo-item-${i.id}'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: i.imageUrl == null ? const Icon(LucideIcons.imageOff, color: kMuted) : _thumb(i.imageUrl!, size: 40),
                    title: Text(i.name, style: inter(14.5, 700)),
                    subtitle: Text(i.imageUrl == null ? tr('No photo yet') : tr('Has a photo: this replaces it'), style: inter(12, 500, color: kMuted)),
                    onTap: () => Navigator.pop(context, i),
                  ),
              ]),
            ),
          ]),
        ),
      );
}

/// From the item form: the Standard photos that best match one item (its pack barcode, brand, category, name), picked and put on it.
/// Answers the photo's link, or null.
Future<String?> pickStandardPhoto(BuildContext context, MediaApi api, {required String itemId, required String itemName}) =>
    showOrderSheet<String>(context, title: tr('Standard photos'), body: (_) => _StandardFor(api: api, itemId: itemId, itemName: itemName));

class _StandardFor extends StatefulWidget {
  const _StandardFor({required this.api, required this.itemId, required this.itemName});
  final MediaApi api;
  final String itemId, itemName;
  @override
  State<_StandardFor> createState() => _StandardForState();
}

class _StandardForState extends State<_StandardFor> {
  List<PoolPhoto>? _photos;
  String? _saving;

  @override
  void initState() {
    super.initState();
    widget.api.standard(itemId: widget.itemId).then((r) {
      if (mounted) setState(() => _photos = r);
    }, onError: (Object e) {
      if (mounted) setState(() => _photos = const []);
    });
  }

  Future<void> _use(PoolPhoto p) async {
    setState(() => _saving = p.id);
    try {
      final url = await widget.api.use(p.id, widget.itemId);
      if (mounted) Navigator.pop(context, url);
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not use the photo. Try again.'));
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _photos;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.55,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Approved photos that match ${widget.itemName}', style: inter(13, 500, color: kMuted)),
        const SizedBox(height: 10),
        Expanded(
          child: list == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : list.isEmpty
                  ? Center(child: Text(tr('No approved photo matches this item yet.'), key: const ValueKey('standard-for-none'), style: inter(14, 500, color: kMuted)))
                  : GridView.count(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 0.78,
                      children: [
                        for (final p in list)
                          InkWell(
                            key: ValueKey('standard-for-${p.id}'),
                            borderRadius: BorderRadius.circular(14),
                            onTap: _saving == null ? () => _use(p) : null,
                            child: Column(children: [
                              Stack(alignment: Alignment.center, children: [
                                _thumb(p.imageUrl, size: 96),
                                if (_saving == p.id) const CircularProgressIndicator(strokeWidth: 2),
                              ]),
                              const SizedBox(height: 4),
                              Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: inter(11.5, 600)),
                            ]),
                          ),
                      ],
                    ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- Review: the Master Media Pool (OneLocal only)

class _Review extends StatefulWidget {
  const _Review({required this.api});
  final MediaApi api;
  @override
  State<_Review> createState() => _ReviewState();
}

class _ReviewState extends State<_Review> {
  String _status = 'submitted';
  List<PoolPhoto> _items = const [];
  bool _loading = true;
  String? _error, _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.api.queue(status: _status);
      if (mounted) setState(() => _items = r.items);
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load the Master Media Pool.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _decide(PoolPhoto p, bool approve) async {
    String? note;
    bool? mapProduct;
    // a new OneLocal product waits with this photo: approve it as the standard product too (barcode, brand, unit, SKU)?
    if (approve && p.raw['master_status'] == 'pending') {
      var on = true;
      final go = await showDialog<bool>(
        context: context,
        builder: (d) => StatefulBuilder(
          builder: (d, set) => AlertDialog(
            title: Text(tr('Approve this photo')),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text([p.raw['sku'], if (p.raw['barcode'] != null) '${tr('Barcode')} ${p.raw['barcode']}', if (p.raw['brand_status'] == 'pending') '${tr('new brand')} ${p.raw['brand_code']}'].join(' · '),
                  style: inter(13, 600)),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const ValueKey('approve-map'),
                contentPadding: EdgeInsets.zero,
                value: on,
                onChanged: (v) => set(() => on = v ?? false),
                title: Text(tr('Also approve it as the standard product: its barcode, brand, unit and SKU join the Master library for every partner.'), style: inter(13, 500)),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Cancel'))),
              FilledButton(key: const ValueKey('approve-confirm'), onPressed: () => Navigator.pop(d, true), child: Text(tr('Approve'))),
            ],
          ),
        ),
      );
      if (go != true || !mounted) return;
      mapProduct = on;
    }
    if (!approve) {
      final c = TextEditingController();
      note = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(tr('Why is it not approved?')),
          content: TextField(key: const ValueKey('reject-note'), controller: c, maxLength: 300, decoration: InputDecoration(hintText: tr('Blurry, wrong product, has a watermark…'))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Cancel'))),
            FilledButton(key: const ValueKey('reject-confirm'), onPressed: () => Navigator.pop(d, c.text.trim()), child: Text(tr('Reject'))),
          ],
        ),
      );
      if (note == null || note.isEmpty || !mounted) return;
    }
    setState(() => _busy = p.id);
    try {
      await widget.api.decide(p.id, approve: approve, note: note, mapProduct: mapProduct);
      if (mounted) showToast(context, approve ? '${p.name} is in the Standard pool now.' : '${p.name} was not approved.');
      await _load();
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not save the decision.'));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    // grouped: store category, then brand (or product category when there is no brand)
    final groups = <String, List<PoolPhoto>>{};
    for (final p in _items) {
      groups.putIfAbsent('${p.storeCategory} › ${p.brand ?? p.productCategory ?? 'Other'}', () => []).add(p);
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(children: [
          for (final (id, label) in const [('submitted', 'Waiting'), ('approved', 'Approved'), ('rejected', 'Rejected')])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: ValueKey('review-$id'),
                selected: _status == id,
                label: Text(tr(label)),
                onSelected: (_) {
                  setState(() => _status = id);
                  _load();
                },
              ),
            ),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))))
                : _items.isEmpty
                    ? Center(child: Text(tr('Nothing here.'), style: inter(14, 500, color: kMuted)))
                    : ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 24), children: [
                        for (final g in groups.entries) ...[
                          Padding(padding: const EdgeInsets.only(top: 6, bottom: 6), child: Text('${g.key} · ${g.value.length}', style: inter(13, 800, color: kMuted))),
                          for (final p in g.value) ...[
                            Container(
                              key: ValueKey('review-${p.id}'),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                              child: Row(children: [
                                _thumb(p.imageUrl, size: 72),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(p.name, style: inter(14.5, 700)),
                                    Text([p.storeName, p.productCategory].whereType<String>().join(' · '), style: inter(12, 500, color: kMuted)),
                                    if (p.raw['sku'] != null)
                                      Text(
                                        [p.raw['sku'], if (p.raw['master_status'] == 'approved') tr('standard') else tr('product waiting')].join(' · '),
                                        key: ValueKey('review-sku-${p.id}'),
                                        style: inter(11.5, 700, color: p.raw['master_status'] == 'approved' ? kGreenText : const Color(0xFFB45309)),
                                      ),
                                    if (p.status == 'rejected' && p.note != null) Text(p.note!, style: inter(12, 500, color: const Color(0xFFC62828))),
                                  ]),
                                ),
                                if (_busy == p.id)
                                  const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                                else ...[
                                  if (p.status == 'submitted')
                                    IconButton(key: ValueKey('approve-${p.id}'), tooltip: tr('Approve'), onPressed: () => _decide(p, true), icon: const Icon(LucideIcons.check, color: kGreenText)),
                                  if (p.status != 'rejected')
                                    IconButton(key: ValueKey('reject-${p.id}'), tooltip: tr('Reject'), onPressed: () => _decide(p, false), icon: const Icon(LucideIcons.x, color: Color(0xFFC62828))),
                                ],
                              ]),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ]),
      ),
    ]);
  }
}
