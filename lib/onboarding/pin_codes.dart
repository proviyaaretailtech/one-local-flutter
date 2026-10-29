/// Which states a PIN code can belong to, from its first three digits (India Post's postal circles). Some ranges are shared
/// (Uttar Pradesh and Uttarakhand, Punjab and Chandigarh, Maharashtra and Goa), so a match is "this state is one of them".
/// The server checks the same table (server/src/schemas/onboarding.ts).
const _pinRanges = <String, List<(int, int)>>{
  'Delhi': [(110, 110)],
  'Haryana': [(121, 136)],
  'Punjab': [(140, 160)],
  'Chandigarh': [(160, 160)],
  'Himachal Pradesh': [(171, 177)],
  'Jammu and Kashmir': [(180, 194)],
  'Ladakh': [(194, 194)],
  'Uttar Pradesh': [(201, 285)],
  'Uttarakhand': [(244, 249), (262, 263)],
  'Rajasthan': [(301, 345)],
  'Gujarat': [(360, 396)],
  'Dadra and Nagar Haveli and Daman and Diu': [(362, 362), (396, 396)],
  'Maharashtra': [(400, 445)],
  'Goa': [(403, 403)],
  'Madhya Pradesh': [(450, 488)],
  'Chhattisgarh': [(490, 497)],
  'Telangana': [(500, 509)],
  'Andhra Pradesh': [(507, 535)],
  'Karnataka': [(560, 591)],
  'Tamil Nadu': [(600, 643)],
  'Puducherry': [(533, 533), (605, 605), (609, 609), (673, 673)],
  'Kerala': [(670, 695)],
  'Lakshadweep': [(682, 682)],
  'West Bengal': [(700, 743)],
  'Sikkim': [(737, 737)],
  'Andaman and Nicobar Islands': [(744, 744)],
  'Odisha': [(751, 770)],
  'Assam': [(781, 788)],
  'Arunachal Pradesh': [(790, 792)],
  'Meghalaya': [(793, 794)],
  'Manipur': [(795, 795)],
  'Mizoram': [(796, 796)],
  'Nagaland': [(797, 798)],
  'Tripura': [(799, 799)],
  'Bihar': [(800, 855)],
  'Jharkhand': [(813, 835)],
};

/// A 6-digit PIN code (not starting with 0).
bool pinLooksValid(String pin) => RegExp(r'^[1-9][0-9]{5}$').hasMatch(pin);

/// Whether [pin] can be in [state]. True for a state not in the table (nothing to check against).
bool pinFitsState(String pin, String? state) {
  final ranges = _pinRanges[state];
  if (ranges == null || !pinLooksValid(pin)) return true;
  final p = int.parse(pin.substring(0, 3));
  return ranges.any((r) => p >= r.$1 && p <= r.$2);
}
