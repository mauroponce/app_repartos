import { test } from "node:test"
import assert from "node:assert/strict"
import { LocationSharing } from "../../app/javascript/offline/location_sharing.js"

const settle = async () => { for (let i = 0; i < 15; i++) await new Promise(resolve => setImmediate(resolve)) }
function fixture({ storage = new Map(), account = "1:2" } = {}) {
  const requests = [], watches = new Map(), messages = []
  const persistent = { getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) }
  let online = true, visible = true, authenticated = true, nextWatch = 0
  const geolocation = { watchPosition: (success, error) => { const id = ++nextWatch; watches.set(id, { success, error }); return id }, clearWatch: id => watches.delete(id) }
  const sharing = new LocationSharing({ account, storage: persistent, geolocation })
  const request = async (method, body) => {
    requests.push({ method, body })
    return method === "GET" ? { version: 0, sharing: false } : { sharing: body.command !== "deactivate", version: 1, captured_at: "2026-11-15T12:00:00Z" }
  }
  sharing.attach({ allowed: async ({ stopping = false } = {}) => online && authenticated && (stopping || visible), request, changed: state => messages.push(state) })
  return { sharing, requests, watches, messages, storage, persistent, request, setOnline: value => online = value, setVisible: value => visible = value, setAuthenticated: value => authenticated = value }
}

test("default is disabled and a stored browser permission never triggers geolocation", async () => {
  const f = fixture()
  await f.sharing.tick()
  assert.equal(f.watches.size, 0)
  assert.equal(f.requests.length, 0)
})

test("voluntary activation precedes every sample and only acknowledged timestamps are shown", async () => {
  const f = fixture()
  await f.sharing.enable()
  await settle()
  assert.equal(f.requests[1].body.command, "activate")
  assert.equal(f.watches.size, 1)
  f.watches.values().next().value.success({ coords: { latitude: -34, longitude: -58, accuracy: 10 }, timestamp: Date.now() })
  await settle()
  assert.equal(f.watches.size, 0)
  assert.equal(f.requests[2].body.command, "sample")
  assert.equal(f.requests[2].body.expected_version, 1)
  assert.match(f.messages.at(-1).message, /Última ubicación enviada/)
})

test("offline revocation cancels a position immediately survives reopening and cannot restart without a new decision", async () => {
  const f = fixture()
  await f.sharing.enable()
  await settle()
  const callback = f.watches.values().next().value.success
  f.setOnline(false)
  await f.sharing.disable()
  callback({ coords: { latitude: 1, longitude: 2, accuracy: 3 }, timestamp: Date.now() })
  await settle()
  assert.equal(f.watches.size, 0)
  assert.equal(f.requests.filter(row => row.body?.command === "sample").length, 0)
  const reopened = fixture({ storage: f.storage })
  assert.equal(reopened.sharing.enabled, false)
  assert.equal(reopened.sharing.stopping, true)
  await reopened.sharing.enable() // first flush the stop, do not enable implicitly
  assert.equal(reopened.requests[0].body.command, "deactivate")
  assert.equal(reopened.sharing.enabled, false)
  assert.equal(reopened.storage.size, 0)
})

test("hidden disconnected and account-locked contexts send no samples or simultaneous requests", async () => {
  const f = fixture()
  await f.sharing.enable()
  await settle()
  await Promise.all([f.sharing.tick(), f.sharing.tick()])
  assert.equal(f.watches.size, 1)
  f.setVisible(false)
  f.sharing.suspend()
  await settle()
  await f.sharing.tick()
  assert.equal(f.watches.size, 0)
  f.setVisible(true)
  f.setAuthenticated(false)
  await f.sharing.tick()
  assert.equal(f.watches.size, 0)
  assert.equal(fixture({ storage: f.storage, account: "2:3" }).sharing.stopping, false)
})

test("revoked sessions retain a pending stop without an endless unauthorized retry loop", async () => {
  const f = fixture()
  await f.sharing.enable()
  await settle()
  f.sharing.request = async () => { f.requests.push({ rejected: true }); const error = new Error("Revoked"); error.status = 401; throw error }
  f.watches.values().next().value.success({ coords: { latitude: 1, longitude: 2, accuracy: 3 }, timestamp: Date.now() })
  await settle()
  assert.equal(f.sharing.enabled, false)
  assert.equal(f.sharing.stopping, true)
  assert.equal(f.requests.filter(row => row.rejected).length, 2)
  assert.equal(f.storage.size, 1)
})

test("double activation is serialized and a stop during the session check cannot activate later", async () => {
  const f = fixture()
  await Promise.all([f.sharing.enable(), f.sharing.enable()])
  await settle()
  assert.equal(f.requests.filter(row => row.body?.command === "activate").length, 1)
  await f.sharing.disable()
  await settle()
  const g = fixture()
  const checks = []
  g.sharing.allowed = () => new Promise(resolve => { checks.push(resolve) })
  const activation = g.sharing.enable()
  const stopping = g.sharing.disable()
  checks.forEach(verify => verify(true))
  await Promise.all([activation, stopping])
  assert.equal(g.requests.filter(row => row.body?.command === "activate").length, 0)
  assert.equal(g.sharing.enabled, false)
})
