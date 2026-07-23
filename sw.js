// Service worker de Fumigaciones AECO.
// Rutas relativas a proposito: este SW se registra con scope './'. Hoy se
// sirve desde la raiz del dominio propio (reportes.fumigacionesaeco.com,
// via CNAME de GitHub Pages), pero al ser todo relativo tambien funcionaria
// igual si en el futuro se sirve desde una subruta. Nada aqui debe
// empezar con "/".

const CACHE_VERSION = 'v1';
const CACHE_NAME = 'aeco-shell-' + CACHE_VERSION;

const QR_LIB_URL = 'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js';

const APP_SHELL = [
  './',
  './index.html',
  './cotizaciones-plagas.html',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    await cache.addAll(APP_SHELL);
    try {
      // Aparte, sin bloquear la instalacion si no hay red en ese momento
      // (la libreria de QR solo se usa en la pestana Estaciones).
      await cache.add(QR_LIB_URL);
    } catch (e) {
      console.warn('SW: no se pudo precachear la libreria de QR (se cacheara en el primer uso online):', e);
    }
    self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const nombres = await caches.keys();
    await Promise.all(nombres.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;

  if (req.method !== 'GET') return; // no interceptar POST/PATCH/DELETE, etc.

  const url = new URL(req.url);

  // Supabase (auth, REST, todo lo dinamico): siempre red, nunca cache.
  if (url.hostname.endsWith('.supabase.co')) return;

  const esMismoOrigen = url.origin === self.location.origin;
  const esLibreriaQr = req.url.startsWith('https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/');

  if (!esMismoOrigen && !esLibreriaQr) return; // cualquier otro origen: pasa de largo

  // App shell y libreria QR: cache-first (abre sin señal), actualizando en
  // segundo plano cuando hay red para que la proxima carga ya traiga lo nuevo.
  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    const cacheado = await cache.match(req, { ignoreSearch: true });
    const actualizarEnRed = fetch(req)
      .then((res) => {
        if (res && res.status === 200) cache.put(req, res.clone());
        return res;
      })
      .catch(() => cacheado);
    return cacheado || actualizarEnRed;
  })());
});
