// Run inside the Linux oracle container. Publish this port on host loopback only:
// the debugging protocol gives clients full access to this disposable browser.
import net from 'node:net';
import puppeteer from 'puppeteer';

const browser = await puppeteer.launch({
 headless: true,
 debuggingPort: 9223,
 args: ['--no-sandbox', '--font-render-hinting=none'],
});

// Chrome binds its debugging listener to loopback. Forward the container port
// without changing Chrome's HTTP discovery or WebSocket protocol.
const server = net.createServer(client => {
 const upstream = net.connect(9223, '127.0.0.1');
 client.on('error', () => upstream.destroy());
 upstream.on('error', () => client.destroy());
 client.pipe(upstream).pipe(client);
});
server.listen(9222, '0.0.0.0', () => console.log('Pinned Linux Chrome ready on port 9222'));
process.on('SIGTERM', async () => { await browser.close(); server.close(); });
