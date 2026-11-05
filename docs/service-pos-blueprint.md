# One Local Service POS End to End Experience

Vendor onboarding to daily service operations. The founder's Service POS blueprint (21 pages), pasted by the user on 2 Nov 2026. This is the spec for all Service POS work; the gap list against the app is in [service-pos-gap-list.md](service-pos-gap-list.md).

---

## 01 / Overview

Build one configurable partner app that understands the business during onboarding, prepares relevant service templates, and takes the partner through a first successful booking or job. Keep the daily interface simple while managing availability, service execution, materials and money accurately behind the scenes.

**What this document provides.** A descriptive product and screen script for the founder, designer and developer. It covers a broad India-oriented service catalogue, onboarding questions, category-specific experiences, nine operational workflows, service recipes, minimal stock handling, roles, failure states and release acceptance checks.

**Reference and continuity.** Based on the supplied OneLocal Partner App Service POS specification version 1.0 and the supplied Jobber screenshots IMG 0183 through IMG 0205. The reference contributes guided questions, suggested services, first steps, schedule views, time tracking and simple settings. All proposed screens below are One Local adaptations. Existing canonical customers, orders, payments and partner records must be reused.

**Core product decision.** Keep a common Home for all partners. Adapt the Schedule, Work and creation forms to the selected service model. A partner can offer multiple categories and both doorstep and premises services without creating a separate account. Each individual service selects the correct operational workflow.

**Planning status.** This is an implementation proposal, not evidence that the features already exist. The sector directory is broad rather than an exhaustive or statutory classification. Category verification requirements must be configured and validated before those categories are enabled. All sample prices, quantities and durations are illustrative.

**Scope.** Current foundation: at-home services and bookings, including walk-ins, sessions and resource reservations. Quote approval supports work whose final scope is unknown. Admission tickets, seat selection, QR entry, advanced customer subscriptions and membership entitlements remain future modules unless separately approved.

**How to use the blueprint.** Read pages 2 to 5 for product structure and sector mapping; pages 6 to 9 for onboarding; pages 10 to 14 for operations; pages 15 to 17 for inventory; pages 18 to 21 for controls and implementation. Screen identifiers in this document are new planning references and require a crosswalk to existing screen IDs.

---

## 02 / Experience structure and navigation

| Area | What the partner does |
|---|---|
| Home | Sees new requests, unassigned work, today's schedule, overdue actions and a compact business summary. |
| Schedule | Uses day or list view; staff or resource filters; map view only for relevant at-home work. |
| Work | Handles Jobs and Bookings, with tabs relevant to the business and explicit statuses. |
| Customers | Searches permitted contact details, service history, upcoming work and outstanding balances. |
| More | Opens catalogue, materials, team, branches, payments, reports, policies and support. |

**One visible creation button.** A floating plus opens only permitted actions: new booking, new at-home job, walk-in, customer, quote or blocked time. The partner selects a service first; this determines which fields appear. Do not expose a large generic form with every category field.

**Three practical home states.** During setup, show a short First steps checklist with Continue setup. During verification, show what can be configured and what remains blocked. After activation, lead with pending actions and today's work. Tutorial cards must be dismissible and must not push operational work below promotional content.

**Keep the vocabulary familiar.** Use Customer, Staff, Service, Materials, Amount due and Today's work. Use Provider for clinics when appropriate and Technician for repairs. Internal data models may be shared; labels and customer questions must suit the selected category. Hindi, Hinglish and English should share the same controls and validation.

**Mobile interaction rules.** Use large tap targets, persistent field labels, numeric keyboards for amounts, search for long lists and a fixed primary action. Break long setup forms into small steps, save drafts automatically and offer Back without losing work. Required fields must explain why they are needed. Put uncommon settings under Advanced.

**Status clarity.** Keep business approval, listing publication, booking or job progress, payment progress and stock progress separate. "Completed" means the service was completed; it does not mean payment was collected. "Online" or "Synced" describes connectivity and must not imply the business is accepting new work.

---

## 03 / Service sectors and default workflows

Each row is a suggested sector family. Within each family, partners may select several services. Workflow codes are defined on page 5; the category changes field templates and defaults, not the underlying accounting model.

| Sector family | Examples | Default flows |
|---|---|---|
| Vehicle care | Car and bike wash, detailing, interior cleaning | F1, F2 |
| Vehicle maintenance | Garage, puncture, battery, roadside assistance | F3, F7 |
| Home and commercial cleaning | Housekeeping, deep cleaning, carpet and sofa | F1, F2, F9 |
| Pest control | Inspection, treatment, follow-up visits | F3, F9 |
| Plumbing and sanitation | Leaks, fittings, drainage, installation | F3 |
| Electrical services | Faults, fittings, wiring, installations | F3 |
| Appliance and cooling | AC, refrigerator, washing machine, geyser | F3, F9 |
| Electronics and IT | Phone, laptop, computer, printer repair | F3, F7 |
| Carpentry and furniture | Repair, assembly, custom furniture | F3, F7 |
| Painting and waterproofing | Site assessment, labour and materials | F3, F9 |
| Construction and property maintenance | Small civil works, maintenance contracts | F3, F9 |
| Security and smart home | CCTV, alarms, networking, home theatre | F3, F9 |
| Salon and barber | Haircut, styling, colour, grooming | F2 |
| Beauty and wellness | At-home beauty, makeup, spa, massage | F1, F2 |
| Health appointments | Clinic, dental, outpatient, allied health | F2 |
| Diagnostics and sample collection | Lab appointments and home collection | F1, F2, F7 |
| Fitness and sports coaching | Trainer, yoga, dance, group exercise | F2, F4 |
| Education and tuition | Tutor, music, language, workshops | F2, F4 |
| Sports and facility reservations | Court, turf, studio, meeting room | F5 |
| Laundry and garment care | Wash, iron, dry clean, alterations | F6, F7 |
| Tailoring and personal goods repair | Stitching, shoe, bag, watch repair | F7 |
| Pet services | Grooming, walking, training, boarding booking | F1, F2, F5 |
| Gardening and landscaping | Garden care, pruning, installation | F1, F3, F9 |
| Movers and local transport services | Packing, relocation, goods movement | F3, F8 |

---

## 04 / Additional sectors and category customization

| Sector family | Examples | Default flows |
|---|---|---|
| Photography and video | Studio, event shoot, editing delivery | F2, F8 |
| Events and celebrations | Decoration, planner, sound, lighting | F3, F8 |
| Catering and event staffing | Event service, cook, serving staff | F3, F8 |
| Floristry and gifting services | Venue decoration and custom gift work | F3, F8 |
| Professional consultations | Accounting, tax, legal, business advice | F2, F7 |
| Design and digital services | Graphic design, web, marketing projects | F3, F7 |
| Property services | Broker meetings, inspection, valuation | F2, F3 |
| Domestic and caregiving services | House help, attendant, eldercare visits | F1, F2, F9 |
| Equipment hire and rentals | Tools, cameras, event equipment | F5, F8 |
| Travel and local experiences | Guide appointments, tours, workshops | F2, F4, F8 |
| Document and administrative assistance | Typing, printing assistance, applications | F2, F7 |
| Utilities and waste services | Water tank clean, septic, waste collection | F1, F3, F9 |

**What changes for each category.** Load the appropriate service names, customer intake fields, price basis, duration model, staff skills, required resources, materials recipe, checklist, evidence requirements and completion criteria. Set sensible suggested defaults, but require partner confirmation of commercial terms and capacity.

**Examples of meaningful branches.** Car wash asks vehicle class and parking access. Cleaning asks property size and rooms. Repair asks symptoms, brand and inspection need. Salon asks service variant and staff preference. Clinic asks appointment type and provider, with minimal administrative intake. Class asks participant count. Court booking asks resource and duration. Laundry asks collection, estimated items and handover checks.

**Category boundaries.** Healthcare screens in this release manage administrative appointments and permitted service billing; clinical notes, diagnoses, prescriptions and medical records need a separately governed module. Similarly, service booking must not silently become transport ticketing, financial advice automation, accommodation management or admission ticket issuance.

**Catalogue governance.** The platform owns versioned category templates. Partners may rename a service, hide irrelevant questions and add approved custom fields, but cannot remove platform-required verification or safety controls. New category requests enter review. Do not treat an unsupported high-risk category as unrestricted Other.

---

## 05 / Nine reusable operational branches

| Code | Workflow | Main sequence |
|---|---|---|
| F1 | Fixed service at customer location | Request → confirm → assign → travel → arrive → start → checklist → complete → bill. |
| F2 | Appointment with provider | Choose service → provider and slot → confirm → check in → start → complete → bill. |
| F3 | Inspect and quote | Request → inspection → itemized quote → customer approval → schedule → execute → bill. |
| F4 | Group session | Choose session → reserve places → confirm → register arrival → attendance → complete. |
| F5 | Resource reservation | Choose resource and duration → capacity hold → confirm → hand over → use → return or checkout. |
| F6 | Pickup and return | Request pickup → acknowledge items → process → quality check → dispatch → hand over. |
| F7 | Drop off or project work | Intake → acknowledge item or brief → quote if needed → work stages → ready → hand over. |
| F8 | Event or multi-resource work | Enquiry → scope → quote → approval and deposit → reserve resources → milestones → close. |
| F9 | Repeat visits | Agree repeat schedule → create separate visits → dispatch or attend → complete each → bill as configured. |

**How the branch is selected.** Each service stores a primary workflow and allowed variants. A car wash can offer F1 doorstep work and F2 premises appointments. A photographer may use F2 for studio portraits and F8 for weddings. Quote-based work uses F3 before execution. Add-ons can change duration, materials and resource needs and must trigger availability checks.

**Multiple flows in one partner account.** Home aggregates actions across all enabled services. Work shows distinct Jobs, Bookings or Orders where needed; every record displays its type. Scheduling uses the same staff and resource availability so work from one category cannot overlap a conflicting booking in another.

**Recommended first implementation.** Launch F1, F2 and a basic F3 first. Build shared support for F4 and F5 where partner demand exists. Keep F6 to F9 designed but explicitly disabled until their operational and financial tests pass. A recurring visit schedule is operational repetition; it does not introduce a customer wallet, subscription or membership entitlement.

---

## 06 / Onboarding script for business discovery

Entry journey: partner app → mobile verification → business discovery → starter catalogue → operations setup → verification → test → activation. Existing retail or restaurant partners add a Service module inside the same partner identity.

**O01 Welcome and language**
- Partner sees: "Let's set up your service business."
- Layout and inputs: English, Hindi or Hinglish; business owner or invited staff; brief explanation of setup.
- Action: Get started or resume setup.
- System response: Restore the last saved step; invited staff receive only their permitted setup tasks.

**O02 Verify contact and business identity**
- Partner sees: "Which number should receive booking updates?"
- Layout and inputs: Mobile, OTP flow, name, business name and optional email; link existing account where verified.
- Action: Verify and continue.
- System response: Rate-limit attempts; protect duplicate accounts; do not merge businesses based only on a matching name.

**O03 Choose business categories**
- Partner sees: "What services do you provide?"
- Layout and inputs: Searchable sector groups and multi-select subcategories. Example: Vehicle care → Car wash and detailing.
- Action: Continue.
- System response: Load relevant template options and requirements. Existing selections remain editable without deleting live records.

**O04 Choose delivery model**
- Partner sees: "Where do you serve customers?"
- Layout and inputs: At their location; at my premises; both; online consultation only where supported.
- Action: Choose one or more.
- System response: Enable addresses and travel for doorstep work; branch and resources for premises work; online instructions for supported consultations.

**O05 Understand the team**
- Partner sees: "Who delivers your services?"
- Layout and inputs: Just me; team size band; one or multiple branches; owner also works toggle.
- Action: Continue.
- System response: Solo operators get themselves as the suggested provider. Do not create dummy staff from a headcount band. Skip unnecessary team management questions.

**Keep discovery short.** Ask business age or growth goals only if the answer changes onboarding help. Make those questions optional. Legal and payout details belong to the verification step rather than the initial discovery form. Save each completed step and show a clear progress indicator.

---

## 07 / Onboarding script for starter services

**O06 Choose operational priorities**
- Partner sees: "What would help you most?"
- Layout and inputs: Selectable chips: fill my calendar; manage my team; handle doorstep jobs; send quotes; track materials; collect payments.
- Action: Continue or skip.
- System response: Reorder suggested setup tasks. Answers cannot disable required controls or hide pending customer requests.

**O07 Prepare the starter catalogue**
- Partner sees: "Choose services to add."
- Layout and inputs: Editable cards relevant to the category. For car wash: exterior, interior, full wash and detailing. Each card shows suggested workflow and whether price or duration needs input.
- Action: Select templates, add my own, or save draft.
- System response: Create selected services as drafts with template version references. No customer publication yet. Show real progress only while work is running.

**O08 Confirm each service**
- Partner sees: "Make this service yours."
- Layout and inputs: Name, short description, image, model, price type and amount, duration, inclusions and exclusions. Category questions appear below.
- Action: Save and next service.
- System response: Validate required fields; preserve future price versions; variant changes affect price, duration and materials together.

**O09 Choose variants and extras**
- Partner sees: "Do options change the work?"
- Layout and inputs: Car class; cleaning area; hair length or treatment; optional extras. Show price and extra time beside each option.
- Action: Confirm variants.
- System response: Calculate the full booked duration and required resources. Require explicit pricing for each saleable combination or a clearly defined quote process.

**O10 Suggest materials setup**
- Partner sees: "Do you want to track materials used?"
- Layout and inputs: Track now; set up later; no consumables. If now, show suggested materials and usage with simple editing.
- Action: Confirm or skip.
- System response: Save draft recipes and tracking preference. Skipping stock entry must not fabricate opening balances or promise materials are available.

**Different price models.** Support fixed total, per unit, starting price and quote after inspection. Show the unit explicitly: vehicle, room, square foot, hour, participant, kilogram or item. Separate inspection fees, labour, materials and travel when they apply. Starting prices must explain what determines the final amount and require customer approval of changes.

---

## 08 / Onboarding script for staff and availability

**O11 Set service locations**
- Partner sees: "Where can customers book you?"
- Layout and inputs: Premises: branch address, map pin and working hours. Doorstep: base address, service zones or radius, travel buffer and travel fee policy.
- Action: Save locations.
- System response: Validate address coverage and timezone. Customer map previews must use the configured service area, not the device's assumed location.

**O12 Add staff and skills**
- Partner sees: "Who can perform each service?"
- Layout and inputs: Owner or staff name, invitation contact, service eligibility, branch and role. Add now or invite later.
- Action: Assign services.
- System response: Enforce qualification or approval requirements where configured. Solo operators may proceed with their own provider profile.

**O13 Add resources when needed**
- Partner sees: "What must be available for a booking?"
- Layout and inputs: Only relevant options: chair, treatment room, court, vehicle bay, equipment or facility; quantity and capacity.
- Action: Save or skip if none.
- System response: A service can require several resources simultaneously. Shared equipment and staff must be checked together.

**O14 Set working time**
- Partner sees: "When can customers book?"
- Layout and inputs: Days, hours, breaks, leave, duration, preparation and cleanup buffers, advance notice, booking horizon and slot interval.
- Action: Preview slots.
- System response: Calculate bookable times from all constraints. Slot interval is not service duration. Conflicting existing appointments must be reviewed before schedule changes apply.

**O15 Choose confirmation and collection rules**
- Partner sees: "How should new work be confirmed?"
- Layout and inputs: Automatic confirmation or partner review, response deadline, payment timing, deposit if supported, cancellation and rescheduling policy.
- Action: Preview customer terms.
- System response: Validate policy and financial settings; customer sees applicable terms before confirming. Do not auto-confirm quote-based final scope before approval.

**Availability examples.** A 30-minute service with 10-minute cleanup blocks 40 minutes. A 15-minute slot grid can still offer a 60-minute service. A doorstep worker needs travel time before the next job. A class of capacity 12 with 9 confirmed places has 3 places remaining, subject to live holds.

---

## 09 / From setup to an operational app

**O16 Business verification and payout setup**
- Partner sees: "Complete the checks for your services."
- Layout and inputs: Public and legal identity; required category documents; tax configuration where applicable; payout destination through approved finance setup; terms acceptance.
- Action: Submit securely.
- System response: Show Draft, Submitted, Under review, Action required or Approved. Protect identity and banking data. Requirements are maintained by the platform, not assumed universal.

**O17 Preview the customer listing**
- Partner sees: "This is what customers will see."
- Layout and inputs: Service variants, total or quote rules, inclusions, location, times, policies and customer questions.
- Action: Edit or confirm preview.
- System response: Flag missing fields, misleading starting prices and unavailable staff or resources. Preview is not publication.

**O18 Run a guided test**
- Partner sees: "Try your first booking."
- Layout and inputs: Test customer and clearly labelled test mode; choose slot, accept, assign, complete and review a sample bill.
- Action: Run test and review result.
- System response: Use sandbox or test records excluded from real payouts, stock and reports. A separate authorized live payment test, if needed, must use real finance controls.

**O19 Review launch readiness**
- Partner sees: "Your business is almost ready."
- Layout and inputs: Checklist: approved verification; service price; availability; eligible staff; required resources; policies; payments where required; notifications; customer preview; test result.
- Action: Fix missing item or request activation.
- System response: Backend validates readiness and permission. Allow controlled offline-only operations where configured; do not publish an incomplete listing.

**O20 Start operations**
- Partner sees: "You're ready to receive work."
- Layout and inputs: Business accepting status; published services; first live availability; New booking and View schedule.
- Action: Open for bookings.
- System response: Activate only approved services and locations. Notify partner of activation. Preserve setup checklist in More for later changes.

**Support and recovery.** Every rejected document gives a specific reason and resubmission path. Interrupted setup resumes at the last valid step. A paused or suspended business sees permitted actions and support routes. Pausing new work preserves confirmed bookings and exposes the tasks still owed to customers.

---

## 10 / Daily screen scripts

**D01 Common home**
- Partner sees: "Here is what needs your attention."
- Layout and inputs: Branch switcher; acceptance status; new requests; unassigned jobs; upcoming appointments; payment follow-ups; compact owner-only financial summary.
- Action: Open next action or tap plus.
- System response: Counts come from authoritative records and respect role permissions. Setup prompts disappear or collapse after completion.

**D02 Work queue**
- Partner sees: "Manage today's work."
- Layout and inputs: New, Confirmed or Assigned, In progress, Completed, Cancelled; overdue badge; filters for service, worker, source and branch.
- Action: Open, accept, assign or confirm.
- System response: Server validates the action and refreshes status. Booking and job labels remain distinct; do not give arrival states to remote consultations.

**D03 Schedule**
- Partner sees: "See who and what is available."
- Layout and inputs: Day and list; optional map; date strip; staff and resource filter; blocks; duration and buffers.
- Action: Add booking, reschedule or block time.
- System response: Check conflicts on save and confirmation. Map pins show service destinations, not continuous worker tracking by default.

**D04 Quick create and walk in**
- Partner sees: "What would you like to create?"
- Layout and inputs: Choose service; identify customer; then show workflow-specific fields. Walk-in may use an available now slot or waiting queue.
- Action: Review and create.
- System response: Validate capacity even for walk-ins. Show duplicate warnings, estimated amount and required customer approval before additional charges.

**D05 Customer profile**
- Partner sees: "View this customer's work."
- Layout and inputs: Permitted contact channels; current bookings; past services; preferences; payment summary where authorized.
- Action: Book again, contact or open issue.
- System response: Do not expose unrelated branch data or sensitive records. Rebooking uses current prices with clear review, while history retains original details.

**D06 More and settings**
- Partner sees: "Manage your business."
- Layout and inputs: Services, Materials, Team, Branches, Payments, Reports, Policies, Notifications and Support; search if the list grows.
- Action: Open an allowed tool.
- System response: Show sync status separately from business acceptance. Ask device notification permission in context and explain how to enable it after denial.

---

## 11 / Fixed jobs and provider appointments

**F1 Doorstep fixed service.** Customer picks service, variant, address and requested time. Validate coverage, travel, materials policy, staff and payment terms. Partner accepts within the configured deadline or the request expires with clear customer communication. Acceptance and assignment are separate actions unless a qualified solo operator is assigned automatically.

**Execution script.** Job detail shows customer, service scope, approved amount, address, time and worker. Worker taps En route, Arrived and Start service in order. Capture relevant arrival confirmation if configured. Show service checklist, optional notes and permitted evidence. Complete only when required checks pass. Issue a bill for the approved scope and show payment independently.

**Category differences.** Car wash: vehicle class, access to water or power, parking, wash checklist and damage observations. Cleaning: property size, room list, included tasks and before or after evidence where appropriate. Gardening: area, task list, equipment and waste removal scope. At-home beauty: treatment, duration, provider eligibility and customer preparation.

**F2 Premises or provider appointment.** Customer chooses service and optional preferred provider. System returns available times and compatible resources. On confirmation, reserve staff, room or chair for the full duration and buffers. Reception sees Check in, Start, Complete, Reschedule and No-show as permitted actions. Attendance and payment are separate.

**Category differences.** Salon: service combinations, stylist, chair, processing time and consumables. Clinic: department, provider, appointment type and minimal administrative intake; appointment completion is not a medical outcome. Consultation: appointment mode, contact instructions and duration. Studio service: provider and room or equipment.

**Delay and exception handling.** If a worker is absent, show reassignable eligible workers and notify the customer of confirmed changes. Delays must not silently shift later appointments. Customer not reachable, access denied or unsafe conditions create a documented exception. Partial work requires explicit scope and financial review; never mark a full service complete just to close the queue.

---

## 12 / Inspection and quote operations

**F3 Before the visit.** Request asks symptoms, item or site details, urgency, photos where appropriate and address. Show any inspection or call-out charge separately. Inspection reserves travel and assessment time; it does not promise the final repair price. Customer can accept the inspection terms before a worker is sent.

**Q01 Assessment and quote**
- Partner sees: "What work is required?"
- Layout and inputs: Findings; labour lines; material quantities; optional extras; taxes configured for the partner; travel; discounts; deposit and expiry.
- Action: Save draft or send for approval.
- System response: Freeze a quote version and record the recipient, amount and approval state. Inventory estimates stay separate from actual usage.

**Q02 Customer approval**
- Partner sees: "Please approve this scope and amount."
- Layout and inputs: Customer-facing description, total, exclusions, expected duration, cancellation terms and optional lines.
- Action: Approve, decline or request change.
- System response: Only a verified approval of the current version authorizes work. Record timestamp and evidence. A changed total or material scope creates a new approval request.

**Q03 Schedule and execute approved work**
- Partner sees: "Ready to schedule."
- Layout and inputs: Approved quote, staff skills, parts availability, resource time and earliest workable slot.
- Action: Confirm time, issue materials, start and complete.
- System response: Reserve staff and required parts under configured rules. A quote approval alone does not create unlimited stock or a confirmed slot.

**Extra work on site.** Worker proposes a change showing extra price, duration and materials. Pause the affected scope until customer approval and availability checks complete. If approval fails, finish only the previously authorized work where feasible or escalate. Do not add unapproved parts to the final bill.

**Repair variants.** Plumbing, electrical and AC work use site symptoms and approved labour plus parts. Device repairs add serial or item identification, existing condition and handover acknowledgement. Painting or civil work adds measurements, site assessment, milestones and progress evidence.

**Settlement and rework.** Convert the final approved scope into order lines; apply legitimate adjustments through linked records. Record warranty or revisit terms for the service. A rework visit links to the original job, with an explicit charge or no-charge decision and separate materials usage.

---

## 13 / Sessions, resources and custody workflows

**F4 Classes and group sessions.** Create session name, instructor, venue, start and end, participant capacity, registration cutoff and price basis. Customer requests a number of places. Backend uses a temporary hold and confirms only if capacity remains. Partner sees capacity, attendee list, check-in, attendance and no-shows. Cancellation releases capacity according to the actual reservation state. Waitlists, if enabled, require explicit offer expiry. This flow is reservations and attendance, not ticket issuance or QR admission.

**F5 Courts, rooms, facilities and equipment.** Customer selects an asset, start and duration. Reserve the asset and any required operator, including setup and turnaround. Staff records handover, use and checkout or return. For rentals, include quantity, condition and due-back time. Deposits are tracked separately from revenue; deductions require a reason, evidence and approval. Resource downtime blocks new requests and triggers review of affected reservations.

**F6 Pickup, process and return.** Customer requests collection. Assign a collection task; record each item or weight, condition, count and acknowledgement at pickup. If count or price changes, obtain customer approval before processing. Track received, processing, quality check, ready, out for return and handed over. Collection and return are separate scheduled tasks. Reconcile missing items or failed handovers as issues; do not close on dispatch alone.

**F7 Drop off or staged project.** At intake, capture an item identifier and condition for physical goods, or an agreed brief and deliverables for projects. Give a receipt or acknowledgement. Move through assessment, awaiting approval, awaiting material, working, quality check, ready and handed over as relevant. Completion of work and customer handover are separate. Digital deliverables record delivery and acceptance without pretending to hold physical stock.

**Inventory implications.** Laundry items and customer repair goods are customer-owned custody records, not the partner's saleable inventory. Rental assets are reusable resources, not consumables. Only detergents, packaging, parts sold or used, and similar partner materials enter stock consumption. This distinction must survive returns and reports.

---

## 14 / Events, repeat visits and communication

**F8 Events and multi-resource services.** Enquiry captures date, venue, guest count or scope and required team or equipment. Prepare a versioned quote with milestones and deposits. Use expiring tentative holds for scarce resources. On approval and required payment verification, confirm the event and assignments. Track setup, delivery, event service, dismantling and asset return. Close after deliverable acceptance, resource return and a clear statement of any outstanding balance.

**Category examples.** Photography records shoot duration, team, deliverables and editing milestones. Decoration records venue access, installation and removal. Catering services record guest-count basis, service scope and approved changes; detailed food production may remain in a connected food module. Movers record origin, destination, item or vehicle needs and handover. Avoid forcing all these into a 30-minute appointment form.

**F9 Repeat operational visits.** Set frequency, service days, start and end, per-visit scope, staff preference and billing rule. Generate visits only within a controlled future horizon. Each visit has its own availability, completion, evidence, materials and payment linkage. Reschedule one visit or future visits explicitly. Avoid duplicate visits on regeneration. Pausing a series must explain which already-confirmed visits remain active.

**Quote and subscription distinction.** A repeat job schedule can exist without a prepaid membership. If recurring auto-debits, credits, usage limits or entitlements are introduced later, implement them as a separate approved commercial feature. Do not infer those permissions from a recurring calendar setting.

**Customer communication by milestone.** Use approved channels and consent settings. Send request received, confirmation, quote approval request, assignment where useful, arrival or delay update, completion, bill and verified payment receipt. Include a clear reschedule or support path. Send cancellations and refund progress as separate messages. Internal notes, material purchase cost and staff-only instructions remain private.

**Partner notifications.** Offer controls for new request, booking, schedule change, assignment, approved quote, payment confirmation, refund issue and active timer. Group routine updates; retain an in-app action queue even when push permission is denied. Failed notification delivery must not change booking or payment truth.

---

## 15 / Inventory masters and service recipes

Partner-facing labels: Materials and Materials used. The backend uses item, unit, recipe, reservation and movement records. Partners should not need to understand a stock ledger to complete ordinary jobs.

| Master | Minimum structure |
|---|---|
| Material item | Item ID, partner, name, stock unit, purchase pack, conversion, tracking mode, reorder level, active status; lot or expiry when relevant. |
| Units and packs | Base unit and dimensional type; pack quantity; conversion factor; permitted decimals and rounding rule. |
| Service recipe version | Service and variant ID, version, effective date, yield basis, material lines, standard quantity, optional allowance, substitutions and deduction rule. |
| Stock location | Branch, store or worker kit; custodian; material balances derived from movements. |
| Stock movement | Item, base quantity, source or destination, type, job link, actor, timestamp, reason and idempotency key. |
| Job material usage | Recipe snapshot, standard quantity, approved substitution, actual quantity, waste, unused return and posting status. |

**Recipe basis.** Define consumption per service, per area, per participant, per kilogram or per hour. Compute standard quantity as recipe quantity × booked basis ÷ recipe yield. Include an explicit allowed rounding rule. Do not infer material consumption from selling price. Optional waste allowance must not be added twice when actual usage already includes waste.

**Unit conversion.** Store shampoo in mL even if purchased as a 5 L can. One can adds 5,000 mL. A 20 mL standard wash allows 250 washes before waste. A sealed sponge issued as a whole pack deducts one pack or its equivalent unit count. Never convert kilograms to litres without an item-specific approved conversion.

**Version preservation.** Copy the applicable recipe version to each job. Later recipe edits affect future work only. A service with no consumables uses No materials required rather than a false empty recipe error. Substitutions require compatibility and permission checks; record the material actually used.

---

## 16 / Minimal inventory screens and posting rules

**I01 Add stock**
- Partner sees: "What arrived?"
- Layout and inputs: Search material, number of packs or loose quantity, pack size, destination and optional cost; show converted stock quantity.
- Action: Save receipt.
- System response: Post once after server confirmation. Batch, expiry or serial fields appear only for items that require them.

**I02 Link a service recipe**
- Partner sees: "What is normally used for this service?"
- Layout and inputs: Suggested material rows with plain quantities, service yield and Track usage toggle. Advanced contains allowance, substitution and stock policy.
- Action: Save standard usage.
- System response: Validate units and version the recipe. Hide this screen from ordinary workers.

**I03 Complete materials used**
- Partner sees: "Did you use the usual materials?"
- Layout and inputs: Default text: "Standard materials will be recorded." Primary Confirm; secondary Change quantities; show only relevant items.
- Action: Confirm usage with service completion.
- System response: Consume actual confirmed quantities once. Larger deviations ask for a reason and, above configured limits, manager approval.

**I04 Materials overview**
- Partner sees: "Do you have enough for upcoming work?"
- Layout and inputs: Available, reserved and low stock; Add stock, Transfer and Adjust. Owner can open history.
- Action: Receive or correct with a reason.
- System response: Show unknown stock separately from zero. Estimated services remaining uses recipe and variant assumptions, clearly labelled.

**Reservation and deduction.** Proposed default: optionally reserve critical stock when work is confirmed; deduct consumables when usage is confirmed at completion. Issue parts earlier when operationally required. A reservation reduces available stock but not on-hand stock. For worker kits, a transfer changes custody; later consumption reduces the kit balance. Do not deduct at both transfer and completion.

**Cancellation and partial work.** Cancellation before use releases reservations. Issued unused material is returned through a movement. Started or partially completed work records actual use even when the job is cancelled. Refunds do not automatically return stock: consumed shampoo cannot be restored by reversing a customer payment.

**Minimum viable tracking.** Default to standard usage with exceptions, basic receipts and low-stock alerts. Offer track later for noncritical materials. Critical shortage policy may block confirmation; soft shortage shows an owner warning. No silent negative stock: any permitted override records actor and reason. An unknown opening balance is an unresolved setup state, not zero.

---

## 17 / Worked materials examples and controls

| Service | Recipe example | What the worker sees |
|---|---|---|
| Exterior car wash | 20 mL shampoo per wash; 1 disposable wipe; reusable cloth excluded from consumption. | Use standard materials or change quantity. |
| Home cleaning | 50 mL cleaner per 100 sq ft. A 600 sq ft job estimates 300 mL. | Standard cleaner estimate; correct actual use if needed. |
| Salon colour treatment | Variant-specific colour and developer quantities; units in grams or mL as appropriate. | Selected treatment materials; record actual quantity. |
| Electrical repair | One approved replacement switch plus permitted consumables. | Confirm fitted part; return unused issued part. |
| Workshop | One materials kit per attendee supplied; unopened spare kits returned. | Number of kits used and returned. |
| Laundry | Detergent per kilogram processed; customer garments tracked separately. | Confirm processed weight and actual exceptions. |

**Car wash transaction example.** Receive two 5 L cans: on hand becomes 10,000 mL. Reserve 200 mL for ten confirmed washes: available becomes 9,800 mL while on hand remains 10,000 mL. One completed wash uses 25 mL: on hand becomes 9,975 mL and remaining reservations 180 mL, so available becomes 9,795 mL. Cancelling one unused future wash releases 20 mL; it does not increase on hand.

**Costs and margins.** Track material cost separately from customer charges. Cost reports must disclose the costing method and whether labour, travel, platform charges and taxes are included. Do not label gross sales less materials as net profit. Missing cost input should show cost unavailable rather than a misleading zero.

**Approvals and traceability.** Only authorized staff may edit recipes, receive restricted materials or adjust stock. Adjustment requires count, reason and actor. Expired, quarantined or otherwise blocked stock cannot satisfy availability or substitutions. Clinical or regulated stock needs additional validated controls before enablement; the generic recipe system alone is insufficient.

**Concurrency and replay.** Completing the same job twice must not double-deduct materials. Receipt retries must not add stock twice. Two simultaneous reservations must not oversell hard-controlled stock. Failed postings leave a visible pending or needs-review state with a safe retry; never report successful synchronization before the server confirms it.

---

## 18 / Payments, refunds and exception states

**Bill and collection screen.** Show approved service lines, extras, materials charged where agreed, applicable configured taxes, discounts, deposits applied, total, amount paid and balance. Provide View bill, supported online collection and authorized Record cash. A QR image or customer screenshot is not proof of a successful payment. Payment truth comes from the approved payment and reconciliation systems.

**Independent state models.** Booking: pending confirmation, confirmed, checked in, in progress, completed, cancelled or no-show. Doorstep job: pending acceptance, accepted, assigned, en route, arrived, in progress, completed or cancelled. Quotes: draft, sent, approved, declined, expired or superseded. Payment: pending, processing, successful, failed, partially refunded, refund pending, refunded or reconciliation required. Track partial execution through execution details and reviewed closure reasons.

**Cancellations and refunds.** Load the policy version accepted for the booking. Show who cancelled, when, work already performed, eligible refund and any proposed charge. Authorized users approve according to permissions. Refund approval, submission and provider-confirmed refund are separate steps. Keep immutable original charges and linked adjustments. Release availability and unused material reservations deliberately. Customer disputes have a support case and evidence history.

**Settlements and financial boundaries.** Partner payments and platform settlements must reuse the canonical finance system. Show collected, outstanding, refundable and settlement-eligible amounts distinctly. Service POS must not create an independent vendor wallet or infer payout availability from a completed job. Settlement schedules, holds and deductions follow the approved finance policy and must be traceable to transactions.

| Failure or edge state | Required experience |
|---|---|
| Slot or staff conflict | Explain what changed; offer valid alternatives; preserve entered details. |
| Payment uncertain | Show verification pending; retry lookup safely; avoid duplicate collection. |
| Weak network | Show cached data age; retain permitted drafts; confirm bookings online. |
| Partial work or access issue | Capture actual work and materials; show review and customer contact route. |
| Notification denied | Explain device settings; keep in-app queue and preferences available. |
| Permission denied | Explain restriction; offer request to authorized manager without leaking data. |

---

## 19 / Roles, backend configuration and data

| Role | Default access |
|---|---|
| Owner | Business setup, services, staff, policies, finances, materials and reports; subject to platform controls. |
| Manager | Day operations, assignment and stock; approval limits configured by owner. |
| Receptionist | Bookings, walk-ins, check-in and permitted billing; limited customer data. |
| Worker or provider | Own schedule, job instructions, status, checklist and actual materials; no unrestricted finances. |
| Finance user | Bills, collection, reconciliation and approved refunds; limited operational editing. |
| Platform reviewer | Verification, category template management and activation within audited permissions. |

**Versioned experience configuration.** Resolve category template → enabled service model → branch → service variant → role. Partner settings may change approved defaults but cannot weaken mandatory controls. Store category ID, workflow ID, field definitions, visibility rules, required checks, pricing basis, duration model, resource rules, checklist, recipe reference, evidence policy and allowed transitions. Record versions used by historical transactions.

**Shared records.** Reuse partner, location, customer, order, order line, payment, refund, staff and audit systems. Add service template, category extension, provider eligibility, resource, schedule rule, availability hold, booking, job, assignment, quote version, execution event, session, attendance, material recipe, stock reservation, movement and usage records. Customer goods custody and reusable assets remain separate from consumables.

**Critical backend transactions.** Hold and confirm capacity atomically with expiry and safe release. Confirm provider and resource conflicts on the backend. Use idempotency keys for creates, completion, stock posts and payment requests. Publish durable events or equivalent reliable delivery so a successful job completion cannot silently lose its stock posting or bill task. Failed downstream work remains visible for retry and reconciliation.

**Audit and privacy.** Log actor, entity, action, previous and new state, reason, time and correlation ID for price, schedule, assignment, completion, stock, finance and permission changes. Restrict identity documents, banking information, private notes and evidence. Remove revoked access from active sessions. Define retention and consent settings with the platform's approved policies.

---

## 20 / Developer handoff and acceptance scenarios

| Area | Required capability or integration contract |
|---|---|
| Onboarding | Save and resume setup; resolve template; submit verification; preview; readiness and activation. |
| Catalogue | Create versioned services, variants, prices, questions, checklists and recipes; preview and publish. |
| Availability | Query authoritative slots; create expiring holds; confirm, reschedule and cancel safely. |
| Operations | Receive requests; transition states; assign eligible staff; capture evidence and execution events. |
| Materials | Receive and transfer; reserve and release; post actual usage; return and adjust with history. |
| Finance | Link orders and approved prices to payments, receipts, refunds and settlement views. |
| Communications | Deliver approved event messages with retry, preferences and delivery status. |
| Support | Open linked cases, limit evidence access, escalate and preserve resolution history. |

**Required handoff assets.** Provide sitemap, the O/D/Q/I screen IDs and their mapping to existing screens, clickable F1/F2/F3 prototypes, field-level validations, role matrix, canonical record mapping, endpoint or event contracts, state transitions, notification catalogue and empty/error/conflict states. Endpoint names are implementation choices; do not create duplicate canonical systems to match a document label.

**Acceptance scenarios.**
1. A solo car-wash owner completes setup, receives a doorstep job, records standard usage and collects verified payment.
2. A cleaning team assigns eligible workers without overlapping jobs or missing travel buffers.
3. A salon combines services and reserves provider plus chair for the correct total time.
4. A clinic books and checks in a customer without exposing clinical information.
5. A repair technician sends a quote, receives approval, fits a part and bills the approved amount.
6. Two customers compete for the last class place: only one confirms.
7. A resource booking includes turnaround and cannot overlap.
8. A cancelled started job records actual materials and a separate refund decision.
9. Offline retries cannot duplicate bookings, charges or stock usage.
10. A role change immediately removes restricted access.

**Inventory correctness checks.** Validate pack conversion, area-based recipe scaling, version preservation, worker kit transfers, unused return, expired-stock exclusion and critical shortages. Replay completion and receipt requests. Confirm that customer refunds do not automatically replenish consumed stock. Reports must reconcile with underlying movements and finance records.

---

## 21 / Release plan and final build instructions

**Release one: reliable foundations.** Deliver discovery and draft services, category templates, verification, branches, staff, availability, F1, F2 and basic F3, checklists, evidence, billing, payment linkage, cancellations, support and role controls. Include basic materials masters, pack conversion, receipts, versioned recipes and one-time usage posting. Publish only categories supported by these tested flows.

**Release two: broader service operations.** Enable F4 sessions and F5 reservations with tested capacity controls. Add F6 pickup/return and F7 custody/staged work when handover tracking is ready. Expand F8 multi-resource events and F9 repeat visits only after deposits, resource conflicts, milestone changes and visit generation are verified. Add richer time tracking and cost reports as operational needs justify them.

**Future commercial modules.** Customer memberships, recurring payment subscriptions, service entitlements, ticket inventory, seat selection, QR entry and ticket transfers remain separately scoped. Partner software subscription billing, if adopted, is also distinct from a customer's recurring service agreement.

**Defaults proposed for founder review.** Use guided templates; allow multi-category businesses; keep one common Home; make Work and Schedule adaptive; use manual confirmation as the initial default for doorstep work; offer automatic confirmation for validated appointment capacity. Record standard materials at completion, with actual-use exceptions. Configure evidence by category and service, with cleaning and car wash as initial photo-based candidates. These are proposals, not implied prior approvals.

**Instructions for the implementation team.** Build this as the Service POS module within the existing One Local Partner App. Preserve working records and reuse canonical services. Derive the visible experience from category, workflow, role and location. Ask only questions that affect the current service. Keep advanced setup behind progressive disclosure. Never publish a template as a live service until the partner confirms its price, duration, capacity and applicable terms.

The app is operational when an approved partner can publish a valid service, receive a real request, reserve true availability, perform the work, record actual materials, bill the approved scope, verify collection and find the complete history. Demonstrate that journey for both an at-home service and a premises appointment before calling the release ready.

**Next visual design set.** Create simple One Local screens for category selection, delivery model, suggested services, price and duration setup, staff and availability, first steps, active Home, adaptive Schedule, job detail, quote approval, materials confirmation and bill/payment. Validate these with a solo operator, a multi-worker team and an appointment-based partner before expanding the screen library.
