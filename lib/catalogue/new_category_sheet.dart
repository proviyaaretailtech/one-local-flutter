import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'catalogue_widgets.dart' show OutlineButton;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import '../ui/i18n.dart';

/// Step 1 of "+ New" category on the Bill: name it (or tap a common one). Answers the trimmed name, or null when cancelled.
/// Step 2, adding its first product, is the caller's (a category only exists once a product is in it).
Future<String?> askNewCategory(BuildContext context, {List<String> existing = const []}) =>
    showDialog<String>(context: context, builder: (_) => _NewCategory(existing: existing));

const _examples = ['Snacks', 'Dairy', 'Beverages', 'Personal care', 'Household', 'Fruits & vegetables'];

class _NewCategory extends StatefulWidget {
  const _NewCategory({required this.existing});
  final List<String> existing;
  @override
  State<_NewCategory> createState() => _NewCategoryState();
}

class _NewCategoryState extends State<_NewCategory> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _value => _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');
  bool get _ready => _value.isNotEmpty && _value.length <= 60;

  @override
  Widget build(BuildContext context) {
    final ideas = _examples.where((e) => !widget.existing.any((x) => x.toLowerCase() == e.toLowerCase())).toList();
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(tr('New category'), style: inter(20, 700))),
            IconButton(tooltip: tr('Close'), onPressed: () => Navigator.of(context).pop(), icon: const Icon(LucideIcons.x, size: 20, color: kMuted)),
          ]),
          Text(tr('Group similar products so they are quick to find on the Bill. Next you add its first product.'), style: inter(13, 400, color: kMuted, height: 1.35)),
          const SizedBox(height: 16),
          Text(tr('Category name'), style: inter(13, 600)),
          const SizedBox(height: 6),
          Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFDADCD5))),
            child: TextField(
              key: const ValueKey('new-category-name'),
              controller: _name,
              autofocus: true,
              maxLength: 60,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _ready ? Navigator.of(context).pop(_value) : null,
              style: inter(14, 400),
              decoration: plainInput.copyWith(counterText: '', hintText: tr('For example Snacks'), hintStyle: inter(14, 400, color: kMuted)),
            ),
          ),
          if (ideas.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(tr('Or tap one'), style: inter(12, 500, color: kMuted)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in ideas)
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => setState(() => _name.text = e),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: _value == e ? kLimeSoft : const Color(0xFFF7F8F6),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _value == e ? kLime : const Color(0xFFE3E8E3)),
                    ),
                    child: Text(e, style: inter(13, _value == e ? 600 : 400)),
                  ),
                ),
            ]),
          ],
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: OutlineButton(tr('Cancel'), onPressed: () => Navigator.of(context).pop(), height: 48)),
            const SizedBox(width: 10),
            Expanded(
              child: Material(
                color: _ready ? kPrimary : const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(24),
                child: InkWell(
                  key: const ValueKey('new-category-next'),
                  borderRadius: BorderRadius.circular(24),
                  onTap: _ready ? () => Navigator.of(context).pop(_value) : null,
                  child: SizedBox(height: 48, child: Center(child: Text(tr('Next: add product'), style: inter(14, 700, color: _ready ? kLime : kMuted)))),
                ),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
