#!/usr/bin/env python3
"""Walks one approved test partner through workspace setup (Figma section C) against the LOCAL stack: checklist, plan, payment,
tax, POS, staff, items, listing + logo, delivery, tour, complete. A second partner checks that one business never sees the other.
Needs: local Supabase, the One Local dev server (SETUP_API, default http://localhost:8093), .env.local, .phasea_test_pw.
The approved application is made directly in the local database (the onboarding walk is tools/onboarding_e2e.py).
Prints PASS/FAIL lines only, never secrets."""
import json, os, random, subprocess, sys, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def env(path, key):
    for l in open(path):
        if l.startswith(key + '='): return l.split('=', 1)[1].strip().strip('"')
SB = 'http://127.0.0.1:54321'
PK = env(os.path.join(ROOT, '.env.local'), 'SUPABASE_PUBLISHABLE_KEY')
SRK = env(os.path.join(ROOT, '..', 'One Local Mobile App ', 'OL-ui', 'frontend', '.env.local'), 'SUPABASE_SERVICE_ROLE_KEY')
PW = open(os.path.join(ROOT, '.phasea_test_pw')).read().strip()
API = os.environ.get('SETUP_API', 'http://localhost:8093')
DEV_KEY = 'dev-only-partner-pii-key-0123456789'   # the server's local-only fallback key (server/partner-setup.ts); never a real key
RUN = '%06d' % random.randint(0, 999999)
results = []

def call(method, url, body=None, headers=None, raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    h = {'Content-Type': 'application/json'} if raw is None else {}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            t = r.read().decode(errors='replace'); return r.status, (json.loads(t) if t and t.strip().startswith(('{', '[')) else t)
    except urllib.error.HTTPError as e:
        t = e.read().decode(errors='replace')
        try: return e.code, json.loads(t)
        except Exception: return e.code, t

def psql(sql):
    return subprocess.run(['docker', 'exec', 'supabase_db_onelocal-dev', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-qAtc', sql],
                          check=True, capture_output=True, text=True).stdout.strip()

def check(name, ok): results.append((name, bool(ok))); print(('PASS  ' if ok else 'FAIL  ') + name)

admin = {'apikey': SRK, 'Authorization': 'Bearer ' + SRK}

def approved_partner(tag, partner_type, sell_plan, phone, with_bank):
    """A fresh login with an application approved by local platform staff. Local test data only."""
    email = f'setup.e2e.{tag}.{RUN}@test.local'
    s, u = call('POST', f'{SB}/auth/v1/admin/users', {'email': email, 'password': PW, 'email_confirm': True}, admin)
    uid = u['id']
    app_id = psql(f"""insert into ol_partner_applications (city_id, business_name, business_type, partner_type, address, pin_code, owner_name, phone, email,
        consent_version, consent_at, submit_key, status, applicant_user_id, category, categories, sell_plan, gst_registered, address_line, locality, city_name,
        services, own_delivery, submitted_at)
      values ('latur', 'E2E Setup {tag} {RUN}', '{'restaurant' if partner_type == 'restaurant' else 'grocery'}', '{partner_type}', 'Main Road, Latur', '413512',
        'Riya Sharma', '{phone}', '{email}', 'v1', now(), 'k-setup-{tag}-{RUN}', 'submitted', '{uid}', 'Grocery', '{{Grocery}}', '{sell_plan}', false,
        '12 Main Road', 'Shivaji Nagar', 'Latur', '{{pickup}}', false, now()) returning id""").splitlines()[0]
    if with_bank:
        psql(f"""insert into ol_partner_application_bank (application_id, holder_name, bank_name, account_last4, account_enc, ifsc, account_type, authorised_at, status)
          values ('{app_id}', 'Riya Sharma', 'HDFC Bank', '6789', extensions.pgp_sym_encrypt('000123456789', '{DEV_KEY}'), 'HDFC0001234', 'current', now(), 'verified')""")
    staff = psql("select user_id from platform_admins where status = 'Active' order by created_at limit 1")
    psql(f"select master_partner_application_decide('{app_id}', 'approve', null, '{staff}')")
    s, tok = call('POST', f'{SB}/auth/v1/token?grant_type=password', {'email': email, 'password': PW}, {'apikey': PK})
    return {'Authorization': 'Bearer ' + tok['access_token']}

phone_a = '98' + RUN + '01'; phone_b = '98' + RUN + '02'
A = approved_partner('a', 'store', 'pos_and_onelocal', phone_a, True)
B = approved_partner('b', 'restaurant', 'onelocal_app', phone_b, False)
def api(method, path, body=None, who=A): return call(method, API + '/api/setup' + path, body, who)

# who ---------------------------------------------------------------------------------------------------------------------
s, _ = call('GET', API + '/api/setup/state'); check('no token is refused (401)', s == 401)
s, tok = call('POST', f'{SB}/auth/v1/admin/users', {'email': f'setup.e2e.none.{RUN}@test.local', 'password': PW, 'email_confirm': True}, admin)
s, t = call('POST', f'{SB}/auth/v1/token?grant_type=password', {'email': f'setup.e2e.none.{RUN}@test.local', 'password': PW}, {'apikey': PK})
s, d = api('GET', '/state', who={'Authorization': 'Bearer ' + t['access_token']}); check('a login without an approved business gets 404', s == 404)

# checklist -----------------------------------------------------------------------------------------------------------------
s, d = api('GET', '/state')
check('state: 8 required items for a POS seller, profile ones done', s == 200 and d['progress']['total'] == 8 and d['progress']['done'] >= 2 and not d['progress']['can_complete'])
check('the application prefills the verified settlement account (masked only)', d['payment']['from_application'] and d['payment']['account_masked'].endswith('6789') and '000123456789' not in json.dumps(d))
s, d = api('GET', '/state', who=B); check('a OneLocal-only restaurant has 7 required items and no POS row', s == 200 and d['progress']['total'] == 7 and all(r['key'] != 'pos' for r in d['checklist']))
s, d = api('POST', '/complete'); check('complete is refused while items are open', s == 400 and 'Finish' in d['detail'])

# plan --------------------------------------------------------------------------------------------------------------------
published = psql("select count(*) from commercial_plans where status = 'Published'")
code = psql("select plan_code from commercial_plans where status = 'Published' order by price limit 1") if published != '0' else None
s, d = api('PUT', '/plan', {'plan_code': 'no-such-plan'}); check('an unknown plan is refused', s == 400)
s, d = api('PUT', '/plan', {'plan_code': code}); check('plan confirmed', s == 200 and d['plan']['confirmed'])

# payment + tax -----------------------------------------------------------------------------------------------------------
s, d = api('PUT', '/payment', {'holder_name': 'Riya Sharma', 'accept_upi': True}); check('UPI on needs a UPI id', s == 400 and 'UPI' in d['detail'])
s, d = api('PUT', '/payment', {'holder_name': 'Riya Sharma', 'account_number': '12', 'ifsc': 'HDFC0001234'}); check('a short account number is refused', s == 400)
s, d = api('PUT', '/payment', {'holder_name': 'Riya Sharma', 'accept_upi': True, 'accept_card': True, 'upi_id': 'e2e.store@okhdfc'})
check('payment saved from the application account, still verified', s == 200 and d['payment']['saved'] and d['payment']['bank_status'] == 'verified' and d['payment']['upi_id'] == 'e2e.store@okhdfc')
s, d = api('PUT', '/payment', {'holder_name': 'Aman', 'accept_card': True}, who=B); check('no application account: the number is required', s == 400 and 'account number' in d['detail'])
s, d = api('PUT', '/tax', {'gst_registered': True, 'gstin': 'BAD', 'prices_include_tax': True}); check('a wrong GSTIN is refused', s == 400 and 'GSTIN' in d['detail'])
s, d = api('PUT', '/tax', {'gst_registered': True, 'gstin': '27abcde1234f1z5', 'invoice_prefix': 'e2e', 'prices_include_tax': True, 'show_address_on_receipt': True, 'show_gstin_on_invoice': True})
check('tax saved; Payment Setup now complete', s == 200 and d['tax']['invoice_prefix'] == 'E2E' and next(r for r in d['checklist'] if r['key'] == 'payment')['status'] == 'completed')

# POS ---------------------------------------------------------------------------------------------------------------------
s, d = api('PUT', '/pos', {'device_name': 'Counter 1', 'peripherals': ['kot_printer'], 'connection': 'usb'}); check('a shop cannot add a KOT printer', s == 400 and 'KOT' in d['detail'])
s, d = api('PUT', '/pos', {'device_name': 'Counter 1', 'peripherals': ['receipt_printer']}); check('peripherals need a connection', s == 400)
s, d = api('PUT', '/pos', {'device_name': 'Counter 1', 'peripherals': ['receipt_printer', 'scanner'], 'connection': 'bluetooth'})
check('POS registered with two peripherals, not yet connected', s == 200 and d['pos']['registered'] and len(d['pos']['devices']) == 3 and not any(x['connected'] for x in d['pos']['devices']))

# staff -------------------------------------------------------------------------------------------------------------------
s, d = api('POST', '/staff', {'name': 'Ravi Kumar', 'email': 'not-an-email', 'role': 'cashier'}); check('a bad invite email is refused', s == 400)
s, d = api('POST', '/staff', {'name': 'Ravi Kumar', 'email': f'ravi.{RUN}@test.local', 'role': 'cashier', 'permissions': ['billing.collect', 'catalogue.view']})
check('staff invited as cashier with two permissions', s == 200 and d['staff']['invites'][0]['role'] == 'biller' and len(d['staff']['invites'][0]['permissions']) == 2)
s, d = api('POST', '/staff', {'name': 'Chef', 'email': f'chef.{RUN}@test.local', 'role': 'kitchen'}); check('a shop has no kitchen role', s == 400)

# catalogue ---------------------------------------------------------------------------------------------------------------
s, d = api('POST', '/items', {'name': 'Tata Salt 1kg', 'category': 'Staples', 'price': 0}); check('price above zero', s == 400)
s, d = api('POST', '/items', {'name': 'Tata Salt 1kg', 'category': 'Staples', 'price': '28'}); check('first item added; Catalogue complete', s == 200 and d['catalogue']['items'] == 1 and d['catalogue']['names_done'])
s, d = api('POST', '/items', {'name': 'tata salt 1kg', 'category': 'staples', 'price': 30}); check('the same item twice is refused (409)', s == 409)

# listing + logo ----------------------------------------------------------------------------------------------------------
L = {'public_name': 'E2E Store', 'description': 'Daily groceries and staples', 'address_line': '12 Main Road, Latur', 'open_days': [1, 2, 3, 4, 5, 6], 'opens_at': '09:00', 'closes_at': '21:00'}
s, d = api('PUT', '/listing', {**L, 'opens_at': '9am'}); check('a bad time is refused', s == 400)
s, d = api('PUT', '/listing', L); check('listing saved', s == 200 and d['listing']['saved'] and d['listing']['open_days'] == [1, 2, 3, 4, 5, 6])
png = b'\x89PNG\r\n\x1a\n' + b'\x00' * 64
s, slot = api('POST', '/images/upload', {'kind': 'logo', 'content_type': 'image/gif', 'size': 10}); check('a GIF is refused', s == 400)
s, slot = api('POST', '/images/upload', {'kind': 'logo', 'content_type': 'image/png', 'size': len(png)})
if s == 200:
    call('PUT', slot['upload_url'], raw=png, headers={'Content-Type': 'image/png', 'x-upsert': 'true'})
    s, d = api('POST', '/images', {'kind': 'logo', 'path': slot['path'], 'content_type': 'image/png', 'size': len(png)})
    check('logo attached; a short-lived link comes back, not the storage path', s == 200 and (d['listing'].get('logo_url') or '').startswith('http') and 'logo_path' not in d['listing'])
    s, d = api('POST', '/images', {'kind': 'logo', 'path': slot['path'].replace(slot['path'].split('/')[0], '00000000-0000-0000-0000-000000000000'), 'content_type': 'image/png', 'size': len(png)})
    check("another business's folder is refused", s == 400)
else:
    check('logo upload slot', False)

# delivery ----------------------------------------------------------------------------------------------------------------
s, d = api('PUT', '/fulfilment', {}); check('at least one way to get orders', s == 400)
s, d = api('PUT', '/fulfilment', {'pickup': True, 'self_delivery': True, 'radius_km': 3, 'min_order': '199', 'delivery_fee': 25, 'service_areas': ['Shivaji Nagar']})
check('delivery saved', s == 200 and d['fulfilment']['saved'] and float(d['fulfilment']['min_order']) == 199.0)

# tour + complete ---------------------------------------------------------------------------------------------------------
s, d = api('POST', '/tour', {'step': 1}); s, d = api('POST', '/tour', {'step': 1}); check('a coach mark is recorded once', s == 200 and d['tour_seen'] == [1])
s, d = api('POST', '/tour', {'step': 11}); check('only steps 1 to 10', s == 400)
s, d = api('POST', '/complete'); check('setup completes with every required item done', s == 200 and d['progress']['completed'] and d['progress']['done'] == 8)
s, d2 = api('POST', '/complete'); check('completing again answers the same', s == 200 and d2['progress']['completed_at'] == d['progress']['completed_at'])

# isolation ---------------------------------------------------------------------------------------------------------------
s, d = api('GET', '/state', who=B)
check('B never sees A', s == 200 and 'E2E Store' not in json.dumps(d) and 'Tata Salt' not in json.dumps(d) and not d['progress']['completed'])
s, d = api('POST', '/complete', who=B); check('B is still blocked', s == 400)

print(f"\nSUMMARY {sum(ok for _, ok in results)} pass / {sum(not ok for _, ok in results)} fail")
sys.exit(0 if all(ok for _, ok in results) else 1)
