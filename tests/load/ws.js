// =============================================================================
//  Prueba de carga del WebSocket (HT-15): 1.000 conexiones (VUS) a través del API Gateway (/ws), todas
//  suscritas a ofertas:activas (tópico público) durante 2 minutos (DURACION).
//
//  Umbrales: ≥ 99 % de conexiones abiertas (101) y suscritas (snapshot recibido), cero cierres
//  inesperados y handshake p95 < 1 s.
//
//  Cada conexión se presenta con su propia IP (CF-Connecting-IP) para no chocar con el límite de
//  conexiones por IP (20, HT-11): el gateway la cree si la conexión viene de REAL_IP_FROM (las redes de
//  Docker) y el Realtime cuenta por el último X-Forwarded-For. Por eso k6 corre en la red de Docker de QA:
//
//    docker run --rm -i --network tripbus-qa_default -v "$PWD/tests/load:/scripts:ro" grafana/k6:1.2.3 \
//      run -e WS=ws://api-gateway:18000/ws /scripts/ws.js
// =============================================================================
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import exec from 'k6/execution';

const WS = __ENV.WS || 'ws://localhost:18000/ws';
const VUS = Number(__ENV.VUS || 1000);
const DURACION_MS = Number(__ENV.DURACION_S || 120) * 1000;
// Origen permitido por WS_ALLOWED_ORIGINS en QA (el frontend servido por el gateway).
const ORIGIN = __ENV.ORIGIN || 'http://localhost:18000';

const conectadas = new Rate('ws_conectadas');
const suscritas = new Rate('ws_suscritas');
const cierresInesperados = new Counter('ws_cierres_inesperados');
const mensajes = new Counter('ws_mensajes_recibidos');
const tiempoSnapshot = new Trend('ws_tiempo_hasta_snapshot', true);

export const options = {
  scenarios: {
    // Una conexión por usuario virtual; se abren repartidas en los primeros 30 s y cada una dura DURACION.
    conexiones: { executor: 'per-vu-iterations', vus: VUS, iterations: 1, maxDuration: `${DURACION_MS / 1000 + 90}s` },
  },
  thresholds: {
    ws_conectadas: ['rate>=0.99'],
    ws_suscritas: ['rate>=0.99'],
    ws_cierres_inesperados: ['count==0'],
    ws_connecting: ['p(95)<1000'],
  },
};

const ip = (n) => `10.${100 + ((n >> 16) & 127)}.${(n >> 8) & 255}.${n & 255}`;

export default function () {
  const n = exec.vu.idInTest;
  sleep(((n - 1) * 30) / VUS);
  const inicio = Date.now();
  let suscrita = false;
  let cerradaPorMi = false;

  const res = ws.connect(WS, { headers: { 'CF-Connecting-IP': ip(n), Origin: ORIGIN }, tags: { prueba: 'ws' } }, (socket) => {
    socket.on('open', () => socket.send(JSON.stringify({ type: 'subscribe', topic: 'ofertas:activas' })));
    socket.on('message', (raw) => {
      mensajes.add(1);
      let m; try { m = JSON.parse(raw); } catch (e) { return; }
      if (m.type === 'ping') socket.send(JSON.stringify({ type: 'pong' }));   // el servidor corta a los 45 s sin pong
      if (m.type === 'snapshot' && !suscrita) { suscrita = true; tiempoSnapshot.add(Date.now() - inicio); }
      if (m.type === 'error') console.warn(`VU ${n}: ${raw}`);
    });
    socket.on('close', (code) => { if (!cerradaPorMi) { cierresInesperados.add(1, { code: String(code) }); } });
    socket.setTimeout(() => { cerradaPorMi = true; socket.close(); }, DURACION_MS);
  });

  conectadas.add(res && res.status === 101);
  suscritas.add(suscrita);
  check(res, { 'handshake 101': (r) => r && r.status === 101 });
}
