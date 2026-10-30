// The units (and sizes) that fit a product's category (founder, 31 Oct 2026): a store selling both groceries and clothes sees kg, l, pack
// for rice and S, M, XL for a shirt, never both. The categories are the store categories of onboarding (server/src/data/partner-taxonomy.json).
// A size is not a unit: the item is counted in pieces (pc) and the size is kept with it ("Size M"). Any other unit can be typed.

/// What a category is counted in, and the sizes it comes in (empty when sizes do not apply).
typedef CategoryUnits = ({List<String> units, List<String> sizes});

const _clothes = ['XS', 'S', 'M', 'L', 'XL', 'XXL', '3XL', 'Free size', '28', '30', '32', '34', '36', '38', '40', 'UK 3', 'UK 4', 'UK 5', 'UK 6', 'UK 7', 'UK 8', 'UK 9', 'UK 10', 'UK 11', 'UK 12'];
const _sportswear = ['XS', 'S', 'M', 'L', 'XL', 'XXL', 'Free size'];

/// Every store category, in the order onboarding lists them, with its units (most used first).
const Map<String, CategoryUnits> kCategoryUnits = {
  'Fashion': (units: ['pc', 'pair', 'set'], sizes: _clothes),
  'Accessories': (units: ['pc', 'pair', 'set', 'box'], sizes: []),
  'Beauty and health': (units: ['pc', 'ml', 'l', 'g', 'kg', 'pack', 'strip', 'box'], sizes: []),
  'Electronics': (units: ['pc', 'set', 'box', 'metre'], sizes: []),
  'Home': (units: ['pc', 'set', 'pair', 'metre', 'kg', 'l', 'box'], sizes: []),
  'Kids, school and office': (units: ['pc', 'pack', 'set', 'box', 'dozen', 'ream'], sizes: []),
  'Pets and garden': (units: ['pc', 'kg', 'g', 'pack', 'l'], sizes: []),
  'Puja and festive': (units: ['pc', 'pack', 'box', 'dozen', 'kg', 'g', 'bunch'], sizes: []),
  'Sports and hobby': (units: ['pc', 'pair', 'set'], sizes: _sportswear),
  'Automotive': (units: ['pc', 'set', 'pair', 'l', 'ml'], sizes: []),
  'Other': (units: ['pc', 'pack', 'set', 'box', 'pair'], sizes: []),
  'Grocery': (units: ['kg', 'g', 'pc', 'pack', 'l', 'ml', 'box'], sizes: []),
  'Fresh food': (units: ['kg', 'g', 'pc', 'dozen', 'bunch'], sizes: []),
  'Dairy': (units: ['l', 'ml', 'kg', 'g', 'pc', 'pack'], sizes: []),
  'Meat': (units: ['kg', 'g', 'pc', 'dozen', 'pack'], sizes: []),
  'Bakery and sweets': (units: ['pc', 'kg', 'g', 'pack', 'box', 'dozen'], sizes: []),
  'Ready to cook and eat': (units: ['pack', 'pc', 'kg', 'g', 'box'], sizes: []),
  'Drinks': (units: ['pc', 'pack', 'box', 'l', 'ml'], sizes: []),
  'Household essentials': (units: ['pc', 'pack', 'l', 'ml', 'kg', 'box'], sizes: []),
  'Daily subscriptions': (units: ['l', 'ml', 'pc', 'pack', 'kg'], sizes: []),
};

/// A category that is not on the list (an older one, or typed by the store): every common unit.
const CategoryUnits kAnyUnits = (units: ['pc', 'pack', 'kg', 'g', 'l', 'ml', 'dozen', 'box', 'pair', 'set', 'metre'], sizes: []);

CategoryUnits unitsFor(String? category) => kCategoryUnits[category?.trim()] ?? kAnyUnits;

/// What a unit is called in the list.
String unitName(String u) => switch (u) {
      'pc' => 'Piece (pc)',
      'pack' => 'Pack',
      'kg' => 'Kilogram (kg)',
      'g' => 'Gram (g)',
      'l' => 'Litre (l)',
      'ml' => 'Millilitre (ml)',
      'dozen' => 'Dozen',
      'box' => 'Box',
      'pair' => 'Pair',
      'set' => 'Set',
      'metre' => 'Metre',
      'bunch' => 'Bunch',
      'strip' => 'Strip',
      'ream' => 'Ream',
      _ => u,
    };

/// "Size M" as kept with the item, and back.
String sizeNote(String size) => 'Size $size';
String? sizeFrom(String? note) => note != null && note.startsWith('Size ') ? note.substring(5) : null;

/// A unit the store types: small letters, a short word ("roll", "sheet").
String? cleanUnit(String typed) {
  final u = typed.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return RegExp(r'^[a-z][a-z0-9 .-]{0,11}$').hasMatch(u) ? u : null;
}
