# Service POS work log

## 2 Nov 2026

Nothing below is committed or pushed yet. Hosted SQL files are waiting to be run on hosted Supabase.

### 1. Test business on this PC (local only)

- Made a local test service business, **Glow Salon**, through the app's own functions: sign-up, approval, setup, staff, services, hours.
  - 3 staff, 6 services and a "Hair wash" add-on, open every day 10:00–20:00 with a 14:00–15:00 break.
  - Two owner logins, both through Sign In → Use password: an email login, and mobile 9004222219 with password 123456.
  - Script: `db/seed/glow_salon_test_seed.sql` (safe to run again).
- Note: the founder wants all service kinds built together, so this test business will be replaced with a mixed one (doorstep job, shop appointment, quote job).
- Copied the missing `svc_dashboard` database function from hosted to local (file: `C:\onelocal\from_hosted\service_dashboard_from_hosted.sql`). Every other service function already matched hosted.

### 2. Checked the money path end to end

Dashboard → slots → price → booking → check-in → start → job checklist → bill → cash payment all work through the server. Found and fixed the problems below (3, 4, 5).

### 3. Receipt after a service payment

- Before: paying closed the screen with a short message; no receipt, no change amount, no print, no WhatsApp bill.
- Now: a "Payment received" screen with bill number, amount, payment method, cash received and change returned, date and time; **Print Receipt**; **Send by WhatsApp** (a short note with the public bill link `https://one-local-flutter.vercel.app/b/<code>`, the same link the store uses); **Done**.
- Files: `lib/service/visit_receipt.dart` (new), `lib/service/visit_screens.dart`, `lib/service/service_api.dart`.
- Tests: `test/service_screens_test.dart`.

### 4. Online bill page reads as a service, not shopping

- A service bill now says "thanks for visiting", shows a "Service" column, a "Visit APT-… · with <staff> · <time>" line and "Thank you for your visit!". Store bills are exactly as before.
- Files: `server/src/bill-page.ts`, test `server/tests/unit/bill-page.test.ts`.
- Hosted SQL: `C:\onelocal\hosted_service_bill_page_2026-11-02.sql` (run after `hosted_bill_link_2026-11-02.sql`). Applied locally.
- To revisit: "visiting" does not fit doorstep or online services; wording to become neutral.

### 5. GST for services (founder: "18%, none if unregistered")

- Before: a service business that said "not GST-registered" was still charged 5% GST, because billing only learns the GST answer when the owner saves Setup → Tax.
- Now, for service businesses only: the GST answer and GSTIN from the application are copied into the billing settings, and the rate is 18% (9% CGST + 9% SGST) added on top; no GST when not registered. The owner's own Setup → Tax answer always wins.
- Screens hide "GST 0%" lines; billing says "GST: None · not GST-registered".
- Hosted SQL: `C:\onelocal\hosted_service_gst_2026-11-02.sql`. Applied locally. Check script: `C:\onelocal\hosted_service_gst_2026-11-02_CHECK_local.sql` (7 checks pass).
- Stores have the same problem (for example Purushottam Super Market is charged 5% though not registered). Founder said to leave stores as they are.

### 6. Store POS kept untouched

- One small change made earlier to the store's success card was undone. The service receipt has its own card.
- Shared files touched only on their service branch: `lib/home/app_shell.dart`, `lib/home/control_centre_screen.dart`, `lib/app_routes.dart`, `server/src/bill-page.ts`. Tests confirm store and restaurant behave as before.

### 7. Planning documents (in `docs/`)

- `service-pos-blueprint.md`: the founder's 21-page Service POS blueprint, word for word. The spec for all service work.
- `service-pos-gap-list.md`: every blueprint section and screen marked built / partly built / missing / later, the 10 acceptance scenarios, and a build order for release one.
- `service-pos-screens.md`: the screens to build from the founder's sketch and the reference screenshots (One Local look, not a copy of Jobber).

### 8. New Service POS frame (step 1 of the rebuild)

- Service businesses now get the founder's bottom bar: **Home · Catalogue · Bill · Bookings · Manage** (Bill is the centre button), in the store POS style.
- New side menu (☰): profile at the top (Manage account), Company details, Team management, Support, Sign out. The ☰ on every service screen opens it.
- Until each tab is rebuilt it opens the closest existing screen: Home = service dashboard, Catalogue = service list, Bill = service history, Bookings = calendar, Manage = hours and slots.
- Files: `lib/service/service_nav.dart` (new), `lib/home/app_shell.dart`, `lib/home/control_centre_screen.dart`, `lib/app_routes.dart`, `lib/service/service_menu.dart`.
- Tests: `test/service_nav_test.dart` (new), `test/app_shell_test.dart`.

### 9. Test data everywhere in the Service POS

- The test business is now **Demo Services** (renamed from Glow Salon), for every kind of service. Same two logins.
- Seed renamed to `db/seed/service_demo_seed.sql`. Run it as `-U supabase_admin`, during working hours (10:00–17:00).
- 13 services of all four kinds:
  - at the customer's place: AC service, Plumber visit, Home deep cleaning;
  - at the shop: Consultation, Pet grooming, haircuts, colour, facial, manicure;
  - group: Yoga workshop (12 places);
  - online: Video consultation.
- 5 staff: Neha, Ravi, Sana, Arjun (technician), Meera (consultant), with their hours and services.
- A ₹200 advance on every booking.
- 15 customers and 36 bookings, made through the app's own booking functions:
  - **last two weeks:** paid visits (cash with change, UPI, card), one no-show (advance kept), one cancelled with refund;
  - **today:** one completed, one doorstep job in progress, one checked in, one confirmed, one waiting for its advance;
  - **next 6 days:** upcoming bookings, one waiting for its advance, one cancelled.
- Past visits were done as real visits today and then moved back to their dates with database triggers off (test data only; payments can't otherwise be edited).
- Checked through the server: the dashboard shows today's figures, the calendar a full week, the history all 36 records.

### 10. New Bookings tab (step 2 of the rebuild)

- Built from the founder's sketch, the same for every kind of service. File: `lib/service/bookings_screen.dart` (new); the Bookings tab now opens it.
- **Calendar:** Day (the day by the hour, a "Now" line, bookings and free-slot counts), Week (strip with counts per day), Month (grid with counts; arrows change month). A **Today** button and an **All staff** filter.
- **Appointments today** (or the chosen day) under the calendar: time and length, what, status, where (at the shop / at customer's place / group / online), customer and phone, staff, address, amount and what is paid.
- **List:** one day with a week strip and arrows.
- **Board (Kanban):** Upcoming · Checked in · In progress · Done · Cancelled.
- **Map:** the day's jobs at a customer's place with "Open in Maps"; the real map needs a Google Maps key.
- **+ New booking** opens the existing booking form (to be rebuilt later).
- Server: `svc_calendar` got a month view, cancelled bookings on request, and each booking's length, kind, phone, address, amount and paid. Hosted SQL: `C:\onelocal\hosted_service_bookings_2026-11-02.sql` (applied locally). POS server schema: `server/src/schemas/service.ts`.
- Tests: `test/service_bookings_test.dart` (8 tests). Store and restaurant not touched.
- Note: one existing server test (restaurant guest page) fails because it needs a web build folder; unrelated to this work.

### 11. New Manage tab: Service management (step 3 of the rebuild)

- Built from the founder's slot table, the same for every kind of service. File: `lib/service/manage_screen.dart` (new); the Manage tab now opens it.
- Founder's choices (2 Nov): the slot table is **worked out from the hours** (not typed in slot by slot); the **word for workers comes from the kind of service chosen at sign-up**.
- **Weekday chips** (Mon–Sun; closed days marked).
- **Opening hours** for that day, with **Edit**: open or closed, opening and closing time, an optional break. Saves the whole week.
- **Slot length**: 15 min, 30 min, 1 hr, 1 hr 30 min, 2 hr, 3 hr, 4 hr. A booking can start at the start of any slot.
- **Slot table**: Time · Slot · Length · number of workers who work the whole slot (red when nobody does). Tap a row to see who.
- **Workers on that day** with their hours, and **Edit** (opens the existing hours screen for now).
- Worker word by kind of service: Beauty → Stylists, Repairs → Technicians, Home skilled work → Workers, Cleaning → Cleaners, Daily help → Helpers, Events → Crew, Education and fitness → Trainers, Professional → Consultants, Health → Providers, Pet care → Pet carers; otherwise Staff. (The local Demo Services was approved before the rename and its application still says "Salon", so it shows "Staff".)
- Server: new `svc_slot_table` and `svc_worker_word`; slot length may now also be 1½, 2, 3 or 4 hours. Hosted SQL: `C:\onelocal\hosted_service_manage_2026-11-02.sql` (applied locally). POS server: `server/src/rpc-manifest.ts` (one new line), `server/src/schemas/service.ts`.
- Tests: `test/service_manage_test.dart` (6 tests). Store and restaurant not touched.

### 12. New Bill tab (step 4 of the rebuild, first half)

- The same for every kind of service. File: `lib/service/bills_screen.dart` (new); the Bill tab now opens it.
- **Bills list:** "Due now" (amount and number of bills) and "Paid this month"; **Due · Paid · All** with counts; search by bill number, customer or phone; each bill with status, where it came from (a booking, or "Bill" made here), customer, date, total and what is due.
- **One bill:** customer, phone, address; services with quantities; subtotal, discount, GST (only when charged), round off, total, paid, due; payments with method and time; the message.
  - **Collect** (cash with change, card, UPI) for a bill made here.
  - A booking's bill says to take payment from the booking, with **Open booking**, so the visit is closed properly.
  - **Send by WhatsApp** (public bill link) and **Print**.
- **New bill:** customer name, mobile, address; services from the catalogue with − / + quantities; discount in ₹ or %; a message; shows the amount before tax; **Save bill** makes it unpaid and opens it to collect or send.
- Wording made neutral for every kind of service: WhatsApp note "Thank you for choosing <business>.", bill page "thanks for choosing", "Booking APT-… · with …", "Thank you for choosing us!" (was "visiting").
- Server: new `svc_bill_list`, `svc_bill_view`, `svc_invoice_create`, `svc_invoice_pay` (bills are normal orders and payments). Hosted SQL: `C:\onelocal\hosted_service_bills_2026-11-02.sql`; `hosted_service_bill_page_2026-11-02.sql` updated (a bill made here also counts as a service bill). POS server: 4 new lines in `server/src/rpc-manifest.ts`, schemas in `server/src/schemas/service.ts`.
- Test data: two bills made here (one paid, one due) added to the seed (part 8).
- Not yet: free-text line items (a bill lists catalogue services only), cancelling a bill, online payment links. New job (several services, a team, repeating visits) is the next step.
- Tests: `test/service_bills_test.dart` (5 tests). Store and restaurant not touched.

### 13. New job (step 4 of the rebuild, second half)

- The same for every kind of service. File: `lib/service/job_screens.dart` (new). Reached from **Bookings → + New job**; a job visit on the calendar, list or board opens its job; a job's bill in the Bill tab has **Open job**.
- **New job form:**
  - **Customer:** name, mobile, the address where the work is.
  - **Job:** title and instructions.
  - **Services:** with − / + quantities, and a discount in ₹ or %.
  - **Schedule:** "Schedule later", or a date with start and end time; arrival window (none, 30 min, 1 hr, 2 hr); repeating (does not repeat, every week, every 2 weeks, every month) with the number of visits (2–12).
  - **Team:** one or more people.
  - **Billing:** "Remind me to bill when I close the job".
- **Job page:**
  - Status; customer, phone and address; instructions; the team.
  - Every visit with date, time and arrival window, and **Start visit** / **Complete visit**.
  - The job's bill (lines, total, due; tap to open it).
  - **Close job:** later visits are cancelled; with the reminder on and money due, it asks "Bill <customer> now?" and opens the bill.
  - **Cancel job:** asks first; only while nothing is paid; cancels its bill too.
- **No double-booking:** a person on a job visit can't be booked at that time; free slots skip it; two jobs can't overlap for the same person ("Arjun Kumar already has work on Tue 10 Nov at 1:00 – 3:00 PM").
- Job visits show on the Bookings calendar (day, week, month counts), list and board, with the team's names.
- Server: new tables `svc_jobs`, `svc_job_team`, `svc_job_visits`; new `svc_job_save`, `svc_job_view`, `svc_job_act`, `svc_job_busy`, `svc_day_count`. One clash check added to `svc_slots`, `svc_book` and reschedule. `svc_calendar` and `svc_bill_json` re-created with jobs. Hosted SQL: `C:\onelocal\hosted_service_jobs_2026-11-02.sql`; check script `C:\onelocal\hosted_service_jobs_2026-11-02_CHECK_local.sql` (13 checks pass). The earlier bills and bill-page files now also recognise job bills. POS server: 3 new lines in `server/src/rpc-manifest.ts`, schemas in `server/src/schemas/service.ts`.
- Test data (seed part 9):
  - J-0001: weekly home cleaning with Meera and Sana, 4 visits from six days out, 10% off.
  - J-0002: AC service and leak repair with Arjun, in two days.
  - J-0003: bathroom fittings, not scheduled yet.
- Not yet: editing a job after saving, moving one visit, photos and checklists on job visits, materials.
- Tests: `test/service_jobs_test.dart` (5 tests). Store and restaurant not touched.

### 14. Founder's screen feedback (2 Nov)

- **Catalogue:** the three rows of filter chips are replaced by one **Filters** button next to search. It opens a sheet (Category, Type, Status, "Show services", "Clear filters"); the filters that are on show as small chips with a ✕ to take one off. File: `lib/service/catalogue_screen.dart`.
- **Bookings week strip:** round day buttons with one letter (M T W T F S S), filled when chosen, ringed for today, the number of bookings under each. The month grid's days are round too.
- **Map:** a drawn example map (streets, river, park) with one numbered, gently pulsing pin per job at a customer's place, and the route between them, marked "Example map" until the Google Maps key is added. File: `lib/service/map_preview.dart` (new).
- **Dashboard figures are tappable:** Visits · today → today's bookings and jobs as a list; Money · today → the Bill tab's new **Today** filter (bills with money taken today, "Taken today" total); Free slots → today's day view with its free slots.
- So the two agree, the dashboard's money now counts every service bill (bookings, package sales, jobs and bills made in the Bill tab), and "Taken today" is net of refunds, like the dashboard. Hosted SQL: `hosted_service_bills_2026-11-02.sql` (Today filter) and `hosted_service_jobs_2026-11-02.sql` (dashboard money) were updated.
- Tests updated and added (catalogue filters, map, dashboard tiles).

### 15. Compact screens (founder: too much scrolling)

- Every service screen is tighter: the shared pieces in `lib/service/service_widgets.dart` were made smaller, so all service screens change together:
  - page titles 30 → 22, page padding 20 → 16;
  - cards with less padding and a smaller title, and less space between cards;
  - label/value rows and service lines closer together, with a narrower label column;
  - chips 40 → 34 high, search 52 → 44 high, smaller status pills and section headings.
- Bookings: smaller day circles, figure tiles and timeline rows; a shorter board; a squarer month grid. Bills, Manage and New job / New bill: smaller tiles, compact text fields, tighter rows and gaps.
- Big buttons (New booking, Save, Collect) are the store's own and were left as they are.
- Create buttons moved to the top of each tab (a slim button, `SvcTopButton` in `service_widgets.dart`), so they are seen without scrolling; the bottom ones are gone: Catalogue **+ Add service**; Bookings **+ New booking** and **+ New job** side by side; Bill **+ New bill**.
- Bill tab: the two figures at the top are tappable. **Due now** shows the due bills, **Paid this month** the paid ones (**Taken today** the bills with money taken today); the figure being shown is ringed in green, with a › to show it can be tapped.

### 16. Offline and online bookings (founder, 2 Nov)

- Every booking and job records where it came from: **offline** (logged by staff in the Service POS) or **online** (booked by a customer in the customer app). Everything made so far is offline. Both kinds share the same time slots, staff hours and clash checks, so a time taken by one is gone for the other.
- **Bookings tab:** an **All · Offline · Online** switch with counts for the days shown. Every booking is tagged **Booked online** (blue, phone icon) or **Booked offline** (grey, shop icon) in the list, the day panel and the map list, and **Online / Offline** in the small blocks of the day view and the board.
- **Booking page and job page:** the same tag next to the status.
- **Dashboard:** the Visits figure says "N offline · N online" for today (bookings and job visits).
- Test data: six customers' bookings (11 in all) are marked as booked online until the customer app can book (seed part 10).
- Server: a `source` on bookings and jobs, the calendar's `source` filter and offline / online counts, the dashboard's `today_sources`; added to `hosted_service_jobs_2026-11-02.sql` (13 job checks still pass). POS server: `source` allowed in `server/src/schemas/service.ts`.
- Online booking itself (the customer app side) is planned in `service-online-booking-plan.md` and waits until the Service POS is finished.

### 17. The store's animations and Google Wallet look (founder, 2 Nov)

- **Animations** (the store POS's motion from the founder's reference video, `lib/ui/motion.dart`, reused, not copied):
  - every service screen's sections build in one after another (fade and a short rise, once), from the shared service page;
  - the figure tiles count up (Bookings, Bill tab, dashboard);
  - the Bookings Calendar · List · Board · Map switch slides its white highlight to the picked view;
  - page changes already used the store's fade-and-rise. Everything stays still when the phone asks for less motion.
- **Google Wallet look for bills** (the store's wallet cards, `lib/ui/wallet.dart`):
  - in the Bill tab every bill is a gradient wallet card — red when due, orange when part paid, green when paid, grey when cancelled;
  - the cards tuck under each other like a wallet, the last one in full, and tapping one opens it;
  - the bill page opens with the bill as a big wallet pass: what for, customer, total, paid and due.
- Tests: wallet cards and the pass checked; tests that look at a screen right after it opens now wait for the animations.

### 18. Dashboard top redone (founder, 2 Nov)

- The heading says **Dashboard** (not "OneLocal"), with an **Open today / Closed today** pill beside it and the date and location under it.
- The dark block is gone. The three figures are light cards in the store's look, each with a coloured icon (green visits, blue money, amber free slots), a full label ("Visits today", "Money today", "Free slots"), the number counting up and a short note ("5 offline · 1 online", "₹7,538 this month", "2 people free"). Still tappable.
- "Operations today" is a white strip with three small figures (in progress, no-show, cancelled) with icons; tap for the calendar.
- File: `lib/service/service_dashboard.dart`; dashboard test updated.

### 19. Bill tab as coloured piles (founder, 2 Nov)

- The Due / Today / Paid / All chips and the top tiles are gone. The Bill tab now opens on three wallet piles, one below the other: **Due** (red), **Taken today** (green), **Paid** (blue). Each pile shows how many bills it holds and how much (for example "2 bills · ₹2,040 due").
- There is no "All bills" pile. Every bill is already in one of the three piles.
- Tap a pile to see its bills as wallet cards in the pile's colour. Tap the open pile again to go back to all three.
- A search lists matching bills from every pile under "Search results". "+ New bill" stays at the top.
- On the dashboard, the Money tile opens the Bill tab on Taken today.
- Files: `lib/service/bills_screen.dart`, `test/service_bills_test.dart`, `test/service_dashboard_test.dart`.

### 20. Free slots: which slots and who is free (founder, 2 Nov)

- The dashboard's Free slots tile now says who is free right now by first name ("Arjun, Meera +2 free now", or "Nobody free now").
- Tapping it opens **Free slots** (`lib/service/free_slots_screen.dart`):
  - two figures: free slots left today, and people free now;
  - each person's card shows their state (Free now / Busy till 5:30 PM / On a job / Not working now / Off today) and their free start times today as chips;
  - tapping a time, or "+ New booking", starts a booking for today.
- Data: new `svc_free_slots`. It uses the same rule the calendar counts with (shortest bookable service plus buffer, working hours, bookings, time off, job visits, closures, opening hours). `svc_dashboard` gains `free_now`.

### 21. Money for services (founder, 2 Nov)

- **Money** is now in the service side menu, at the top (`lib/service/service_money.dart`).
- **Wallet card:** the same dark card as the store. It shows the balance (cash drawer, UPI, bank) with Money in, Money out and Transfer, read from the same `smoney_*` books. Service payments already land in those books, so no new SQL was needed for the wallet.
- **From your services** (service-only), switchable between Today and Month:
  - money taken, net of refunds;
  - a coloured bar and rows for Bookings, Jobs, Bills made here, and Packages & memberships;
  - Offline (in the POS) vs Online (customer app);
  - Cash / UPI / Card and refunds.
  - Tapping the total opens the Bill tab on Taken today (or Paid for the month). Data: new `svc_money_split`.
- **Cash drawer:**
  - opening cash, cash from services, other cash in or out, and what should be in the drawer;
  - "Close day · count the cash" (the store's `smoney_close_day`).
- **Customers owe:** unpaid service bills (the total is on the tab). "Collect" opens the bill to take payment.
- **Still store wording:** the Money in / Money out screens are the store's own (`lib/money/money_flow.dart`, not touched), so their type list still starts with "Income (sales of goods)". Changing that needs a small edit in the store file.
- Server: `svc_free_slots` and `svc_money_split` added to `rpc-manifest.ts` and `schemas/service.ts`.
- Hosted SQL: `C:\onelocal\hosted_service_free_money_2026-11-02.sql`. Run it after `hosted_service_jobs_2026-11-02.sql`.
- Tests: new `test/service_money_test.dart`; dashboard and side-menu tests updated.

### 22. Bill cards with colour accents; Manage made compact (founder, 2 Nov)

- **Bill cards** (`BillAccentCard` in `lib/service/bills_screen.dart`): bills inside an open pile, and in search results, are now white cards. The colour is only an accent: a stripe down the left, the status pill and the amount due, in the pile's colour (red Due, green Taken today, blue Paid; in a search, the bill's own status colour). Cards are listed plainly, no longer tucked under each other. The piles themselves and the bill page's pass stay full-colour.
- **Manage** (`lib/service/manage_screen.dart`):
  - the week is one row of round letters (M T W T F S S); closed days are faded, struck through and marked "Closed";
  - the day's hours, its break and the slot length share one card ("Edit hours" on it);
  - the slots are a grid of small tiles, three to a row, instead of a long table. Each tile shows the start, the end and length, and how many work it ("2 Technicians"). Slots with nobody are red, and a line above says how many there are. Tap a tile to see who works it;
  - the staff list is short rows: name, then hours or Off.
- Tests: `service_bills_test.dart` and `service_manage_test.dart` updated.

### 23. Service photos (founder, 2 Nov)

- **Add service / Edit service** has a **Photo** card at the top: a preview, then **Camera**, **Gallery**, **Remove background** (for a new photo; puts it on white) and **Remove**.
  - A new photo waits until the service is saved, then goes on it. Removing the saved photo takes effect on save.
  - If the photo fails, the service still saves, and the message says so.
- It reuses the store's photo tools unchanged (`lib/catalogue/item_photo.dart`): the same camera screen, AI background removal, 5 MB limit, and signed upload through `cat_item_photo_slot`, `_attach` and `_remove`. A service is a catalogue item, so these work as they are; the service owner's upload slot was checked locally.
- The catalogue list shows the photo instead of the type icon, and Service Detail shows it on top.
- Also fixed: the "Add-on to another service" switch in the same form tripped Flutter's ink assertion inside the white card. It is now a plain row with a switch.
- Hosted SQL: `C:\onelocal\hosted_service_photos_2026-11-02.sql` (`svc_service_detail` and `svc_service_list` return `image_url`).
- Tests: new `test/service_photo_test.dart`.

### 24. Service media manager and standard photos (founder, 2 Nov)

- **Media** is in the service side menu, below Money (`lib/service/service_media.dart`). It is the store's media pool, for services.
- **My photos:**
  - every service photo with where it stands: Only your business, Waiting for review, Standard photo (used by N), Not approved (with OneLocal's note), Taken back, or From standard media;
  - Offer to OneLocal asks first; Take back is there once a photo is offered or approved;
  - "Without a photo" lists services with no photo, each with a Standard photo button.
- **Standard media:** approved service photos.
  - It opens on the business's own kind of service. Chips switch to All kinds or another kind, each with its count. Search is on top.
  - Tap a photo, then choose the service to put it on.
- **Add / Edit service:** the photo card has a third option, **Standard**. It opens standard photos with the best matches for that service first; the chosen photo goes on the service when it is saved.
- **Kinds of service** come from the kind chosen at sign-up (`svc_media_kind`): Beauty & personal care, Cleaning, Repairs, Home skilled work, Vehicle care, Daily help, Education & fitness, Pet care, Other services. **Events, Health and Professional** keep their own photos only. There is no Offer and no standard photos for them, and the screens say why. Their customers judge the business on its own work, or a stock photo could mislead.
- **Database:** the same `media_pool` table, plus `scope` ('product' or 'service') and `service_kind`. New functions: `svc_media_pool`, `_offer`, `_withdraw`, `_standard`, `_use`.
  - OneLocal reviews service photos in the same Review queue (store app → Media manager → Review). They are grouped as "Services · <kind>".
  - The store's standard search (`media_standard_search`) now shows product photos only, so a service photo never lands on a product. This was the one change to a store function, and the store screens are unchanged.
- **Checked locally:** a photo was uploaded to Hair colour, offered, approved in SQL (as a local test), then put on another service and removed again. Demo Services now has one standard photo, a pink test pattern on Hair colour.
- Server: `svc_media_*` in `rpc-manifest.ts`, schemas in `schemas/media.ts`.
- Hosted SQL: `C:\onelocal\hosted_service_media_2026-11-02.sql`, run after the photos file. Safe to run again.
- Tests: new `test/service_media_test.dart`; side-menu test updated.

### 25. Softer count-up on the dashboard figures (founder, 2 Nov)

- The figures (Visits today, Money today, Free slots, and the Bookings figure) now count up with `SoftCountUp` in `lib/service/service_widgets.dart`. It runs 1.6 s instead of 0.7 s and eases out gently, so the last numbers settle slowly. It counts in whole numbers, so there's no paise flicker, and the figure fades in as it starts. The exact value shows at the end; nothing animates when the phone's "reduce motion" is on, or for zero.
- The store's own `CountUp` (`lib/ui/motion.dart`) is unchanged.

### 26. Month calendar overflow fixed (2 Nov)

- On a phone, the Bookings month grid showed red "BOTTOM OVERFLOWED BY 5.7 PIXELS" stripes. Each day cell's height was tied to its width, so on a narrow screen it was about 42 px tall: too short for the 34 px circle plus the count under it.
- Fixed in `lib/service/bookings_screen.dart`: the rows are now a fixed 54 px tall, and a cell scales down instead of overflowing on very narrow screens.
- New test at 360 px wide (`service_bookings_test.dart`) checks that each day's circle and count fit inside the cell. The old tests missed this because the shared test helper hides overflow errors.

### 27. Month calendar as a planner (founder, 2 Nov; after a Dribbble "Planner App" reference)

- Bookings → Calendar → **Month** is now a planner (`lib/service/bookings_screen.dart`):
  - a **dark month card**: white dates, a soft grey rounded pill for the chosen day, a lime ring on today, and up to three lime dots under each day that has bookings. Arrows change the month;
  - a **white sheet** joined under it, with a drag handle. It lists the chosen day's bookings as **pastel cards**: yellow for coming up, pink for waiting for the advance, green for happening now, blue for completed, grey for cancelled or no-show. Each card shows the service and status, then time and length, customer, staff, address, and Online or Offline;
  - **pull the handle up**, or tap it, and the month folds smoothly into the chosen week. The sheet then shows that day by the hour with pastel blocks and the Now line. **Pull it down** and the month opens again. A quick flick or a slow 40 px pull both work, and folding needs no extra call to the server.
- Day and Week views are unchanged.
- Tests: `service_bookings_test.dart` covers the month test and a new fold test (handle up, handle down, handle tap, pastel colour).

### 28. Calendar simplified: white planner, no Day / Week / Month, store motion (founder, 2 Nov)

- **White:** the planner card is white with a thin edge and dark text. The chosen day is a dark rounded pill, today has a green ring, the booking dots are green, and the sheet under the month is off-white with a line above it.
- **Less mess:**
  - the **Day / Week / Month chips are gone**. The calendar is the planner itself: the month with the chosen day's cards, and pulled up, the week with that day by the hour. It always loads the month in one call;
  - **All / Offline / Online and All staff are one row**;
  - **Today** moved into the calendar's own header and only shows when you're away from today. List, Board and Map keep their Today chip.
  - The old Day view's two figure tiles were removed (the dashboard has Visits and Free slots).
- **Store motion** (founder's reference video): the day's cards cascade in one after another each time a day is picked (the store's `Entrance`). A new month slides in from the side you moved to, with a fade. Folding and opening the month, and the chosen-day pill, were already animated.
- Tests: `service_bookings_test.dart` rewritten for the planner (opens on the month, white card, no range chips, cascade, month slide); `service_jobs_test.dart` taps the visit's card.

### 29. Service catalogue rebuilt from the founder's design (3 Nov)

The founder's design canvas ("Service catalogue · chosen design") replaces the old catalogue, drawn in OneLocal's own components (`lib/service/catalogue_screen.dart`).

- **Two tabs, Services and Inventory**, with the store's sliding segmented highlight and a count on each tab.
- **Services:** a green outlined **Add service** button, search plus one **Filter** button (the type of service, in a sheet), and one sideways row of chips: All, Active, Paused/Draft (only when there are any), then the business's categories. Each row has the photo, name, code · category, a type pill and a status pill (green active, amber draft, grey paused), the price and length, and ⋮. Rows cascade in.
- **Add service** asks "What are you adding?": Appointment, Event, On-location, On-demand (each opens the service form with that delivery picked, new `fulfilment` parameter on `ServiceEditScreen`), Package, Membership (open their pages).
- **Inventory:** the team from `svc_staff_list`, loaded when the tab opens: initials, name, state pill, title · availability, and the services each person does. **+ Add** and a tap open Staff & service providers.
- Places, Tools, Materials and Items in care from the design are not built: OneLocal has no tables for them yet.
- No SQL change. Checked on screen at phone width.

### 30. Inventory: places, tools, materials, items in care (founder, 3 Nov)

The rest of the design's Inventory tab, for every kind of service business (`lib/service/inventory_pane.dart`, `InventoryPane`).

- **Five tiles:** Team, Places, Tools, Materials, In care, each with its count; an amber dot on a tile with something to do. The Inventory tab says "N to do". The picked section shows its warnings, then its list (cards cascade in).
- **Places** (rooms, chairs, courts, bays): Ready or Blocked with the reason and date; Block for now / Take it back in use; how many; the services each is for.
- **Tools and gear:** "2 of 3 available · With Arjun", a fill bar; **Lend out** (how many, who has them) and **Got back**. A warning when all are out.
- **Materials:** stock with unit, "warn me at" level and use per booking; **Add stock** / **Use some**; Low (amber) and Out (red) with a warning on top.
- **Items in care:** a customer's item with a tag (C-1, C-2...), note and promised day; **Working on it**, **Ready to collect**, **Handed back**; Overdue (red) past the promised day.
- Adding and editing places, tools and materials, blocking and removing: manager roles. Lending, using stock and items in care: anyone who may book.
- **Database:** new tables `svc_inventory_items` and `svc_care_items`, functions `svc_inventory`, `svc_inventory_save`, `svc_inventory_move`, `svc_care_save` (all labels, states and warnings come from the server). The existing `svc_resources` (chairs and rooms that bookings use) is not touched. Server: schemas and allow-list entries for the four functions.
- **Hosted SQL:** `C:\onelocal\hosted_service_inventory_2026-11-03.sql`, **run on hosted 3 Nov** and checked read-only afterwards (tables, functions, grants). Applied and tried on local (every action and refusal); hosted checked read-only: no name clashes, everything it needs is there.
- Tests: `test/service_inventory_test.dart` (7). Checked on screen at phone width (lending a dryer out).

### 31. Ol, the guide, in the last slot of the service bar (founder, 3 Nov)

The store's character (Ol, the lime shop) replaces Manage at the end of the floating bar and works as a guide (`lib/service/service_ol.dart`).

- **In the bar:** Ol bobs and blinks as in the store. It says hello the first time the app opens, and one short tip the first time each tab opens (Home, Catalogue, Bill, Bookings), once per phone. No tips while a walkthrough is running.
- **Tapped: "Where do you want to go?"** with
  - **Take me to:** Bookings, Bills, Services, Inventory, Service management, Free slots, Money, Team & providers (more as you type: Media, Packages, Memberships, Visit history, Holidays & time off). A page opens inside its tab, so the bar stays.
  - **Show me how:** Book a visit, Start a job, Collect a bill, Add a service, Lend out a tool, Change opening hours. The screen dims, the button to tap is lit, and Ol's bubble says what to do, across screens (the restaurant's walkthrough engine).
  - **Ask me:** a box and this tab's quick questions. Ol answers with numbered steps and **Take me there**. All on the phone: no AI, no network.
- **Service management** moved to the ☰ side menu (first row) and is one of Ol's places, so nothing is lost.
- Shared code: `lib/home/app_shell.dart` only gains the service branch (Ol in the bar's last slot, and opening a page inside a tab). Store and restaurant bars are unchanged; their Ol tests pass.
- Tests: `test/service_ol_test.dart` (7); `service_nav_test` and `app_shell_test` updated for the new bar. Checked on screen: the sheet, and "Lend out a tool" walked through Catalogue → Inventory → Tools.

### Tests run

All pass: service screens and frames, service dashboard, shell, navigation, routes, home, store sell and restaurant bill tests, server bill-page tests.

### Waiting on

- ~~Run on hosted~~ **Done 2 Nov 2026:** all of it was run on hosted as one file, `C:\onelocal\hosted_service_pos_ALL_2026-11-02.sql` (the bill link plus the nine service files, in order), and checked read-only on hosted afterwards (22 functions, the job tables, media columns and the patched functions are all there).
- ~~Run `C:\onelocal\hosted_service_inventory_2026-11-03.sql` on hosted (section 30)~~ **Done 3 Nov 2026.**
- One commit and push when asked.
- Next build steps: Bookings (calendar day/week/month, list, Kanban, today panel), Service management slots, New job and Bill, Quotes, Clients, Timesheet, Expenses, Search, settings; Map after a Google Maps key.
