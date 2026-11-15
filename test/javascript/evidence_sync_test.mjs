import { test } from "node:test"
import assert from "node:assert/strict"
import { IDBFactory } from "fake-indexeddb"
import { OfflineStore, MAX_PENDING_FILE_BYTES } from "../../app/javascript/offline/store.js"
import { SyncEngine } from "../../app/javascript/offline/sync.js"

const account = "1:2"
const json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } })
const work = () => ({ version: 4, account: { company_id: 1, user_id: 2 }, csrf_token: "csrf", downloaded_at: new Date().toISOString(), packages: [] })
const operation = () => {
  const file = { id: crypto.randomUUID(), kind: "photo", sha256: "a".repeat(64), blob: new Blob(["photo bytes"], { type: "image/jpeg" }) }
  return { operation_id: crypto.randomUUID(), visit_id: 1, status: "completed", items: [{ id: 1, delivered_quantity: "18" }],
    receipt_version: 1, notes: "Faltante", failure_reason: "shortage", receiver_name: "María", location: null, recorded_at: new Date().toISOString(), proof: "proof",
    evidence: [{ id: file.id, kind: file.kind, sha256: file.sha256 }], files: [file] }
}
async function fixture() {
  const factory = new IDBFactory(), store = new OfflineStore(factory)
  await store.activate(account)
  const row = operation()
  await store.enqueue(account, row)
  return { factory, store, row }
}

test("image blobs survive close and reopen and are uploaded before the receipt", async () => {
  const { factory, store, row } = await fixture()
  store.db.close()
  const reopened = new OfflineStore(factory)
  assert.equal(await (await reopened.operations(account))[0].files[0].blob.text(), "photo bytes")
  const calls = []
  const engine = new SyncEngine({ store: reopened, account, fetcher: async (url, options) => {
    if (url.endsWith("work")) return json(work())
    calls.push(url)
    if (url.endsWith("evidences")) {
      assert.ok(options.body instanceof FormData)
      assert.equal(options.body.get("evidence[evidence_uuid]"), row.files[0].id)
      assert.equal(await options.body.get("evidence[file]").text(), "photo bytes")
      return json({ id: row.files[0].id, sha256: row.files[0].sha256, uploaded: true })
    }
    const submitted = JSON.parse(options.body).operation
    assert.equal(submitted.failure_reason, "shortage")
    assert.deepEqual(submitted.evidence, row.evidence)
    assert.equal(submitted.files, undefined)
    return json({ operation_id: row.operation_id, status: "synced", result: { evidence_ids: [row.files[0].id] } })
  } })
  assert.equal((await engine.run()).ok, true)
  assert.deepEqual(calls, ["/repartidor/api/v1/evidences", "/repartidor/api/v1/operations"])
  const saved = (await reopened.operations(account))[0]
  assert.equal(saved.state, "synced")
  assert.deepEqual(saved.files, [])
  assert.deepEqual(saved.evidence, row.evidence)
})

test("an interrupted upload retains files UUIDs and all quantities for the next retry", async () => {
  const { store, row } = await fixture()
  const submissions = []
  let failing = true, confirmations = 0
  const engine = new SyncEngine({ store, account, fetcher: async (url, options) => {
    if (url.endsWith("work")) return json(work())
    if (url.endsWith("evidences")) {
      submissions.push(options.body.get("evidence[evidence_uuid]"))
      if (failing) return json({ error: "R2 unavailable" }, 503)
      return json({ id: row.files[0].id, sha256: row.files[0].sha256, uploaded: true })
    }
    confirmations++
    return json({ operation_id: row.operation_id, status: "synced", result: { evidence_ids: [row.files[0].id] } })
  } })
  assert.equal((await engine.run()).ok, false)
  assert.equal(confirmations, 0)
  let saved = (await store.operations(account))[0]
  assert.equal(saved.state, "pending")
  assert.equal(await saved.files[0].blob.text(), "photo bytes")
  assert.deepEqual(saved.items, row.items)
  failing = false
  assert.equal((await engine.run(true)).ok, true)
  assert.deepEqual(submissions, [row.files[0].id, row.files[0].id])
  saved = (await store.operations(account))[0]
  assert.equal(saved.operation_id, row.operation_id)
  assert.equal(saved.state, "synced")
})

test("files are kept unless the server acknowledges every evidence, including on conflicts", async () => {
  for (const status of ["synced", "conflict", "invalid"]) {
    const { store, row } = await fixture()
    const engine = new SyncEngine({ store, account, fetcher: async url => {
      if (url.endsWith("work")) return json(work())
      if (url.endsWith("evidences")) return json({ id: row.files[0].id, sha256: row.files[0].sha256, uploaded: true })
      return json({ operation_id: row.operation_id, status, result: { evidence_ids: [] } })
    } })
    await engine.run()
    const saved = (await store.operations(account))[0]
    assert.equal(saved.state, status === "synced" ? "pending" : status)
    assert.equal(await saved.files[0].blob.text(), "photo bytes")
  }
})

test("a permanent upload rejection preserves the file for review without confirming delivery", async () => {
  const { store } = await fixture()
  let confirmations = 0
  const engine = new SyncEngine({ store, account, fetcher: async url => {
    if (url.endsWith("work")) return json(work())
    if (url.endsWith("evidences")) return json({ error: "Imagen no válida" }, 422)
    confirmations++
  } })
  await engine.run()
  const saved = (await store.operations(account))[0]
  assert.equal(saved.state, "invalid")
  assert.equal(await saved.files[0].blob.text(), "photo bytes")
  assert.equal(confirmations, 0)
})

test("an incompatible server cannot process a receipt while omitting its photos", async () => {
  const { store } = await fixture()
  let uploads = 0
  const engine = new SyncEngine({ store, account, fetcher: async url => {
    if (url.endsWith("work")) return json({ ...work(), version: 1 })
    uploads++
  } })
  assert.equal((await engine.run()).locked, true)
  assert.equal(uploads, 0)
  assert.equal(await store.active(), null)
  const saved = (await store.operations(account))[0]
  assert.equal(saved.state, "pending")
  assert.equal(await saved.files[0].blob.text(), "photo bytes")
})

test("the local file budget rejects the entire write without losing previous records", async () => {
  const { store } = await fixture()
  const extra = operation()
  extra.visit_id = 2
  extra.files[0].blob = new Blob([new Uint8Array(MAX_PENDING_FILE_BYTES)])
  await assert.rejects(store.enqueue(account, extra), /50 MB/)
  assert.equal((await store.operations(account)).length, 1)
})

test("upgrading a v1 database preserves legacy work and prevents v1 clients from reopening it", async () => {
  const factory = new IDBFactory()
  const old = await new Promise((resolve, reject) => {
    const request = factory.open("repartos-offline", 1)
    request.onupgradeneeded = () => {
      request.result.createObjectStore("meta", { keyPath: "key" })
      for (const name of ["packages", "operations"]) request.result.createObjectStore(name, { keyPath: "key" }).createIndex("account", "account")
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
  await new Promise(resolve => {
    const tx = old.transaction(["operations"], "readwrite")
    tx.objectStore("operations").add({ ...operation(), key: "legacy", account, files: [], state: "pending" })
    tx.oncomplete = resolve
  })
  old.onversionchange = () => old.close()
  const upgraded = new OfflineStore(factory)
  await upgraded.open()
  assert.equal((await upgraded.operations(account)).length, 1)
  await assert.rejects(new Promise((resolve, reject) => {
    const request = factory.open("repartos-offline", 1)
    request.onerror = () => reject(request.error)
    request.onsuccess = resolve
  }), { name: "VersionError" })
})
