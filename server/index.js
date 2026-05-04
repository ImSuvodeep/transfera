const http = require('http');
const { Server } = require('socket.io');
const fs   = require('fs');
const path = require('path');

const buffers = new Map();
const lastOffsets = new Map(); // Store the last chunk offset per session for deduplication

// The tunnel URL is injected at startup by ready_for_remote.sh via an env variable.
// This allows the app to dynamically fetch the URL instead of having it hardcoded.
const TUNNEL_URL = process.env.TUNNEL_URL || '';
console.log(`[SERVER] Tunnel URL set to: ${TUNNEL_URL || '(none - local only mode)'}`);

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, x-chunk-offset');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  // Dynamic config endpoint - app fetches this at startup to get the live tunnel URL
  if (req.method === 'GET' && req.url === '/config') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ tunnelUrl: TUNNEL_URL }));
    return;
  }

  // ── App download endpoints ─────────────────────────────────────────────────
  if (req.method === 'GET' && req.url === '/download/android') {
    const apkPath = path.join(__dirname, 'Transfera-Android.apk');
    if (!fs.existsSync(apkPath)) {
      res.writeHead(404); res.end('APK not found'); return;
    }
    const stat = fs.statSync(apkPath);
    res.writeHead(200, {
      'Content-Type': 'application/vnd.android.package-archive',
      'Content-Disposition': 'attachment; filename="Transfera.apk"',
      'Content-Length': stat.size,
    });
    fs.createReadStream(apkPath).pipe(res);
    return;
  }

  if (req.method === 'GET' && req.url === '/download/macos') {
    const zipPath = path.join(__dirname, 'Transfera-macOS.zip');
    if (!fs.existsSync(zipPath)) {
      res.writeHead(404); res.end('macOS build not found'); return;
    }
    const stat = fs.statSync(zipPath);
    res.writeHead(200, {
      'Content-Type': 'application/zip',
      'Content-Disposition': 'attachment; filename="Transfera-macOS.zip"',
      'Content-Length': stat.size,
    });
    fs.createReadStream(zipPath).pipe(res);
    return;
  }

  // ── Proxy: fetches a remote file and forces download (fixes cross-origin inline preview) ──
  if (req.method === 'GET' && req.url.startsWith('/proxy')) {
    const proxyUrl  = new URL(req.url, 'http://localhost');
    const targetUrl = proxyUrl.searchParams.get('url');
    const fileName  = proxyUrl.searchParams.get('name') || 'download';

    if (!targetUrl || !targetUrl.startsWith('http')) {
      res.writeHead(400); res.end('Missing or invalid url param'); return;
    }

    // Only allow known safe hosts
    const allowedHosts = ['litter.catbox.moe', 'files.catbox.moe'];
    let targetHost;
    try { targetHost = new URL(targetUrl).hostname; } catch { targetHost = ''; }
    if (!allowedHosts.includes(targetHost)) {
      res.writeHead(403); res.end('Host not allowed'); return;
    }

    const https = require('https');
    const proxyReq = https.get(targetUrl, (proxyRes) => {
      const contentType = proxyRes.headers['content-type'] || 'application/octet-stream';
      const safeFileName = fileName.replace(/[^a-zA-Z0-9._\- ()]/g, '_');
      res.writeHead(200, {
        'Content-Type': contentType,
        'Content-Disposition': `attachment; filename="${safeFileName}"`,
        'Content-Length': proxyRes.headers['content-length'] || '',
        'Cache-Control': 'no-store',
      });
      proxyRes.pipe(res);
    });

    proxyReq.on('error', (e) => {
      console.error('[PROXY] Error:', e.message);
      if (!res.headersSent) { res.writeHead(502); res.end('Proxy error'); }
    });
    return;
  }

  // ── External Share Landing Page ────────────────────────────────────────────
  // Query params: dl (gofile direct link), name (file/folder name), size (bytes), count (file count)
  if (req.method === 'GET' && req.url.startsWith('/share')) {
    const urlObj = new URL(req.url, 'http://localhost');
    const dlLink  = urlObj.searchParams.get('dl')    || '';
    const name    = urlObj.searchParams.get('name')  || 'File';
    const sizeB   = parseInt(urlObj.searchParams.get('size')  || '0', 10);
    const count   = parseInt(urlObj.searchParams.get('count') || '1', 10);

    // Human-readable size
    function fmtSize(b) {
      if (b >= 1e9) return (b / 1e9).toFixed(1) + ' GB';
      if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB';
      if (b >= 1e3) return (b / 1e3).toFixed(1) + ' KB';
      return b + ' B';
    }

    const sizeStr = sizeB > 0 ? fmtSize(sizeB) : '';
    const fileLabel = count > 1 ? `${count} files` : name;
    const subLabel  = count > 1 ? name : (sizeStr || '');

    const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Transfera — ${fileLabel}</title>
  <meta name="description" content="Download ${fileLabel} shared via Transfera" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;700;800&display=swap" rel="stylesheet" />
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --purple: #BB86FC;
      --teal:   #03DAC6;
      --bg:     #050505;
      --card:   rgba(255,255,255,0.045);
      --border: rgba(255,255,255,0.08);
    }

    body {
      font-family: 'Outfit', sans-serif;
      background: var(--bg);
      min-height: 100svh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 24px 16px;
      overflow-x: hidden;
    }

    /* Animated mesh background */
    body::before {
      content: '';
      position: fixed;
      inset: 0;
      background:
        radial-gradient(ellipse 80% 60% at 20% 10%, rgba(187,134,252,0.12) 0%, transparent 60%),
        radial-gradient(ellipse 60% 50% at 80% 90%, rgba(3,218,198,0.08) 0%, transparent 60%),
        radial-gradient(ellipse 40% 40% at 50% 50%, rgba(98,0,238,0.06) 0%, transparent 70%);
      animation: meshMove 12s ease-in-out infinite alternate;
      pointer-events: none;
      z-index: 0;
    }

    @keyframes meshMove {
      0%   { opacity: 0.7; transform: scale(1)   rotate(0deg); }
      100% { opacity: 1;   transform: scale(1.05) rotate(2deg); }
    }

    .container {
      position: relative;
      z-index: 1;
      width: 100%;
      max-width: 420px;
    }

    /* Logo / Brand */
    .brand {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-bottom: 32px;
      justify-content: center;
    }
    .brand-icon {
      width: 36px; height: 36px;
      background: linear-gradient(135deg, var(--purple), var(--teal));
      border-radius: 10px;
      display: flex; align-items: center; justify-content: center;
      font-size: 18px;
    }
    .brand-name {
      font-size: 22px; font-weight: 700;
      background: linear-gradient(90deg, var(--purple), var(--teal));
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
      background-clip: text;
    }

    /* Main card */
    .card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 28px;
      padding: 36px 28px 32px;
      backdrop-filter: blur(24px);
      -webkit-backdrop-filter: blur(24px);
      box-shadow: 0 8px 40px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.06);
      animation: cardIn 0.6s cubic-bezier(0.34,1.56,0.64,1) both;
    }

    @keyframes cardIn {
      from { opacity: 0; transform: translateY(24px) scale(0.96); }
      to   { opacity: 1; transform: translateY(0)    scale(1); }
    }

    /* File icon area */
    .file-icon-wrap {
      width: 80px; height: 80px;
      border-radius: 20px;
      background: rgba(187,134,252,0.1);
      border: 1px solid rgba(187,134,252,0.2);
      display: flex; align-items: center; justify-content: center;
      font-size: 36px;
      margin: 0 auto 20px;
      animation: pulse 3s ease-in-out infinite;
    }
    @keyframes pulse {
      0%, 100% { box-shadow: 0 0 0 0 rgba(187,134,252,0.15); }
      50%       { box-shadow: 0 0 0 12px rgba(187,134,252,0); }
    }

    .file-name {
      font-size: 20px; font-weight: 700; color: #fff;
      text-align: center; margin-bottom: 6px;
      word-break: break-word;
    }
    .file-meta {
      font-size: 13px; color: rgba(255,255,255,0.4);
      text-align: center; margin-bottom: 28px;
      letter-spacing: 0.5px;
    }

    /* Divider */
    .divider {
      height: 1px;
      background: linear-gradient(90deg, transparent, var(--border), transparent);
      margin-bottom: 24px;
    }

    /* Buttons */
    .btn {
      display: flex; align-items: center; justify-content: center; gap: 10px;
      width: 100%; padding: 16px;
      border: none; border-radius: 16px;
      font-family: 'Outfit', sans-serif;
      font-size: 16px; font-weight: 600;
      cursor: pointer; text-decoration: none;
      transition: transform 0.15s, box-shadow 0.15s, opacity 0.15s;
      margin-bottom: 12px;
    }
    .btn:active { transform: scale(0.97); }

    .btn-primary {
      background: linear-gradient(135deg, var(--purple), #7B2FFF);
      color: #fff;
      box-shadow: 0 4px 20px rgba(187,134,252,0.35);
    }
    .btn-primary:hover { box-shadow: 0 6px 28px rgba(187,134,252,0.5); transform: translateY(-1px); }

    .btn-secondary {
      background: rgba(255,255,255,0.05);
      color: rgba(255,255,255,0.8);
      border: 1px solid var(--border);
    }
    .btn-secondary:hover { background: rgba(255,255,255,0.09); }

    /* Platform dropdown */
    .platform-list {
      display: none;
      flex-direction: column;
      gap: 8px;
      margin-top: 4px;
      margin-bottom: 12px;
      animation: fadeDown 0.25s ease both;
    }
    .platform-list.open { display: flex; }

    @keyframes fadeDown {
      from { opacity: 0; transform: translateY(-8px); }
      to   { opacity: 1; transform: translateY(0); }
    }

    .platform-btn {
      display: flex; align-items: center; gap: 10px;
      padding: 12px 16px;
      border-radius: 12px;
      background: rgba(255,255,255,0.04);
      border: 1px solid var(--border);
      color: rgba(255,255,255,0.75);
      text-decoration: none;
      font-family: 'Outfit', sans-serif;
      font-size: 14px; font-weight: 500;
      transition: background 0.15s;
    }
    .platform-btn:hover { background: rgba(255,255,255,0.08); }
    .platform-btn .icon { font-size: 20px; width: 24px; text-align: center; }

    /* Shared by tag */
    .shared-tag {
      text-align: center;
      margin-top: 24px;
      font-size: 12px;
      color: rgba(255,255,255,0.2);
      letter-spacing: 0.5px;
    }
    .shared-tag span {
      background: linear-gradient(90deg, var(--purple), var(--teal));
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
      background-clip: text;
      font-weight: 600;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="brand">
      <div class="brand-icon">⚡</div>
      <div class="brand-name">Transfera</div>
    </div>

    <div class="card">
      <div class="file-icon-wrap">${count > 1 ? '📁' : '📦'}</div>
      <div class="file-name">${fileLabel.replace(/</g,'&lt;').replace(/>/g,'&gt;')}</div>
      <div class="file-meta">${subLabel ? subLabel.replace(/</g,'&lt;') + (count > 1 && sizeStr ? ' &nbsp;·&nbsp; ' + sizeStr : '') : ''}</div>

      <div class="divider"></div>

      ${dlLink ? `<a id="dlBtn" class="btn btn-primary" href="${dlLink.replace(/"/g, '&quot;')}" download>
        <span>⬇</span> Download File
      </a>` : `<div class="btn btn-primary" style="opacity:0.4;cursor:not-allowed">
        <span>⚠</span> Link Unavailable
      </div>`}

      <button class="btn btn-secondary" id="appBtn" onclick="handleAppDownload()">
        <span>📲</span> Download Transfera
      </button>

      <!-- Rendered by JS based on detected platform -->
      <div id="platformInfo" style="display:none;margin-top:8px;text-align:center;font-size:12px;color:rgba(255,255,255,0.35);line-height:1.6;"></div>
    </div>

    <div class="shared-tag">Shared securely via <span>Transfera</span></div>
  </div>

  <script>
    // ── Platform detection ───────────────────────────────────────────────────
    const ua  = navigator.userAgent || '';
    const isAndroid = /android/i.test(ua);
    const isIOS     = /iphone|ipad|ipod/i.test(ua);
    const isMac     = /macintosh|mac os x/i.test(ua) && !isIOS;
    const isWindows = /windows/i.test(ua);
    const isLinux   = /linux/i.test(ua) && !isAndroid;

    const TUNNEL = 'https://transfera-server.onrender.com';

    // Map platform → {label, icon, url, note}
    function getPlatformInfo() {
      if (isAndroid) return {
        label : 'Download for Android',
        icon  : '🤖',
        url   : TUNNEL + '/download/android',
        note  : 'APK · Enable "Install from unknown sources" in Settings',
        direct: true,
      };
      if (isMac) return {
        label : 'Download for macOS',
        icon  : '💻',
        url   : TUNNEL + '/download/macos',
        note  : 'After opening: right-click the app → Open to bypass Gatekeeper',
        direct: true,
      };
      if (isIOS) return {
        label : 'Coming soon on iOS',
        icon  : '🍎',
        url   : null,
        note  : 'iOS version is in development. Check back soon!',
        direct: false,
      };
      if (isWindows) return {
        label : 'Coming soon on Windows',
        icon  : '🪟',
        url   : null,
        note  : 'Windows version is in development. Star us on GitHub to get notified.',
        direct: false,
      };
      return {
        label : 'View on GitHub',
        icon  : '🐧',
        url   : 'https://github.com/ImSuvodeep/transfera/releases/latest',
        note  : '',
        direct: true,
      };
    }

    // Update the "Download Transfera" button to show the right label
    (function initBtn() {
      const p   = getPlatformInfo();
      const btn = document.getElementById('appBtn');
      btn.innerHTML = '<span>' + p.icon + '</span> ' + p.label;
      if (!p.url) {
        btn.style.opacity = '0.55';
        btn.style.cursor  = 'default';
      }
    })();

    function handleAppDownload() {
      const p    = getPlatformInfo();
      const info = document.getElementById('platformInfo');

      if (!p.url) {
        // Not available — show the note
        info.style.display = 'block';
        info.textContent   = p.note;
        return;
      }

      // Navigate to download
      window.location.href = p.url;

      // Show the install note below the button
      if (p.note) {
        info.style.display = 'block';
        info.textContent   = p.note;
      }
    }
  </script>
</body>
</html>`;

    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
    return;
  }

  if (req.method === 'POST' && req.url.startsWith('/relay/')) {
    let sid = req.url.split('/')[2];
    if (codes.has(sid)) sid = codes.get(sid);
    
    const offsetHeader = req.headers['x-chunk-offset'];
    
    let body = [];
    req.on('data', (chunk) => body.push(chunk));
    req.on('end', () => {
      // DEDUPLICATION LOGIC:
      // If a network connection drops mid-upload, the Sender might timeout and resend the identical chunk.
      // We must drop the exact duplicate to prevent inserting redundant bytes into the stream and corrupting the AES offset.
      if (offsetHeader) {
        const lastOffset = lastOffsets.get(sid);
        const queue = buffers.get(sid);
        // Only deduplicate if the queue is non-empty (mid-file retry).
        // If queue is empty, the sender started a NEW file (offset resets to 0),
        // so we must accept this chunk even if the offset matches the last one.
        if (lastOffset === offsetHeader && queue && queue.length > 0) {
          console.log(`[SERVER] Ignored duplicate HTTP POST chunk for session ${sid} at offset ${offsetHeader}`);
          res.writeHead(200);
          res.end('ok');
          return;
        }
        lastOffsets.set(sid, offsetHeader);
      }
      
      const buffer = Buffer.concat(body);
      if (!buffers.has(sid)) buffers.set(sid, []);
      buffers.get(sid).push(buffer);
      console.log(`[SERVER] Received HTTP POST chunk for session ${sid} at offset ${offsetHeader || 'unknown'}. Queue size: ${buffers.get(sid).length}`);
      io.to(sid).emit('relay-ready');
      res.writeHead(200);
      res.end('ok');
    });
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/relay/')) {
    let sid = req.url.split('/')[2];
    if (codes.has(sid)) sid = codes.get(sid);
    
    const queue = buffers.get(sid);
    if (queue && queue.length > 0) {
      const data = queue.shift();
      console.log(`[SERVER] Served HTTP GET chunk for session ${sid}. Remaining: ${queue.length}`);
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(data);
    } else {
      res.writeHead(404);
      res.end('not found');
    }
    return;
  }
});

const io = new Server(server, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  },
  maxHttpBufferSize: 1e8,
  allowEIO3: true,
  pingTimeout: 60000,
  pingInterval: 25000
});

// Map to store sessions: sessionID -> { senderId: string, receiverId: string, code: string }
const sessions = new Map();
// Map to store PIN codes: code -> sessionID
const codes = new Map();

function generateCode() {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

io.on('connection', (socket) => {
  console.log(`[SERVER] New connection: ${socket.id}`);

  socket.on('create-session', (data) => {
    const { sessionId, encryptionKey, encryptionIv } = data;
    
    // Check if session already exists (sender reconnected)
    const existingSession = sessions.get(sessionId);
    if (existingSession) {
      existingSession.senderId = socket.id;
      existingSession.encryptionKey = encryptionKey;
      existingSession.encryptionIv = encryptionIv;
      console.log(`[SERVER] Updated existing session ${sessionId} with new sender ID: ${socket.id}`);
      
      socket.sessionId = sessionId;
      socket.role = 'sender';
      socket.join(sessionId);
      
      socket.emit('session-created', { code: existingSession.code });
      
      // If a receiver is already present, trigger join-success immediately
      if (existingSession.receiverId) {
        io.to(sessionId).emit('join-success', { 
          sessionId: sessionId,
          senderId: socket.id,
          receiverId: existingSession.receiverId,
          encryptionKey: existingSession.encryptionKey,
          encryptionIv: existingSession.encryptionIv
        });
        console.log(`[SERVER] Sender reconnected to session ${sessionId}. Re-broadcasting join-success.`);
      }
      return;
    }

    const code = generateCode();
    console.log(`[SERVER] Creating session: ${sessionId} for socket: ${socket.id} with PIN: ${code}`);
    
    sessions.set(sessionId, { 
      senderId: socket.id, 
      receiverId: null, 
      code: code,
      encryptionKey: encryptionKey,
      encryptionIv: encryptionIv
    });
    codes.set(code, sessionId);
    
    socket.sessionId = sessionId;
    socket.role = 'sender';
    socket.join(sessionId);

    socket.emit('session-created', { code: code });
  });

  socket.on('join-session', (data) => {
    let { sessionId, code } = data;
    
    if (code) {
      sessionId = codes.get(code);
      console.log(`[SERVER] Joining by code: ${code} -> ${sessionId}`);
    }
    
    if (!sessionId) {
      socket.emit('error', { message: 'Invalid session or code' });
      return;
    }

    const session = sessions.get(sessionId);
    if (session) {
      console.log(`[SERVER] Socket ${socket.id} joining session: ${sessionId}`);
      session.receiverId = socket.id;
      socket.sessionId = sessionId;
      socket.role = 'receiver';
      socket.join(sessionId);

      // Notify EVERYONE IN THE ROOM that the session is joined
      // This is much more robust than private ID messaging
      io.to(sessionId).emit('join-success', { 
        sessionId: sessionId,
        senderId: session.senderId,
        receiverId: session.receiverId,
        encryptionKey: session.encryptionKey,
        encryptionIv: session.encryptionIv
      });
      
      console.log(`[SERVER] Join Success broadcasted to session room: ${sessionId}`);
    } else {
      socket.emit('error', { message: 'Session not found' });
    }
  });

  socket.on('offer', (data) => {
    const sid = socket.sessionId || data.sessionId;
    if (sid) {
      console.log(`[SERVER] Relay offer in room ${sid} from ${socket.id}`);
      socket.to(sid).emit('offer', data);
    }
  });

  socket.on('answer', (data) => {
    const sid = socket.sessionId || data.sessionId;
    if (sid) {
      console.log(`[SERVER] Relay answer in room ${sid} from ${socket.id}`);
      socket.to(sid).emit('answer', data);
    }
  });

  socket.on('ice-candidate', (data) => {
    const sid = socket.sessionId || data.sessionId;
    if (sid) {
      socket.to(sid).emit('ice-candidate', data);
    }
  });

  socket.on('signal-data', (data) => {
    const sid = socket.sessionId || data.sessionId;
    if (sid) {
      if (data.text && data.text.includes('"type":"debug"')) {
        try {
          const json = JSON.parse(data.text);
          console.log(`[MAC DEBUG] ${json.msg}`);
        } catch(e) {}
      } else if (data.text && data.text.includes('"type": "debug"')) {
        try {
          const json = JSON.parse(data.text);
          console.log(`[MAC DEBUG] ${json.msg}`);
        } catch(e) {}
      }
      // Force the true room UUID onto the packet so receiver PINs don't break sender filters
      data.sessionId = sid;
      // Broadcast to room (excluding sender)
      socket.to(sid).emit('on-data', data);
    }
  });

  socket.on('disconnect', () => {
    if (socket.sessionId) {
      console.log(`[SERVER] Socket disconnected: ${socket.id} (${socket.role}) for session: ${socket.sessionId}`);
      const session = sessions.get(socket.sessionId);
      if (session && (session.senderId === socket.id || session.receiverId === socket.id)) {
        socket.to(socket.sessionId).emit('peer-disconnected');
      } else {
        console.log(`[SERVER] Ignoring disconnect for stale socket: ${socket.id}`);
      }
    }
  });
});

const port = process.env.PORT || 3000;
server.listen(port, '0.0.0.0', () => {
  console.log(`Signaling server listening on port ${port} (Socket.IO)`);
});
