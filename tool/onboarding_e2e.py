#!/usr/bin/env python3
"""Walks one test partner through all of onboarding against the LOCAL stack: sign in, 7 sections, upload, submit.
Needs: local Supabase, the POS server on :8090 (new-mobile-flutter/server, `npm run dev`), .env.local, .phasea_test_pw. Prints PASS/FAIL lines only, never secrets."""
import json, os, sys, urllib.request, urllib.error, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def env(path, key):
    for l in open(path):
        if l.startswith(key + '='): return l.split('=', 1)[1].strip()
SB = 'http://127.0.0.1:54321'
PK = env(os.path.join(ROOT, '.env.local'), 'SUPABASE_PUBLISHABLE_KEY')
SRK = env(os.path.join(ROOT, 'server', '.env'), 'SUPABASE_SERVICE_ROLE_KEY')  # the standalone POS server's own env file
PW = open(os.path.join(ROOT, '.phasea_test_pw')).read().strip()
API = os.environ.get('POS_API', 'http://localhost:8090')  # the standalone POS server (new-mobile-flutter/server, `npm run dev`)
EMAIL = 'phasea.onboard@test.local'
results = []

def call(method, url, body=None, headers=None, raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    h = {'Content-Type': 'application/json'} if raw is None else {}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            t = r.read().decode(); return r.status, (json.loads(t) if t and t.strip().startswith(('{', '[')) else t)
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try: return e.code, json.loads(t)
        except Exception: return e.code, t

def check(name, ok): results.append((name, bool(ok))); print(('PASS  ' if ok else 'FAIL  ') + name)

# a clean test login (re-created each run so the walk starts from nothing)
admin = {'apikey': SRK, 'Authorization': 'Bearer ' + SRK}
s, users = call('GET', f'{SB}/auth/v1/admin/users?per_page=200', headers=admin)
import subprocess
subprocess.run(['docker', 'exec', 'supabase_db_onelocal-dev', 'psql', '-U', 'postgres', '-d', 'postgres', '-qc', "delete from ol_partner_applications where phone = '9830000777'"], check=True)  # local test data only
for u in users.get('users', []):
    if u.get('email') == EMAIL: call('DELETE', f"{SB}/auth/v1/admin/users/{u['id']}", headers=admin)
s, u = call('POST', f'{SB}/auth/v1/admin/users', {'email': EMAIL, 'password': PW, 'email_confirm': True, 'user_metadata': {'full_name': 'Onboard Tester'}}, admin)
s, tok = call('POST', f'{SB}/auth/v1/token?grant_type=password', {'email': EMAIL, 'password': PW}, {'apikey': PK})
H = {'Authorization': 'Bearer ' + tok['access_token']}
# The walk keeps the screen-level call sites; each is sent through the one generic endpoint POST /rpc/<name>.
RPC = {('GET', '/api/onboarding/application'): 'partner_app_get', ('GET', '/api/onboarding/taxonomy'): 'static_taxonomy',
       ('PUT', '/api/onboarding/profile'): 'partner_app_save_profile', ('PUT', '/api/onboarding/plan'): 'partner_app_choose_plan',
       ('PUT', '/api/onboarding/address'): 'partner_app_save_address', ('PUT', '/api/onboarding/tax'): 'partner_app_save_tax',
       ('PUT', '/api/onboarding/identity'): 'partner_app_save_identity', ('PUT', '/api/onboarding/bank'): 'partner_app_save_bank',
       ('PUT', '/api/onboarding/consents'): 'partner_app_save_consents', ('PUT', '/api/onboarding/agreement'): 'partner_app_accept_agreement',
       ('POST', '/api/onboarding/submit'): 'partner_app_submit', ('POST', '/api/onboarding/documents/upload'): 'partner_app_document_slot',
       ('POST', '/api/onboarding/documents'): 'partner_app_document_attach'}
def api(method, path, body=None):
    import re
    m = re.match(r'/api/onboarding/documents/([a-z_]+)/preview$', path)
    fn, args = ('partner_app_document_preview', {'kind': m.group(1)}) if m else (RPC[(method, path)], body or {})
    return call('POST', f'{API}/rpc/{fn}', args, H)

s, _ = call('POST', API + '/rpc/partner_app_get', {})
check('no token is refused (401)', s == 401)
s, d = api('GET', '/api/onboarding/application'); check('a new login has no application yet', s == 200 and d.get('exists') is False)
s, t = api('GET', '/api/onboarding/taxonomy'); check('lists: categories, states, banks', s == 200 and len(t['states']) > 30 and 'HDFC Bank' in t['banks'] and len(t['store']) > 5)

store_cat = next(c for c in t['store'] if c['name'] == 'Grocery'); sub = store_cat['subcategories'][0]
s, d = api('PUT', '/api/onboarding/profile', {'partner_type': 'store', 'business_name': 'E2E General Store', 'owner_name': 'Riya Sharma', 'phone': '9830000777', 'email': EMAIL, 'selling_mode': 'physical', 'category': 'Grocery', 'subcategory': sub})
check('profile saved, draft created', s == 200 and d['application']['status'] == 'draft' and d['application']['category_family'] == store_cat['family'])
s, d = api('PUT', '/api/onboarding/profile', {'partner_type': 'store', 'business_name': 'X', 'owner_name': 'Riya Sharma', 'phone': '9830000777', 'selling_mode': 'physical', 'category': 'Grocery', 'subcategory': sub})
check('a one-letter shop name is refused with a plain message', s == 400 and 'shop name' in d['detail'])
s, d = api('PUT', '/api/onboarding/profile', {'partner_type': 'store', 'business_name': 'E2E General Store', 'owner_name': 'Riya', 'phone': '98300', 'selling_mode': 'physical', 'category': 'Grocery', 'subcategory': sub})
check('a short mobile number is refused', s == 400 and '10-digit' in d['detail'])
s, d = api('PUT', '/api/onboarding/profile', {'partner_type': 'store', 'business_name': 'E2E General Store', 'owner_name': 'Riya', 'phone': '9830000777', 'selling_mode': 'physical', 'category': 'Not a category', 'subcategory': sub})
check('a category outside the list is refused', s == 400)
s, d = api('PUT', '/api/onboarding/plan', {'plan': 'free'}); check('an unknown plan is refused', s == 400)
s, d = api('PUT', '/api/onboarding/plan', {'plan': 'pos_and_onelocal'}); check('plan saved', s == 200 and d['application']['sell_plan'] == 'pos_and_onelocal')
s, d = api('PUT', '/api/onboarding/address', {'address_line': '12, 2nd Main Road', 'locality': 'Indiranagar', 'city': 'Bengaluru', 'state': 'Karnataka', 'pin_code': '560038', 'confirmed': True})
check('address saved', s == 200 and d['address']['confirmed'] is True)
s, d = api('PUT', '/api/onboarding/address', {'address_line': '12, 2nd Main Road', 'locality': 'Indiranagar', 'city': 'Bengaluru', 'state': 'Atlantis', 'pin_code': '560038', 'confirmed': True}); check('a state outside the list is refused', s == 400)
s, d = api('PUT', '/api/onboarding/tax', {'pan': 'abcde1234f', 'gst_registered': True, 'gstin': ''}); check('GST registered needs a GSTIN', s == 400 and 'GSTIN' in d['detail'])
s, d = api('PUT', '/api/onboarding/tax', {'pan': 'abcde1234f', 'gst_registered': False})
check('tax saved; PAN comes back masked only', s == 200 and d['tax']['pan_masked'] == '••••••234F' and 'ABCDE1234F' not in json.dumps(d))
s, d = api('PUT', '/api/onboarding/tax', {'gst_registered': False}); check('saving tax again without a PAN keeps the saved one', s == 200 and d['tax']['pan_masked'] == '••••••234F')
s, d = api('PUT', '/api/onboarding/identity', {'consent': False}); check('identity needs consent', s == 400)
s, d = api('PUT', '/api/onboarding/identity', {'consent': True, 'aadhaar_last4': '4821'}); check('identity saved', s == 200 and d['identity']['aadhaar_last4'] == '4821')

def upload(kind, content, ctype='application/pdf', name='file.pdf'):
    s, slot = api('POST', '/api/onboarding/documents/upload', {'kind': kind, 'content_type': ctype, 'size': len(content), 'file_name': name})
    if s != 200: return s, slot
    ps, _ = call('PUT', slot['upload_url'], raw=content, headers={'Content-Type': ctype, 'x-upsert': 'true'})
    return api('POST', '/api/onboarding/documents', {'kind': kind, 'path': slot['path'], 'content_type': ctype, 'size': len(content), 'file_name': name})
s, _ = api('POST', '/api/onboarding/documents/upload', {'kind': 'pan_copy', 'content_type': 'application/zip', 'size': 10, 'file_name': 'a.zip'}); check('a zip is refused', s == 400)
s, _ = api('POST', '/api/onboarding/documents/upload', {'kind': 'pan_copy', 'content_type': 'application/pdf', 'size': 6_000_000, 'file_name': 'a.pdf'}); check('a file over 5 MB is refused before upload', s == 400)
s, d = upload('pan_copy', b'%PDF-1.4 pan one', name='pan-masked.pdf'); check('PAN copy uploaded and attached', s == 200 and any(x['kind'] == 'pan_copy' and x['status'] == 'uploaded' for x in d['documents']))
s, d = upload('pan_copy', b'%PDF-1.4 pan two replaced', name='pan-2.pdf'); check('replacing keeps one PAN copy', s == 200 and sum(x['kind'] == 'pan_copy' for x in d['documents']) == 1 and d['documents'][0]['file_name'] == 'pan-2.pdf')
s, d = upload('business_proof', b'\x89PNG\r\n\x1a\nproof', 'image/png', 'shop-act.png'); check('business proof uploaded', s == 200 and len(d['documents']) == 2)
s, p = api('GET', '/api/onboarding/documents/pan_copy/preview'); check('a preview link works', s == 200 and p['url'].startswith('http'))
if s == 200:
    s2, body = call('GET', p['url']); check('the preview link returns the file', s2 == 200 and 'pan two' in str(body))
s, p = api('GET', '/api/onboarding/documents/food_license/preview'); check('no food licence, no preview (404)', s == 404)

s, d = api('PUT', '/api/onboarding/bank', {'holder_name': 'Riya Sharma', 'bank_name': 'HDFC Bank', 'account_number': '000123456789', 'confirm_account_number': '000123456780', 'ifsc': 'HDFC0001234', 'account_type': 'current', 'authorised': True})
check('mismatching account numbers are refused', s == 400 and 'do not match' in d['detail'])
s, d = api('PUT', '/api/onboarding/bank', {'holder_name': 'Riya Sharma', 'draft': True}); check('save for later keeps a partial bank form', s == 200 and d['bank']['status'] == 'draft')
s, d = api('PUT', '/api/onboarding/bank', {'holder_name': 'Riya Sharma', 'bank_name': 'HDFC Bank', 'account_number': '000123456789', 'confirm_account_number': '000123456789', 'ifsc': 'hdfc0001234', 'account_type': 'current', 'authorised': True})
check('bank saved unverified; only the last four come back', s == 200 and d['bank']['status'] == 'unverified' and d['bank']['account_masked'] == '•••• •••• 6789' and '000123456789' not in json.dumps(d))
s, d = api('POST', '/api/onboarding/submit'); check('submit is refused until consent and agreement are done', s == 400 and 'Agreement' in d['detail'])
s, d = api('PUT', '/api/onboarding/consents', {'service_terms': True, 'privacy_notice': False}); check('privacy is required', s == 400)
s, d = api('PUT', '/api/onboarding/consents', {'service_terms': True, 'privacy_notice': True, 'marketing_updates': False}); check('consents saved', s == 200 and d['consents']['service_terms'])
s, d = api('PUT', '/api/onboarding/agreement', {'version': 'DEMO 1.0', 'acknowledged': False}); check('agreement needs the tick', s == 400)
s, d = api('PUT', '/api/onboarding/agreement', {'version': 'DEMO 1.0', 'acknowledged': True}); check('agreement accepted; seven of seven', s == 200 and d['progress']['done'] == 7 and d['progress']['can_submit'] is True)
s, d = api('POST', '/api/onboarding/submit'); ref = d.get('application', {}).get('reference')
check('submitted with a reference and four checks', s == 200 and d['application']['status'] == 'submitted' and ref and len(d['checks']) == 4)
s, d2 = api('POST', '/api/onboarding/submit'); check('submitting again answers the same application', s == 200 and d2['application']['reference'] == ref)
s, d = api('PUT', '/api/onboarding/address', {'address_line': 'Another', 'locality': 'Area', 'city': 'City', 'state': 'Karnataka', 'pin_code': '560001', 'confirmed': True}); check('a submitted application cannot be edited (409)', s == 409)
print(f"\nSUMMARY {sum(ok for _, ok in results)} pass / {sum(not ok for _, ok in results)} fail")
sys.exit(0 if all(ok for _, ok in results) else 1)
