# IP INFORMATION GATHERING

**Developer: UG ALOK**

A clean, professional terminal tool for **Android Termux** (and any system with Python 3.8+) that shows your network addresses and detailed information about any IPv4 or IPv6 address.

Built with the Python standard library only. Nothing is installed besides Python, and nothing is ever saved to disk.

---

## Main menu

| Option | Name | What it does |
| --- | --- | --- |
| **1** | **IP Show** | Displays available local and public IPv4 / IPv6 addresses. |
| **2** | **IP Info** | Asks for an IPv4 or IPv6 address and shows its relevant details. |

## Features

- **Two-option menu** - simple and immediate.
- **IP Show** - local IPv4/IPv6 and public IPv4/IPv6, checked in parallel.
- **IP Info** - validation with Python's `ipaddress` module and accurate classification of public, private, loopback, link-local, multicast, CGNAT, documentation, reserved and other special-use ranges.
- **Reverse DNS** and prefix information for every address.
- **Public geolocation** (public addresses only) over HTTPS: country, region, city, coordinates, time zone, map URL, plus continent, capital, postal code, calling code, ISP, ASN, organization and domain, when the provider supplies them. IP Show never displays this data.
- **Random color theme per report** - green, cyan, yellow, blue or magenta, never the same theme twice in a row. All themes use bright, high-contrast colors.
- **Honest results** - unavailable data is shown as `Not available`; an IPv6 address is reported as unavailable only when the connection attempt shows there is no IPv6 route, otherwise it is shown as `Not confirmed (reason)`.
- **Mobile-friendly** - the layout adapts to narrow terminals and falls back to plain text/ASCII when colors or Unicode are unavailable (`NO_COLOR` is respected).
- **No file output** - no reports, logs, caches, databases or config files.

## Terminal preview

Illustrative layout only - values below are placeholders, not real lookup results, and the accent color changes with each report.

```
╔══════════════════════════════════════════════════╗
║                                                  ║
║            IP INFORMATION GATHERING              ║
║                                                  ║
╠══════════════════════════════════════════════════╣
║               DEVELOPER: UG ALOK                 ║
╚══════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════╗
║                    MAIN MENU                     ║
╠══════════════════════════════════════════════════╣
║                                                  ║
║  [1] IP Show                                     ║
║  [2] IP Info                                     ║
║                                                  ║
╚══════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════╗
║                     IP SHOW                      ║
╠══════════════════════════════════════════════════╣
║ LOCAL NETWORK                                    ║
║ Local IPv4        : 192.168.x.x                  ║
║ Local IPv6        : Not available                ║
╠══════════════════════════════════════════════════╣
║ PUBLIC INTERNET                                  ║
║ Public IPv4       : x.x.x.x                      ║
║ Public IPv6       : Not available (no IPv6       ║
║                     route)                       ║
╚══════════════════════════════════════════════════╝
```

## Requirements

- Python **3.8 or newer**
- An internet connection (only for public IP detection and geolocation)
- No root access, no third-party packages

## Installation (Termux)

```bash
pkg update && pkg install python git
git clone <your-repository-url> IP-INFORMATION-GATHERING
cd IP-INFORMATION-GATHERING
bash install.sh
```

`install.sh` checks for Python, makes `main.py` executable and offers to launch the app. It does not download or run remote scripts, does not need root and does not ask for credentials. Use `bash install.sh --no-launch` to check requirements only.

You can also skip the installer entirely:

```bash
python "IP info.sh"
```

## Usage

1. Start the app and choose an option:
   - **1 - IP Show** shows results immediately. Press Enter to return to the menu.
   - **2 - IP Info** asks for an IPv4 or IPv6 address, e.g. `8.8.8.8`, `192.168.1.1` or `2001:4860:4860::8888`. Leave the line empty to go back.
2. Press **Ctrl+C** at any time to exit cleanly.

For private, loopback, link-local and other non-global addresses, the app shows the classification and core details and explains that public geolocation does not apply.

## Privacy and limitations

- **Nothing is saved.** The app writes no files and keeps no history.
- **Network requests.** Public IP detection contacts `api4.ipify.org` / `api6.ipify.org` (fallback: `icanhazip.com`). Geolocation sends the public IP you enter to `ipwho.is`. Those services receive your request like any website would. No API keys are used.
- **Local IP detection** opens a UDP socket purely to let the OS choose the outbound interface; no packet is sent.
- **Geolocation is approximate.** Results can be off by many kilometers or point to a provider's hub rather than a user.
- **IP addresses alone do not reliably identify an individual.** Shared connections, VPNs, proxies and carrier-grade NAT are common.
- **External services can fail** or rate-limit requests. The app reports this and keeps the core details visible.
- Data quality for ISP, ASN and similar fields depends entirely on the provider.

## Troubleshooting

| Problem | What to try |
| --- | --- |
| `python: command not found` | `pkg update && pkg install python` |
| Public IPv4 shows `Not confirmed (...)` | Check your connection; the provider may be down or rate-limiting. Try again later. |
| Public IPv6 shows `Not available (no IPv6 route)` | Your network has no IPv6 connectivity. This is normal on many mobile and Wi-Fi networks. |
| Lookup fails with `TLS/certificate error` | Check your device date/time and run `pkg upgrade`. |
| Box lines look garbled | Use a UTF-8 terminal; the app falls back to ASCII borders when it cannot detect UTF-8. |
| Colors look wrong or you prefer plain text | Set `NO_COLOR=1` before running to disable colors. |
| Output wraps on a small screen | Rotate the phone or reduce the terminal font size. |

## Disclaimer

**Disclaimer:** This tool is provided for educational purposes and legitimate network diagnostics only. The developer is not responsible for illegal activities, misuse, unauthorized access, or damages resulting from the use of this software. Users are solely responsible for complying with applicable laws and obtaining proper authorization before conducting network-related activities.

This disclaimer does not remove or replace any legal responsibility, and it does not guarantee protection from liability. Use the tool responsibly.
