# TL;DR — who can sideload what, and how

## For end users

- You can **fairly side-load** an iPhone/iOS app.
- **How easily depends on the app developer.**
- If you're willing to **pay Apple $99/year**, you can sideload **unlimited apps to your
  own devices**, and you refresh the installs **yearly**. **This is the easiest path.**
- If you **don't want to pay Apple**:
  1. **If the developer didn't pay Apple either** — you put your iPhone/iPad into
     **Developer Mode** (via Settings) and install **via USB**.
  2. **If the developer paid Apple $99** — you install the app via a **QR code** this app
     gives you, with **nothing to do to your iPhone/iPad**. However, this limits **total
     worldwide installs to 100 devices**, so the developer might not want it — but it's
     perfect for apps with smaller audiences.

## For developers

- **Use a free Apple ID** — people install your app (as an `.ipa`) by logging into
  **their own** free Apple account, putting their device into **Developer Mode**,
  **trusting the key**, and connecting to their **Mac via USB**. The app **refreshes
  every 7 days** (or **yearly** if they have a paid $99 Apple ID). Your app can be
  installed to **unlimited devices**.
- **Or get a paid Apple ID** and sign your `.ipa` with an **ad-hoc cert** — then people
  install your app via a **QR code that SideStep creates**, and the user **doesn't have
  to do anything else to their device**. However, this limits your app to being installed
  on **100 devices**.

---

*Deeper dives: the [step-by-step guide](GUIDE.md) for end users, and the
[wireless install/refresh research](wireless/) + [AI bootstrap](AI-BOOTSTRAP.md) for the
technical detail behind the QR/over-the-air path.*
