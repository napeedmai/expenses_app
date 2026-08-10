# Hosting the web build on GitHub Pages

Gives your team a public URL. No laptop running, no tunnel, no APK.

## Before you start

Confirm the app actually works in a browser, because a broken web build
deploys just as happily as a working one:

```
npx expo start --web
```

Some dependencies have no real web implementation and may need
`Platform.OS === 'web'` guards — `expo-notifications`,
`@react-native-community/datetimepicker`, `expo-document-picker`,
`expo-file-system`, `expo-sharing`. Fix anything fatal before deploying.

---

## 1. Set the base URL to match the repo name

Already added to `app.json`:

```json
"experiments": { "baseUrl": "/expense-app" }
```

`baseUrl` must equal the repo name, because Pages serves project repos at
`https://<user>.github.io/<repo>/` while Expo otherwise references assets
from `/`. Mismatch here is the usual cause of a blank white page with 404s
for every `.js` file in the browser console.

**Exception:** if you name the repo `<your-username>.github.io`, it is served
from the root — delete the `experiments` block entirely in that case.

## 2. Build

```
npx expo export -p web
```

Produces `dist/`.

## 3. Add .nojekyll  — DO NOT SKIP

GitHub Pages runs Jekyll by default, and Jekyll **ignores every folder whose
name starts with an underscore**. Expo puts all its JavaScript in `_expo/`.
Without this file the page loads and renders nothing, with 404s on every
bundle.

```
cd dist
type nul > .nojekyll
```

## 4. Push dist to a new repo

Create an empty repo on GitHub named `expense-app` (no README, no
.gitignore), then from inside `dist`:

```
git init
git add -A
git commit -m "Web build"
git branch -M main
git remote add origin https://github.com/<your-username>/expense-app.git
git push -u origin main
```

Only the built site goes in this repo, not your source. Keep it separate
from your app source repo — `dist/` is gitignored in the project for good
reason.

## 5. Enable Pages

Repo → **Settings** → **Pages** → Source: **Deploy from a branch**,
Branch: `main`, folder: `/ (root)` → Save.

Live within a minute or two at:

```
https://<your-username>.github.io/expense-app/
```

## 6. Redeploying after code changes

```
npx expo export -p web
cd dist
type nul > .nojekyll
git add -A
git commit -m "Update"
git push
```

---

## CORS — the app will not work without this

Your team's browsers will call `https://karyasiddhi.trinamix.com` from the
`github.io` origin. Browsers block cross-origin requests unless the server
explicitly permits them, so **every API call including login fails** until
ORDS is configured to allow it.

This never came up for the mobile app because native apps aren't subject to
CORS. `13_cors_fix_for_web_testing.sql` exists for exactly this; your notes
say to skip it for mobile-only deployments, which is why it was never run
on prod.

Apply it to `REPO` with the Pages origin allowed:

```
https://<your-username>.github.io
```

Set `p_origins_allowed` on the ORDS modules to that origin. Check what is
currently allowed with:

```sql
SELECT name, uri_prefix, origins_allowed FROM user_ords_modules;
```

Note the origin is scheme + host only — no path, no trailing slash.

## Security note

A public GitHub Pages site is readable by anyone, and it talks to your
production API. The build contains no secrets (`config.js` holds only the
base URL, and OAuth credentials live server-side), so exposure is limited to
the URL itself — but anyone who finds the page can attempt logins against
prod. Take the repo private, or delete it once the demo is done.
