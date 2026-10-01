# CookieTag Monitor

A small macOS app with a dashboard and menu-bar indicator that checks once a day whether a nearby Samsung Galaxy SmartTag2 is still transmitting. It warns you when no response is heard, which can catch a dead CR2032 battery while Cookie is safely beside the laptop.

## Install

1. In Terminal, open this folder and run:

   ```sh
   chmod +x scripts/build-app.sh
   ./scripts/build-app.sh
   ```

2. Move `dist/CookieTag Monitor.app` into `/Applications`.
3. Open the app. Approve Bluetooth and notification access when macOS asks.
4. Add it in **System Settings → General → Login Items** so it runs after login.
5. Keep Cookie near the Mac during the first 45-second check. Use the radio-wave icon in the menu bar to run another check at any time.

The app stays in the menu bar, scans at launch, and checks every day at **11:00 AM local time**. It registers itself as a login item so it can keep the schedule after restarts. A successful detection is saved, and a missing response produces a notification. macOS may ask you to approve the login item in **System Settings → General → Login Items**.

During a scan, the 🐶 menu-bar label shows the estimated distance to the nearest Samsung tracker. This is a rough BLE signal-strength estimate rather than precise ranging; Cookie’s body, walls, furniture, and tag orientation can change it substantially. For a personalized estimate, place Cookie 90 cm from the Mac after a successful scan and click **Calibrate at 90 cm**, then scan again.

The dashboard also decodes the SmartTag battery state advertised over BLE (`Full`, `Medium`, `Low`, or `Very low`), keeps the most recent 90 check records locally, and summarizes the last seven checks. A low or very-low reading triggers an immediate CR2032 replacement warning. Samsung exposes a four-level state rather than a precise percentage.

## Important limitation

Samsung SmartTag2 rotates its BLE privacy identity. A Mac can recognize the Samsung Find Network advertisement (`FD5A`), but cannot reliably bind that changing signal to one physical tag. If another Samsung tracker is nearby, the app will warn that the result is ambiguous. For the most dependable daily check, have Cookie beside the Mac and keep other Samsung tags away for the 45-second scan.

This is a transmitter-health check, not a replacement for SmartThings Find and not a location tracker.
