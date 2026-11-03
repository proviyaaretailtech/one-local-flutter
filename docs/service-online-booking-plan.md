# Online booking: customers book services from the customer app (plan, 2 Nov 2026)

Today every service booking is entered by staff in the Service POS. The customer app (`onelocal-customer`, Expo / React Native, with its own
server routes in `frontend/app/api` on the same Supabase database) has a **Book It** tab, but its "booking" only saves a demo enquiry for an
event (`booking-enquiries`, status `demo_enquiry_saved`); nothing reaches a business. This plan connects the two, the same for every kind of
service, following the blueprint (F1 doorstep, F2 appointment; D01 "new requests"; O15 confirmation rules).

## What the customer does

1. **Find** a service business in Book It (nearby, by kind of service: beauty, repairs, cleaning, health…) and open its page: services
   with price, length and where (at the shop / at your place / online).
2. **Choose** a service (and add-ons), then a day, then a free time. Optionally a person ("Any" by default).
3. **Details:** name and mobile (from their account), the address for work at their place, a note.
4. **Send**: they see the booking's state: *Requested* (waiting for the business), *Confirmed*, *Declined* (with the reason) or *Expired*.
5. **My bookings:** upcoming and past, cancel within the business's rule (free until N hours before).
6. Later: pay the advance online (the customer app already has Cashfree), reminders, rate the visit.

## What the business sees (Service POS)

- **Home:** a "New requests" figure (tap → the requests); the bottom-bar Bookings tab shows a count badge.
- **Bookings:** a **Requests** column first on the Board, and requests marked "Online" in the list and calendar (the time stays held
  while waiting, so nobody else books it).
- **A request:** customer, service, time, address; **Accept** (pick the person when the customer chose "Any") or **Decline** with a
  reason (busy, outside our area, …). Accepting makes it a normal booking: check-in, job, bill, receipt as today.
- **Auto accept switch on the Home screen** (founder): on = requests are confirmed at once; off = the business accepts each one.
- **Manage → Online booking:** on/off; the same auto accept switch (the founder's choice replaces the blueprint's
  "automatic for the shop, accept for doorstep"); how long a request waits (15 / 30 / 60 min) before it expires; which services can be booked online;
  how far ahead (e.g. 30 days) and minimum notice.
- A request not answered in time expires and frees the time; the customer is told.

## Building blocks

### 1. Database (service only, one hosted SQL file, then local)
- `svc_appointments`: a `source` (`pos` / `app`), and two new states: `requested` (waiting for the business) and `declined`; plus
  `expired`. A requested booking holds its time like a confirmed one (it joins the clash checks).
- `svc_online_settings`: on/off, auto-confirm, response minutes, booking horizon, minimum notice; `svc_services.online` (bookable online).
- Public reads for the customer app (no POS login): the business's online page (services, prices, lengths, kinds, policies) and free
  times for a service on a day (the same slot rules as the POS).
- Customer actions (the signed-in customer): send a request, see their bookings, cancel within the rule.
- Business actions (POS): list requests, accept (with a person), decline (with a reason). Expiry is checked whenever requests are read
  or the time is asked for, so no background job is needed at first.
- Each request is an ordinary order, like every booking, so bills, receipts and the Bill tab work unchanged.

### 2. POS server (`one-local-flutter/server`)
- New allow-listed calls for the POS: requests list, accept, decline, online settings.

### 3. Service POS app (`lib/service/`)
- Home figure, Bookings badge and Requests column, request page with Accept / Decline, Manage → Online booking settings.

### 4. Customer app (`onelocal-customer/frontend`)
- Book It: service businesses and their pages (replacing the demo events for services), the book flow (service → day → time → details →
  send), the booking state screen, My bookings (replacing the demo enquiries), cancel.
- Its server routes call the new public / customer functions with the database's service role, as its other routes do.

### 5. Messages (after the first version)
- WhatsApp / SMS to the customer on confirmed, declined and expired, and to the business on a new request; push notifications later.

## Suggested order

1. Database + POS side (requests, accept / decline, settings) with test requests made from the database, so the POS can be tried first.
2. Customer app book flow and My bookings, against the local database.
3. Advance payment online, messages, reminders.

## Founder's decisions (2 Nov 2026)

1. **Confirmation: an "Auto accept" switch, on the Service POS dashboard.** On: a request for a free time is confirmed at once. Off: every
   request waits for the business to Accept or Decline. The switch sits on the Home screen where it is always seen (and is also in
   Manage → Online booking with the other online settings).
2. **Payment: both.** When booking in the app the customer chooses **Pay advance now** (online, the app's Cashfree) or **Pay later** (at the
   shop or after the job). Paying now confirms the advance on the booking like an advance taken in the POS.
3. **Person: both.** The customer chooses **Any available** (the business assigns someone) or picks a person from the business's staff
   for that service.

Someone else is working in the customer app (`onelocal-customer`) now, so this work does not change that repository. Its developer gets a written hand-off: the functions to call, what to send, what comes back and the booking states.
