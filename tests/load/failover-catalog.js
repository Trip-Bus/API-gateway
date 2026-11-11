// =============================================================================
//  Escenario de calidad 1.1 (despliegue distribuido, docs/despliegue-distribuido.md): carga constante
//  sobre Catalog a través del API Gateway mientras se detiene y se vuelve a arrancar la réplica del
//  nodo B. NGINX debe reintentar en la otra réplica (proxy_next_upstream): cero respuestas 5xx.
//
//  Cada usuario virtual se presenta con su propia IP (CF-Connecting-IP) para no chocar con el límite por
//  IP del gateway. k6 corre en la red de Docker del nodo A:
//
//    docker run --rm -i --network tripbus-nodo-a_default -v "${PWD}/tests/load:/scripts:ro" grafana/k6:1.2.3 \
//      run -e API=http://api-gateway:18000 /scripts/failover-catalog.js
//
//  Variables: API, RPS (50 peticiones por segundo), DURACION (3m), RUTA (/routes, GET público de Catalog).
// =============================================================================
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import exec from 'k6/execution';

const API = __ENV.API || 'http://localhost:18000';
const RPS = Number(__ENV.RPS || 50);
const DURACION = __ENV.DURACION || '3m';
const RUTA = __ENV.RUTA || '/routes';

const errores5xx = new Counter('errores_5xx');

export const options = {
  scenarios: {
    carga: {
      executor: 'constant-arrival-rate',
      rate: RPS,
      timeUnit: '1s',
      duration: DURACION,
      preAllocatedVUs: 50,
      maxVUs: 200,
    },
  },
  thresholds: {
    errores_5xx: ['count==0'],
    http_req_failed: ['rate==0'],
  },
};

// 2xx, 3xx y 4xx son respuestas esperadas: http_req_failed = 5xx o error de red.
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

export default function () {
  const vu = exec.vu.idInTest;
  const ip = `10.${(vu >> 16) & 255}.${(vu >> 8) & 255}.${vu & 255}`;
  const res = http.get(`${API}${RUTA}`, { headers: { 'CF-Connecting-IP': ip } });
  if (res.status >= 500 || res.status === 0) {
    errores5xx.add(1);
  }
  check(res, { 'sin 5xx': (r) => r.status > 0 && r.status < 500 });
}
