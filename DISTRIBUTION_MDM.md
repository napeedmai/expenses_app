# Distributing the Expenses app through ManageEngine MDM

Written September 2026, after the prod migration. Supersedes the store-launch
assumptions in `LAUNCH_CHECKLIST.md` if you go the MDM route.

## A correction first

I said earlier that MDM distribution means "no store review". **That is true for
Android and not true for iOS.** Apple reviews private Custom Apps too — they are
simply not listed publicly. Getting that wrong would have set the wrong
expectation about timelines, so it is worth stating plainly before anything else.

## What MDM actually does

ManageEngine MDM is the *delivery* mechanism, not the *signing* mechanism. You
upload a built binary (`.apk` for Android, `.ipa` for iOS) to the MDM server and
push it to enrolled devices, either silently or through the MDM App Catalog.

What it does not do is create the right to install that binary. Android will
install a self-signed APK once the device trusts the source — which a managed
device does. iOS will not install anything Apple has not signed off on, whatever
the MDM says. So the two platforms diverge completely from here.

## Android — genuinely simple

1. Build an APK. **This already works in this repo** — `eas.json` has a
   `preview` profile with `"distribution": "internal"` and
   `"buildType": "apk"`:

   ```
   eas build --platform android --profile preview
   ```

2. Download the `.apk` from the EAS build page.
3. Upload it to MDM as an **in-house / enterprise app**.
4. Distribute silently to a device group, or publish to the App Catalog and let
   people install it themselves.

No Play Store, no review, no listing, no data-safety form. Updates are the same
loop: new build, upload, MDM pushes it.

## iOS — three routes, and only two are open

### 1. Ad Hoc — works today, does not scale

Needs a paid Apple Developer Program membership ($99/yr). EAS handles the
credential work.

- **Cap of 100 devices per year**, across the whole membership
- You need each device's **UDID** registered before it can install
- Adding a device means a **rebuild or re-sign** — the provisioning profile
  carries a fixed allow-list

`eas device:create` collects UDIDs by URL or QR code, and `eas build --profile
preview` produces the `.ipa`. That IPA can be uploaded to MDM like any other.

Fine for a pilot with a handful of testers. Painful as a company rollout,
because every new joiner needs a rebuild.

### 2. Apple Business Manager Custom App — the sustainable route

Apple's current answer for private distribution.

- **Unlimited devices**, no UDID management
- Distributed to your organisation only — **not listed on the public App Store**
- **Still goes through App Store Connect and Apple review.** Private, not
  unreviewed
- Assign to your MDM through ABM, and MDM pushes it like any other app

Requires the organisation to be enrolled in Apple Business Manager (needs a
D-U-N-S number) and a normal Apple Developer Program membership.

This is what I would plan around. The review is a one-off cost per release, not
per device, and it is the only route that does not fall over as headcount grows.

### 3. Apple Developer Enterprise Program — probably not available

Unlimited devices, no review, designed exactly for MDM delivery. Also:

- Requires **100+ employees** and a legal entity (no DBAs or trade names)
- Apple grants it only for cases *not* served by the App Store, ABM Custom Apps,
  Ad Hoc, or TestFlight
- As of 2026 it is reported to be **closed to new organisations**

Worth one email to Apple to confirm if Trinamix already holds a membership. Do
not build the plan on getting a new one.

## What this repo already has

| | Status |
|---|---|
| Bundle id / package | `com.trinamix.expenseapp`, both platforms |
| Version | `1.0.0` |
| EAS project id | set in `app.json` |
| Android APK profile | **ready** — `preview` in `eas.json` |
| iOS internal profile | `preview` exists; needs ad hoc credentials or a Custom App setup |
| Camera / photo permissions | present, with usage strings |
| `ITSAppUsesNonExemptEncryption` | already `false` |

## What still has to happen either way

These are not MDM questions — they apply to any distribution route.

1. **`src/config.js` points at `karyasiddhitest`.** Until it points at
   `karyasiddhi.trinamix.com`, every build talks to dev regardless of what prod
   contains.
2. **Rebuild the GitHub Pages bundle, or retire it.** It is stale — it predates
   the camera, image compression, bill detail view, the category fix and the
   login messages. If the app ships through MDM, the public web build may be
   worth removing entirely rather than maintaining.
3. **Trim the localhost CORS origins** on prod.
4. **The API stays public.** This is the part MDM does not solve: private app
   distribution does not make `karyasiddhi.trinamix.com` private. Anyone who
   finds the host can still reach `auth/login`. Retiring the public web build
   removes the obvious signpost, but per-IP limiting is still the only control
   that sees a password spray across many accounts.
5. **Receipt scanning is inert on prod** until an APEX AI service exists in
   prod's workspace and `AI_SERVICE_STATIC_ID` holds its real static id — and
   until the OpenAI account has credit.

## The decision that shapes everything else

**How many iPhones, and are they company-owned?**

- Few iPhones, or a pilot → Ad Hoc now, ABM later
- Android-only workforce → nothing above matters; ship the APK through MDM this
  week
- Mixed fleet at any real size → start the Apple Business Manager enrolment now,
  because that is the long-pole item and it involves finance and legal, not
  engineering

## Sources

- [ManageEngine — Distributing apps to devices](https://www.manageengine.com/mobile-device-management/help/app_management/mdm_distributing_apps_to_devices.html)
- [ManageEngine — Mobile Application Management](https://www.manageengine.com/mobile-device-management/mdm-app-management.html)
- [Expo — Internal distribution](https://docs.expo.dev/build/internal-distribution/)
- [Apple — Developer Enterprise Program](https://developer.apple.com/programs/enterprise/)
- [Apple Enterprise Developer Program in 2026: what changed](https://www.appaloosa.io/blog/news/is-it-soon-over-for-apple-enterprise-developer-accounts)
