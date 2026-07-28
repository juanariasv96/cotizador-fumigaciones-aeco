// Service worker de Fumigaciones AECO.
// Rutas relativas a proposito: este SW se registra con scope './'. Hoy se
// sirve desde la raiz del dominio propio (reportes.fumigacionesaeco.com,
// via CNAME de GitHub Pages), pero al ser todo relativo tambien funcionaria
// igual si en el futuro se sirve desde una subruta. Nada aqui debe
// empezar con "/".

const CACHE_VERSION = 'v3';
const CACHE_NAME = 'aeco-shell-' + CACHE_VERSION;

const QR_LIB_URL = 'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js';
const HTML2PDF_LIB_URL = 'https://cdnjs.cloudflare.com/ajax/libs/html2pdf.js/0.10.1/html2pdf.bundle.min.js';

// Documentos HTML: se actualizan seguido (nuevas pestanas/funciones), asi
// que van con network-first mas abajo, nunca cache-first.
const HTML_DOCUMENTOS = [
  './',
  './index.html',
  './cotizaciones-plagas.html',
];

// Assets estaticos: cambian poco, cache-first esta bien para ellos.
const ASSETS_ESTATICOS = [
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png',
];

const APP_SHELL = [...HTML_DOCUMENTOS, ...ASSETS_ESTATICOS];

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
    try {
      // Igual para html2pdf.js (Descargar PDF del certificado): si no hay
      // red al instalar, se cachea sola la primera vez que se use online.
      await cache.add(HTML2PDF_LIB_URL);
    } catch (e) {
      console.warn('SW: no se pudo precachear html2pdf.js (se cacheara en el primer uso online):', e);
    }
    // Toma control de inmediato: no espera a que se cierren las pestanas
    // viejas para que el SW nuevo (y su CACHE_VERSION) entre en accion.
    self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    // Borra cualquier cache de una version anterior (aeco-shell-v1, etc.):
    // asi cada bump de CACHE_VERSION limpia lo viejo automaticamente.
    const nombres = await caches.keys();
    await Promise.all(nombres.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)));
    await self.clients.claim();
  })());
});

// Network-first: intenta la red primero y siempre aplica lo que llegue de
// ahi de inmediato (no un load despues, como pasaba con cache-first). Si no
// hay red, cae al HTML cacheado para que la app siga abriendo offline.
async function networkFirstConFallback(req){
  const cache = await caches.open(CACHE_NAME);
  try {
    const resRed = await fetch(req);
    if (resRed && resRed.status === 200) cache.put(req, resRed.clone());
    return resRed;
  } catch (e) {
    const cacheado = await cache.match(req, { ignoreSearch: true });
    if (cacheado) return cacheado;
    throw e;
  }
}

// Cache-first con actualizacion en segundo plano (para assets estaticos y
// la libreria QR externa): responde rapido desde cache, y de paso refresca
// el cache con la red para la proxima vez que ese asset cambie.
async function cacheFirstConActualizacion(req){
  const cache = await caches.open(CACHE_NAME);
  const cacheado = await cache.match(req, { ignoreSearch: true });
  const actualizarEnRed = fetch(req)
    .then((res) => {
      if (res && res.status === 200) cache.put(req, res.clone());
      return res;
    })
    .catch(() => cacheado);
  return cacheado || actualizarEnRed;
}

function esDocumentoHtml(req, url){
  return req.mode === 'navigate' || url.pathname.endsWith('.html') || url.pathname.endsWith('/');
}

self.addEventListener('fetch', (event) => {
  const req = event.request;

  if (req.method !== 'GET') return; // no interceptar POST/PATCH/DELETE, etc.

  const url = new URL(req.url);

  // Supabase (auth, REST, todo lo dinamico): siempre red, nunca cache.
  if (url.hostname.endsWith('.supabase.co')) return;

  const esMismoOrigen = url.origin === self.location.origin;
  const esLibreriaQr = req.url.startsWith('https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/');
  const esLibreriaHtml2pdf = req.url.startsWith('https://cdnjs.cloudflare.com/ajax/libs/html2pdf.js/');

  if (!esMismoOrigen && !esLibreriaQr && !esLibreriaHtml2pdf) return; // cualquier otro origen: pasa de largo

  if (esMismoOrigen && esDocumentoHtml(req, url)) {
    event.respondWith(networkFirstConFallback(req));
    return;
  }

  event.respondWith(cacheFirstConActualizacion(req));
});
