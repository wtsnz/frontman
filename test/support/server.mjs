import http from 'node:http';

let active = 0;

const server = http.createServer((request, response) => {
  if (request.url === '/__frontend/ready') {
    response.setHeader('content-type', 'application/json');
    const token = process.env.BAD_READINESS_TOKEN ? 'wrong-token' : process.env.FRONTEND_WORKER_TOKEN;
    response.end(JSON.stringify({ token, pid: process.pid, active }));
    return;
  }
  active++;
  response.once('close', () => active--);
  if (request.url === '/freeze') {
    response.end('freezing');
    // Fault fixture: the registered SIGTERM handler cannot run while JS blocks the event loop.
    setTimeout(() => { while (true) {} }, 20);
  } else if (request.url.startsWith('/cached')) {
    // Marked cacheable. Each render's body is unique, so a repeat shows a cache hit.
    const send = () => {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'x-frontman-cache': 'public' });
      response.end(`${process.env.APP_LABEL} ${process.pid} ${process.hrtime.bigint()}`);
    };
    request.url.startsWith('/cached-slow') ? setTimeout(send, 300) : send();
  } else if (request.url === '/backend-down') {
    response.writeHead(503);
    response.end('Database unavailable');
  } else if (request.url.startsWith('/stream') || request.url === '/hang') {
    response.writeHead(200, { 'content-type': 'text/plain' });
    response.write('first\n');
    if (request.url !== '/hang') {
      const timer = setTimeout(() => response.end('last\n'), 800);
      response.on('close', () => clearTimeout(timer));
    }
  } else {
    response.end(process.env.APP_LABEL);
  }
});

server.listen(Number(process.env.PORT), process.env.HOST);
process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
  // Short force-close budget for fault tests. Production Nitro has its own drain budget.
  setTimeout(() => server.closeAllConnections(), 200).unref();
});
