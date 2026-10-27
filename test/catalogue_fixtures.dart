// Server answers for the section G tests (shapes as in server/ENDPOINTS.md).
Map<String, dynamic> item(String id, String name, String sku, int price, {String unit = 'pc', String category = 'Beverages', num? stock, String status = 'active', bool barcode = true, int version = 1, String? desc}) => {
      'id': id,
      'name': name,
      'sku': sku,
      'category': category,
      'price_minor': price,
      'mrp_minor': null,
      'currency': 'INR',
      'selling_unit': unit,
      'net_qty': null,
      'net_qty_unit': null,
      'unit_description': desc,
      'purchase_pack_units': 1,
      'barcode': barcode ? 'BC-$sku' : null,
      'has_barcode': barcode,
      'hsn': null,
      'gst_pct': null,
      'tax_verified': false,
      'item_kind': 'product',
      'status': status,
      'available': status == 'active',
      'stock_qty': stock,
      'stock_known': stock != null,
      'image_url': null,
      'version': version,
    };

Map<String, dynamic> catalogueList(List<Map<String, dynamic>> items, {int total = 142, int page = 1}) => {
      'counts': {'total': total, 'active': 340, 'out_of_stock': 12, 'inactive': 643, 'combos': 3, 'categories': 4, 'drafts': 7},
      'categories': ['Beverages', 'Dairy', 'Snacks', 'Staples'],
      'total_matching': total,
      'page': page,
      'page_size': 6,
      'items': items,
    };

final sixItems = [
  item('i1', 'Coca-Cola 500ml', 'CC500', 4000, unit: 'l', stock: 84, desc: '500ml bottle'),
  item('i2', 'Parle-G Biscuits', 'PG80G', 1000, unit: 'pack', stock: 240, category: 'Snacks'),
  item('i3', 'Amul Butter 500g', 'AB500', 56, unit: 'g', stock: 42000, category: 'Dairy'),
  item('i4', 'Maggi Noodles 70g', 'MN70G', 1400, stock: 320, category: 'Snacks'),
  item('i5', 'Tata Salt 1kg', 'TS1KG', 2800, unit: 'kg', stock: 56, category: 'Staples'),
  item('i6', 'Farm Fresh Eggs', 'EGG12', 7200, unit: 'dozen', stock: 18, category: 'Dairy'),
];

Map<String, dynamic> row(String state, {Map<String, dynamic>? invoice, Map<String, dynamic>? received, num accepted = 0, num shortfall = 0, int claim = 0, int acceptedValue = 0}) => {
      'state': state,
      'severity': state == 'matched' ? 'ok' : (state == 'missing' || state == 'not_on_invoice') ? 'red' : 'amber',
      'invoice': invoice,
      'received': received,
      'accepted_qty': accepted,
      'shortfall_qty': shortfall,
      'claim_minor': claim,
      'accepted_value_minor': acceptedValue,
    };

Map<String, dynamic> colaRow() => row('rejected',
    invoice: {'name': 'Coca-Cola 500ml', 'qty': 24, 'unit': 'units', 'unit_price_minor': 3000, 'amount_minor': 72000},
    received: {'line_id': 'l1', 'name': 'Coca-Cola 500ml', 'qty': 24, 'rejected_qty': 2, 'unit': 'unit', 'unit_cost_minor': 3000},
    accepted: 22, shortfall: 2, claim: 6000, acceptedValue: 66000)
  ..addAll({'item_id': 'i1', 'gst_pct': 18});

Map<String, dynamic> grnView({String status = 'matching', bool valid = false, Map<String, dynamic>? actions, List<String> blockers = const ['Resolve the exceptions first.'], bool hasInvoice = true, List<Map<String, dynamic>>? rows, int version = 4, String? decisionNote}) => {
      'id': 'g1',
      'receipt_document_id': 'r1',
      'grn_no': 'GRN-105',
      'doc_no': 'RCV-105',
      'po_ref': 'PO-105',
      'invoice_no': 'INV-5512',
      'has_invoice': hasInvoice,
      'supplier_name': 'Coca-Cola Bottling',
      'status': status,
      'version': version,
      'posting_status': status == 'approved' ? 'posted' : 'not_posted',
      'approver': {'name': 'Rohan Shah', 'role': 'org_owner'},
      'decision_note': decisionNote,
      'rows': rows ?? [colaRow()],
      'totals': {'invoice_amount_minor': 72000, 'accepted_value_minor': 66000, 'claim_minor': 6000, 'claim_units': 2, 'accepted_units': 22, 'matched': 0, 'exceptions': 1},
      'resolution': {
        'selected': valid ? 'accept_claim_credit' : null,
        'valid': valid,
        'claim_ref': valid ? 'CLM-105' : null,
        'claim_evidence': valid ? 'Seal inspection · 2 photos' : null,
        'note': null,
        'claim_minor': valid ? 6000 : 0,
        'options': [
          {'code': 'accept_claim_credit', 'accepted_units': 22, 'claim_units': 2, 'claim_minor': 6000, 'enabled': true},
          {'code': 'accept_as_received', 'accepted_units': 22, 'enabled': true},
        ],
      },
      'preview': [
        {'item_id': 'x', 'name': 'Coca-Cola 500ml', 'unit': 'unit', 'accepted_qty': 22, 'rejected_qty': 2, 'stock_now': 84},
      ],
      'checklist': [
        {'key': 'count', 'label': 'Physical count verified', 'done': true, 'by': {'name': 'Niraj'}},
        {'key': 'lot', 'label': 'Lot and expiry captured', 'done': true, 'detail': 'CC-C', 'expiry_date': '2027-11-15'},
        {'key': 'claim', 'label': 'Supplier claim recorded', 'done': valid, 'claim_minor': 6000},
        {'key': 'approval', 'label': 'Owner approval', 'done': status == 'approved'},
      ],
      'blockers': blockers,
      'actions': actions ?? {'can_resolve': true, 'can_request': valid, 'can_approve': false, 'can_reject': false},
    };

Map<String, dynamic> matchingView() => {
      'receipt_document_id': 'r1',
      'doc_no': 'RCV-2026-BB4',
      'invoice_no': 'INV-2024-0047',
      'invoice_date': '2024-09-15',
      'supplier_name': 'Metro Cash & Carry',
      'has_invoice': true,
      'operator': {'name': 'Niraj'},
      'invoice_lines': [
        {'name': 'Amul Butter 500g', 'qty': 12, 'unit': 'pcs', 'unit_price_minor': 26000},
        {'name': 'Maggi Noodles 13-Pack', 'qty': 55, 'unit': 'packs', 'unit_price_minor': 16800},
        {'name': 'Tata Salt 1kg', 'qty': 24, 'unit': 'bags', 'unit_price_minor': 2800},
        {'name': 'Aashirvaad Atta 1kg', 'qty': 40, 'unit': 'bags', 'unit_price_minor': 29000},
      ],
      'rows': [
        row('short', invoice: {'name': 'Amul Butter 500g', 'qty': 12, 'unit': 'pcs', 'unit_price_minor': 26000, 'amount_minor': 312000}, received: {'line_id': 'a', 'name': 'Amul Butter 500g', 'qty': 10, 'rejected_qty': 0, 'unit': 'pcs', 'unit_cost_minor': 26000}),
        row('missing', invoice: {'name': 'Tata Salt 1kg', 'qty': 24, 'unit': 'bags', 'unit_price_minor': 2800, 'amount_minor': 67200}, received: {'line_id': 'b', 'name': 'Tata Salt 1kg', 'qty': 0, 'rejected_qty': 0, 'unit': 'bags', 'unit_cost_minor': null}),
        row('matched', invoice: {'name': 'Aashirvaad Atta 1kg', 'qty': 40, 'unit': 'bags', 'unit_price_minor': 29000, 'amount_minor': 1160000}, received: {'line_id': 'c', 'name': 'Aashirvaad Atta 1kg', 'qty': 40, 'rejected_qty': 0, 'unit': 'bags', 'unit_cost_minor': 29000}),
        row('not_on_invoice', received: {'line_id': 'd', 'name': 'Vim Bar 125g', 'qty': 8, 'rejected_qty': 0, 'unit': 'pcs', 'unit_cost_minor': 17000}),
      ],
      'matched': 1,
      'exceptions': 3,
    };
