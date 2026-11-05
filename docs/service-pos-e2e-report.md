# Service POS forms: end-to-end test results

4 Nov 2026 · `test/service_forms_e2e_test.dart` · **80 of 80 forms pass**

Each subcategory below was opened as its own form on a 375 px phone (category fixed, no dropdown to change it), walked through all six steps (Basics, How it is booked, Where and who, Price, What it uses, Notes and confirm), filled in and published. For each one the test checked that nothing spills off the screen, that only fields relevant to that subcategory show, that the dropdowns offer that subcategory’s options, and what reaches the server.

## Bugs found and fixed during this run

1. **A new subcategory kept the last one’s settings.** Picking *Museum visit* kept “Slot” booking instead of ticketed “Entry”; picking *Plumbing* kept “At your place”, so it was saved as an in-shop appointment instead of a job at the customer’s place. A subcategory now always starts from its own defaults.
2. **Fields that didn’t fit the subcategory** (fixed before the run): a swimming lane or snooker table asked for a turf or court surface; museum and park visits asked which court or turf customers book; Events, Service and Stay showed the sports amenity list (flood lights, ball boy). Each subcategory now has its own profile.
3. **The category could be changed inside a form.** It is now fixed once picked. Only a service saved before the categories, or a template without one, shows the five tiles once.


## Events (9)

| Subcategory | Booked as | Customers book | Surface | Parts | Where | Pricing basis (first is default) | Who-can-come rules | Saved as | Result |
|---|---|---|---|---|---|---|---|---|---|
| Stand-up comedy | Entry | - | - | - | At your place/Both/On call | Per person/Per entry/Per group/By type/No charge to book | age+gender | ticketed event | ✅ pass |
| Live music | Entry | - | - | - | At your place/Both/On call | Per person/Per entry/Per group/By type/No charge to book | age+gender | ticketed event | ✅ pass |
| Workshop | Entry | - | - | - | At your place/Both/On call | Per person/Per entry/Per group/By type/No charge to book | age+gender | ticketed event | ✅ pass |
| Screening | Entry | - | - | - | At your place/Both/On call | Per person/Per entry/Per group/By type/No charge to book | age+gender | ticketed event | ✅ pass |
| Exhibition | Entry | - | - | - | At your place/Both/On call | Per person/Per entry/Per group/By type/No charge to book | age+gender | ticketed event | ✅ pass |
| Kids party venue | Slot | Hall | - | - | at the venue | Per slot/Per person/By type | - | ticketed event | ✅ pass |
| Party hall and banquet | Slot | Hall | - | - | at the venue | Per slot/Per person/By type | - | ticketed event | ✅ pass |
| Event planning | Slot | - | - | - | On call/Both/At your place | By type/Per booking/Per hour | - | ticketed event | ✅ pass |
| Event decoration | Slot | - | - | - | On call/Both/At your place | By type/Per booking/Per hour | - | ticketed event | ✅ pass |

## Activities (11)

| Subcategory | Booked as | Customers book | Surface | Parts | Where | Pricing basis (first is default) | Who-can-come rules | Saved as | Result |
|---|---|---|---|---|---|---|---|---|---|
| Gaming zone and arcade | Slot/Entry | Station | - | - | at the venue | Per person/Per slot/By type | age+gender | at your place | ✅ pass |
| Bowling | Slot | Lane | - | - | at the venue | Per slot/Per person/Per group | age+gender | at your place | ✅ pass |
| Escape room | Slot | Room | - | - | at the venue | Per group/Per person | age+gender | at your place | ✅ pass |
| VR gaming | Slot/Entry | Station | - | - | at the venue | Per person/Per slot/By type | age+gender | at your place | ✅ pass |
| Trampoline park | Slot/Entry | Zone | - | - | at the venue | Per person/By type | age+gender+safety | at your place | ✅ pass |
| Go-karting | Slot | Kart | - | - | at the venue | Per person/By type | age+gender+safety | at your place | ✅ pass |
| Paintball | Slot | Arena | - | - | at the venue | Per person/Per group | age+gender+safety | at your place | ✅ pass |
| Museum visit | Entry/Slot | - | - | - | at the venue | Per person/By type/Per group | age+gender+safety | ticketed event | ✅ pass |
| Farm and nature visit | Entry/Slot | - | - | - | at the venue | Per person/By type/Per group | age+gender+safety | ticketed event | ✅ pass |
| Amusement and water park | Entry/Slot | - | - | - | at the venue | Per person/By type/Per group | age+gender+safety | ticketed event | ✅ pass |
| Guided tour | Slot/Entry | - | - | - | At your place/Both/On call | Per person/Per group/By type | age+gender | at your place | ✅ pass |

## Play (13)

| Subcategory | Booked as | Customers book | Surface | Parts | Where | Pricing basis (first is default) | Who-can-come rules | Saved as | Result |
|---|---|---|---|---|---|---|---|---|---|
| Football turf | Slot/Entry | Turf | Artificial turf/Natural grass | yes | at the venue | Per slot/Per hour/Per person/By type | gender+safety | at your place | ✅ pass |
| Box cricket | Slot/Entry | Box | Artificial turf/Cement/Mat | yes | at the venue | Per slot/Per hour/By type | gender+safety | at your place | ✅ pass |
| Cricket nets | Slot | Net | Artificial turf/Cement/Mat/Natural grass | - | at the venue | Per slot/Per hour/Per person | gender+safety | at your place | ✅ pass |
| Basketball court | Slot/Entry | Court | Wooden/Hard court/Synthetic | yes | at the venue | Per slot/Per hour/Per person/By type | gender+safety | at your place | ✅ pass |
| Badminton court | Slot/Entry | Court | Wooden/Synthetic/Wooden + Synthetic/Cement | yes | at the venue | Per slot/Per hour/Per person/By type | gender+safety | at your place | ✅ pass |
| Tennis court | Slot/Entry | Court | Hard court/Clay/Natural grass/Synthetic | yes | at the venue | Per slot/Per hour/Per person/By type | gender+safety | at your place | ✅ pass |
| Pickleball court | Slot/Entry | Court | Hard court/Synthetic | yes | at the venue | Per slot/Per hour/Per person/By type | gender+safety | at your place | ✅ pass |
| Volleyball court | Slot/Entry | Court | Sand/Synthetic/Wooden/Hard court | yes | at the venue | Per slot/Per hour/Per person/By type | gender+safety | at your place | ✅ pass |
| Squash court | Slot/Entry | Court | Wooden | yes | at the venue | Per slot/Per hour/Per person/By type | gender+safety | at your place | ✅ pass |
| Table tennis table | Slot | Table | - | - | at the venue | Per hour/Per slot/Per person | gender | at your place | ✅ pass |
| Snooker and pool table | Slot | Table | - | - | at the venue | Per hour/Per slot/Per person | gender | at your place | ✅ pass |
| Swimming lane | Slot/Entry | Lane | - | - | at the venue | Per person/Per slot/Per hour | gender+safety | at your place | ✅ pass |
| Indoor arena | Slot/Entry | Arena | Synthetic/Wooden/Artificial turf | yes | at the venue | Per slot/Per hour/By type | gender+safety | at your place | ✅ pass |

## Service (39)

| Subcategory | Booked as | Customers book | Surface | Parts | Where | Pricing basis (first is default) | Who-can-come rules | Saved as | Result |
|---|---|---|---|---|---|---|---|---|---|
| General physician | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |
| Dentist | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |
| Orthodontist | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |
| Paediatrician | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |
| Dermatologist | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |
| Gynaecologist | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |
| Eye specialist | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |
| Physiotherapist | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |
| Dietitian | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |
| Garage service appointment | Slot | - | - | - | On call/Both/At your place | By type/Per booking | - | at the customer’s place | ✅ pass |
| Puncture repair | Slot | - | - | - | On call/Both/At your place | By type/Per booking | - | at the customer’s place | ✅ pass |
| Battery jump-start | Slot | - | - | - | On call/Both/At your place | By type/Per booking | - | at the customer’s place | ✅ pass |
| Roadside assistance | Slot | - | - | - | On call/Both/At your place | By type/Per booking | - | at the customer’s place | ✅ pass |
| Towing | Slot | - | - | - | On call/Both/At your place | By type/Per booking | - | at the customer’s place | ✅ pass |
| Men's salon | Slot | - | - | - | At your place/Both/On call | By type/Per booking/Per person | gender | at your place | ✅ pass |
| Women's salon | Slot | - | - | - | At your place/Both/On call | By type/Per booking/Per person | gender | at your place | ✅ pass |
| Unisex salon | Slot | - | - | - | At your place/Both/On call | By type/Per booking/Per person | gender | at your place | ✅ pass |
| Beauty parlour | Slot | - | - | - | At your place/Both/On call | By type/Per booking/Per person | gender | at your place | ✅ pass |
| Spa | Slot | - | - | - | At your place/Both/On call | By type/Per booking/Per person | gender | at your place | ✅ pass |
| Makeup artist | Slot | - | - | - | Both/At your place/On call | By type/Per person/Per hour | gender | at your place | ✅ pass |
| Mehendi artist | Slot | - | - | - | Both/At your place/On call | By type/Per person/Per hour | gender | at your place | ✅ pass |
| CA and tax | Slot | - | - | - | Both/At your place/On call | Per hour/By type/Per booking | - | at your place | ✅ pass |
| Lawyer | Slot | - | - | - | Both/At your place/On call | Per hour/By type/Per booking | - | at your place | ✅ pass |
| Counsellor | Slot | - | - | - | Both/At your place/On call | Per hour/By type/Per booking | - | at your place | ✅ pass |
| Digital solutions | Slot | - | - | - | Both/At your place/On call | Per hour/By type/Per booking | - | at your place | ✅ pass |
| Financial advisor | Slot | - | - | - | Both/At your place/On call | Per hour/By type/Per booking | - | at your place | ✅ pass |
| Architect and interior | Slot | - | - | - | Both/At your place/On call | Per hour/By type/Per booking | - | at your place | ✅ pass |
| Cleaning | Slot | - | - | - | On call/Both/At your place | By type/Per booking/Per hour | - | at the customer’s place | ✅ pass |
| Plumbing | Slot | - | - | - | On call/Both/At your place | By type/Per booking/Per hour | - | at the customer’s place | ✅ pass |
| Electrical | Slot | - | - | - | On call/Both/At your place | By type/Per booking/Per hour | - | at the customer’s place | ✅ pass |
| Appliance and AC repair | Slot | - | - | - | On call/Both/At your place | By type/Per booking/Per hour | - | at the customer’s place | ✅ pass |
| Pest control | Slot | - | - | - | On call/Both/At your place | By type/Per booking/Per hour | - | at the customer’s place | ✅ pass |
| Carpentry | Slot | - | - | - | On call/Both/At your place | By type/Per booking/Per hour | - | at the customer’s place | ✅ pass |
| Painting | Slot | - | - | - | On call/Both/At your place | By type/Per booking/Per hour | - | at the customer’s place | ✅ pass |
| Pet grooming | Slot | - | - | - | Both/At your place/On call | By type/Per booking/Per hour | gender | at your place | ✅ pass |
| Fitness trainer | Slot | - | - | - | Both/At your place/On call | By type/Per booking/Per hour | gender | at your place | ✅ pass |
| Yoga | Slot | - | - | - | Both/At your place/On call | By type/Per booking/Per hour | gender | at your place | ✅ pass |
| Massage | Slot | - | - | - | Both/At your place/On call | By type/Per booking/Per hour | gender | at your place | ✅ pass |
| Printing | Slot | - | - | - | At your place/Both/On call | By type/Per booking | - | at your place | ✅ pass |

## Stay (8)

| Subcategory | Booked as | Customers book | Surface | Parts | Where | Pricing basis (first is default) | Who-can-come rules | Saved as | Result |
|---|---|---|---|---|---|---|---|---|---|
| Hotel | Nights | - | - | - | at the venue | Per night/By type | age | at your place | ✅ pass |
| Bed and breakfast | Nights | - | - | - | at the venue | Per night/By type | age | at your place | ✅ pass |
| Homestay | Nights | - | - | - | at the venue | Per night/By type | age | at your place | ✅ pass |
| Guest house | Nights | - | - | - | at the venue | Per night/By type | age | at your place | ✅ pass |
| Resort | Nights | - | - | - | at the venue | Per night/By type | age | at your place | ✅ pass |
| Farmhouse | Nights | - | - | - | at the venue | Per night/By type | age | at your place | ✅ pass |
| Hostel and dormitory | Nights | - | - | - | at the venue | Per night/By type | age+gender | at your place | ✅ pass |
| Day-use room | Slot | - | - | - | at the venue | Per hour/Per slot | age | at your place | ✅ pass |

## What this does not cover

- **Real device and browser:** these are automated widget tests at phone size. The in-app browser was not drawing the app during this session, so no forms were checked by eye.
- **Bookings using the answers:** the forms save every answer, but booking and checkout don’t act on most of them yet (price rules, who-can-come rules, age and gender limits, units, time bands, peak price). That is the next piece of work.
- **Tool and material suggestions per subcategory** (football turf → ball, bibs) are not built.
- **Hosted database:** the no-Dining SQL (`C:onelocalhosted_service_no_dining_2026-11-04.sql`) has not been run on hosted yet.

## Whole suite

All service, shell and storefront tests: 286 passed. Server: 120 passed, 1 failed (the guest web page test, failing before this work and unrelated).
