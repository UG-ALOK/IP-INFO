#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IP INFORMATION GATHERING
Developer: UG ALOK
========================
A terminal tool for Android Termux (and any Python 3.8+ system) with two options:

  1. IP Show - local and public IPv4 / IPv6 addresses
  2. IP Info - classification, reverse DNS and, for public addresses,
               approximate geolocation details

Design notes
  * Python standard library only - no third-party dependencies.
  * Nothing is written to disk: no reports, logs, caches or config files.
  * All network requests use HTTPS with finite timeouts.
  * A readable color theme is picked at random for every report.
  * For educational purposes and legitimate network diagnostics only.
"""

from __future__ import annotations

import errno
import ipaddress
import json
import math
import os
import random
import re
import shutil
import socket
import ssl
import sys
import textwrap
import threading
import urllib.error
import urllib.parse
import urllib.request

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

TOOL_NAME = "IP INFORMATION GATHERING"
DEVELOPER = "UG ALOK"
VERSION = "1.1.0"

NOT_AVAILABLE = "Not available"
HTTP_TIMEOUT = 8            # seconds, per request
PARALLEL_TIMEOUT = 15       # seconds, upper bound when waiting for a worker
MAX_RESPONSE_BYTES = 256 * 1024
USER_AGENT = "IP-Information-Gathering/%s (stdlib urllib)" % VERSION

V4_ENDPOINTS = ("https://api4.ipify.org", "https://ipv4.icanhazip.com")
V6_ENDPOINTS = ("https://api6.ipify.org", "https://ipv6.icanhazip.com")
GEO_ENDPOINT = "https://ipwho.is/"

LABEL_WIDTH = 17            # width of the longest label: "Globally Routable"
MAX_INNER_WIDTH = 50        # inner width of the boxes on wide terminals
MIN_INNER_WIDTH = 30
STACK_BELOW = 44            # narrower than this: label above value


# --------------------------------------------------------------------------- #
# Theme and box drawing
# --------------------------------------------------------------------------- #

# Each theme: (accent = bright, high-contrast; label = secondary tone).
THEMES = {
    "green":   ("92", "32"),
    "cyan":    ("96", "36"),
    "yellow":  ("93", "33"),
    "blue":    ("38;5;117", "38;5;75"),
    "magenta": ("95", "35"),
}


class Theme:
    """ANSI styling with a random per-report color theme and plain fallback."""

    FIXED = {
        "bold": "1",
        "white": "97",              # normal text
        "gray": "38;5;246",         # secondary info (kept readable)
        "red": "91",                # errors
        "yellow": "93",             # warnings
    }

    def __init__(self) -> None:
        forced = bool(os.environ.get("FORCE_COLOR"))
        try:
            is_tty = sys.stdout.isatty()
        except (AttributeError, ValueError):
            is_tty = False
        self.color = forced or (
            is_tty
            and "NO_COLOR" not in os.environ
            and os.environ.get("TERM", "") != "dumb"
        )
        encoding = (getattr(sys.stdout, "encoding", None) or "").lower()
        self.unicode = "utf" in encoding
        self.interactive = is_tty
        self.name = None
        self.accent = self.label = ""
        self.reroll()

    def reroll(self) -> None:
        """Pick a new random theme (never the same one twice in a row)."""
        choices = [name for name in THEMES if name != self.name]
        self.name = random.choice(choices)
        self.accent, self.label = THEMES[self.name]

    def _code(self, style: str) -> str:
        if style == "accent":
            return self.accent
        if style == "label":
            return self.label
        return self.FIXED[style]

    def paint(self, text: str, *styles: str) -> str:
        if not self.color or not styles or not text:
            return text
        codes = ";".join(self._code(s) for s in styles)
        return "\033[%sm%s\033[0m" % (codes, text)


_UNICODE_GLYPHS = {"tl": "╔", "tr": "╗", "bl": "╚", "br": "╝",
                   "h": "═", "v": "║", "ml": "╠", "mr": "╣"}
_ASCII_GLYPHS = {"tl": "+", "tr": "+", "bl": "+", "br": "+",
                 "h": "-", "v": "|", "ml": "+", "mr": "+"}


class Box:
    """Builds an aligned, width-aware report box. Call render() to get text."""

    def __init__(self, theme: Theme) -> None:
        self.t = theme
        columns = shutil.get_terminal_size((MAX_INNER_WIDTH + 2, 24)).columns
        self.inner = max(MIN_INNER_WIDTH, min(MAX_INNER_WIDTH, columns - 2))
        self.cw = self.inner - 2                   # usable content width
        self.g = _UNICODE_GLYPHS if theme.unicode else _ASCII_GLYPHS
        self.stacked = self.inner < STACK_BELOW
        self.lines = []

    # -- structure ---------------------------------------------------------- #

    def _border(self, left: str, right: str) -> str:
        return self.t.paint(left + self.g["h"] * self.inner + right, "label")

    def top(self) -> None:
        self.lines.append(self._border(self.g["tl"], self.g["tr"]))

    def mid(self) -> None:
        self.lines.append(self._border(self.g["ml"], self.g["mr"]))

    def bottom(self) -> None:
        self.lines.append(self._border(self.g["bl"], self.g["br"]))

    def _row(self, segments) -> None:
        plain_len = sum(len(text) for text, _ in segments)
        pad = " " * max(0, self.cw - plain_len)
        body = "".join(self.t.paint(text, *style) for text, style in segments)
        edge = self.t.paint(self.g["v"], "label")
        self.lines.append("%s %s%s %s" % (edge, body, pad, edge))

    @staticmethod
    def _wrap(text: str, width: int):
        width = max(4, width)
        return textwrap.wrap(text, width, break_long_words=True,
                             break_on_hyphens=False) or [""]

    # -- content ------------------------------------------------------------ #

    def title(self, text: str, style=("bold", "accent")) -> None:
        text = text[: self.cw]
        left = (self.cw - len(text)) // 2
        self._row([(" " * left, ()), (text, style)])

    def center(self, segments) -> None:
        plain = sum(len(text) for text, _ in segments)
        left = max(0, (self.cw - plain) // 2)
        self._row([(" " * left, ())] + list(segments))

    def blank(self) -> None:
        self._row([("", ())])

    def section(self, text: str) -> None:
        self._row([(text.upper()[: self.cw], ("bold", "accent"))])

    def text(self, text: str, style=("white",)) -> None:
        for chunk in self._wrap(text, self.cw):
            self._row([(chunk, style)])

    def field(self, label: str, value, style=None) -> None:
        value = NOT_AVAILABLE if value in (None, "") else str(value)
        if style is None:
            style = ("gray",) if value.startswith(NOT_AVAILABLE) else ("accent",)
        if self.stacked:
            self._row([(label, ("label",))])
            for chunk in self._wrap(value, self.cw - 2):
                self._row([("  ", ()), (chunk, style)])
            return
        value_width = self.cw - LABEL_WIDTH - 3
        for index, chunk in enumerate(self._wrap(value, value_width)):
            if index == 0:
                self._row([(label.ljust(LABEL_WIDTH), ("label",)),
                           (" : ", ("gray",)), (chunk, style)])
            else:
                self._row([(" " * (LABEL_WIDTH + 3), ()), (chunk, style)])

    def render(self) -> str:
        return "\n".join(self.lines)


# --------------------------------------------------------------------------- #
# Network helpers (standard library only)
# --------------------------------------------------------------------------- #

class FetchError(Exception):
    """A categorised network failure with a human-readable message."""

    HUMAN = {
        "no_route": "no network route",
        "dns": "DNS lookup failed",
        "timeout": "request timed out",
        "http": "service returned an error",
        "tls": "TLS/certificate error",
        "invalid": "malformed response",
        "api": "provider rejected the request",
        "failed": "request failed",
    }

    def __init__(self, kind: str, detail: str = "") -> None:
        super().__init__(detail or self.HUMAN.get(kind, "request failed"))
        self.kind = kind


_NO_ROUTE_ERRNOS = {
    getattr(errno, name)
    for name in ("ENETUNREACH", "EHOSTUNREACH", "EADDRNOTAVAIL",
                 "EAFNOSUPPORT", "ENETDOWN")
    if hasattr(errno, name)
}


def _classify_exception(exc) -> FetchError:
    if isinstance(exc, (socket.timeout, TimeoutError)):
        return FetchError("timeout")
    if isinstance(exc, socket.gaierror):
        return FetchError("dns")
    if isinstance(exc, ssl.SSLError):
        return FetchError("tls")
    if isinstance(exc, OSError) and exc.errno in _NO_ROUTE_ERRNOS:
        return FetchError("no_route")
    return FetchError("failed")


def http_get(url: str) -> bytes:
    """HTTPS GET with a finite timeout and a response-size cap."""
    if not url.lower().startswith("https://"):
        raise FetchError("failed", "refusing non-HTTPS URL")
    request = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT,
                      "Accept": "application/json, text/plain"})
    context = ssl.create_default_context()
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT,
                                    context=context) as response:
            data = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise FetchError("http", "HTTP %s from provider" % exc.code)
    except urllib.error.URLError as exc:
        raise _classify_exception(exc.reason)
    except (OSError, ValueError) as exc:
        raise _classify_exception(exc)
    except Exception:                     # http.client errors and similar
        raise FetchError("failed")
    if len(data) > MAX_RESPONSE_BYTES:
        raise FetchError("invalid", "response too large")
    return data


def run_parallel(*funcs):
    """Run callables in daemon threads. Returns results (None on failure)."""
    results = [None] * len(funcs)

    def runner(index, func):
        try:
            results[index] = func()
        except Exception as exc:          # never let a worker crash the app
            results[index] = exc

    threads = [threading.Thread(target=runner, args=(i, f), daemon=True)
               for i, f in enumerate(funcs)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(PARALLEL_TIMEOUT)
    return results


def detect_local_ip(version: int):
    """Return this device's outbound-interface address, or None.

    A UDP socket is "connected" to a well-known address purely to let the OS
    pick the outbound interface. No packet is transmitted.
    """
    if version == 4:
        family, target = socket.AF_INET, "8.8.8.8"
    else:
        family, target = socket.AF_INET6, "2001:4860:4860::8888"
    try:
        with socket.socket(family, socket.SOCK_DGRAM) as sock:
            sock.settimeout(2.0)
            sock.connect((target, 53))
            address = sock.getsockname()[0]
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except (OSError, ValueError):
        return None
    if ip.version != version or ip.is_unspecified or ip.is_loopback:
        return None
    return str(ip)


def fetch_public_ip(version: int):
    """Return (address, status). status is 'ok' or a FetchError kind."""
    endpoints = V4_ENDPOINTS if version == 4 else V6_ENDPOINTS
    last = "failed"
    for url in endpoints:
        try:
            text = http_get(url).decode("ascii").strip()
            address = ipaddress.ip_address(text)
        except FetchError as exc:
            last = exc.kind
            continue
        except (ValueError, UnicodeDecodeError):
            last = "invalid"
            continue
        if address.version != version:
            last = "invalid"
            continue
        return str(address), "ok"
    return None, last


def reverse_dns(ip_text: str):
    """Return a PTR hostname or None. Bounded by run_parallel()'s timeout."""
    try:
        name = socket.gethostbyaddr(ip_text.split("%", 1)[0])[0]
    except (OSError, UnicodeError):
        return None
    return sanitize(name)


# --------------------------------------------------------------------------- #
# IP classification
# --------------------------------------------------------------------------- #

_SPECIAL_RANGES = [
    ("0.0.0.0/8", "This network", "special"),
    ("10.0.0.0/8", "Private (RFC 1918)", "private"),
    ("100.64.0.0/10", "Shared address space / CGNAT", "special"),
    ("127.0.0.0/8", "Loopback", "loopback"),
    ("169.254.0.0/16", "Link-local (APIPA)", "link-local"),
    ("172.16.0.0/12", "Private (RFC 1918)", "private"),
    ("192.0.0.0/24", "IETF protocol assignments", "special"),
    ("192.0.2.0/24", "Documentation (TEST-NET-1)", "special"),
    ("192.88.99.0/24", "6to4 relay anycast (deprecated)", "special"),
    ("192.168.0.0/16", "Private (RFC 1918)", "private"),
    ("198.18.0.0/15", "Benchmarking", "special"),
    ("198.51.100.0/24", "Documentation (TEST-NET-2)", "special"),
    ("203.0.113.0/24", "Documentation (TEST-NET-3)", "special"),
    ("224.0.0.0/4", "Multicast", "multicast"),
    ("240.0.0.0/4", "Reserved (future use)", "special"),
    ("255.255.255.255/32", "Limited broadcast", "special"),
    ("::/128", "Unspecified", "special"),
    ("::1/128", "Loopback", "loopback"),
    ("::ffff:0:0/96", "IPv4-mapped IPv6", "mapped"),
    ("64:ff9b::/96", "NAT64 translation", "special"),
    ("100::/64", "Discard-only", "special"),
    ("2001::/32", "Teredo tunneling", "special"),
    ("2001:db8::/32", "Documentation", "special"),
    ("2002::/16", "6to4 transition", "special"),
    ("fc00::/7", "Unique local (ULA, private)", "private"),
    ("fe80::/10", "Link-local", "link-local"),
    ("fec0::/10", "Site-local (deprecated)", "special"),
    ("ff00::/8", "Multicast", "multicast"),
]
_SPECIAL_NETS = [(ipaddress.ip_network(n), label, kind)
                 for n, label, kind in _SPECIAL_RANGES]
_GLOBAL_UNICAST_V6 = ipaddress.ip_network("2000::/3")


def classify(ip) -> dict:
    """Classify an ipaddress object accurately, including special-use blocks."""
    best = None
    for net, label, kind in _SPECIAL_NETS:
        if net.version == ip.version and ip in net:
            if best is None or net.prefixlen > best[0].prefixlen:
                best = (net, label, kind)

    if ip.version == 6 and ip.ipv4_mapped is not None:
        inner = dict(classify(ip.ipv4_mapped))
        inner["label"] = "IPv4-mapped (%s)" % inner["label"]
        inner["range"] = str(best[0]) if best else None
        inner["lookup_ip"] = ip.ipv4_mapped
        inner["mapped"] = True
        return inner

    result = {"label": "", "range": None, "private": False, "global": False,
              "loopback": ip.is_loopback, "link_local": ip.is_link_local,
              "multicast": ip.is_multicast, "lookup_ip": ip, "mapped": False}
    if best:
        net, label, kind = best
        result.update(label=label, range=str(net),
                      private=(kind == "private"),
                      loopback=result["loopback"] or kind == "loopback",
                      link_local=result["link_local"] or kind == "link-local",
                      multicast=result["multicast"] or kind == "multicast")
    elif ip.version == 6 and ip not in _GLOBAL_UNICAST_V6:
        result["label"] = "Reserved (outside 2000::/3)"
    elif ip.is_global:
        result.update(label="Public", **{"global": True})
    else:
        result["label"] = "Reserved / non-global"
    return result


def parse_ip(raw: str):
    """Validate user input with the ipaddress module. Raises ValueError."""
    text = raw.strip()
    if not text or len(text) > 64 or any(ord(ch) < 32 for ch in text):
        raise ValueError("empty or unsafe input")
    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1]
    if "%" in text:                                  # optional IPv6 zone id
        text, zone = text.split("%", 1)
        if ":" not in text or not re.fullmatch(r"[A-Za-z0-9._-]{1,32}", zone):
            raise ValueError("bad zone id")
    return ipaddress.ip_address(text)


# --------------------------------------------------------------------------- #
# Geolocation (public addresses only)
# --------------------------------------------------------------------------- #

def sanitize(value, limit: int = 120):
    """Return clean printable text, or None for missing/placeholder values."""
    if value is None or isinstance(value, (bool, dict, list)):
        return None
    text = "".join(ch for ch in str(value) if ch.isprintable()).strip()
    if not text or text.lower() in {"none", "null", "nan", "n/a", "unknown"}:
        return None
    return text[:limit]


def _as_float(value):
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def parse_geo(data) -> dict:
    """Turn a provider JSON document into display-ready values."""
    if not isinstance(data, dict):
        raise FetchError("invalid")
    if data.get("success") is False:
        raise FetchError("api", sanitize(data.get("message"), 80)
                         or FetchError.HUMAN["api"])

    connection = data.get("connection")
    connection = connection if isinstance(connection, dict) else {}
    tz = data.get("timezone")
    tz_name = sanitize(tz.get("id") if isinstance(tz, dict) else tz)

    lat, lon = _as_float(data.get("latitude")), _as_float(data.get("longitude"))
    coords = map_url = None
    if lat is not None and lon is not None \
            and -90 <= lat <= 90 and -180 <= lon <= 180:
        coords = "%.4f, %.4f" % (lat, lon)
        map_url = ("https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f"
                   "#map=10/%.5f/%.5f" % (lat, lon, lat, lon))

    asn = sanitize(connection.get("asn"), 20)
    if asn and asn.isdigit():
        asn = "AS" + asn
    calling = sanitize(data.get("calling_code"), 10)
    if calling:
        calling = "+" + calling.lstrip("+")

    return {
        "country": sanitize(data.get("country")),
        "region": sanitize(data.get("region")),
        "city": sanitize(data.get("city")),
        "coords": coords,
        "timezone": tz_name,
        "map_url": map_url,
        "continent": sanitize(data.get("continent")),
        "capital": sanitize(data.get("capital")),
        "postal": sanitize(data.get("postal"), 20),
        "calling_code": calling,
        "isp": sanitize(connection.get("isp")),
        "asn": asn,
        "org": sanitize(connection.get("org")),
        "domain": sanitize(connection.get("domain")),
    }


def geolocate(ip_text: str) -> dict:
    url = GEO_ENDPOINT + urllib.parse.quote(ip_text, safe=":.")
    raw = http_get(url)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise FetchError("invalid")
    return parse_geo(data)


# --------------------------------------------------------------------------- #
# Screens
# --------------------------------------------------------------------------- #

def yes_no(flag: bool, yes_style=("accent",)):
    return ("Yes", yes_style) if flag else ("No", ("gray",))


def build_banner(theme: Theme) -> str:
    box = Box(theme)
    box.top()
    box.blank()
    box.title(TOOL_NAME)
    box.blank()
    box.mid()
    box.center([("DEVELOPER: ", ("bold", "white")),
                (DEVELOPER, ("bold", "accent"))])
    box.bottom()
    return box.render()


def build_menu(theme: Theme) -> str:
    box = Box(theme)
    box.top()
    box.title("MAIN MENU")
    box.mid()
    box.blank()
    box._row([(" [1]", ("bold", "accent")), (" IP Show", ("white",))])
    box._row([(" [2]", ("bold", "accent")), (" IP Info", ("white",))])
    box.blank()
    box.bottom()
    return box.render()


def _public_display(version: int, address, status):
    if address:
        return address, ("bold", "accent")
    if status == "no_route":
        label = "no IPv6 route" if version == 6 else "no route"
        return "%s (%s)" % (NOT_AVAILABLE, label), ("gray",)
    reason = FetchError.HUMAN.get(status, "request failed")
    return "Not confirmed (%s)" % reason, ("yellow",)


def build_ip_show(theme: Theme, local4, local6, pub4, pub6) -> str:
    """pub4 / pub6 are (address, status) tuples."""
    box = Box(theme)
    box.top()
    box.title("IP SHOW")
    box.mid()
    box.section("Local Network")
    box.field("Local IPv4", local4 or NOT_AVAILABLE,
              ("bold", "accent") if local4 else None)
    box.field("Local IPv6", local6 or NOT_AVAILABLE,
              ("bold", "accent") if local6 else None)
    box.mid()
    box.section("Public Internet")
    for label, version, (address, status) in (("Public IPv4", 4, pub4),
                                              ("Public IPv6", 6, pub6)):
        text, style = _public_display(version, address, status)
        box.field(label, text, style)
    box.bottom()
    return box.render()


def build_ip_info(theme: Theme, ip, info: dict, hostname, geo, geo_error) -> str:
    box = Box(theme)
    box.top()
    box.title("IP INFO")
    box.mid()
    box.field("IP Address", str(ip), ("bold", "accent"))
    box.field("Version", "IPv%d" % ip.version, ("white",))
    box.field("Classification", info["label"], ("accent",))
    routable = yes_no(info["global"])
    box.field("Globally Routable", routable[0],
              routable[1] if info["global"] else ("yellow",))
    for label, key in (("Private", "private"), ("Loopback", "loopback"),
                       ("Link-Local", "link_local"), ("Multicast", "multicast")):
        text, style = yes_no(info[key])
        box.field(label, text, style)
    box.field("Reverse DNS", hostname or NOT_AVAILABLE)
    box.field("Prefix Length", "/%d (single address)" % ip.max_prefixlen,
              ("white",))
    if info["range"]:
        box.field("Address Block", info["range"], ("white",))
    if info["mapped"]:
        box.field("Embedded IPv4", str(info["lookup_ip"]), ("accent",))

    box.mid()
    if not info["global"]:
        box.section("Public Lookup")
        box.text("Not applicable: public geolocation is unavailable for "
                 "this address because it is not globally routable.",
                 ("yellow",))
    elif geo_error is not None:
        box.section("Location")
        box.text("Lookup failed: %s. Core details above are still valid."
                 % geo_error, ("yellow",))
    else:
        box.section("Location")
        box.field("Country", geo["country"])
        box.field("Region", geo["region"])
        box.field("City", geo["city"])
        box.field("Coordinates", geo["coords"])
        box.field("Time Zone", geo["timezone"])
        box.field("Map URL", geo["map_url"])
        box.mid()
        box.section("Regional")
        box.field("Continent", geo["continent"])
        box.field("Capital", geo["capital"])
        box.field("Postal Code", geo["postal"])
        box.field("Calling Code", geo["calling_code"])
        box.mid()
        box.section("Network")
        box.field("ISP", geo["isp"])
        box.field("ASN", geo["asn"])
        box.field("Organization", geo["org"])
        box.field("Domain", geo["domain"])
        box.mid()
        box.text("Geolocation is approximate and does not identify a "
                 "person's exact physical address. Data: ipwho.is",
                 ("gray",))
    box.bottom()
    return box.render()


def clear_screen(theme: Theme) -> None:
    if theme.interactive and theme.color:
        sys.stdout.write("\033[2J\033[H")
        sys.stdout.flush()


def ask(theme: Theme, text: str) -> str:
    sys.stdout.write(theme.paint(text, "bold", "accent"))
    sys.stdout.flush()
    return input()


def begin_screen(theme: Theme) -> None:
    """Start a report screen: new random theme, clear, branded header."""
    theme.reroll()
    clear_screen(theme)
    print(build_banner(theme))
    print()


def pause(theme: Theme) -> None:
    print()
    ask(theme, "Press Enter to return to menu ")


def screen_ip_show(theme: Theme) -> None:
    print(theme.paint("Checking network...", "gray"))
    results = run_parallel(lambda: detect_local_ip(4),
                           lambda: detect_local_ip(6),
                           lambda: fetch_public_ip(4),
                           lambda: fetch_public_ip(6))
    local4, local6 = [r if isinstance(r, str) else None for r in results[:2]]
    pub4, pub6 = [r if isinstance(r, tuple) else (None, "failed")
                  for r in results[2:]]
    print()
    print(build_ip_show(theme, local4, local6, pub4, pub6))
    if pub4[0] is None and pub6[0] is None and \
            pub4[1] in ("dns", "no_route", "timeout"):
        print(theme.paint("Warning: the internet connection appears to be "
                          "offline or unreachable.", "yellow"))
    pause(theme)


def screen_ip_info(theme: Theme) -> None:
    print(theme.paint("Leave empty to go back.", "gray"))
    while True:
        raw = ask(theme, "Enter an IPv4 or IPv6 address: ")
        if not raw.strip():
            return
        try:
            ip = parse_ip(raw)
            break
        except ValueError:
            print(theme.paint("Error: not a valid IPv4 or IPv6 address. "
                              "Example: 8.8.8.8 or 2001:db8::1", "red"))

    info = classify(ip)
    if info["global"]:
        print(theme.paint("Looking up details...", "gray"))
        target = str(info["lookup_ip"])
        hostname, geo = run_parallel(lambda: reverse_dns(str(ip)),
                                     lambda: geolocate(target))
    else:
        hostname = run_parallel(lambda: reverse_dns(str(ip)))[0]
        geo = None
    hostname = hostname if isinstance(hostname, str) else None
    geo_error = None
    if info["global"]:
        if isinstance(geo, dict):
            geo_error = None
        elif isinstance(geo, FetchError):
            geo_error = str(geo)
        else:
            geo_error = FetchError.HUMAN["failed"]
    print()
    print(build_ip_info(theme, ip, info, hostname,
                          geo if isinstance(geo, dict) else None, geo_error))
    pause(theme)


def main() -> int:
    theme = Theme()
    notice = ""
    try:
        while True:
            clear_screen(theme)
            print(build_banner(theme))
            print()
            print(build_menu(theme))
            if notice:
                print(theme.paint(notice, "red"))
                notice = ""
            choice = ask(theme, "Select an option [1-2]: ").strip().lower()
            if choice == "1":
                begin_screen(theme)
                screen_ip_show(theme)
            elif choice == "2":
                begin_screen(theme)
                screen_ip_info(theme)
            elif choice in ("q", "quit", "exit", "0"):
                break
            else:
                notice = "Invalid choice. Please enter 1 or 2."
    except (KeyboardInterrupt, EOFError):
        pass
    except BrokenPipeError:               # output pipe closed (e.g. "| head")
        return 0
    try:
        print("\n" + theme.paint("Goodbye.", "gray"))
    except BrokenPipeError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
