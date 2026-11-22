# EasySqueezy plugin for Lyrion Music Server

Companion plugin for **EasySqueezy Player**, an Android app that plays music from a
[Lyrion Music Server](https://lyrion.org) (formerly Logitech Media Server) on the phone, at home
and on the go, with Android Auto.

The app works without this plugin. With it, the server does more for the phone:

- **Conversion that just works:** each phone gets its own conversion rules, so plugins such as
  C-3PO and SqueezeDSP can't leave it without MP3 on mobile data, and DSD plays when the server
  has ffmpeg.
- **Lossless format:** the app chooses how lossless music comes: PCM, FLAC as it is, or FLAC
  16-bit/44.1 kHz.
- **Smoother playback on the road:** a paused phone stays paused when it reconnects, and a next
  song whose download broke is fetched or streamed again in time.
- **Remote access:** installs and runs Tailscale on the server (Linux, FreeBSD), or detects
  ZeroTier, and tells the app the server's address.
- **Clearer diagnostics:** the app can show what the server can do for the phone, why playback
  stopped at the end of the queue, and (if the server admin allows it) the server's log lines
  about the phone.

## Installing

1. In Lyrion, open *Settings → Manage Plugins*.
2. At the bottom, under *Additional Repositories*, add
   `https://raw.githubusercontent.com/iragetjk/easysqueezy-lms-plugin/main/repo.xml`
   and press *Apply*.
3. Find *EasySqueezy Player* in the list, tick it, press *Apply* and restart Lyrion when asked.

Lyrion offers updates on the same page. The plugin's settings are under *Settings → Advanced →
EasySqueezy Player* (or *Manage Plugins → EasySqueezy Player → Settings*).

Requires Lyrion 8.0 or later.

## Help

The app's FAQ (English, Russian) covers the plugin and common setup problems:
https://irage.org/easysqueezy/faq.html

## Layout

- `EasySqueezy/`: the plugin, as Lyrion installs it.
- `repo.xml`: the Lyrion plugin repository file; the plugin zips are attached to the
  [releases](https://github.com/iragetjk/easysqueezy-lms-plugin/releases).

## Licence

Copyright (C) 2026 Eradj Tursun-Zade (irage).
Licensed under the GNU General Public License, version 2 only (GPL-2.0-only); see
[LICENSE](LICENSE).
