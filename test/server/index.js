const WebSocket = require('ws');
const http = require('http');

const port = process.env.PORT || 3000;
const server = http.createServer();
const wss = new WebSocket.Server({ server });

// Map to store sessions: sessionID -> { sender: socket, receiver: socket }
const sessions = new Map();

wss.on('connection', (ws) => {
  console.log('New connection');

  ws.on('message', (message) => {
    let data;
    try {
      data = JSON.parse(message);
    } catch (e) {
      console.error('Invalid message format', message);
      return;
    }

    const { type, sessionId, payload } = data;

    switch (type) {
      case 'create-session':
        console.log(`Creating session: ${sessionId}`);
        sessions.set(sessionId, { sender: ws, receiver: null });
        ws.sessionId = sessionId;
        ws.role = 'sender';
        break;

      case 'join-session':
        console.log(`Joining session: ${sessionId}`);
        const session = sessions.get(sessionId);
        if (session) {
          session.receiver = ws;
          ws.sessionId = sessionId;
          ws.role = 'receiver';
          // Notify sender that receiver joined
          session.sender.send(JSON.stringify({ type: 'receiver-joined' }));
        } else {
          ws.send(JSON.stringify({ type: 'error', message: 'Session not found' }));
        }
        break;

      case 'signal':
        // Forward SDP/ICE candidates between peers
        const targetSession = sessions.get(sessionId);
        if (targetSession) {
          const recipient = ws.role === 'sender' ? targetSession.receiver : targetSession.sender;
          if (recipient) {
            recipient.send(JSON.stringify({ type: 'signal', payload }));
          }
        }
        break;

      case 'heartbeat':
        // Keep-alive
        break;
    }
  });

  ws.on('close', () => {
    if (ws.sessionId) {
      console.log(`Connection closed for session: ${ws.sessionId}`);
      const session = sessions.get(ws.sessionId);
      if (session) {
        // Notify other peer if one closes
        const otherPeer = ws.role === 'sender' ? session.receiver : session.sender;
        if (otherPeer) {
          otherPeer.send(JSON.stringify({ type: 'peer-disconnected' }));
        }
        sessions.delete(ws.sessionId);
      }
    }
  });

  ws.on('error', (err) => {
    console.error('WebSocket error:', err);
  });
});

server.listen(port, () => {
  console.log(`Signaling server listening on port ${port}`);
});
