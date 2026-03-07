#!/usr/bin/env python3
"""
build-deeplink.py — Generate pre-filled reservation deep links for major platforms.

Usage:
  python3 build-deeplink.py --platform resy --slug carbone --city new-york-ny --party 2 --date 2026-02-21 --time 19:30
  python3 build-deeplink.py --platform opentable --slug carbone-new-york --party 4 --date 2026-02-21 --time 20:00
  python3 build-deeplink.py --platform tock --slug alinea --party 2 --date 2026-02-21 --time 18:00
  python3 build-deeplink.py --platform sevenrooms --slug nobu-malibu --party 2
  python3 build-deeplink.py --platform direct --url https://restaurant.com/reservations

Outputs:
  Line 1: Deep link URL
  Line 2: Human-readable label (e.g. "Book on Resy for 2 · Feb 21 · 7:30 PM")
"""

import sys
import argparse
import urllib.parse
from datetime import datetime, timedelta


def tomorrow():
    return (datetime.now() + timedelta(days=1)).strftime("%Y-%m-%d")


def to_ampm(time_24h):
    """Convert '19:30' → '7:30 PM'"""
    try:
        h, m = map(int, time_24h.split(":"))
        suffix = "AM" if h < 12 else "PM"
        h12 = h % 12 or 12
        return f"{h12}:{m:02d} {suffix}"
    except Exception:
        return time_24h


def format_display_date(date_str):
    """Convert '2026-02-21' → 'Feb 21'"""
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d")
        return dt.strftime("%b %-d")
    except Exception:
        return date_str


def build_opentable(slug, party, date, time):
    dt = f"{date}T{time}:00"
    url = f"https://www.opentable.com/r/{slug}?covers={party}&dateTime={urllib.parse.quote(dt)}"
    return url


def build_resy(slug, city, party, date):
    url = f"https://resy.com/cities/{city}/venues/{slug}?date={date}&party_size={party}"
    return url


def build_tock(slug, party, date, time):
    ampm = to_ampm(time)
    url = f"https://www.exploretock.com/{slug}?date={date}&size={party}&time={urllib.parse.quote(ampm)}"
    return url


def build_sevenrooms(slug, party, date):
    compact_date = date.replace("-", "")
    url = f"https://www.sevenrooms.com/reservations/{slug}?date={compact_date}&party_size={party}"
    return url


def build_yelp(slug, party, date, time):
    url = f"https://www.yelp.com/reservations/{slug}?covers={party}&date={date}&time={time}"
    return url


def main():
    p = argparse.ArgumentParser(description="Build reservation deep links")
    p.add_argument("--platform", required=True,
                   choices=["opentable", "resy", "tock", "sevenrooms", "yelp", "direct"])
    p.add_argument("--slug",   default="", help="Restaurant slug on the platform")
    p.add_argument("--city",   default="new-york-ny", help="City slug (Resy: e.g. new-york-ny)")
    p.add_argument("--party",  type=int, default=2, help="Party size")
    p.add_argument("--date",   default="", help="YYYY-MM-DD (default: tomorrow)")
    p.add_argument("--time",   default="19:30", help="HH:MM 24h (default: 19:30)")
    p.add_argument("--url",    default="", help="Full URL for platform=direct")
    args = p.parse_args()

    date = args.date or tomorrow()
    time = args.time or "19:30"
    party = args.party
    slug = args.slug
    platform = args.platform

    if platform == "opentable":
        if not slug:
            print("ERROR: --slug required for opentable", file=sys.stderr); sys.exit(1)
        link = build_opentable(slug, party, date, time)
        label = f"Book on OpenTable · {party} guests · {format_display_date(date)} · {to_ampm(time)}"

    elif platform == "resy":
        if not slug:
            print("ERROR: --slug required for resy", file=sys.stderr); sys.exit(1)
        link = build_resy(slug, args.city, party, date)
        label = f"Book on Resy · {party} guests · {format_display_date(date)}"

    elif platform == "tock":
        if not slug:
            print("ERROR: --slug required for tock", file=sys.stderr); sys.exit(1)
        link = build_tock(slug, party, date, time)
        label = f"Book on Tock · {party} guests · {format_display_date(date)} · {to_ampm(time)}"

    elif platform == "sevenrooms":
        if not slug:
            print("ERROR: --slug required for sevenrooms", file=sys.stderr); sys.exit(1)
        link = build_sevenrooms(slug, party, date)
        label = f"Book via SevenRooms · {party} guests · {format_display_date(date)}"

    elif platform == "yelp":
        if not slug:
            print("ERROR: --slug required for yelp", file=sys.stderr); sys.exit(1)
        link = build_yelp(slug, party, date, time)
        label = f"Book on Yelp · {party} guests · {format_display_date(date)} · {to_ampm(time)}"

    elif platform == "direct":
        link = args.url or f"https://{slug}"
        label = f"Book directly · {party} guests · {format_display_date(date)} · {to_ampm(time)}"

    else:
        print(f"ERROR: unknown platform '{platform}'", file=sys.stderr)
        sys.exit(1)

    print(link)
    print(label)


if __name__ == "__main__":
    main()
