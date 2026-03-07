# Restaurant Scout Knowledge Base
#
# Format:
#   [restaurant:{Name}|{City}]  Platform: X | Slug: X | City: X | DeepLink: X | Phone: X | Notes: X | LastChecked: YYYY-MM-DD
#   [pattern:{platform}]        Detection rules and URL patterns
#   [city:{city}]               Resy city code mapping
#
# {DATE} and {PARTY} are placeholders replaced by the deep link builder at query time.
# Scout READS this file before every search and WRITES to it after every search.

## Platform Detection Patterns

[pattern:resy] Detect in HTML: "resy.com" OR "ResyWidget" OR "resy-widget" OR "ResyButton" OR "cdn.resy.com". Detect in search snippets: "Book on Resy" OR "Reserve on Resy" OR "resy.com/cities/". Common at: trendy/buzzy restaurants in NYC, LA, Miami, SF, Chicago, London. Deep link format: https://resy.com/cities/{city}/venues/{slug}?date={YYYY-MM-DD}&party_size={n}. Find slug in any resy.com URL after /venues/.

[pattern:opentable] Detect in HTML: "opentable.com" OR "ot-widget" OR "OTFlickWidget" OR "otWidgetTargetId" OR "opentable-widget". Detect in search snippets: "Reserve on OpenTable" OR "Book on OpenTable" OR "opentable.com/r/". Most common platform overall — mainstream restaurants, hotel dining, chains. Deep link format: https://www.opentable.com/r/{slug}?covers={n}&dateTime={YYYY-MM-DD}T{HH:MM}:00. Find slug in any opentable.com/r/{slug} URL.

[pattern:tock] Detect in HTML: "exploretock.com" OR "tock-embed" OR "TockWidget" OR "assets.tock.com". Detect in search snippets: "Book on Tock" OR "exploretock.com/". Common at: upscale tasting menu restaurants, ticketed dining experiences, prix fixe only spots. Deep link format: https://www.exploretock.com/{slug}?date={YYYY-MM-DD}&size={n}&time={HH%3AMM+AM%2FPM}. Find slug in any exploretock.com/{slug} URL.

[pattern:sevenrooms] Detect in HTML: "sevenrooms.com" OR "sr-res-widget" OR "SevenRoomsWidget" OR "cdn.sevenrooms.com". Detect in search snippets: "Reserve via SevenRooms" OR "sevenrooms.com/reservations/". Common at: hotel restaurants, luxury properties, private clubs, Las Vegas venues. Deep link format: https://www.sevenrooms.com/reservations/{slug}?date={YYYYMMDD}&party_size={n}. Find slug in any sevenrooms.com/reservations/{slug} URL.

[pattern:yelp] Detect in search snippets: "yelp.com/reservations" or Yelp showing reservation button. Common at: casual dining, chain restaurants. Deep link: https://www.yelp.com/reservations/{slug}?covers={n}&date={YYYY-MM-DD}&time={HH:MM}.

[pattern:reserve-with-google] Detect: "reserve.google.com" link in search results or Google's "Reserve a table" button. Use the exact URL Google provides — it handles its own pre-filling.

[pattern:direct] No third-party widget found on restaurant's homepage. Restaurant uses its own booking system. Look for /reservations, /book, /reserve, /dining-reservations in navigation. Use that URL directly.

[pattern:call-to-book] Signals: "Please call to reserve" OR "Reservations by phone only" OR no booking widget on page. Present phone number prominently with hours. No deep link possible.

[pattern:walk-in-only] Signals: "Walk-ins welcome" OR "No reservations accepted" OR "First come, first served". Note in response. Suggest smart arrival times (open + 30min, or late seating).

[pattern:resy-vs-opentable] Rule of thumb: If a NYC/LA/Miami restaurant is hot or newish (opened after 2018), lean toward Resy first in your search. If it's a classic/hotel/mainstream spot, lean OpenTable first. Many have both — search snippet usually clarifies.

## Resy City Codes

[city:new-york] Resy code: new-york-ny | Matches: NYC, New York, Manhattan, Brooklyn, Queens, Williamsburg, DUMBO, Astoria
[city:los-angeles] Resy code: los-angeles-ca | Matches: LA, West Hollywood, WeHo, Santa Monica, Venice, Culver City, Silver Lake, Los Feliz, Malibu, Beverly Hills
[city:miami] Resy code: miami-fl | Matches: Miami, South Beach, Brickell, Wynwood, Midtown Miami, Coconut Grove
[city:chicago] Resy code: chicago-il | Matches: Chicago, River North, West Loop, Lincoln Park, Logan Square
[city:san-francisco] Resy code: san-francisco-ca | Matches: SF, San Francisco, SoMa, Mission, Hayes Valley, Marina, Nob Hill
[city:las-vegas] Resy code: las-vegas-nv | Matches: Las Vegas, The Strip, Henderson
[city:washington-dc] Resy code: washington-dc | Matches: DC, Washington, Georgetown, Dupont Circle, Shaw, H Street
[city:boston] Resy code: boston-ma | Matches: Boston, Back Bay, South End, Cambridge, Fenway
[city:seattle] Resy code: seattle-wa | Matches: Seattle, Capitol Hill, Belltown, South Lake Union
[city:austin] Resy code: austin-tx | Matches: Austin, South Congress, East Austin, Downtown Austin
[city:denver] Resy code: denver-co | Matches: Denver, LoDo, RiNo, Cherry Creek
[city:atlanta] Resy code: atlanta-ga | Matches: Atlanta, Buckhead, Midtown Atlanta, Inman Park, Ponce City Market
[city:philadelphia] Resy code: philadelphia-pa | Matches: Philadelphia, Philly, Center City, Fishtown
[city:houston] Resy code: houston-tx | Matches: Houston, Montrose, River Oaks, Midtown Houston
[city:dallas] Resy code: dallas-tx | Matches: Dallas, Uptown Dallas, Deep Ellum, Bishop Arts
[city:nashville] Resy code: nashville-tn | Matches: Nashville, 12 South, East Nashville, Gulch
[city:portland-or] Resy code: portland-or | Matches: Portland OR, NW Portland, SE Portland, Pearl District
[city:new-orleans] Resy code: new-orleans-la | Matches: New Orleans, NOLA, French Quarter, Garden District
[city:minneapolis] Resy code: minneapolis-mn | Matches: Minneapolis, North Loop
[city:scottsdale] Resy code: scottsdale-az | Matches: Scottsdale, Old Town Scottsdale, Paradise Valley
[city:charleston] Resy code: charleston-sc | Matches: Charleston SC, Downtown Charleston
[city:london] Resy code: london-uk | Matches: London, Mayfair, Soho, Shoreditch, Chelsea, Notting Hill
[city:paris] Resy code: paris-fr | Matches: Paris
[city:toronto] Resy code: toronto-on | Matches: Toronto, Yorkville, King West, Ossington
[city:montreal] Resy code: montreal-qc | Matches: Montreal, Mile End, Old Montreal
[city:barcelona] Resy code: barcelona-es | Matches: Barcelona
[city:amsterdam] Resy code: amsterdam-nl | Matches: Amsterdam

## Known Restaurants (Pre-Seeded)

[restaurant:Carbone|NYC] Platform: resy | Slug: carbone | City: new-york-ny | DeepLink: https://resy.com/cities/new-york-ny/venues/carbone?date=2026-02-21&party_size=2 | Phone: (212) 254-3000 | Notes: Slots drop Mon/Tue at 9am ET, 28 days out. Bar seating walk-in friendly. Lunch easier. Private dining for groups. | LastChecked: 2026-02-20
[restaurant:Don Angie|NYC] Platform: resy | Slug: don-angie | City: new-york-ny | Phone: (212) 889-8884 | Notes: Slots drop Sunday 9am ET, 28 days out. Counter seating sometimes available same-day on Resy app. | LastChecked: 2026-02-20
[restaurant:Via Carota|NYC] Platform: walk-in | Phone: (212) 255-1962 | Notes: No reservations. Arrive 5:30pm to beat the queue. Bar seating. Worth the wait. | LastChecked: 2026-02-20
[restaurant:Le Bernardin|NYC] Platform: opentable | Slug: le-bernardin-new-york | Phone: (212) 554-1515 | Notes: 3-Michelin star. Jacket required for dinner. Lunch prix fixe is better value. Easier to book than dinner. | LastChecked: 2026-02-20
[restaurant:Eleven Madison Park|NYC] Platform: tock | Slug: eleven-madison-park | Notes: Ticketed/prepaid. Plant-based tasting menu. Book well in advance — popular on weekends. | LastChecked: 2026-02-20
[restaurant:Alinea|Chicago] Platform: tock | Slug: alinea | Notes: Ticketed. Multiple rooms: Gallery (most flexible), Salon (prix fixe), Kitchen Table (chef's table). Book 3+ months out for weekends. | LastChecked: 2026-02-20
[restaurant:Nobu Malibu|Malibu] Platform: sevenrooms | Slug: nobu-malibu | Phone: (310) 317-9140 | Notes: Lunch walk-in often available. Bar and patio walk-in friendly. Sunset dinner slots most sought-after. | LastChecked: 2026-02-20
[restaurant:Nobu Downtown|NYC] Platform: sevenrooms | Slug: nobu-downtown | City: new-york-ny | Phone: (212) 431-0111 | Notes: Easier to book than Nobu 57. Bar walk-in usually available. | LastChecked: 2026-02-20
[restaurant:Nobu 57|NYC] Platform: sevenrooms | Slug: nobu-fifty-seven | City: new-york-ny | Phone: (212) 757-3000 | Notes: Classic location. Omakase requires advance booking. Regular dinner more available. | LastChecked: 2026-02-20
[restaurant:Rao's|NYC] Platform: call | Phone: (212) 722-6709 | Notes: No online reservations. Regulars own tables — effectively impossible for newcomers. Ask to be put on cancellation list. | LastChecked: 2026-02-20
[restaurant:L'Artusi|NYC] Platform: resy | Slug: lartusi | City: new-york-ny | DeepLink: https://resy.com/cities/new-york-ny/venues/lartusi?date=2026-02-20&party_size=2 | Phone: (212) 255-5757 | Notes: Great West Village Italian. Easier to book than Carbone/Don Angie. Bar walk-in often works. | LastChecked: 2026-02-20
[restaurant:Buvette|NYC] Platform: walk-in | Phone: (212) 255-3590 | Notes: No reservations. French-Italian bistro. Arrive before 6pm. Cozy and always worth it. | LastChecked: 2026-02-20
[restaurant:Odys and Penelope|LA] Platform: resy | Slug: odys-and-penelope | City: los-angeles-ca | Notes: Great LA BBQ/grill. Book a few days out on Resy. | LastChecked: 2026-02-20
[restaurant:Gjelina|LA] Platform: resy | Slug: gjelina | City: los-angeles-ca | Phone: (310) 450-1429 | Notes: Venice beach staple. Walk-in at bar usually works. Book for weekends. | LastChecked: 2026-02-20
[restaurant:n/naka|LA] Platform: tock | Slug: n-naka | Notes: 2-Michelin star omakase. Ticketed/prepaid. Very hard to get — book months out for weekends. | LastChecked: 2026-02-20
[restaurant:Lilia|NYC] Platform: resy | Slug: lilia | City: new-york-ny | DeepLink: https://resy.com/cities/new-york-ny/venues/lilia?date=2026-02-27&party_size=4 | Phone: (718) 576-3095 | Notes: Popular Williamsburg Italian from Chef Missy Robbins. Reservations on Resy; call between 10am-4pm if needed. | LastChecked: 2026-02-20
[restaurant:Atomix|NYC] Platform: tock | Slug: atomixnyc | City: new-york-ny | DeepLink: https://www.exploretock.com/atomixnyc?date=2026-02-21&size=4&time=7%3A30%20PM | Phone:  | Notes: Bar and tasting experiences; Tock shows sold-out notices often — try first-of-month drops and check search page for releases. | LastChecked: 2026-02-21
