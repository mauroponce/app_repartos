import { test } from "node:test"
import assert from "node:assert/strict"
import { IDBFactory } from "fake-indexeddb"
import { OfflineStore, VERSION } from "../../app/javascript/offline/store.js"
import { SyncEngine } from "../../app/javascript/offline/sync.js"

const account = "1:2"
const operation = () => ({ operation_id: crypto.randomUUID(), visit_id: 1, status: "completed", notes: "18 de 20", recorded_at: new Date().toISOString(), proof: "signed-work", items: [{ id: 1, delivered_quantity: "18" }] })
const work = (user = 2) => ({ version: 4, account: { company_id: 1, user_id: user }, csrf_token: "memory-only", downloaded_at: new Date().toISOString(), packages: [{ id: 1, html: "private template", visits: [{ id: 1, status: "pending" }] }] })
const json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } })
async function fixture() { const factory = new IDBFactory(); const store = new OfflineStore(factory); await store.activate(account); return { factory, store } }

test("IndexedDB persists downloaded work and operations across close/reopen without persisting CSRF", async () => {
  const { factory, store } = await fixture()
  await store.saveWork(account, work())
  const row = operation()
  await store.enqueue(account, row)
  store.db.close()
  const reopened = new OfflineStore(factory)
  assert.equal(await reopened.active(), account)
  assert.equal((await reopened.operations(account))[0].operation_id, row.operation_id)
  assert.equal((await reopened.packages(account))[0].html, "private template")
  assert.ok(!JSON.stringify(await reopened.packages(account)).includes("memory-only"))
})

test("partition changes and logout lock access without deleting either account's pending operations", async () => {
  const { store } = await fixture()
  await store.enqueue(account, operation())
  await store.activate("2:3")
  await store.enqueue("2:3", operation())
  assert.equal((await store.operations(account)).length, 1)
  assert.equal((await store.operations("2:3")).length, 1)
  await assert.rejects(store.enqueue(account, { ...operation(), visit_id: 2 }))
  await store.activate(null)
  assert.equal(await store.active(), null)
  assert.equal((await store.operations(account)).length, 1)
})

test("simultaneous local submissions and synchronization claims are serialized", async () => {
  const { store } = await fixture()
  const results = await Promise.all([store.enqueue(account, operation()), store.enqueue(account, operation())])
  assert.equal(results.filter(Boolean).length, 1)
  const claims = await Promise.all([store.claim(account), store.claim(account)])
  assert.equal(claims.filter(Boolean).length, 1)
})

test("an interrupted sending lease becomes recoverable after a restart", async () => {
  const { factory, store } = await fixture()
  await store.enqueue(account, operation())
  const claimed = await store.claim(account, 100)
  store.db.close()
  const reopened = new OfflineStore(factory)
  assert.equal(await reopened.claim(account, 200), null)
  assert.equal((await reopened.claim(account, 30101)).operation_id, claimed.operation_id)
})

test("temporary network failure preserves the operation and retry uses exactly the same UUID and payload", async () => {
  const { store } = await fixture()
  const row = operation()
  await store.enqueue(account, row)
  let failing = true
  const submitted = []
  const engine = new SyncEngine({ store, account, fetcher: async (url, options) => {
    if (url.endsWith("work")) return json(work())
    submitted.push(JSON.parse(options.body).operation)
    if (failing) throw new Error("Disconnected after sending")
    return json({ operation_id: row.operation_id, status: "synced", result: { visit_status: "completed" } })
  } })
  await engine.run()
  let saved = (await store.operations(account))[0]
  assert.equal(saved.state, "pending")
  assert.equal(saved.attempts, 1)
  assert.ok(saved.next_attempt > Date.now())
  await store.finish(saved, { next_attempt: 0 })
  failing = false
  engine.retryAt = 0
  await engine.run()
  assert.equal((await store.operations(account))[0].state, "synced")
  assert.deepEqual(submitted[0], submitted[1])
})

test("business conflicts and validation errors remain readable and are never blindly resent", async () => {
  for (const state of ["conflict", "invalid"]) {
    const { store } = await fixture()
    const row = operation()
    await store.enqueue(account, row)
    let writes = 0
    const engine = new SyncEngine({ store, account, fetcher: async url => {
      if (url.endsWith("work")) return json(work())
      writes++
      return json({ operation_id: row.operation_id, status: state, result: { message: "Revisar con administración" } })
    } })
    await engine.run()
    await engine.run()
    const saved = (await store.operations(account))[0]
    assert.equal(saved.state, state)
    assert.equal(saved.notes, row.notes)
    assert.equal(writes, 1)
  }
})

test("revocation or a different session locks the local account before sending anything", async () => {
  for (const answer of [json({ error: "authentication_required" }, 401), json(work(9))]) {
    const { store } = await fixture()
    await store.enqueue(account, operation())
    let writes = 0
    const engine = new SyncEngine({ store, account, fetcher: async url => { if (!url.endsWith("work")) writes++; return answer } })
    assert.equal((await engine.run()).locked, true)
    assert.equal(writes, 0)
    assert.equal(await store.active(), null)
    assert.equal((await store.operations(account))[0].state, "pending")
  }
})

test("a worker-style additive database upgrade retains pending operations and prevents an older client from erasing them", async () => {
  const { factory, store } = await fixture()
  await store.enqueue(account, operation())
  const upgraded = await new Promise((resolve, reject) => {
    const request = factory.open("repartos-offline", VERSION + 1)
    request.onupgradeneeded = () => request.result.createObjectStore("future_metadata")
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
  const count = await new Promise(resolve => {
    upgraded.transaction("operations").objectStore("operations").count().onsuccess = event => resolve(event.target.result)
  })
  assert.equal(count, 1)
  await assert.rejects(new OfflineStore(factory).open(), { name: "VersionError" })
  upgraded.close()
})

test("a temporary 503 during authentication refresh preserves the queue and backs off before a successful retry", async () => {
  const { store } = await fixture()
  const row = operation()
  await store.enqueue(account, row)
  let failing = true, calls = 0
  const engine = new SyncEngine({ store, account, fetcher: async url => {
    calls++
    if (failing) return json({ error: "temporary" }, 503)
    if (url.endsWith("work")) return json(work())
    return json({ operation_id: row.operation_id, status: "synced", result: {} })
  } })
  assert.equal((await engine.run()).ok, false)
  await engine.run()
  assert.equal(calls, 1)
  assert.equal((await store.operations(account))[0].state, "pending")
  failing = false
  engine.retryAt = 0
  assert.equal((await engine.run()).ok, true)
  assert.equal((await store.operations(account))[0].state, "synced")
})

test("a stale tab cannot lock the new user's active partition", async () => {
  const { store } = await fixture()
  await store.enqueue(account, operation())
  await store.activate("1:9")
  const engine = new SyncEngine({ store, account, fetcher: async () => json(work(9)) })
  assert.equal((await engine.run()).locked, true)
  assert.equal(await store.active(), "1:9")
  assert.equal((await store.operations(account)).length, 1)
})

test("the queue preserves insertion order and manual retry bypasses backoff without stealing a lease", async () => {
  const { store } = await fixture()
  const first = { ...operation(), operation_id: "ffffffff-ffff-4fff-8fff-ffffffffffff" }
  const second = { ...operation(), visit_id: 2, operation_id: "00000000-0000-4000-8000-000000000000" }
  await store.enqueue(account, first)
  await store.enqueue(account, second)
  const claimed = await store.claim(account)
  assert.equal(claimed.operation_id, first.operation_id)
  const another = await store.claim(account, Date.now(), true)
  assert.equal(another.operation_id, second.operation_id)
  await store.finish(claimed, { state: "pending", next_attempt: Date.now() + 60000 })
  assert.equal(await store.claim(account), null)
  assert.equal((await store.claim(account, Date.now(), true)).operation_id, first.operation_id)
})

test("new authenticated work removes revoked packages while preserving unsynchronized operations and other accounts", async () => {
  const { store } = await fixture()
  await store.saveWork(account, work())
  await store.saveWork("2:3", { ...work(3), packages: [{ id: 9, html: "other company" }] })
  const saved = operation()
  await store.enqueue(account, saved)
  await store.saveWork(account, { ...work(), packages: [{ id: 7, revision: "new plan", html: "new route" }] })
  assert.deepEqual((await store.packages(account)).map(pack => pack.id), [7])
  assert.equal((await store.operations(account))[0].operation_id, saved.operation_id)
  assert.equal((await store.packages("2:3"))[0].id, 9)
})

test("arrival unloading and confirmation keep independent ordered durable operations for one visit", async () => {
  const { store } = await fixture()
  const time = new Date().toISOString()
  const stages = ["arrived_at", "unloading_started_at", "unloading_finished_at"]
  const checkpoints = stages.map(checkpoint => ({ ...operation(), operation_type: "visit_checkpoint", checkpoint, occurred_at: time, status: "pending", items: [] }))
  for (const row of checkpoints) assert.equal(await store.enqueue(account, row), true)
  assert.equal(await store.enqueue(account, { ...checkpoints[0], operation_id: crypto.randomUUID() }), false)
  const final = operation()
  assert.equal(await store.enqueue(account, final), true)
  assert.equal(await store.enqueue(account, { ...checkpoints[0], operation_id: crypto.randomUUID(), checkpoint: "new_stage" }), false)
  const sent = []
  const engine = new SyncEngine({ store, account, fetcher: async (url, options) => {
    if (url.endsWith("work")) return json(work())
    const row = JSON.parse(options.body).operation
    sent.push(row)
    return json({ operation_id: row.operation_id, status: "synced", result: { checkpoint: row.checkpoint, occurred_at: row.occurred_at } })
  } })
  assert.equal((await engine.run()).ok, true)
  assert.deepEqual(sent.map(row => row.checkpoint || "confirmation"), [...stages, "confirmation"])
  assert.equal((await store.operations(account)).length, 4)
  assert.ok((await store.operations(account)).every(row => row.state === "synced"))
})

test("a checkpoint is kept pending until the server acknowledges its exact stage and time", async () => {
  const { store } = await fixture()
  await store.enqueue(account, { ...operation(), operation_type: "visit_checkpoint", checkpoint: "arrived_at", occurred_at: new Date().toISOString(), items: [] })
  const engine = new SyncEngine({ store, account, fetcher: async (url, options) => {
    if (url.endsWith("work")) return json(work())
    const row = JSON.parse(options.body).operation
    return json({ operation_id: row.operation_id, status: "synced", result: {} })
  } })
  assert.equal((await engine.run()).ok, false)
  assert.equal((await store.operations(account))[0].state, "pending")
})

test("upgrading a v2 queue retains its exact legacy payload and binary files", async () => {
  const factory = new IDBFactory()
  const legacy = await new Promise((resolve, reject) => {
    const request = factory.open("repartos-offline", 2)
    request.onupgradeneeded = () => {
      request.result.createObjectStore("meta", { keyPath: "key" })
      for (const name of ["packages", "operations"]) request.result.createObjectStore(name, { keyPath: "key" }).createIndex("account", "account")
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
  const payload = { ...operation(), key: `${account}:legacy`, account, state: "pending", sequence: 1, attempts: 0, next_attempt: 0,
    files: [{ id: "photo", blob: new Blob(["original photo"], { type: "image/jpeg" }) }] }
  await new Promise((resolve, reject) => {
    const tx = legacy.transaction(["meta", "operations"], "readwrite")
    tx.objectStore("meta").put({ key: "active", value: account })
    tx.objectStore("operations").add(payload)
    tx.oncomplete = resolve
    tx.onerror = () => reject(tx.error)
  })
  legacy.close()
  const current = new OfflineStore(factory)
  assert.equal(await current.active(), account)
  const saved = (await current.operations(account))[0]
  assert.deepEqual(saved, payload)
  assert.equal(await saved.files[0].blob.text(), "original photo")
  assert.equal("operation_type" in saved, false)
  current.db.close()
})

test("workflow reports and visit confirmation share the durable queue without hiding or duplicating each other", async () => {
  const { factory, store } = await fixture()
  const report = { ...operation(), operation_type: "workflow", workflow: { command: "incident_report", visit_id: 1, kind: "closed", description: "Local cerrado", occurred_at: new Date().toISOString(), photos: [] }, items: [], files: [] }
  assert.equal(await store.enqueue(account, report), true)
  assert.equal(await store.enqueue(account, { ...report, operation_id: crypto.randomUUID() }), false)
  assert.equal(await store.enqueue(account, operation()), true)
  store.db.close()
  const reopened = new OfflineStore(factory)
  const sent = []
  const engine = new SyncEngine({ store: reopened, account, fetcher: async (url, options) => {
    if (url.endsWith("work")) return json(work())
    if (url.endsWith("workflow-operations")) {
      const data = JSON.parse(options.body.get("operation"))
      sent.push(data.command)
      return json({ operation_id: data.operation_id, status: "synced", result: { incident_id: 7, attachment_ids: [] } })
    }
    const data = JSON.parse(options.body).operation
    sent.push("confirmation")
    return json({ operation_id: data.operation_id, status: "synced", result: {} })
  } })
  await engine.run()
  assert.deepEqual(sent, ["incident_report", "confirmation"])
  assert.deepEqual((await reopened.operations(account)).map(row => row.state), ["synced", "synced"])
})

test("workflow photos survive a lost acknowledgement and are cleared only after exact attachment confirmation", async () => {
  const { store } = await fixture()
  const file = { id: crypto.randomUUID(), kind: "incident_photo", blob: new Blob(["photo"], { type: "image/jpeg" }), sha256: "hash" }
  const row = { ...operation(), operation_type: "workflow", workflow: { command: "incident_report", kind: "damaged", description: "Daño", photos: [{ id: file.id, sha256: file.sha256 }] }, files: [file], items: [] }
  await store.enqueue(account, row)
  let confirm = false
  const submitted = []
  const engine = new SyncEngine({ store, account, fetcher: async (url, options) => {
    if (url.endsWith("work")) return json(work())
    const data = JSON.parse(options.body.get("operation"))
    submitted.push(data)
    assert.equal(options.body.getAll("files[]").length, 1)
    return json({ operation_id: row.operation_id, status: "synced", result: { incident_id: 1, attachment_ids: confirm ? [file.id] : [] } })
  } })
  await engine.run()
  let saved = (await store.operations(account))[0]
  assert.equal(saved.state, "pending")
  assert.equal(saved.files[0].blob.size, 5)
  confirm = true
  await engine.run(true)
  saved = (await store.operations(account))[0]
  assert.equal(saved.state, "synced")
  assert.equal(saved.files.length, 0)
  assert.deepEqual(submitted[0], submitted[1])
})

test("offline notice reads never become server confirmed and inbox caches remain isolated by account", async () => {
  const { factory, store } = await fixture()
  await store.saveInbox(account, { html: "instrucción privada", pending: 1, downloaded_at: new Date().toISOString() })
  const row = { ...operation(), operation_type: "workflow", workflow: { command: "notice_read", id: 7 }, items: [], files: [] }
  await store.enqueue(account, row)
  assert.equal((await store.inbox(account)).pending, 1)
  const engine = new SyncEngine({ store, account, fetcher: async url => url.endsWith("work") ? json(work()) : Promise.reject(new Error("offline")) })
  await engine.run()
  assert.equal((await store.operations(account))[0].state, "pending")
  await store.activate("2:9")
  assert.equal(await store.inbox("2:9"), null)
  await assert.rejects(store.saveInbox(account, { html: "stale request" }))
  store.db.close()
  const reopened = new OfflineStore(factory)
  assert.equal((await reopened.inbox(account)).html, "instrucción privada")
})
