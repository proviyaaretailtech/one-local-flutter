import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'price_basis.dart';
import 'sku_api.dart';

// The SKU picker (founder's "OL SKU.xlsx", 31 Oct 2026): subcategory, brand / item code and size; the SKU is shown, never typed, and
// never made from the name. Its number (-01, -02) is given by the database when the item is saved.

const _line = Color(0xFFD9DBD5);

class SkuPicker extends StatefulWidget {
  const SkuPicker({super.key, required this.api, required this.basis, required this.onChanged, this.matched, this.barcode});
  final SkuApi api;
  final PriceBasis basis;

  /// The parts once all three are chosen (null until then).
  final ValueChanged<SkuParts?> onChanged;

  /// The OneLocal product the barcode matched: its parts are taken and its SKU is reused.
  final MasterProduct? matched;

  /// The pack's barcode, sent with a new brand so Master review sees it.
  final String? barcode;

  @override
  State<SkuPicker> createState() => SkuPickerState();
}

class SkuPickerState extends State<SkuPicker> {
  SkuOptions? _o;
  String? _error;
  SkuSub? _sub;
  SkuBrand? _brand;
  String? _unit;
  final _qty = TextEditingController();
  List<MasterProduct> _variants = const [];
  String? _master; // a variant chosen as the same product
  bool _newVariant = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SkuPicker old) {
    super.didUpdateWidget(old);
    if (old.matched?.sku != widget.matched?.sku && widget.matched != null) _take(widget.matched!);
    if (old.basis != widget.basis) {
      _master = null;
      _newVariant = false;
      _variants = const [];
      _emit();
      _loadVariants();
    }
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final o = await widget.api.options();
      if (!mounted) return;
      setState(() => _o = o);
      if (widget.matched != null) _take(widget.matched!);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the OneLocal lists. Check your connection.');
    }
  }

  /// The barcode's OneLocal product: its subcategory, brand and size, and its SKU.
  void _take(MasterProduct m) {
    final o = _o;
    if (o == null) return;
    final size = RegExp(r'^((?:[0-9]+X)?[0-9]+(?:\.[0-9]+)?)?([A-Z]+)$').firstMatch(m.size);
    setState(() {
      _sub = o.subs.where((s) => s.code == m.sub).firstOrNull;
      _brand = o.brands.where((b) => b.code == m.slot3).firstOrNull;
      _qty.text = size?.group(1) ?? '';
      _unit = size?.group(2);
      _master = m.sku;
      _newVariant = false;
      _variants = [m];
    });
    _emit();
  }

  String? get _size {
    final u = _unit;
    if (u == null) return null;
    final q = _qty.text.trim().toUpperCase().replaceAll(' ', '');
    return '$q$u';
  }

  SkuParts? get _draft =>
      _sub == null || _brand == null || _size == null ? null : SkuParts(sub: _sub!.code, slot3: _brand!.code, size: _size!, masterSku: widget.basis == PriceBasis.mrp ? _master : null);

  /// The parts, once complete; when OneLocal already has products with these parts, only after saying whether it is one of them
  /// (never a second SKU for the same product).
  SkuParts? get parts => widget.basis == PriceBasis.mrp && widget.matched == null && _variants.isNotEmpty && _master == null && !_newVariant ? null : _draft;

  // told after the frame: a change can come while the screen above is building (a new price type, a barcode found)
  void _emit() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) widget.onChanged(parts);
  });

  Future<void> _loadVariants() async {
    final p = _draft;
    if (p == null || widget.basis != PriceBasis.mrp || widget.matched != null) return setState(() => _variants = const []);
    try {
      final v = await widget.api.variants(sub: p.sub, slot3: p.slot3, size: p.size);
      if (mounted && _draft?.sub == p.sub && _draft?.slot3 == p.slot3 && _draft?.size == p.size) {
        setState(() => _variants = v);
        _emit();
      }
    } catch (_) {}
  }

  void _changed() {
    _master = null;
    _newVariant = false;
    _emit();
    _loadVariants();
    setState(() {});
  }

  // ------------------------------------------------------------------ choosing
  Future<T?> _sheet<T>(String title, Widget Function(BuildContext, StateSetter, TextEditingController) body) {
    final q = TextEditingController();
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
          child: SizedBox(
            height: MediaQuery.sizeOf(c).height * 0.75,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                  child: Text(tr(title), style: inter(18, 800)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    key: const ValueKey('sku-search'),
                    controller: q,
                    autofocus: true,
                    onChanged: (_) => set(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: tr('Search'),
                      prefixIcon: const Icon(LucideIcons.search, size: 18),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(child: body(c, set, q)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickSub() async {
    final o = _o;
    if (o == null) return;
    final s = await _sheet<SkuSub>('Choose the subcategory', (c, set, q) {
      final t = q.text.trim().toLowerCase();
      final list = o.subs.where((s) => t.isEmpty || '${s.name} ${s.examples} ${s.code} ${s.category}'.toLowerCase().contains(t)).toList();
      return ListView(
        children: [
          for (final s in list)
            ListTile(
              key: ValueKey('sku-sub-${s.code}'),
              dense: true,
              title: Text('${s.name} · ${s.code}', style: inter(14.5, 700)),
              subtitle: Text(
                '${s.category} · ${s.examples}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: inter(12, 500, color: kMuted),
              ),
              onTap: () => Navigator.pop(c, s),
            ),
        ],
      );
    });
    if (s == null || !mounted) return;
    _sub = s;
    _changed();
  }

  /// MRP-based: brands. Store-based: loose items, local brands, and LSE (loose / unbranded).
  bool _fits(SkuBrand b) => widget.basis == PriceBasis.mrp ? b.kind != 'loose_item' : b.kind != 'brand';

  Future<void> _pickBrand() async {
    final o = _o;
    if (o == null) return;
    final store = widget.basis == PriceBasis.store;
    final b = await _sheet<Object>(store ? 'Choose the item or local brand' : 'Choose the brand', (c, set, q) {
      final t = q.text.trim().toLowerCase();
      final list = o.brands.where((b) => _fits(b) && (t.isEmpty || '${b.name} ${b.synonyms} ${b.code}'.toLowerCase().contains(t))).toList();
      return ListView(
        children: [
          for (final b in list)
            ListTile(
              key: ValueKey('sku-brand-${b.code}'),
              dense: true,
              title: Text('${b.name} · ${b.code}', style: inter(14.5, 700)),
              subtitle: Text(
                [
                  switch (b.kind) {
                    'loose_item' => tr('Loose item'),
                    'local_brand' => tr('Local brand'),
                    'reserved' => tr('No maker name'),
                    _ => tr('Brand'),
                  },
                  if (b.pending) tr('waiting for OneLocal review'),
                  if (b.synonyms.isNotEmpty) b.synonyms,
                ].join(' · '),
                style: inter(12, 500, color: b.pending ? const Color(0xFFB45309) : kMuted),
              ),
              onTap: () => Navigator.pop(c, b),
            ),
          if (q.text.trim().length >= 2 && !list.any((b) => b.name.toLowerCase() == t))
            ListTile(
              key: const ValueKey('sku-brand-new'),
              leading: const Icon(LucideIcons.plus, color: kLink),
              title: Text('${tr(store ? 'Add new item code' : 'Add new brand')} “${q.text.trim()}”', style: inter(14.5, 700, color: kLink)),
              subtitle: Text(tr('A code is made now and used at once. OneLocal reviews it with the product photo.'), style: inter(12, 500, color: kMuted)),
              onTap: () => Navigator.pop(c, q.text.trim()),
            ),
        ],
      );
    });
    if (b == null || !mounted) return;
    if (b is String) {
      try {
        final made = await widget.api.proposeBrand(b, kind: store ? 'loose_item' : 'brand', barcode: widget.barcode);
        if (!mounted) return;
        setState(() => o.brands.add(made));
        _brand = made;
      } catch (e) {
        if (mounted) showToast(context, tr('Could not add that brand. Try again.'));
        return;
      }
    } else {
      _brand = b as SkuBrand;
    }
    _changed();
  }

  // ------------------------------------------------------------------ build
  Widget _box(String label, String? value, Key key, VoidCallback? onTap, {String? hint}) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(label), style: inter(12, 700, color: kMuted)),
        const SizedBox(height: 4),
        InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _line),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value ?? tr(hint ?? 'Choose'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: inter(14, value == null ? 500 : 700, color: value == null ? kMuted : kInk),
                  ),
                ),
                const Icon(LucideIcons.chevronDown, size: 16, color: kMuted),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  String get _preview {
    final o = _o;
    final sub = _sub?.code ?? '···', slot = _brand?.code ?? '···', size = _size ?? '···';
    if (_master != null && widget.basis == PriceBasis.mrp) return _master!;
    return widget.basis == PriceBasis.mrp ? 'OL-$sub-$slot-$size-##' : 'OL-$sub-$slot-$size-${o?.initials ?? '···'}-${o?.lot ?? '····'}-##';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Row(
        children: [
          Expanded(
            child: Text(tr(_error!), style: inter(12.5, 600, color: kError)),
          ),
          TextButton(
            onPressed: _load,
            child: Text(tr('Try again'), style: inter(13, 700, color: kLink)),
          ),
        ],
      );
    }
    if (_o == null) return const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator(minHeight: 2));
    final locked = widget.matched != null;
    final units = _o!.units.where((u) => !const {'PLT', 'HLF', 'FUL', 'GLS', 'PRT', 'SES', 'HR', 'VIS', 'JOB', 'SQFT', 'MON', 'APT', 'TST', 'SEAT', 'TKT'}.contains(u)).toList();
    return Column(
      key: const ValueKey('sku-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _box('Subcategory', _sub == null ? null : '${_sub!.name} · ${_sub!.code}', const ValueKey('sku-sub'), locked ? null : _pickSub),
            const SizedBox(width: 8),
            _box(
              widget.basis == PriceBasis.store ? 'Item / local brand' : 'Brand',
              _brand == null ? null : '${_brand!.name} · ${_brand!.code}',
              const ValueKey('sku-brand'),
              locked ? null : _pickBrand,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(tr('Size'), style: inter(12, 700, color: kMuted)),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(
              width: 92,
              height: 46,
              child: TextField(
                key: const ValueKey('sku-qty'),
                controller: _qty,
                enabled: !locked,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.xX]')), LengthLimitingTextInputFormatter(8)],
                onChanged: (_) => _changed(),
                style: inter(14.5, 700),
                decoration: InputDecoration(
                  hintText: widget.basis == PriceBasis.store ? tr('—') : '500',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _line),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final u in units)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          key: ValueKey('sku-unit-$u'),
                          label: Text(u, style: inter(12.5, _unit == u ? 800 : 600)),
                          selected: _unit == u,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          selectedColor: const Color(0xFFD2F64B),
                          backgroundColor: Colors.white,
                          side: BorderSide(color: _unit == u ? const Color(0xFFB9E33A) : _line),
                          onSelected: locked
                              ? null
                              : (_) {
                                  _unit = u;
                                  _changed();
                                },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            tr(widget.basis == PriceBasis.store ? 'Loose goods: the unit alone (KG). Packs: the size, like 500G or 6X80G.' : 'The pack size, like 500G, 1L or 6X80G.'),
            style: inter(11.5, 500, color: kMuted),
          ),
        ),
        if (_variants.isNotEmpty && widget.basis == PriceBasis.mrp && !locked) ...[
          const SizedBox(height: 10),
          Text(tr('Already on OneLocal: is it one of these?'), style: inter(12.5, 800)),
          Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                for (final v in _variants)
                  RadioListTile<String>(
                    key: ValueKey('sku-variant-${v.sku}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: v.sku,
                    groupValue: _master ?? (_newVariant ? '' : null),
                    onChanged: (_) {
                      setState(() => _master = v.sku);
                      _emit();
                    },
                    title: Text('${v.name} · ${v.sku}', style: inter(13.5, 700)),
                    subtitle: v.barcode == null ? null : Text('${tr('Barcode')} ${v.barcode}', style: inter(11.5, 500, color: kMuted)),
                  ),
                RadioListTile<String>(
                  key: const ValueKey('sku-variant-new'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: '',
                  groupValue: _master ?? (_newVariant ? '' : null),
                  onChanged: (_) {
                    setState(() {
                      _master = null;
                      _newVariant = true;
                    });
                    _emit();
                  },
                  title: Text(tr('No, a different product (new variant)'), style: inter(13.5, 700)),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: const Color(0xFFF1FAE8), borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              const Icon(LucideIcons.tag, size: 16, color: Color(0xFF2F8A0B)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _preview,
                      key: const ValueKey('sku-preview'),
                      style: inter(14, 800, color: kInk),
                    ),
                    Text(
                      tr(
                        _master != null && widget.basis == PriceBasis.mrp
                            ? (locked ? 'Found by its barcode on OneLocal: the same SKU.' : 'The same OneLocal product: the same SKU.')
                            : 'SKU · made by the system, never changes. ## is given when you save.',
                      ),
                      style: inter(11.5, 500, color: kMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// True when the item's SKU still has to be chosen: a short message, or null when the parts are complete.
String? skuProblem(SkuParts? p) => p == null ? 'Choose the subcategory, brand and size for the SKU.' : null;
