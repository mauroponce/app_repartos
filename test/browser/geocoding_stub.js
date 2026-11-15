// Raw provider responses for isolated tests. The real HTTP clients, caches,
// provider parsers, evaluator, pipeline and import jobs still run unchanged.
import http from "node:http"
import { readFileSync } from "node:fs"
if (process.env.PWA_BROWSER_TEST !== "1") throw new Error("Only for isolated browser tests")
const customers = JSON.parse(readFileSync(new URL("../../docs/ejemplos/onboarding/datos_demo.json", import.meta.url))).customers
const fold = value => value.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase().replace(/\bav\.?\s+/g, "avenida ").replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim()
const find = (street, city) => customers.findIndex(row => fold(row.address) === fold(street) && fold(row.city) === fold(city))
const point = index => [-58.40 - index % 6 * 0.003, -34.79 - Math.floor(index / 6) * 0.015 - index % 3 * 0.002]
const parts = text => {
  const match = text.match(/^(.*?)\s+(\d+)$/)
  return match ? [match[1], match[2]] : [text, null]
}
http.createServer(async (request, response) => {
  const url = new URL(request.url, "http://127.0.0.1")
  let result
  if (url.pathname === "/health") result = { test_stub: true }
  else if (url.pathname === "/georef/direcciones" && request.method === "POST") {
    let body = ""
    for await (const chunk of request) body += chunk
    result = { resultados: JSON.parse(body).direcciones.map(input => {
      const index = find(input.direccion, input.localidad || "")
      const [street, number] = parts(input.direccion)
      const [lon, lat] = point(Math.max(index, 0))
      const directions = index >= 0 && index < 24 ? [{ calle: { nombre: street }, altura: { valor: number },
        localidad: { nombre: input.localidad }, departamento: { nombre: "Distrito de prueba" }, provincia: { nombre: "Buenos Aires" },
        ubicacion: { lat, lon }, nomenclatura: `${input.direccion}, ${input.localidad}` }] : []
      return { total: directions.length, direcciones: directions }
    }) }
  } else if (url.pathname === "/photon") {
    const query = url.searchParams.get("q").split(",").map(value => value.trim())
    const index = find(query[0], query[1] || "")
    const [street, number] = parts(query[0])
    const feature = offset => ({ type: "Feature", geometry: { type: "Point", coordinates: point(index).map((value, axis) => value + (axis === 1 ? offset : 0)) },
      properties: { street, housenumber: number, city: query[1], county: "Distrito de prueba", state: "Buenos Aires", countrycode: "ar", type: "house", osm_key: "building" } })
    result = { features: index >= 0 && index < 20 ? [feature(0)] : (index >= 22 && index < 24 ? [feature(0), feature(0.02)] : []) }
  } else {
    response.writeHead(404)
    return response.end()
  }
  response.writeHead(200, { "Content-Type": "application/json" })
  response.end(JSON.stringify(result))
}).listen(Number(process.env.PWA_GEOCODING_PORT || 3198), "127.0.0.1")
