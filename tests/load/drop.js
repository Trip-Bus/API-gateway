// =============================================================================
//  Prueba de carga (HT-15): un "drop" de oferta relámpago a través del API Gateway.
//  500 usuarios virtuales (VUS) consultan la vitrina y compiten por una oferta de cupo 50 (CUPO).
//  Cada ganador compra su puesto (reserva + pago con la pasarela de prueba).
//
//  Umbrales:  cero respuestas 5xx · p95 < 800 ms (solo la competencia, no la preparación) ·
//             exactamente CUPO reservas exitosas y CUPO ventas en las métricas de la oferta.
//  Los 429 (rate limit) y los 409 (agotada, límite por persona) son respuestas correctas.
//
//  Cada usuario virtual se presenta con su propia IP (header CF-Connecting-IP, el mismo que pone el túnel
//  de Cloudflare): el gateway la cree si la conexión viene de REAL_IP_FROM (las redes de Docker), así los
//  límites por IP se aplican por usuario y no a todo k6. Por eso k6 corre en la red de Docker de QA:
//
//    docker run --rm -i --network tripbus-qa_default -v "$PWD/tests/load:/scripts:ro" grafana/k6:1.2.3 \
//      run -e API=http://api-gateway:18000 /scripts/drop.js
//
//  Variables: API, VUS (500), CUPO (50), DEMO_USERS_PASSWORD (TripBus2026), ORIGEN/DESTINO (Bogotá/Medellín).
//  Requiere QA con el seed y los usuarios de demostración.
// =============================================================================
import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Counter, Gauge } from 'k6/metrics';
import exec from 'k6/execution';

const API = __ENV.API || 'http://localhost:18000';
const VUS = Number(__ENV.VUS || 500);
const CUPO = Number(__ENV.CUPO || 50);
const PASS = __ENV.DEMO_USERS_PASSWORD || 'TripBus2026';
const ORIGEN = __ENV.ORIGEN || 'Bogotá';
const DESTINO = __ENV.DESTINO || 'Medellín';
const RUN = `${Date.now()}`;

const errores5xx = new Counter('errores_5xx');
const reservasOk = new Counter('reservas_ok');
const rechazos = new Counter('reservas_rechazadas');
const limitadas = new Counter('respuestas_429');
const comprasOk = new Counter('compras_ok');
const ventasOferta = new Gauge('ventas_oferta');

// 2xx, 3xx y 4xx son respuestas esperadas (429 = rate limit, 409 = agotada): http_req_failed = 5xx o red.
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

export const options = {
  setupTimeout: '15m',
  teardownTimeout: '5m',
  scenarios: {
    drop: { executor: 'per-vu-iterations', vus: VUS, iterations: 1, maxDuration: '5m' },
  },
  thresholds: {
    errores_5xx: ['count==0'],
    http_req_failed: ['rate==0'],
    'http_req_duration{fase:drop}': ['p(95)<800'],
    reservas_ok: [`count==${CUPO}`],
    ventas_oferta: [`value==${CUPO}`],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'max'],
};

// IP ficticia y documento únicos por número de usuario (1..VUS).
const ip = (n) => `10.${(n >> 16) & 255}.${(n >> 8) & 255}.${n & 255}`;
const doc = (n) => `9${RUN.slice(-6)}${String(n).padStart(4, '0')}`;

function params(token, n, fase) {
  const headers = { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip(n) };
  if (token) headers.Authorization = `Bearer ${token}`;
  return { headers, tags: { fase } };
}

function contar(res) {
  if (res.status >= 500) errores5xx.add(1, { url: res.request.url });
  if (res.status === 429) limitadas.add(1);
  return res;
}

function json(res, path) {
  try { return res.json(path); } catch (e) { return undefined; }
}

function login(email, n) {
  const r = http.post(`${API}/auth/login`, JSON.stringify({ email, password: PASS }), params(null, n, 'setup'));
  const t = json(r, 'accessToken');
  if (!t) fail(`login de ${email}: ${r.status} ${r.body}`);
  return t;
}

function manana() {
  const d = new Date(Date.now() + 24 * 3600 * 1000 - 5 * 3600 * 1000); // fecha de Colombia
  return d.toISOString().slice(0, 10);
}

export function setup() {
  const admin = login('admin@tripbus.co', 70001);

  // 1. Un viaje de mañana con al menos CUPO asientos libres.
  const q = `origin=${encodeURIComponent(ORIGEN)}&destination=${encodeURIComponent(DESTINO)}&date=${manana()}`;
  const viajes = json(http.get(`${API}/trips/search?${q}`, params(null, 70002, 'setup'))) || [];
  let itinerario = null; let libres = [];
  for (const v of viajes) {
    const mapa = json(http.get(`${API}/seats/itineraries/${v.itineraryId}`, params(null, 70003, 'setup')));
    const disp = ((mapa && mapa.asientos) || []).filter((a) => a.estado === 'DISPONIBLE').map((a) => a.seatNumber);
    if (disp.length >= CUPO) { itinerario = v; libres = disp.slice(0, CUPO); break; }
  }
  if (!itinerario) fail(`no hay un viaje ${ORIGEN}→${DESTINO} mañana con ${CUPO} asientos libres`);

  // 2. Se cierran las ofertas abiertas de ese viaje (no se pueden cruzar) y se crea la del drop.
  const abiertas = json(http.get(`${API}/operator/offers?size=100`, params(admin, 70004, 'setup')), 'content') || [];
  for (const o of abiertas) {
    if (o.oferta && o.oferta.itineraryId === itinerario.itineraryId && o.oferta.estado !== 'CERRADA') {
      http.post(`${API}/offers/${o.oferta.offerId}/close`, null, params(admin, 70004, 'setup'));
    }
  }
  const base = Number(json(http.get(`${API}/itineraries/${itinerario.itineraryId}`, params(null, 70005, 'setup')), 'precioBase'));
  const precioOferta = Math.round((base * 0.6) / 100) * 100;
  const inicio = new Date(Date.now() + 20 * 1000).toISOString();
  const fin = new Date(Date.now() + 30 * 60 * 1000).toISOString();
  const r = http.post(`${API}/offers`, JSON.stringify({
    itineraryId: itinerario.itineraryId, seatNumbers: libres, precioOferta, cupo: CUPO, inicio, fin,
  }), params(admin, 70006, 'setup'));
  const offerId = json(r, 'offerId');
  if (r.status !== 201 || !offerId) fail(`crear la oferta: ${r.status} ${r.body}`);

  // 3. VUS pasajeros nuevos, en lotes (el registro hashea la contraseña: es lo más lento de la preparación).
  const tokens = [];
  for (let desde = 1; desde <= VUS; desde += 50) {
    const lote = [];
    for (let n = desde; n < Math.min(desde + 50, VUS + 1); n++) {
      lote.push(['POST', `${API}/auth/register`, JSON.stringify({
        email: `carga.${RUN}.${n}@tripbus.co`, password: 'Passw0rd1', documentoIdentidad: `CC${doc(n)}`,
        nombre: `Carga ${n}`, aceptaPoliticaDatos: true,
      }), params(null, n, 'setup')]);
    }
    for (const res of http.batch(lote)) {
      const t = json(res, 'accessToken');
      if (!t) fail(`registro: ${res.status} ${res.body}`);
      tokens.push(t);
    }
  }

  // 4. Se espera a que la oferta quede ACTIVA (el scheduler de flash-offers la activa al llegar el inicio).
  for (let i = 0; i < 90; i++) {
    if (json(http.get(`${API}/offers/${offerId}`, params(null, 70007, 'setup')), 'estado') === 'ACTIVA') {
      return { offerId, tokens, admin, itineraryId: itinerario.itineraryId };
    }
    sleep(1);
  }
  fail(`la oferta ${offerId} no se activó`);
}

export default function (data) {
  const n = exec.vu.idInTest;
  const token = data.tokens[n - 1];

  // Vitrina y cupo, como haría la app antes de pulsar "Reservar".
  const vitrina = contar(http.get(`${API}/offers/showcase`, params(null, n, 'drop')));
  check(vitrina, { 'vitrina 200 o 429': (r) => r.status === 200 || r.status === 429 });
  contar(http.get(`${API}/offers/${data.offerId}/quota`, params(null, n, 'drop')));

  const r = contar(http.post(`${API}/offers/${data.offerId}/reservations`, JSON.stringify({ docId: doc(n) }),
    params(token, n, 'drop')));
  check(r, { 'reserva: 201, 409 o 429': (x) => [201, 409, 429].includes(x.status) });
  if (r.status !== 201) { rechazos.add(1, { status: String(r.status) }); return; }
  reservasOk.add(1);

  // Ganador: compra el puesto con la pasarela de prueba.
  const b = contar(http.post(`${API}/bookings`, JSON.stringify({
    holdId: json(r, 'holdId'),
    pasajeros: [{ nombre: `Carga ${n}`, tipoDocumento: 'CC', numeroDocumento: doc(n) }],
  }), params(token, n, 'compra')));
  const bookingId = json(b, 'bookingId');
  if (b.status !== 201 || !bookingId) { console.error(`reserva de compra ${n}: ${b.status} ${b.body}`); return; }
  const pagoParams = params(token, n, 'compra');
  pagoParams.headers['Idempotency-Key'] = `carga-${RUN}-${n}`;
  const p = contar(http.post(`${API}/bookings/${bookingId}/pay`,
    JSON.stringify({ cardToken: 'tok_visa_approved', cardLast4: '4242' }), pagoParams));
  if (check(p, { 'pago aceptado': (x) => x.status === 200 || x.status === 202 })) comprasOk.add(1);
}

// Las ventas se confirman de forma asíncrona (webhook → booking → evento → flash-offers): se esperan hasta
// 3 minutos en las métricas de la oferta.
export function teardown(data) {
  let ventas = -1;
  for (let i = 0; i < 90; i++) {
    const m = http.get(`${API}/offers/${data.offerId}/metrics`, params(data.admin, 70008, 'teardown'));
    if (m.status !== 200) { console.warn(`métricas de la oferta: ${m.status}`); break; }
    ventas = Number(json(m, 'ventas'));
    if (ventas >= CUPO) break;
    sleep(2);
  }
  const cupo = json(http.get(`${API}/offers/${data.offerId}/quota`, params(null, 70009, 'teardown')), 'cupoRestante');
  console.log(`oferta ${data.offerId}: ventas=${ventas}, cupo restante=${cupo}`);
  if (ventas >= 0) ventasOferta.add(ventas);
  http.post(`${API}/offers/${data.offerId}/close`, null, params(data.admin, 70010, 'teardown'));
}
