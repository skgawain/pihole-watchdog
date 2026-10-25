# Pi-hole Watchdog

Oct 24, 2026 · @Daniel

A "smoke detector" for your Pi-hole. It runs on the Pi and sends an alert to your phone when Pi-hole, Unbound or the Pi's hardware has a problem. Each alert says what's wrong and how to fix it.

> **Read this first**
>
> - **Shared as-is.** This is a personal project, free to use, with no support or warranty.
> - **It can shut your Pi down.** If the Pi stays at 85°C or higher, or its power supply stays too weak, for 3 minutes straight, the watchdog powers the Pi off to protect it. That takes your home internet down until you fix the cause, plug the Pi back in, or set your router's DNS back to automatic. You get an alert before it happens.
> - **It can change one Pi-hole setting.** If you use Unbound and Unbound stops working, it switches Pi-hole's upstream DNS to Cloudflare (1.1.1.1) so the house stays online, then switches back when Unbound recovers.
> - **Alerts go through ntfy.sh**, a free public notification service. Your channel name is random and private, but anyone who learns it could read your alerts.

## What it checks

| Check | How often | What it catches |
| --- | --- | --- |
| Pi-hole running and answering | Every 30 min | Pi-hole crashed or stopped answering, so the house has no internet |
| Ad blocking working | Every 30 min | Blocklists missing or blocking switched off |
| Unbound answering (if installed) | Every 30 min | Unbound broken, often by a router feature that intercepts DNS |
| Pi clock in sync | Every 30 min | A wrong clock, which makes Unbound fail |
| CPU temperature, fan | Every 30 min | Overheating, blocked vents, a dead fan (fan speed on Pi 5 only) |
| Power supply voltage | Every 30 min | A weak power supply or cable, the top cause of SD card corruption |
| SD card health and space | Every 30 min | Read/write errors, a card gone read-only, a card over 90% full |
| Memory, unexpected reboots | Every 30 min | Memory nearly full; restarts from power outages or crashes |
| Emergency guard | Every minute | 85°C or failing power for 3 minutes straight: shuts the Pi down cleanly |
| Daily summary | 5:30 AM | Lookups and blocked % for the last 24 hours, plus a health line |

It restarts a broken service once before alerting you, repeats an alert every 4 hours while a problem lasts, and every repeating alert has a **Snooze 3h** button.

## Choose your guide

| Guide | Who it's for |
| --- | --- |
| **[Beginner's Guide](BEGINNERS-GUIDE.md)** | Never used SSH or a command line. Step by step with plain-English explanations, what you'll see on screen, and a troubleshooting table. About 20 minutes. |
| **[Technical Guide](TECHNICAL.md)** | Comfortable with SSH and Linux. How it works, the one-line install, testing with simulated alerts, and every setting. About 10 minutes. |

Both use the same installer, **pihole-watchdog-install.sh**, in the file list above.

## Quick install

Requires Pi-hole v6 on Raspberry Pi OS or Debian. Log into the Pi over SSH and run:

```bash
curl -fsSL https://raw.githubusercontent.com/skgawain/pihole-watchdog/main/pihole-watchdog-install.sh -o pihole-watchdog-install.sh && bash pihole-watchdog-install.sh
```

Then subscribe to the channel name it prints in the ntfy app and run `sudo pihole-watchdog.sh test`.

## License

MIT. See [LICENSE](LICENSE). Free to use, change and share, with no warranty.
