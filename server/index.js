/**
 * BiciMAD Garmin Watch App — Proxy Backend
 *
 * Standalone Node.js proxy that bridges the Garmin watch app with the
 * EMT Madrid BiciMAD API (https://openapi.emtmadrid.es / https://apiemtpay.emtmadrid.es).
 *
 * Why a proxy?
 *   The Garmin SDK routes HTTP requests through Garmin's own infrastructure,
 *   which cannot reach apiemtpay.emtmadrid.es directly. This proxy runs on
 *   a server with unrestricted internet access (e.g. a VPS or Cloudflare Workers).
 *
 * Endpoints
 * ─────────────────────────────────────────────────────────────────────────────
 *  GET /api/stations    Nearby stations (GPS) or search by name
 *  GET /api/trips       User trip history (last 5 + active trip)
 *  GET /api/check       Verify a bike exists by plate number
 *  GET /api/unlock      Unlock a specific bike by plate (full DES crypto flow)
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * Usage:
 *   npm install
 *   npm start              (production)
 *   npm run dev            (development with auto-reload)
 *
 * Environment:
 *   PORT   HTTP port to listen on (default: 3000)
 */

import express from 'express';
import crypto  from 'crypto';

const app  = express();
const PORT = process.env.PORT || 3000;

// ── App credentials (extracted from the official BiciMAD APK) ─────────────
// These identify the BiciMAD app itself — not a specific user account.
// They are embedded in the APK and are public knowledge for anyone who
// decompiles the app (libkeys.so analysis).
const BICIMAD_X_CLIENT_ID = '8ff527f9-f85b-45ef-b1b2-bd9eb59e0fff';
const BICIMAD_PASS_KEY    = 'C3D0E659D8D397782B414AB6FCC477B5C727435FE91E72069D34CEBB2C1491B3B8563FDAC043EA704660C0E87E6FE503C39D38FF43F7447563B1E437B349ACEC';

// Operator ID extracted from APK constants (Constants.OPERATOR_ID)
const OPERATOR_ID = 'b6cf40a4-6130-439f-9917-15654c79c22e';

// ── EMT Madrid API base URLs ──────────────────────────────────────────────
const OPENAPI_BASE  = 'https://openapi.emtmadrid.es/v2';
const APIEMTPAY_BASE = 'https://apiemtpay.emtmadrid.es';

// ── Anonymous app token cache (refreshed when it expires) ────────────────
// The anonymous login uses only the app credentials, no user account needed.
// The API returns the lifetime as tokenSecExpiration (seconds).
let _anonToken  = null;
let _anonExpiry = 0; // seconds since epoch

async function getAnonToken() {
  const now = Date.now() / 1000;
  if (_anonToken && now < _anonExpiry - 300) return _anonToken;

  const res  = await fetch(`${OPENAPI_BASE}/mobilitylabs/user/login/`, {
    headers: {
      'X-ClientId':        BICIMAD_X_CLIENT_ID,
      'passKey':            BICIMAD_PASS_KEY,
      'accessToken':        '',
      'userId':             '',
      'appName':            'BiciMAD',
      'appPlatform':        'Android',
      'appPlatformVersion': 'Android 12',
      'appVersion':         '5.0.0',
      'deviceId':           'garmin-proxy',
      'deviceModel':        '{}',
      'language':           'ES',
      'latitude':           '40.416775',
      'longitude':          '-3.703790',
    },
  });

  const data = await res.json();
  if ((data.code === '00' || data.code === '01') && data.data?.[0]?.accessToken) {
    const ttlSec = Number(data.data[0].tokenSecExpiration || 0);
    _anonToken  = data.data[0].accessToken;
    _anonExpiry = ttlSec > 0 ? now + ttlSec : 0;
    console.log(`[auth] Anonymous token refreshed${_anonExpiry > 0 ? `, expires ${new Date(_anonExpiry * 1000).toISOString()}` : ''}`);
    return _anonToken;
  }
  throw new Error(`Anonymous login failed: code=${data.code} — ${data.description}`);
}

// ── Distance helper (equirectangular approximation) ───────────────────────
function distanceMeters(lat1, lon1, lat2, lon2) {
  const R    = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const mLat = (lat1 + lat2) * Math.PI / 360;
  return Math.round(Math.sqrt(dLon ** 2 * Math.cos(mLat) ** 2 + dLat ** 2) * R);
}

// ── Standard response helpers ─────────────────────────────────────────────
const ok  = (res, data, maxAge = 0) => {
  if (maxAge > 0) res.set('Cache-Control', `public, max-age=${maxAge}`);
  res.json(data);
};
const err = (res, msg, status = 400) => res.status(status).json({ error: msg });

// ── CORS (allow requests from the Garmin infrastructure) ─────────────────
app.use((req, _res, next) => {
  _res.set('Access-Control-Allow-Origin', '*');
  next();
});

// ─────────────────────────────────────────────────────────────────────────
//  GET /api/stations
// ─────────────────────────────────────────────────────────────────────────
//  Returns a compact list of BiciMAD stations — either sorted by GPS
//  proximity or filtered by name.
//
//  Query params:
//    filter=coordinates  value=<lat>,<lon>   → nearest stations (GPS)
//    filter=name         value=<text>        → stations matching the name
//    limit=<n>                               → max results (default 15, max 30)
//
//  The full EMT response contains 632 stations (~296 KB). This endpoint
//  filters and compacts it to <5 KB so the Garmin watch can parse it.
//
//  Response: [{id, name, bikes, slots, dist}]
// ─────────────────────────────────────────────────────────────────────────
app.get('/api/stations', async (req, res) => {
  const { filter = 'coordinates', value = '', limit = '15' } = req.query;
  const maxResults = Math.min(parseInt(limit), 30);

  if (!value) return err(res, 'Missing value parameter');

  let token;
  try { token = await getAnonToken(); }
  catch (e) { return err(res, `Auth error: ${e.message}`, 502); }

  const stRes  = await fetch(`${OPENAPI_BASE}/transport/bicimad/stations/`, {
    headers: { 'accessToken': token, 'appName': 'BiciMAD', 'appPlatform': 'Android', 'appVersion': '5.0.0', 'language': 'ES' },
  });
  const stData = await stRes.json();
  const all    = (stData.data || []).filter(s => s.light > 0 && s.geometry?.coordinates?.length >= 2);

  let result;

  if (filter === 'coordinates') {
    const [lat, lon] = value.split(',').map(Number);
    if (isNaN(lat) || isNaN(lon)) return err(res, 'Invalid coordinates — expected lat,lon');

    result = all
      .map(s => {
        const [sLon, sLat] = s.geometry.coordinates;
        return { id: String(s.id), name: s.name, bikes: s.dock_bikes ?? 0, slots: s.free_bases ?? 0, dist: distanceMeters(lat, lon, sLat, sLon) };
      })
      .sort((a, b) => a.dist - b.dist)
      .slice(0, maxResults);

  } else if (filter === 'name') {
    const q = value.toLowerCase().trim();
    result  = all
      .filter(s => s.name.toLowerCase().includes(q))
      .map(s => ({ id: String(s.id), name: s.name, bikes: s.dock_bikes ?? 0, slots: s.free_bases ?? 0, dist: 0 }))
      .slice(0, maxResults);

  } else {
    return err(res, 'Invalid filter — use coordinates or name');
  }

  ok(res, result, 30); // cache 30 s in CDN
});

// ─────────────────────────────────────────────────────────────────────────
//  GET /api/trips
// ─────────────────────────────────────────────────────────────────────────
//  Returns the user's trip history in compact format.
//  An active trip (dock == null) is marked with active: true.
//
//  Query params:
//    token   User's accessToken (from login)
//    userId  User's ID
//
//  The full EMT response is ~65 KB (28 trips with all fields).
//  This endpoint reduces it to ~7 KB by keeping only display-relevant fields.
//
//  Response: { code, data: [{id, bike, mins, cost, active, undock, dock}] }
// ─────────────────────────────────────────────────────────────────────────
app.get('/api/trips', async (req, res) => {
  const { token, userId } = req.query;
  if (!token || !userId) return err(res, 'Missing token or userId');

  const tripsRes = await fetch(`${APIEMTPAY_BASE}/v1/bicimad/trips/`, {
    headers: { 'accessToken': token, 'userId': userId, 'mode': 'mPass' },
  });

  if (!tripsRes.ok) return err(res, `EMT returned ${tripsRes.status}`, tripsRes.status);

  const data  = await tripsRes.json();
  const trips = data.data || [];

  const compact = trips.map(t => ({
    id:     t.trip_id || '',
    bike:   t.id_bike || '',
    mins:   +(t.trip_minutes || 0).toFixed(1),
    cost:   +(t.trip_cost    || 0).toFixed(2),
    active: !t.dock,
    undock: t.undock ? { name: t.undock.undock_station_name || '', ts: (t.undock.undock_ts || '').substring(0, 16) } : null,
    dock:   t.dock   ? { name: t.dock.dock_station_name     || '', ts: (t.dock.dock_ts     || '').substring(0, 16) } : null,
  }));

  ok(res, { code: data.code, data: compact }, 10);
});

// ─────────────────────────────────────────────────────────────────────────
//  GET /api/check
// ─────────────────────────────────────────────────────────────────────────
//  Verifies that a bike exists by its plate number and returns its location.
//  Used before confirming an unlock to show the user bike details.
//
//  Query params:
//    plate   Bike plate number (e.g. "15198")
//    token   User's accessToken
//    userId  User's ID
//
//  Calls: GET /v1/checkresource/bicimad/{plate}/
//
//  Response: { code, data: { number, docker, fleet, lat, lon } }
//    docker  = anchor/dock ID within the station
//    fleet   = 1 (BiciMAD Classic) or 2 (BiciMAD Go)
// ─────────────────────────────────────────────────────────────────────────
app.get('/api/check', async (req, res) => {
  const { plate, token, userId = '' } = req.query;
  if (!plate || !token) return err(res, 'Missing plate or token');

  const chkRes  = await fetch(`${APIEMTPAY_BASE}/v1/checkresource/bicimad/${plate}/`, {
    headers: {
      'accessToken':    token,
      'userId':         userId,
      'appName':        'BiciMAD',
      'appPlatform':    'Android',
      'appVersion':     '5.0.0',
      'language':       'ES',
      'deviceId':       'garmin-proxy',
      'Content-Type':   'application/octet-stream',
      'Accept-Charset': 'multipart/encrypted',
    },
  });

  if (chkRes.status === 401) return err(res, 'EMT returned 401', 401);
  const data = await chkRes.json();
  if (data.code !== '00') return res.json({ code: data.code, description: data.description });

  const b = data.data;
  ok(res, {
    code: '00',
    data: {
      number: b.number,
      docker: b.docker,
      fleet:  b.fleet,
      lat:    b.geometry?.coordinates?.[1],
      lon:    b.geometry?.coordinates?.[0],
    },
  }, 5);
});

// ─────────────────────────────────────────────────────────────────────────
//  GET /api/unlock
// ─────────────────────────────────────────────────────────────────────────
//  Unlocks a specific bike by plate number (starts a trip).
//  This implements the full cryptographic flow from the official BiciMAD app:
//
//  1. checkresource/{plate}/ — verify the bike and get docker/coordinates
//  2. Compute hashcode using DES encryption (reverse-engineered from APK):
//       plaintext = bikeNumber#docker#lon10#lat10#U#userId  (padded to 8n)
//       step1     = "B" + DES_ECB(plaintext, userId[0:8])  → hex uppercase
//       hashcode  = DES_ECB(step1 padded, operatorId[0:8]) → Base64
//  3. sellTicket — POST with hashcode header to start the trip
//
//  Query params:
//    plate   Bike plate number
//    token   User's accessToken
//    userId  User's ID
//    lat     User's latitude
//    lon     User's longitude
//
//  Response: { code, description, bike, docker }
// ─────────────────────────────────────────────────────────────────────────
app.get('/api/unlock', async (req, res) => {
  const { plate, token, userId, lat = '40.4168', lon = '-3.7038' } = req.query;
  if (!plate || !token || !userId) return err(res, 'Missing plate, token or userId');

  // Step 1: verify the bike
  const chkRes  = await fetch(`${APIEMTPAY_BASE}/v1/checkresource/bicimad/${plate}/`, {
    headers: {
      'accessToken': token, 'userId': userId,
      'appName': 'BiciMAD', 'appPlatform': 'Android', 'appVersion': '5.0.0',
      'language': 'ES', 'deviceId': 'garmin-proxy',
      'Content-Type': 'application/octet-stream', 'Accept-Charset': 'multipart/encrypted',
    },
  });
  if (chkRes.status === 401) return err(res, 'EMT returned 401', 401);
  const chkData = await chkRes.json();
  if (chkData.code !== '00') return err(res, `Bike not found: ${chkData.description}`, 404);

  const bike = chkData.data;

  // Step 2: compute hashcode (reverse-engineered from APK cifrarHashcode())
  const hashcode = computeHashcode(bike.number, bike.docker, parseFloat(lat), parseFloat(lon), userId, OPERATOR_ID);

  // Step 3: sell ticket (unlock the bike)
  // v2 + PUT confirmed working (v1/POST gives "Not valid xClientId")
  const stRes  = await fetch(`${APIEMTPAY_BASE}/v2/payment/qrcodesdk/sellticket/`, {
    method:  'PUT',
    headers: {
      'accessToken': token,
      'hashcode':    hashcode,
      'latitude':    lat.toString(),
      'longitude':   lon.toString(),
      'userId':      userId,
      'operatorId':  OPERATOR_ID,
      'appName':     'BiciMAD',
      'appPlatform': 'Android',
      'appVersion':  '5.0.0',
      'language':    'ES',
      'deviceId':    'garmin-proxy',
      'Content-Type': 'application/json',
    },
  });

  if (stRes.status === 401) return err(res, 'EMT returned 401', 401);
  const stData = await stRes.json();
  console.log(`[unlock] plate=${plate} code=${stData.code} — ${stData.description}`);

  ok(res, { code: stData.code, description: stData.description, bike: bike.number, docker: bike.docker });
});

// ─────────────────────────────────────────────────────────────────────────
//  DES hashcode implementation
//  Reverse-engineered from EMTingSDK QRService.cifrarHashcode()
// ─────────────────────────────────────────────────────────────────────────

function desEcbEncrypt(data, key8) {
  const k = Buffer.from(key8, 'utf-8').slice(0, 8);
  // NOTE: requires NODE_OPTIONS=--openssl-legacy-provider on Node.js >= 18
  // or use the pure-JS implementation below if DES is not available
  try {
    const c = crypto.createCipheriv('des-ecb', k, null);
    c.setAutoPadding(false);
    return Buffer.concat([c.update(Buffer.from(data, 'utf-8')), c.final()]);
  } catch {
    // Fallback to pure JS DES if OpenSSL legacy DES is unavailable
    return desEcbJS(Buffer.from(data, 'utf-8'), k);
  }
}

function computeHashcode(bikeNumber, docker, lat, lon, userId, operatorId) {
  // Normalize lon/lat to exactly 10 characters
  let lonStr = lon.toString();
  lonStr = lonStr.length >= 10 ? lonStr.substring(0, 10) : lonStr.padEnd(10, '0');
  let latStr = lat.toString();
  latStr = latStr.length >= 10 ? latStr.substring(0, 10) : latStr.padEnd(10, '0');

  // Build plaintext
  let str = `${bikeNumber}#${docker}#${lonStr}#${latStr}#U#${userId}`;
  const rem1 = str.length % 8;
  if (rem1 !== 0) str += '#'.repeat(8 - rem1);

  // First DES pass: encrypt with first 8 chars of userId → hex uppercase
  const hex = desEcbEncrypt(str, userId.substring(0, 8)).toString('hex').toUpperCase();

  // Prepend hash type and pad to multiple of 8
  let str2 = 'B' + hex;
  const rem2 = str2.length % 8;
  if (rem2 !== 0) str2 += 'Z'.repeat(8 - rem2);

  // Second DES pass: encrypt with first 8 chars of operatorId UPPERCASE → Base64
  return desEcbEncrypt(str2, operatorId.toUpperCase().substring(0, 8)).toString('base64');
}

// ── Pure-JS DES (ECB, no padding) as fallback ────────────────────────────
// Used when Node.js OpenSSL 3 blocks legacy DES algorithm.
function desEcbJS(data, key) {
  const enc = desEncryptor(key);
  const out  = Buffer.alloc(data.length);
  for (let i = 0; i < data.length; i += 8) enc(data.slice(i, i + 8)).copy(out, i);
  return out;
}

function desEncryptor(key8) {
  const PC1=[57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4];
  const PC2=[14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32];
  const IP=[58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7];
  const IP2=[40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25];
  const E=[32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1];
  const P=[16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25];
  const S=[[14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],[15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],[10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],[7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14],[2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],[12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],[4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],[13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11]];
  const SH=[1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1];
  const gb=(b,n)=>(b[Math.floor((n-1)/8)]>>(7-(n-1)%8))&1;
  const pm=(s,t)=>{const o=new Uint8Array(Math.ceil(t.length/8));for(let i=0;i<t.length;i++){if(gb(s,t[i]))o[Math.floor(i/8)]|=1<<(7-i%8);}return o;};
  const rl=(h,n)=>{const a=[...h];for(let i=0;i<n;i++){const b=a[0];a.shift();a.push(b);}return a;};
  const k=new Uint8Array(key8);
  const kp=pm(k,PC1);
  let C=Array.from({length:28},(_,i)=>gb(kp,i+1));
  let D=Array.from({length:28},(_,i)=>gb(kp,i+29));
  const sks=[];
  for(let r=0;r<16;r++){C=rl(C,SH[r]);D=rl(D,SH[r]);const cd=[...C,...D];const cb=new Uint8Array(7);for(let i=0;i<56;i++)if(cd[i])cb[Math.floor(i/8)]|=1<<(7-i%8);sks.push(pm(cb,PC2));}
  return function(blk){
    const d=new Uint8Array(blk);let lr=pm(d,IP);
    let L=Array.from({length:32},(_,i)=>gb(lr,i+1));
    let R=Array.from({length:32},(_,i)=>gb(lr,i+33));
    for(let r=0;r<16;r++){
      const rb=new Uint8Array(4);for(let i=0;i<32;i++)if(R[i])rb[Math.floor(i/8)]|=1<<(7-i%8);
      const er=pm(rb,E);const sk=sks[r];const xr=er.map((b,i)=>b^(sk[i]||0));
      let f=[];
      for(let s=0;s<8;s++){const row=(xr[Math.floor(s*6/8)]>>(7-s*6%8)&1)<<1|(xr[Math.floor((s*6+5)/8)]>>(7-(s*6+5)%8)&1);let col=0;for(let c=1;c<=4;c++)col=(col<<1)|((xr[Math.floor((s*6+c)/8)]>>(7-(s*6+c)%8))&1);const v=S[s][row*16+col];for(let b=3;b>=0;b--)f.push((v>>b)&1);}
      const fb=new Uint8Array(4);for(let i=0;i<32;i++)if(f[i])fb[Math.floor(i/8)]|=1<<(7-i%8);
      const pf=pm(fb,P);const nr=L.map((_,i)=>_^gb(pf,i+1));L=R;R=nr;
    }
    const o=new Uint8Array(8);for(let i=0;i<32;i++)if(R[i])o[Math.floor(i/8)]|=1<<(7-i%8);for(let i=0;i<32;i++)if(L[i])o[4+Math.floor(i/8)]|=1<<(7-i%8);
    return Buffer.from(pm(o,IP2));
  };
}

// ── Start ──────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`BiciMAD proxy running on http://localhost:${PORT}`);
  console.log('Endpoints:');
  console.log('  GET /api/stations?filter=coordinates&value=40.41,-3.70');
  console.log('  GET /api/stations?filter=name&value=callao');
  console.log('  GET /api/trips?token=TOKEN&userId=USER_ID');
  console.log('  GET /api/check?plate=15198&token=TOKEN&userId=USER_ID');
  console.log('  GET /api/unlock?plate=15198&token=TOKEN&userId=USER_ID&lat=40.41&lon=-3.70');
});
