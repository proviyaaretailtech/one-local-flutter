// Section J answers shaped like the contract in specs/pos-section-j/spec.md (the Figma sample data), for tests and frame exports.

Map<String, dynamic> lowStockJson({List<Map<String, dynamic>>? items, bool missingLevels = true}) => {
      'snapshot_at': '2026-10-05T10:30:00+05:30',
      'location_name': 'Latur Main Branch',
      'viewer_name': 'Rahul Sharma',
      'counts': {'low': 15, 'critical': 8},
      'missing_levels': missingLevels,
      'items': items ??
          [
            {
              'id': 'i-biryani', 'name': 'Biryani', 'unit': 'units', 'available': 3, 'level': 'critical', 'reorder_level': null, 'quantity_short': null,
              'days_cover': 0.5, 'inbound_qty': 15, 'inbound_eta': '2026-10-06', 'supplier_name': null, 'last_purchase_price': null,
            },
            {
              'id': 'i-paneer', 'name': 'Paneer', 'unit': 'units', 'available': 12, 'level': 'low', 'reorder_level': null, 'quantity_short': null,
              'days_cover': null, 'inbound_qty': null, 'inbound_eta': null, 'supplier_name': null, 'last_purchase_price': null,
            },
            {
              'id': 'i-gulab', 'name': 'Gulab Jamun', 'unit': 'units', 'available': 4, 'level': 'low', 'reorder_level': null, 'quantity_short': null,
              'days_cover': null, 'inbound_qty': null, 'inbound_eta': null, 'supplier_name': null, 'last_purchase_price': null,
            },
          ],
    };

Map<String, dynamic> suggestionsJson({List<Map<String, dynamic>>? suggestions}) => {
      'snapshot_at': '2026-10-05T10:30:00+05:30',
      'location_name': 'Latur Main Branch',
      'viewer_name': 'Rahul Sharma',
      'suggestions': suggestions ??
          [
            {
              'id': 's-biryani', 'item_id': 'i-biryani', 'name': 'Biryani', 'unit': 'units', 'available': 3, 'level': 'critical', 'reason': 'urgent',
              'days_cover': 0.5, 'suggested_qty': 6, 'inbound_qty': 15, 'inbound_eta': '2026-10-06', 'supplier_name': null, 'estimated_unit_cost': null,
              'delivery_days': null,
            },
            {
              'id': 's-paneer', 'item_id': 'i-paneer', 'name': 'Paneer', 'unit': 'units', 'available': 12, 'level': 'low', 'reason': 'low_stock',
              'days_cover': null, 'suggested_qty': 2, 'inbound_qty': null, 'inbound_eta': null, 'supplier_name': null, 'estimated_unit_cost': null,
              'delivery_days': null,
            },
            {
              'id': 's-gulab', 'item_id': 'i-gulab', 'name': 'Gulab Jamun', 'unit': 'units', 'available': 4, 'level': 'low', 'reason': 'low_stock',
              'days_cover': null, 'suggested_qty': null, 'inbound_qty': null, 'inbound_eta': null, 'supplier_name': null, 'estimated_unit_cost': null,
              'delivery_days': null,
            },
          ],
    };
