# Service POS: blueprint vs the app (2 Nov 2026)

Compares [service-pos-blueprint.md](service-pos-blueprint.md) with what is built today: the app (`lib/service/`, `lib/onboarding/`, `lib/setup/`), the POS server (`server/src/rpc-manifest.ts`, 22 `svc_*` calls) and the local database (51 `svc_*` functions, 20 `svc_*` tables, same as hosted). Checked by reading the code and calling the server as a test business; not every screen was clicked through in the app.

**Status:** ✅ built · 🟡 partly built · ❌ missing · ⏸ later (release two or future in the blueprint).

## Summary

The day-to-day booking engine is the strongest part: services with duration, buffer and add-ons; staff with their services and hours; location hours, breaks, closures and time off; slots; booking with advance; check-in, start, checklist, approved extras, bill, payment, cancel with refund, no-show, reschedule; history, packages and memberships. It is built around one shape of work, the appointment (F2), with a partial doorstep job (F1).

The biggest gaps, in order of how much they block release one:
1. **Onboarding (O01–O20)**: partners pick one service kind from a short list; the setup steps after approval are the store's; nothing sets hours, staff, service area or rules; there are no starter services, no preview, no test booking, no launch check.
2. **Navigation**: service partners get the store's bottom bar; the blueprint's Home / Schedule / Work / Customers / More with one plus button does not exist.
3. **F3 inspect and quote**: not built at all.
4. **Materials (pages 15–17)**: not built; only one-off extras the customer approves on the job.
5. **"Completed" = "paid"**: a visit can only be completed by paying for it, against the blueprint's status rules.
6. **Requests from customers**: every booking is made by staff in the POS; there is no request → accept flow, and neither customer app (`onelocal-customer`, `customer app`) has any service booking code, so "receive a real request" (page 21) cannot happen yet.

## 02 Navigation and structure

| Blueprint | Status | Today |
|---|---|---|
| Home / Schedule / Work / Customers / More | ❌ | Store bar: Money, Item, Bill, Online order, Stock. Bill opens the appointment calendar; Home shows the service dashboard. Service screens are reached from a ☰ "Service" sheet. |
| One plus button (booking, at-home job, walk-in, customer, quote, block time) | ❌ | "+ Book appointment" on the calendar only. |
| Three home states (setup, verification, active) | 🟡 | Store setup wizard runs before the shell; the service dashboard has one state. |
| Familiar labels (Technician for repairs, Provider for clinics) | ❌ | Fixed words ("Provider", "Appointment", "studio"). |
| Completed ≠ paid; separate status lines | ❌ | `svc_bill` completes the visit only when the order is paid. |

## 03–05 Sectors and workflows

| Blueprint | Status | Today |
|---|---|---|
| 36 sector families, multi-select subcategories | 🟡 | 10 service kinds in `server/src/data/partner-taxonomy.json`, with subcategories, but sign-up takes one kind and drops the subcategory. |
| Versioned category templates (fields, price basis, checklist, evidence) | ❌ | No templates; every service is a free form. |
| Each service picks a workflow (F1–F9) | 🟡 | `svc_services.fulfilment`: appointment, on_location, event, on_demand. No workflow codes, no allowed variants. |
| F1 doorstep fixed service | 🟡 | Address, access note, arrival code, check-in, checklist, approved extras, bill. Missing: request → accept, assign as its own step, En route / Arrived, coverage or travel check, evidence photos. |
| F2 appointment | ✅ | Service → provider → slot → book (advance optional) → check in → start → bill. Reschedule, no-show, cancel with refund. Resource is stored but not checked (see F5). |
| F3 inspect and quote (Q01–Q03) | ❌ | `svc_quote` is only a price preview. No quote versions, customer approval or approved-scope billing. |
| F4 group sessions | 🟡 ⏸ | `event` fulfilment and capacity exist (Figma event screens); no holds, attendee list or attendance. Release two. |
| F5 resources | 🟡 ⏸ | `svc_resources` table exists (name, kind) but slots ignore it; no capacity or turnaround. Release two, but O13 / scenario 3 (chair) needs resource checks in release one. |
| F6–F9 | ⏸ | Not built; blueprint keeps them disabled until release two. |
| Price models: fixed, per unit, starting price, quote | 🟡 | Fixed price only (plus add-ons). |
| Variants that change price, time and materials | 🟡 | Add-ons change price and time; no variants (car class, area, hair length). |

## 06–09 Onboarding (O01–O20)

| Screen | Status | Today |
|---|---|---|
| O01 Welcome and language | 🟡 | App has languages and resumes a draft application; no service-specific welcome. |
| O02 Mobile, OTP, identity | ✅ | Shared sign-up (mobile code, name, business, optional email). |
| O03 Categories, multi-select | 🟡 | One "Services" dropdown, 10 kinds, no subcategories, no search. |
| O04 Delivery model (their place / my premises / both / online) | ❌ | Only the store's "how you sell" (physical / online). |
| O05 Team (just me, size, branches) | ❌ | |
| O06 Priorities | ❌ | |
| O07 Starter catalogue from templates | ❌ | Setup → Catalogue adds a store product (no duration, not bookable). |
| O08 Confirm each service | 🟡 | Service catalogue edit screen exists after setup (name, price, duration, buffer, staff, add-ons, checklist); not part of onboarding; no image, inclusions, price type. |
| O09 Variants and extras | 🟡 | Add-ons only. |
| O10 Materials setup | ❌ | |
| O11 Locations: premises hours, doorstep zones and travel | 🟡 | Location hours in Availability; no service zones, radius, travel buffer or fee. Setup has the store's Delivery step instead. |
| O12 Staff and skills | 🟡 | Staff & providers screen (services, title, skills, certification, area); setup's Staff step invites cashier/manager only; solo owner is not offered as the provider. |
| O13 Resources | ❌ | |
| O14 Working time and slot preview | 🟡 | Availability screen: hours, breaks, staff hours, slot interval, closures, time off. Not in onboarding; no notice/horizon setting in UI; no preview. |
| O15 Confirmation and collection rules | 🟡 | Deposit amount and free-cancel hours exist in `svc_settings`; no auto/manual confirm, response deadline or customer terms preview. |
| O16 Verification and payout | ✅ | Shared application: address, tax, documents, bank, agreement, review (auto-approved while testing). No category-specific documents. |
| O17 Customer listing preview | ❌ | |
| O18 Guided test booking (test mode) | ❌ | |
| O19 Launch readiness | 🟡 | Store setup checklist (plan, POS device, profile); nothing checks prices, hours, staff or policies. |
| O20 Open for bookings | 🟡 | `ol_merchant_channels.accepting` exists for the store; no service activation. |

## 10 Daily screens (D01–D06)

| Screen | Status | Today |
|---|---|---|
| D01 Home | 🟡 | Service dashboard: today's visits, money, free slots, needs attention (to bill, advances, no-shows), next up, providers. No requests/unassigned (none exist), no branch switcher. |
| D02 Work queue | 🟡 | Service history with filters; no live queue of New / Assigned / In progress. |
| D03 Schedule | 🟡 | Calendar day/week, provider filter. Blocked time and holidays only from Availability, not the calendar. No list or map view, no resource filter. |
| D04 Quick create / walk-in | 🟡 | Booking form (service first, then provider and slot). No walk-in queue or "now" slot. |
| D05 Customer profile | ❌ | Figma "Customer Service 360" not built in the app. |
| D06 More / settings | 🟡 | ☰ Service sheet: calendar, catalogue, packages, memberships, staff, availability, history. No materials, policies, reports or notifications for services. |

## 11–12 Operations details

| Blueprint | Status | Today |
|---|---|---|
| Checklist before completion | ✅ | Service checklist, ticked on the job; billing waits for it. |
| Evidence photos | ❌ | Screen says "Photo upload is not available in this release." |
| Extra work approved by customer before billing | 🟡 | Extras need "approved by customer" tick; no customer-side approval record or price/time recheck. |
| Arrival confirmation | ✅ | 4-digit arrival code or customer confirmation request. |
| Reassign absent worker, exceptions (no access, unsafe) | ❌ | |
| Rework linked to original job | ❌ | |

## 13–14 Later workflows, communication

| Blueprint | Status | Today |
|---|---|---|
| F4–F9 | ⏸ | See above. |
| Customer messages by milestone | 🟡 | Only the paid bill on WhatsApp (2 Nov) and the arrival code. No booking confirmation, reminder, delay or cancellation messages. |
| Partner notifications | ❌ | For services. |

## 15–17 Materials

| Blueprint | Status | Today |
|---|---|---|
| Material items, packs, conversion | ❌ | Store stock exists (`lib/stock`), not used by services; the blueprint wants service materials kept simple and separate from saleable stock. |
| Service recipes (versioned) | ❌ | |
| "Standard materials used" at completion (I03) | ❌ | |
| Materials overview, add stock (I01, I04) | ❌ | |

## 18 Money

| Blueprint | Status | Today |
|---|---|---|
| Bill: lines, extras, tax, discount, deposit, paid, balance | ✅ | Service Billing screen; receipt with print and WhatsApp bill link (2 Nov). |
| GST rules | ✅ | 18% for services, none when not registered (2 Nov). |
| Reuse canonical orders and payments | ✅ | Every booking is a normal order; payments through `pos_record_payment`. |
| Cancellation with policy, refund steps | 🟡 | Cancel with refund method, free-cancel window, advance kept or released. No policy version, no separate approve → submit → confirmed refund steps. |
| Payment uncertain / online collection | 🟡 | Cash, UPI, card recorded by staff; no online payment link for services. |

## 19 Roles

| Blueprint | Status | Today |
|---|---|---|
| Owner, manager, receptionist, worker, finance, reviewer | 🟡 | `svc_can`: "book" (owner, admin, manager, biller, captain, …) and "manage" (owner, admin, manager, …). No worker-only "my jobs" view; no finance role split. |
| Audit of changes | ✅ | `audit_logs` rows from every `svc_*` save. |
| Idempotency on creates, completion, payments | ✅ | Every write carries an idempotency key. |

## 20 Acceptance scenarios (today)

| # | Scenario | Can it pass today? |
|---|---|---|
| 1 | Solo car wash: setup → doorstep job → standard materials → paid | ❌ setup and materials missing |
| 2 | Cleaning team: no overlaps, travel buffers | 🟡 staff overlap checked; no travel buffer |
| 3 | Salon: provider + chair for the full time | 🟡 provider yes, chair not checked |
| 4 | Clinic booking without clinical data | 🟡 booking works; no clinic wording |
| 5 | Repair: quote → approval → part → bill approved amount | ❌ no quotes |
| 6 | Last class place: only one confirms | ❌ |
| 7 | Resource turnaround, no overlap | ❌ |
| 8 | Cancelled started job: actual materials + refund decision | ❌ no materials |
| 9 | Retries never duplicate bookings, charges or stock | 🟡 bookings and charges yes (idempotency); no stock yet |
| 10 | Role change removes access at once | 🟡 roles checked on every call; not tested |

## Suggested build order for release one

Smallest steps that each leave the app working; every step keeps service code in `lib/service/` and service SQL, with no store POS changes.

1. **Completed ≠ paid** (F1/F2 status rule): allow Complete before payment; the bill stays open with its balance. Small, and every later step depends on it.
2. **Service onboarding, part 1** (O03–O05, O07–O08, O11, O12, O14): multi-select kinds and subcategories; where you serve; just me / team; starter services from simple templates (name, workflow, price type, duration); hours and staff in setup; replaces the store's Catalogue / Inventory / Delivery steps for service partners.
3. **Navigation** (02, D01–D06): Home / Schedule / Work / Customers / More and the plus button, for service partners only.
4. **F1 doorstep job states**: request → accept → assign → en route → arrived → start → complete; service zone and travel buffer.
5. **F3 quotes** (Q01–Q03): quote versions, customer approval link (like the bill link), approved scope becomes the bill.
6. **Basic materials** (I01–I04): items with packs, recipes per service, standard usage at completion.
7. **Onboarding, part 2** (O15–O20): confirmation rules, customer preview, test booking, launch check.
8. **Resources** for F2 (chair, room) so scenario 3 passes.

Founder sketches decide the look of steps 2, 3 and 7.
