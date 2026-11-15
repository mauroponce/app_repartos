
export class SessionUnavailable extends Error {}
class EvidenceRejected extends Error {
  constructor(message, status) { super(message); this.status = status }
}
export class SyncEngine {
  constructor({ store, account, fetcher = globalThis.fetch.bind(globalThis), changed = () => {} }) {
    Object.assign(this, { store, account, fetcher, changed })
  }

  async request(url, options = {}) {
    const { timeout = 12000, ...requestOptions } = options
    const response = await this.fetcher(url, { ...requestOptions, credentials: "same-origin", cache: "no-store", redirect: "error", signal: AbortSignal.timeout(timeout), headers: { Accept: "application/json", ...options.headers } })
    if ([401, 403, 422].includes(response.status) && !response.headers.get("content-type")?.includes("application/json")) throw new SessionUnavailable("La sesión necesita verificarse")
    if ([401, 403].includes(response.status)) throw new SessionUnavailable("Volvé a iniciar sesión con esta cuenta para sincronizar. Los registros siguen guardados.")
    return response
  }

  async refresh() {
    const response = await this.request("/repartidor/api/v1/work")
    if (!response.ok) throw new Error(`Servidor temporalmente no disponible (${response.status})`)
    const work = await response.json()
    if (work.version !== 4) throw new SessionUnavailable("La versión requiere actualizar la aplicación; los registros se conservan")
    if (`${work.account.company_id}:${work.account.user_id}` !== this.account || await this.store.active() !== this.account) throw new SessionUnavailable("La cuenta cambió en este navegador")
    this.csrf = work.csrf_token
    await this.store.saveWork(this.account, work)
    return work
  }

  async run(force = false) {
    if (this.running) return this.running
    if (!force && this.retryAt && Date.now() < this.retryAt) return { ok: false, message: "Esperando el próximo reintento" }
    this.running = this.process(force).finally(() => { this.running = null })
    return this.running
  }

  async process(force = false) {
    try {
      // Authentication and CSRF are renewed in memory, before reading the queue.
      await this.refresh()
      for (;;) {
        const row = await this.store.claim(this.account, Date.now(), force)
        if (!row) break
        this.changed()
        const operation = Object.fromEntries(["operation_id", "visit_id", "operation_type", "checkpoint", "occurred_at", "status", "items", "notes", "recorded_at", "proof", "receipt_version", "failure_reason", "receiver_name", "location", "evidence"].filter(key => key in row).map(key => [key, row[key]]))
        try {
          let response
          if (row.operation_type === "workflow") {
            if (!await this.store.renew(row)) throw new SessionUnavailable("La cuenta cambió o la acción ya se sincroniza en otra pestaña")
            const body = new FormData()
            body.append("operation", JSON.stringify({ ...row.workflow, operation_id: row.operation_id }))
            for (const file of row.files || []) body.append("files[]", file.blob, `${file.id}.jpg`)
            response = await this.request("/repartidor/api/v1/workflow-operations", { method: "POST", timeout: 45000, headers: { "X-CSRF-Token": this.csrf }, body })
          } else {
            await this.uploadEvidence(row)
            response = await this.request("/repartidor/api/v1/operations", { method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrf }, body: JSON.stringify({ operation }) })
          }
          if (response.status >= 500 || response.status === 429) throw new Error(`Servidor temporalmente no disponible (${response.status})`)
          const result = await response.json()
          if (response.ok && result.operation_id !== row.operation_id) throw new Error("Respuesta de operación inesperada")
          const state = response.ok ? result.status : response.status === 409 ? "conflict" : "invalid"
          if (!["synced", "conflict", "invalid"].includes(state)) throw new Error("Estado de sincronización inesperado")
          if (state === "synced" && row.operation_type === "workflow") {
            const command = row.workflow.command, receipt = result.result || {}
            const key = command.startsWith("task_") ? "task_id" : command === "notice_read" ? "notice_id" : "incident_id"
            if (command === "incident_report" ? !Number.isInteger(receipt.incident_id) || receipt.incident_id < 1 : String(receipt[key]) !== String(row.workflow.id)) throw new Error("El servidor no confirmó la acción solicitada. Se conserva para reintentar.")
            if (command === "notice_read" && !Number.isFinite(Date.parse(receipt.read_at))) throw new Error("El servidor todavía no confirmó la lectura del aviso.")
            if (command === "task_start" && receipt.task_status !== "in_progress" || command === "task_complete" && (receipt.task_status !== "completed" || !Number.isFinite(Date.parse(receipt.closed_at)))) throw new Error("El servidor todavía no confirmó el estado de la tarea.")
          }
          if (state === "synced" && row.operation_type === "workflow" && row.files?.length) {
            const expected = row.files.map(file => file.id).sort()
            if (JSON.stringify(expected) !== JSON.stringify([...(result.result?.attachment_ids || [])].sort())) throw new Error("El servidor no confirmó todas las fotografías de la incidencia. Se conservan para reintentar.")
          }
          if (state === "synced" && row.operation_type === "visit_checkpoint") {
            if (result.result?.checkpoint !== row.checkpoint || Date.parse(result.result?.occurred_at) !== Date.parse(row.occurred_at)) throw new Error("El servidor todavía no confirmó el horario. Se conserva para reintentar.")
          }
          if (state === "synced" && row.evidence?.length) {
            const expected = row.evidence.map(file => file.id).sort()
            if (JSON.stringify(expected) !== JSON.stringify([...(result.result?.evidence_ids || [])].sort())) throw new Error("El servidor todavía no confirmó todas las evidencias. Se conservarán en el dispositivo.")
          }
          await this.store.finish(row, { state, receipt: result, error: result.result?.message || result.error || null })
          if (row.operation_type === "workflow" && globalThis.document) document.dispatchEvent(new CustomEvent("workflow:changed"))
        } catch (error) {
          if (error instanceof EvidenceRejected) {
            await this.store.finish(row, { state: error.status === 409 ? "conflict" : "invalid", error: error.message })
            await this.changed()
            continue
          }
          const attempts = row.attempts + 1
          await this.store.finish(row, { state: "pending", attempts, next_attempt: Date.now() + retryDelay(attempts), error: error.message })
          throw error
        }
        await this.changed()
      }
      await this.refresh()
      this.failures = 0
      this.retryAt = 0
      return { ok: true }
    } catch (error) {
      if (error instanceof SessionUnavailable) {
        if (await this.store.active() === this.account) await this.store.activate(null)
        return { locked: true, message: error.message }
      }
      this.failures = (this.failures || 0) + 1
      this.retryAt = Date.now() + retryDelay(this.failures)
      return { ok: false, message: error.message }
    } finally { await this.changed() }
  }

  async uploadEvidence(row) {
    for (const manifest of row.evidence || []) {
      if (!await this.store.renew(row)) throw new SessionUnavailable("La cuenta cambió o el registro ya está sincronizándose desde otra pestaña")
      const file = row.files?.find(file => file.id === manifest.id)
      if (!file?.blob) throw new EvidenceRejected("No se encuentra el archivo local de una evidencia. Conservá el registro y revisalo con administración.", 422)
      const body = new FormData()
      const attributes = { operation_id: row.operation_id, visit_id: row.visit_id, evidence_uuid: file.id, kind: file.kind, sha256: file.sha256, proof: row.proof }
      Object.entries(attributes).forEach(([key, value]) => body.append(`evidence[${key}]`, String(value)))
      body.append("evidence[file]", file.blob, `${file.id}.${file.kind === "signature" ? "png" : "jpg"}`)
      const response = await this.request("/repartidor/api/v1/evidences", { method: "POST", timeout: 35000, headers: { "X-CSRF-Token": this.csrf }, body })
      if (response.status >= 500 || response.status === 429) throw new Error("No se pudo subir una evidencia. Se reintentará con conexión.")
      if (response.status === 413) throw new EvidenceRejected("La evidencia supera el tamaño permitido por el servidor. Se conserva para revisión.", 413)
      const result = await response.json()
      if (!response.ok) throw new EvidenceRejected(result.error || "El servidor rechazó una evidencia", response.status)
      if (result.id !== manifest.id || result.sha256 !== manifest.sha256 || !result.uploaded) throw new Error("No se pudo verificar la subida de una evidencia")
    }
  }
}

export function retryDelay(attempts) { return Math.min(60000, 1000 * 2 ** Math.min(attempts, 6)) + Math.floor(Math.random() * 500) }
