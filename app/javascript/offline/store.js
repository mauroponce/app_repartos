export const DATABASE = "repartos-offline"
// Version 4 adds internal workflow operations without changing existing stores.
// Old clients must not interpret these rows as delivery confirmations.
export const VERSION = 4
export const MAX_PENDING_FILE_BYTES = 50 * 1024 * 1024
export const accountKey = account => `${account.company_id}:${account.user_id}`
export const unresolved = operation => operation.state !== "synced"

export class OfflineStore {
  constructor(factory = globalThis.indexedDB) { this.factory = factory }

  async open() {
    if (this.db) return this
    if (this.opening) { await this.opening; return this }
    this.opening = new Promise((resolve, reject) => {
      const request = this.factory.open(DATABASE, VERSION)
      request.onupgradeneeded = () => {
        const db = request.result
        if (!db.objectStoreNames.contains("meta")) db.createObjectStore("meta", { keyPath: "key" })
        for (const name of ["packages", "operations"]) {
          if (!db.objectStoreNames.contains(name)) db.createObjectStore(name, { keyPath: "key" }).createIndex("account", "account")
        }
      }
      request.onblocked = () => reject(new Error("Cerrá las otras pestañas para actualizar. Los registros se conservan."))
      request.onerror = () => reject(request.error)
      request.onsuccess = () => {
        const db = request.result
        this.db = db
        db.onversionchange = () => { db.close(); if (this.db === db) this.db = null }
        resolve()
      }
    })
    try { await this.opening } finally { this.opening = null }
    return this
  }

  async transaction(names, mode, work) {
    await this.open()
    return new Promise((resolve, reject) => {
      const tx = this.db.transaction(names, mode, mode === "readwrite" ? { durability: "strict" } : undefined)
      let value
      tx.oncomplete = () => resolve(value)
      tx.onerror = tx.onabort = () => reject(tx.failure || tx.error || new Error("No se pudo guardar en este dispositivo"))
      try { work(tx, result => { value = result }) } catch (error) { tx.abort(); reject(error) }
    })
  }

  async active() {
    return this.transaction(["meta"], "readonly", (tx, done) => {
      tx.objectStore("meta").get("active").onsuccess = event => done(event.target.result?.value || null)
    })
  }

  async activate(account) {
    await this.transaction(["meta"], "readwrite", tx => tx.objectStore("meta").put({ key: "active", value: account }))
    if (typeof BroadcastChannel !== "undefined") {
      const channel = new BroadcastChannel("repartos-account")
      channel.postMessage(account)
      channel.close()
    }
  }

  async inbox(account) {
    return this.transaction(["meta"], "readonly", (tx, done) => {
      tx.objectStore("meta").get(`inbox:${account}`).onsuccess = event => done(event.target.result?.value || null)
    })
  }

  async saveInbox(account, value) {
    return this.transaction(["meta"], "readwrite", tx => {
      tx.objectStore("meta").get("active").onsuccess = event => {
        if (event.target.result?.value !== account) { tx.abort(); return }
        tx.objectStore("meta").put({ key: `inbox:${account}`, value })
      }
    })
  }

  async packages(account) { return this.list("packages", account) }
  async operations(account) { return (await this.list("operations", account)).sort((a, b) => (a.sequence || 0) - (b.sequence || 0)) }
  async list(name, account) {
    return this.transaction([name], "readonly", (tx, done) => {
      tx.objectStore(name).index("account").getAll(account).onsuccess = event => done(event.target.result)
    })
  }

  async saveWork(account, response) {
    await this.transaction(["packages", "meta"], "readwrite", tx => {
      // This authenticated response is authoritative for available routes.
      // Queued operations and their evidence remain untouched after reassignment.
      const keys = new Set(response.packages.map(pack => `${account}:${pack.id}`))
      tx.objectStore("packages").index("account").getAll(account).onsuccess = event => {
        for (const pack of event.target.result) if (!keys.has(pack.key)) tx.objectStore("packages").delete(pack.key)
      }
      for (const pack of response.packages) tx.objectStore("packages").put({ ...pack, account, key: `${account}:${pack.id}`, downloaded_at: response.downloaded_at })
      tx.objectStore("meta").put({ key: `download:${account}`, value: response.downloaded_at })
    })
  }

  async enqueue(account, operation) {
    return this.transaction(["operations", "meta"], "readwrite", (tx, done) => {
      tx.objectStore("meta").get("active").onsuccess = event => {
        if (event.target.result?.value !== account) { tx.abort(); return }
        const store = tx.objectStore("operations")
        store.index("account").getAll(account).onsuccess = event => {
          const checkpoint = operation.operation_type === "visit_checkpoint"
          if (operation.operation_type === "workflow") {
            const data = operation.workflow
            const duplicate = event.target.result.some(row => row.operation_id === operation.operation_id || (row.operation_type === "workflow" && ["pending", "syncing"].includes(row.state) && (
              data.command === "incident_report" ? row.workflow.command === data.command && String(row.visit_id) === String(operation.visit_id) && row.workflow.kind === data.kind && row.workflow.description === data.description : (row.workflow.command === data.command || (row.workflow.command.startsWith("task_") && data.command.startsWith("task_"))) && String(row.workflow.id) === String(data.id))))
            if (duplicate) { done(false); return }
          }
          const duplicate = operation.operation_type !== "workflow" && event.target.result.some(row => row.operation_type !== "workflow" && String(row.visit_id) === String(operation.visit_id) && (
            checkpoint ? (row.operation_type === "visit_checkpoint" && row.checkpoint === operation.checkpoint) || row.operation_type !== "visit_checkpoint" : row.operation_type !== "visit_checkpoint"))
          if (duplicate) { done(false); return }
          const bytes = [...event.target.result, operation].reduce((total, row) => total + (row.files || []).reduce((sum, file) => sum + (file.blob?.size || 0), 0), 0)
          if (bytes > MAX_PENDING_FILE_BYTES) {
            tx.failure = new Error("Hay más de 50 MB de evidencias pendientes. Sincronizá las visitas guardadas o quitá fotos de esta visita antes de guardar.")
            tx.abort()
            return
          }
          const sequence = event.target.result.reduce((maximum, row) => Math.max(maximum, row.sequence || 0), 0) + 1
          store.add({ ...operation, key: `${account}:${operation.operation_id}`, account, sequence, state: "pending", attempts: 0, next_attempt: 0 })
          done(true)
        }
      }
    })
  }

  async claim(account, now = Date.now(), force = false) {
    return this.transaction(["operations", "meta"], "readwrite", (tx, done) => {
      tx.objectStore("meta").get("active").onsuccess = event => {
        if (event.target.result?.value !== account) { done(null); return }
        const store = tx.objectStore("operations")
        store.index("account").getAll(account).onsuccess = event => {
          const row = event.target.result.sort((a, b) => (a.sequence || 0) - (b.sequence || 0)).find(row => (row.state === "pending" || (row.state === "syncing" && row.lease_until <= now)) && (force || row.next_attempt <= now))
          if (!row) { done(null); return }
          row.state = "syncing"
          row.lease_until = now + 30000
          row.owner = crypto.randomUUID()
          store.put(row)
          done(row)
        }
      }
    })
  }

  async finish(operation, changes) {
    await this.transaction(["operations"], "readwrite", tx => {
      const store = tx.objectStore("operations")
      store.get(operation.key).onsuccess = event => {
        const row = event.target.result
        if (row && row.owner === operation.owner) store.put({ ...row, ...changes, ...(changes.state === "synced" ? { files: [] } : {}), lease_until: 0 })
      }
    })
  }

  async renew(operation) {
    return this.transaction(["operations", "meta"], "readwrite", (tx, done) => {
      tx.objectStore("meta").get("active").onsuccess = event => {
        if (event.target.result?.value !== operation.account) { done(false); return }
        const store = tx.objectStore("operations")
        store.get(operation.key).onsuccess = result => {
          const row = result.target.result
          if (!row || row.owner !== operation.owner) { done(false); return }
          store.put({ ...row, lease_until: Date.now() + 90000 })
          done(true)
        }
      }
    })
  }
}
