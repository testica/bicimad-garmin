# BiciMAD — Garmin Connect IQ Watch App

A native Garmin smartwatch app for the **BiciMAD** bike-share system in Madrid.
Find nearby stations, check availability, search bikes by plate number, and view your trip history — all from your wrist.

> **Disclaimer:** This is an unofficial third-party app. BiciMAD and EMT Madrid are trademarks of Empresa Municipal de Transportes de Madrid S.A.

---

## Features

| Feature | Description |
|---------|-------------|
| **Stations by GPS** | Find the nearest BiciMAD stations sorted by walking distance |
| **Search by name** | Type a station name and get matching results |
| **Unlock by plate** | Enter a bike's plate number to verify it and start a trip |
| **Trip history** | See your last 5 trips and any active trip in progress |
| **Secure login** | Authenticates with your BiciMAD account via the MPass API |
| **Persistent session** | Token stored on-device — no need to login every time |

---

## Screenshots / Flow

```
Main Menu
├── View Stations
│   ├── Nearby (GPS) ──→ ProgressBar ──→ Station list (native Menu2)
│   └── Search by Name ──→ TextPicker ──→ ProgressBar ──→ Station list
├── Trips (when logged in)
│   ├── Active Trip ──→ Active trip detail
│   └── History    ──→ Last 5 trips (native Menu2)
├── Unlock Bike
│   ├── Plate   ──→ TextPicker
│   └── Unlock  ──→ ProgressBar → Confirmation → ProgressBar → Result
└── Sign In / Sign Out
    ├── Email    ──→ TextPicker (native keyboard via phone)
    ├── Password ──→ TextPicker
    └── Connect  →
```

---

## Architecture

### Watch App (Monkey C / Connect IQ)

Built with Garmin's **Connect IQ SDK 3.2.0+** using native UI components throughout:

| Component | Used for |
|-----------|----------|
| `WatchUi.Menu2` | Main menu, login form, search form, station results, trip history |
| `WatchUi.TextPicker` | Email, password, plate number, station name search |
| `WatchUi.Confirmation` | Unlock confirmation dialog |
| `WatchUi.ProgressBar` | All loading states (GPS, network, unlock) |

### Proxy Backend (Node.js)

A lightweight proxy server that bridges the watch and the EMT Madrid API.
Necessary because **Garmin routes all HTTP requests through its own infrastructure**, which cannot reach `apiemtpay.emtmadrid.es` directly.

```
Garmin Watch → Garmin Servers → Proxy → EMT Madrid API
```

The proxy also handles:
- **Response size reduction** — the EMT stations API returns 632 stations (~296 KB). The proxy filters and compacts to <5 KB for the watch.
- **DES cryptography** — the bike unlock flow requires a hashcode computed with DES encryption (reverse-engineered from the official APK).

---

## API Endpoints

All endpoints are prefixed with `/api`. The proxy is deployed separately (e.g. on a VPS or Cloudflare Workers).

---

### `GET /api/stations`

Returns BiciMAD stations — sorted by proximity or filtered by name.

**Why a proxy?**
The full EMT API response contains all 632 stations at ~296 KB. The Garmin watch has a ~32 KB network buffer limit. The proxy filters it to the 15 nearest stations at <5 KB.

| Parameter | Type | Description |
|-----------|------|-------------|
| `filter` | `coordinates` \| `name` | Search mode |
| `value` | `lat,lon` or text | GPS coordinates or name fragment |
| `limit` | number | Max results (default 15, max 30) |

**Example — GPS proximity:**
```
GET /api/stations?filter=coordinates&value=40.4168,-3.7038&limit=10
```

**Example — Name search:**
```
GET /api/stations?filter=name&value=callao
```

**Response:**
```json
[
  { "id": "1406", "name": "2 - Metro Callao", "bikes": 11, "slots": 14, "dist": 57 },
  { "id": "1428", "name": "25A - Plaza de Celenque A", "bikes": 6, "slots": 15, "dist": 179 }
]
```

**Upstream call:**
`GET https://openapi.emtmadrid.es/v2/transport/bicimad/stations/`
Uses an anonymous app token (no user account required).

---

### `GET /api/trips`

Returns the authenticated user's trip history in compact format.

**Why a proxy?**
The full EMT response is ~65 KB (all trip fields for 28 trips). The watch limit is ~32 KB. The proxy reduces it to ~7 KB by keeping only display-relevant fields.

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | User's `accessToken` from login |
| `userId` | string | User's ID |

**Example:**
```
GET /api/trips?token=ACCESS_TOKEN&userId=USER_ID
```

**Response:**
```json
{
  "code": "00",
  "data": [
    {
      "id": "41437512",
      "bike": "00015858",
      "mins": 16.2,
      "cost": 0.50,
      "active": false,
      "undock": { "name": "250 - Serrano - CSIC", "ts": "2026-05-29 20:32" },
      "dock":   { "name": "17 - Plaza de Carlos Cambronero", "ts": "2026-05-29 20:48" }
    }
  ]
}
```

**Active trip:** a trip with `active: true` has no `dock` — the user is currently riding.

**Upstream call:**
`GET https://apiemtpay.emtmadrid.es/v1/bicimad/trips/`
Headers: `accessToken`, `userId`, `mode: mPass`

---

### `GET /api/check`

Verifies that a bike exists by its plate number and returns its current location.

| Parameter | Type | Description |
|-----------|------|-------------|
| `plate` | string | Bike plate/number (e.g. `15198`) |
| `token` | string | User's `accessToken` |
| `userId` | string | User's ID |

**Example:**
```
GET /api/check?plate=15198&token=ACCESS_TOKEN&userId=USER_ID
```

**Response:**
```json
{
  "code": "00",
  "data": {
    "number": "15198",
    "docker": "198",
    "fleet": 1,
    "lat": 40.402033,
    "lon": -3.707794
  }
}
```

`docker` is the anchor/dock ID. `fleet` is `1` (BiciMAD Classic) or `2` (BiciMAD Go).

**Upstream call:**
`GET https://apiemtpay.emtmadrid.es/v1/checkresource/bicimad/{plate}/`

---

### `GET /api/unlock`

Unlocks a specific bike by plate number, starting a trip. This is the most complex endpoint — it replicates the **DES encryption flow** from the official BiciMAD app.

| Parameter | Type | Description |
|-----------|------|-------------|
| `plate` | string | Bike plate number |
| `token` | string | User's `accessToken` |
| `userId` | string | User's ID |
| `lat` | float | User's latitude |
| `lon` | float | User's longitude |

**Example:**
```
GET /api/unlock?plate=15198&token=ACCESS_TOKEN&userId=USER_ID&lat=40.4168&lon=-3.7038
```

**Response:**
```json
{ "code": "00", "description": "Trip started", "bike": "15198", "docker": "198" }
```

**Full flow (3 steps):**

1. **Verify bike** — `GET /v1/checkresource/bicimad/{plate}/`
   Gets the bike's current dock, GPS coordinates, and fleet type.

2. **Compute hashcode** — DES encryption (reverse-engineered from `QRService.cifrarHashcode()` in the official APK):
   ```
   plaintext = bikeNumber + "#" + docker + "#" + lon10 + "#" + lat10 + "#U#" + userId
   padded    = plaintext padded to multiple of 8 with "#"
   step1     = "B" + DES_ECB(padded, userId[0:8]) as HEX UPPERCASE
   step1     = step1 padded to multiple of 8 with "Z"
   hashcode  = DES_ECB(step1, operatorId[0:8]) as BASE64
   ```
   Where `operatorId = "b6cf40a4-6130-439f-9917-15654c79c22e"` (from APK constants).

3. **Sell ticket** — `POST /v1/payment/qrcodesdk/sellticket/`
   Sends the computed `hashcode` as a header. The server validates it and unlocks the bike.

---

## Authentication

### Anonymous token (for station data)

The proxy obtains an anonymous token using only the **app credentials** — no user account needed:

```
GET https://openapi.emtmadrid.es/v2/mobilitylabs/user/login/
Headers: X-ClientId, passKey, (no email/password)
```

These credentials (`X-ClientId`, `passKey`) are extracted from the official BiciMAD APK via `libkeys.so` disassembly. They identify the BiciMAD application, not any individual user.

### User token (for trips and unlock)

The watch authenticates the user with their BiciMAD credentials:

```
GET https://openapi.emtmadrid.es/v2/mobilitylabs/user/login/
Headers: X-ClientId, passKey, accessToken (app token), email, password
```

The API returns `tokenSecExpiration` as a relative lifetime in seconds. In the
observed account flow the app token lasts 24 hours and the user token lasts 30
days. The watch converts that TTL to an absolute expiry, refreshes the app
token first, and then re-authenticates the user shortly before expiry. A 401
response clears the local session so the user can log in again.

---


## Setup

### Watch App

1. Install the [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
2. **Install the [TinyMetrix](https://tinymetrix.com) barrel** — required because the app imports `Tinymetrix` for analytics and crash reporting.

   **Option A: Using VS Code (recommended)**

   1. Open the project in VS Code with the Monkey C extension
   2. Run `Monkey C: Configure Monkey Barrel` from the command palette
   3. Download and select `tinymetrix-2.1.6.barrel` from:
      https://tinymetrix.com/assets/binaries/tinymetrix-2.1.6.barrel

   This creates or updates the local `barrels.jungle` configuration. The barrel
   dependency itself is declared in `manifest.xml`.

   **Option B: Manual configuration**

   Create `barrels.jungle` in the project root with the path to the downloaded
   barrel:

   ```text
   Tinymetrix = "/path/to/tinymetrix-2.1.6.barrel"
   base.barrelPath = $(base.barrelPath);$(Tinymetrix)
   ```

   Keep `barrels.jungle` local because the path is machine-specific. When
   building from the command line, include it together with `monkey.jungle`:

   ```bash
   monkeyc -f "monkey.jungle;barrels.jungle" ...
   ```

3. **Configure the local properties file**

   Copy the example file:

   ```bash
   cp resources/properties.xml.example resources/properties.xml
   ```

   The example contains a development `MOCK_TOKEN`. For production, replace it
   locally with your TinyMetrix token. Never commit `resources/properties.xml`.

4. Build and sideload to your watch or run in the simulator

### Proxy Backend

```bash
cd server
npm install
npm start
```

The server starts on `http://localhost:3000`. Set the `PORT` environment variable to change it.

**Deploy to production:**
The production proxy is deployed on the `garmin.land` Cloudflare Worker at
`https://bicimad.garmin.land/api/*`. For a separate local Node.js proxy, set
the same URLs in `BiciMadService.mc`:
```monkey-c
private const URL_PROXY  = "https://bicimad.garmin.land/api/stations";
private const URL_TRIPS  = "https://bicimad.garmin.land/api/trips";
private const URL_CHECK  = "https://bicimad.garmin.land/api/check";
private const URL_UNLOCK = "https://bicimad.garmin.land/api/unlock";
```

### Update Station Coordinates

The app includes a static snapshot of all 632 station coordinates (`source/StationsData.mc`), used for fast offline distance calculation. To update when EMT adds new stations:

```bash
./update_stations.sh
```

This fetches fresh data from the [GBFS feed](https://madrid.publicbikesystem.net/customer/gbfs/v3.0/station_information) and regenerates `StationsData.mc`.

---

## Project Structure

```
bicimad/
├── source/                     # Monkey C source (watch app)
│   ├── bicimadApp.mc           # App entry point, storage, session management
│   ├── bicimadView.mc          # Main menu (Menu2) and delegate
│   ├── BiciMadService.mc       # All API calls (login, stations, trips, unlock)
│   ├── StationsData.mc         # Static station coordinates (auto-generated)
│   ├── StationListView.mc      # Station search flow (GPS + name)
│   ├── LoginView.mc            # Login form (Menu2 + TextPicker)
│   ├── PlateSearchView.mc      # Unlock bike by plate flow
│   ├── TripsView.mc            # Trip history and active trip
│   ├── ReservationView.mc      # Station booking flow
│   └── PositionManager.mc      # GPS location handler
├── resources/
│   ├── strings/strings.xml     # Default localized strings (English)
│   ├── layouts/layout.xml      # Base layout
│   └── menus/menu.xml          # Menu resources
├── resources-eng/              # English strings
├── resources-spa/              # Spanish strings
├── server/                     # Proxy backend (Node.js)
│   ├── index.js                # Express server with all API endpoints
│   └── package.json
├── manifest.xml                # App manifest (permissions, target devices)
├── monkey.jungle               # Build configuration
└── update_stations.sh          # Script to refresh station coordinates
```

---

## License

MIT — see [LICENSE](LICENSE) for details.

This project is not affiliated with, endorsed by, or connected to EMT Madrid or Garmin.
