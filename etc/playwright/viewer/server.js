const http = require("http");
const fs = require("fs");
const path = require("path");

const cdp = { host: "127.0.0.1", port: 9222 };
const listenPort = 9224;
const staticRoutes = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/client.js": ["client.js", "text/javascript; charset=utf-8"],
};

// CDP は loopback 以外の Host と Origin 付き接続を拒否するため Host を付け替え Origin を除去
const toCdpHeaders = ({ origin, ...headers } = {}) => ({ ...headers, host: `${cdp.host}:${cdp.port}` });

const server = http.createServer((req, res) => {
  const route = staticRoutes[req.url];
  if (route) {
    const [file, contentType] = route;
    res.writeHead(200, { "content-type": contentType });
    fs.createReadStream(path.join(__dirname, file)).pipe(res);
    return;
  }
  if (req.url === "/json") {
    const upstream = http.get({ ...cdp, path: "/json/list", headers: toCdpHeaders() }, cdpRes => {
      res.writeHead(cdpRes.statusCode, { "content-type": "application/json" });
      cdpRes.pipe(res);
    });
    upstream.on("error", err => { res.writeHead(502); res.end(String(err)); });
    return;
  }
  res.writeHead(404);
  res.end();
});

server.on("upgrade", (req, clientSocket, head) => {
  const upstream = http.request({ ...cdp, path: req.url, headers: toCdpHeaders(req.headers) });
  upstream.on("upgrade", (cdpRes, cdpSocket) => {
    const statusLine = "HTTP/1.1 101 Switching Protocols\r\n";
    const headerLines = Object.entries(cdpRes.headers).map(([k, v]) => `${k}: ${v}`).join("\r\n");
    clientSocket.write(statusLine + headerLines + "\r\n\r\n");
    if (head && head.length) cdpSocket.write(head);
    cdpSocket.pipe(clientSocket);
    clientSocket.pipe(cdpSocket);
    clientSocket.on("error", () => cdpSocket.destroy());
    cdpSocket.on("error", () => clientSocket.destroy());
  });
  upstream.on("error", () => clientSocket.destroy());
  upstream.end();
});

server.listen(listenPort, "0.0.0.0");
