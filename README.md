# NotchCute

![NotchCute](assets/hero.png)

Hover your MacBook's notch, pick a category of cute things, and the screen dims around a centered player that auto-plays posts from r/Eyebleach, r/aww, r/rarepuppers and friends.

## What it does

- **Notch hover:** rest the pointer in the notch for ~0.3 s and a black panel grows out of it with six categories: Eye Bleach, Puppies, Kitties, Tiny Critters, Birbs, Otters & Pals.
- **Spotlight:** click a category and everything dims except a centered window. Images stay up 8 s; videos play muted to the end.
- **Controls:** arrow keys or space to skip, Esc / click outside / the ✕ to close.
- **Menu bar:** a 🐾 icon offers the same categories and Quit.
- **Gentle filter:** skips posts whose titles mention NSFW or sad words ("RIP", "passed away"…). Not perfect.
- **Polite to Reddit:** uses public RSS feeds (no login), spaces requests 2.5 s apart, caches for 15 minutes and falls back to the last good copy on disk.

## Build

Requires macOS 14+ on Apple Silicon and the Xcode command-line tools.

```bash
bash build.sh
open build/NotchCute.app
```

`build.sh` draws the app icon from `Icon/make_icon.swift`, compiles `Sources/main.swift`, and ad-hoc signs the bundle. Copy `build/NotchCute.app` to `/Applications` to install.

On Macs without a notch, a thin strip at the top-center of the screen acts as the trigger.

## License

MIT
