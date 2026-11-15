# Google Cloud setup (one time, about 20 minutes)

You need this before **Phase 2** (real distances) and **Phase 3** (Google Sheet).
Phase 1 runs without it.

App identifiers used below:

| Platform | Identifier |
|---|---|
| Android package name | `com.dunnrecordkeeping.mileage_log` |
| macOS bundle ID | `com.dunnrecordkeeping.mileageLog` |

## 1. Create a project

1. Go to <https://console.cloud.google.com/> and sign in with the Google account
   that should own the mileage spreadsheet.
2. Project picker (top bar), then **New project**. Name it `Mileage Log`, then **Create**.
3. **Billing**: link a billing account. Routes and Places require one. Personal
   use (a few trips a day) stays inside Google's free monthly allowance. You can
   also set a budget alert under **Billing → Budgets & alerts**, for example $5.

## 2. Turn on the APIs

**APIs & Services → Library**. Search for each of these and click **Enable**:

- Google Sheets API
- Google Drive API (lets the app find its spreadsheet on your second device)
- Routes API
- Places API (New)

## 3. OAuth consent screen

**APIs & Services → OAuth consent screen** (may be labeled **Google Auth Platform**):

1. App name `Mileage Log`, user support email = your email.
2. Audience: **External** for a personal Gmail account. Choose **Internal** if your
   Google account is in a Google Workspace organization.
3. Data access / scopes: add both of these (Google lists both as
   non-sensitive):
   - `.../auth/drive.file`: only files the app created itself (the
     mileage spreadsheet).
   - `.../auth/drive.appdata`: the app's own hidden settings folder in your
     Drive, used to keep the API key and settings the same on phone and Mac.
4. Test users: add your own email address.
5. After signing in from the app works, go to **Audience → Publish app**.
   Apps left in testing mode make you sign in again about every 7 days.
   Personal apps with fewer than 100 users don't need Google's review; when
   you sign in you may see "Google hasn't verified this app". Click
   **Advanced → Go to Mileage Log** to continue.

## 4. OAuth client IDs

**APIs & Services → Credentials → Create credentials → OAuth client ID**.

### Android

- Application type: **Android**
- Package name: `com.dunnrecordkeeping.mileage_log`
- SHA-1: run this on the Mac after Flutter and Android Studio are installed,
  then copy the `SHA1:` line:

```bash
"/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

  The file `~/.android/debug.keystore` only exists after the app has been
  built for Android once (`flutter build apk --debug`).

  When you make a release build later (Phase 5), add a second Android client
  using the release keystore's SHA-1.

### Web application (needed by Android sign-in)

Android's sign-in system needs a "web" client ID too, even though there is
no website.

- Application type: **Web application**
- Name: `Mileage Log Android server`
- Leave the JavaScript origins and redirect URIs empty, then **Create**.
- Copy the **Client ID**.

### Desktop app (Mac sign-in)

The Mac app signs in through your web browser.

- Application type: **Desktop app**
- Name: `Mileage Log Mac`
- **Create**, then copy the **Client ID** and **Client secret** (or download
  the JSON).

An earlier version of this guide said to make an **iOS** client for the Mac.
The app doesn't use it, so you can delete it or leave it.

### Put the IDs in the app's build config

Copy `config/google_oauth.example.json` to `config/google_oauth.json` and
fill in the three values. That file is excluded from git. Builds read it with:

```bash
flutter run --dart-define-from-file=config/google_oauth.json
```

Without it the app still runs, with Google sign-in turned off.

## 5. API key for Routes and Places

1. **Credentials → Create credentials → API key**.
2. Click the new key, then **API restrictions → Restrict key**. Tick only
   **Routes API** and **Places API (New)**, then save.
3. Copy the key. You will paste it into the app's **Settings** screen, which
   stores it in the phone's or Mac's secure storage. Do not put it in the code
   or in chat.

## What to send back

When you finish, tell me it's done and paste **only** these (they are not secret):

- The macOS **Client ID** and **iOS URL scheme**

Keep the API key to yourself and enter it in the app's Settings.
