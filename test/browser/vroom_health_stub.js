// UI contract tests only; this server never calculates or approves routes.
import http from "node:http"
if (process.env.PWA_BROWSER_TEST !== "1") throw new Error("This fixture is only for browser tests")
http.createServer((request, response) => {
  response.writeHead(request.url === "/health" ? 200 : 503, { "Content-Type": "application/json" })
  response.end(JSON.stringify({ test_stub: true }))
}).listen(Number(process.env.PWA_VROOM_HEALTH_PORT || 3199), "127.0.0.1")
