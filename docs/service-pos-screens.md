# Service POS: screens to build (2 Nov 2026)

The founder's direction for the new Service POS, built from scratch (the current `lib/service/` screens are replaced, not patched). One set of screens for **every kind of service**: only fields and a few labels change by service (for example "Technician", "Worker", "Provider"). Sources, in order of authority:

1. The founder's hand sketch (2 Nov, 14:22): bottom bar, side menu, dashboard, Service management table, Bookings views.
2. [service-pos-blueprint.md](service-pos-blueprint.md): workflows F1–F9, onboarding O01–O20, rules.
3. Reference screenshots of the Jobber app (2 Nov): which functions to include. One Local look and words, not Jobber's design or branding.

Gaps against today's app: [service-pos-gap-list.md](service-pos-gap-list.md).

## App frame (from the sketch)

- **Top bar:** ☰ menu · OneLocal · notifications bell · profile avatar.
- **Bottom bar:** Home · Service catalogue · Bill · Bookings · Service management.
- **Side menu (☰):** Profile & manage account · Company details · Team management · Support · Sign out.
- **Plus button** (from the screenshots): Client · Job · Quote · Invoice · Expense · Task · Request · Time. Shows only what the person's role allows.

## Screens

| # | Screen | What it holds | Source |
|---|---|---|---|
| 1 | **Home / Service dashboard** | Date and day; business health (job value and visits this week, change from last week); ongoing appointments; today's work; clock-in timer; "Schedule a new job"; setup checklist while setting up; dismissible tips. | Sketch, screenshots, blueprint D01 |
| 2 | **Service catalogue** | Services with name, description, price (fixed / per unit / starting / quote), duration, workflow, staff, add-ons; templates by service kind. | Sketch, blueprint O07–O09 |
| 3 | **Bill** | New invoice: billed to client (pick or add: name, address, phone, email), title, issue date, line items (name, description, qty × price), subtotal, discount, tax, total, online payment on/off, client message, disclaimer, Review and send / Save. Receipt with print and WhatsApp bill link. | Sketch, screenshots |
| 4 | **Bookings** | Calendar Day / Week / Month with "Today"; list view with date strip; Kanban by status; map of where appointments are; "Appointments today" panel: time, hours, workers, customer. Per-staff rows with counts. | Sketch, screenshots, blueprint D02–D03 |
| 5 | **Service management** | Slot table: time (e.g. 1–2 pm), slot number, slot length (hours/minutes), workers per slot (word set per service: employees, workers, technicians…); working days and hours, breaks, holidays. | Sketch, blueprint O14 |
| 6 | **New job** | Client and property address, job title, instructions, line items, subtotal / discount / tax / total, schedule later or date + start/end, arrival window, repeating (does not repeat / weekly …), team, "remind me to invoice when I close the job", Save. | Screenshots, blueprint F1/F9 |
| 7 | **New quote** | Client and address, title, introduction, line items (recommended / optional), discount (₹ or %), tax, total, required deposit, attachments, images, client message, terms ("valid for 30 days"), Review and send. Start from a template or manually. Customer approves by link. | Screenshots, blueprint F3 / Q01–Q03 |
| 8 | **Clients** | Client list and profile: contacts, properties/addresses, jobs, quotes, invoices, balance; book again. | Screenshots, blueprint D05 |
| 9 | **Timesheet** | Clock in / out; time types: Visit, Driving, Office, Supplies, Break, General; total today; time log per person per day. | Screenshots |
| 10 | **Expenses** | Snap a receipt or enter details; needs review / reviewed; pending reimbursement. | Screenshots |
| 11 | **Tasks and requests** | Requests from customers to accept; internal tasks. | Screenshots, blueprint F1 |
| 12 | **Search** | One search across clients, jobs, quotes, invoices, expenses, with type filters. | Screenshots |
| 13 | **Profile** | Name, email, mobile, change password. | Sketch, screenshots |
| 14 | **Company details** | Logo, business name, email, phone, website; location: name, address lines, city, state, PIN. | Sketch, screenshots |
| 15 | **Team management** | Active users count / limit, list, add/invite, role, services each can do. | Sketch, screenshots, blueprint O12 |
| 16 | **Preferences** | Save photos to device; notifications: today's work, schedule changed, new request, new online booking, client viewed quote, client approved quote, active timer. | Screenshots |
| 17 | **Support** | Help and contact. | Sketch |

## Not copied from the screenshots

- "Voice AI" job/quote creation and "Apps & integrations", "Marketing", "Refer a friend": not in the sketch; left out unless asked.
- Map view needs a maps key for the app (Google Maps); the rest works without it.

## Rules carried from the blueprint

- Completed is not paid; job, quote, invoice and payment each have their own status.
- Reuse One Local's customers, orders, payments, staff and audit; no second wallet.
- Every write has an idempotency key; the database checks every rule.
- No changes to the store POS.
