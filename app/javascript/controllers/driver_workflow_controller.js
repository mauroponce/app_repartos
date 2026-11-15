import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["inbox", "count", "status", "detail", "detailBody"]
  connect() {
    this.connected = true
    this.pages = { notices: 1, tasks: 1, incidents: 1 }
    this.load()
    this.timer = setInterval(() => this.refresh(), 20000)
  }
  disconnect() { this.connected = false; clearInterval(this.timer); clearTimeout(this.debounce); this.request?.abort() }
  get driver() { return this.application.getControllerForElementAndIdentifier(this.element, "repartidor") }
  schedule() { clearTimeout(this.debounce); this.debounce = setTimeout(() => this.refresh(), 400) }
  page(event) { this.pages[event.currentTarget.dataset.pageScope || "notices"] = Number(event.currentTarget.dataset.page); this.refresh() }
  async load() {
    try {
      const driver = this.driver
      await driver.ready
      const cached = await driver.store.inbox(driver.accountValue)
      if (!this.connected || driver.locked) return
      if (cached && this.hasInboxTarget && (driver.restoredValue || !navigator.onLine)) { this.pages = cached.page_state || this.pages; this.render(cached) }
      await this.pendingActions()
      this.refresh()
    } catch { if (this.connected) this.statusTarget.textContent = "No se pudo recuperar la bandeja del dispositivo." }
  }
  render(data) {
    if (this.element.querySelector("[data-workflow-form][data-work-dirty]") || this.detailTarget.open) return
    this.inboxTarget.innerHTML = data.html
    this.countTargets.forEach(target => { target.textContent = data.pending; target.hidden = data.pending === 0 })
    this.statusTarget.textContent = `Última bandeja descargada: ${new Date(data.downloaded_at).toLocaleString("es-AR")}.`
  }
  async refresh() {
    if (!this.connected || this.loading || !navigator.onLine || document.visibilityState === "hidden") return
    const driver = this.driver
    await driver.ready
    if (driver.locked || await driver.store.active() !== driver.accountValue) return
    this.loading = true
    this.request = new AbortController()
    try {
      const response = await fetch(`/repartidor/avisos?page=${this.pages.notices}&tasks_page=${this.pages.tasks}&incidents_page=${this.pages.incidents}`, { credentials: "same-origin", cache: "no-store", redirect: "error", headers: { Accept: "application/json" }, signal: AbortSignal.any([this.request.signal, AbortSignal.timeout(12000)]) })
      if (!response.ok || !response.headers.get("content-type")?.includes("application/json")) throw new Error("No se confirmó la conexión")
      const data = { ...await response.json(), downloaded_at: new Date().toISOString() }
      if (!this.connected || driver.locked || await driver.store.active() !== driver.accountValue) return
      await driver.store.saveInbox(driver.accountValue, data)
      this.render(data)
      await this.pendingActions()
    } catch { if (this.connected) this.statusTarget.textContent = "Bandeja sin actualización confirmada. Se conservan los últimos datos descargados." }
    finally { this.loading = false }
  }
  async pendingActions() {
    const driver = this.driver
    const rows = await driver.store.operations(driver.accountValue)
    for (const row of rows.filter(row => row.operation_type === "workflow" && ["pending", "syncing", "conflict", "invalid"].includes(row.state))) {
      const data = row.workflow
      this.element.querySelectorAll("[data-workflow-form]").forEach(form => {
        if (form.elements.id?.value !== String(data.id) || !(form.dataset.command === data.command || (form.dataset.command.startsWith("task_") && data.command.startsWith("task_")))) return
        form.querySelector("[type=submit]").disabled = true
        form.querySelector("[data-workflow-message]").textContent = row.state === "pending" || row.state === "syncing" ? "Acción guardada en el dispositivo, pendiente de confirmación del servidor." : `La acción requiere revisión: ${row.error || row.state}. Consultá los registros del dispositivo.`
      })
    }
  }
  async submit(event) {
    event.preventDefault()
    const form = event.target, button = form.querySelector("[type=submit]"), message = form.querySelector("[data-workflow-message]")
    button.disabled = true
    let saved = false
    try {
      const driver = this.driver
      await driver.ready
      const values = Object.fromEntries(new FormData(form))
      delete values.photos
      values.command = form.dataset.command
      const files = []
      if (values.command === "incident_report") {
        values.occurred_at = new Date().toISOString()
        const originals = Array.from(form.querySelector('[name="photos"]').files)
        if (originals.length > 4) throw new Error("Podés adjuntar hasta 4 fotos")
        message.textContent = "Preparando el reporte y sus fotografías…"
        for (const file of originals) {
          if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) throw new Error("Usá fotografías JPEG, PNG o WebP")
          const bitmap = await createImageBitmap(file)
          const scale = Math.min(1, 1600 / Math.max(bitmap.width, bitmap.height))
          const canvas = document.createElement("canvas")
          canvas.width = Math.round(bitmap.width * scale); canvas.height = Math.round(bitmap.height * scale)
          canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height)
          bitmap.close()
          const blob = await new Promise(resolve => canvas.toBlob(resolve, "image/jpeg", .8))
          if (!blob || blob.size > 2 * 1024 * 1024) throw new Error("Una fotografía supera 2 MB después de reducirla")
          const sha256 = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", await blob.arrayBuffer())), byte => byte.toString(16).padStart(2, "0")).join("")
          files.push({ id: crypto.randomUUID(), kind: "incident_photo", sha256, blob })
        }
        values.photos = files.map(file => ({ id: file.id, sha256: file.sha256 }))
      }
      form.dataset.operationId ||= crypto.randomUUID()
      saved = await driver.store.enqueue(driver.accountValue, { operation_type: "workflow", operation_id: form.dataset.operationId,
        workflow: values, visit_id: values.visit_id || null, status: "pending", recorded_at: new Date().toISOString(), notes: values.description || values.result || values.message || "Comunicación interna",
        files, items: [], evidence: [], snapshot: { customer_name: form.dataset.customerName || "Avisos y tareas", items: [] } })
      if (!saved) throw new Error("Ya hay una acción equivalente guardada. Consultá los registros del dispositivo.")
      delete form.dataset.workDirty
      delete form.dataset.operationId
      form.reset()
      message.textContent = "Guardado en este dispositivo. Pendiente de confirmación del servidor; no se considera recibido ni ejecutado todavía."
      await this.pendingActions()
      await driver.updateSyncStatus()
      driver.syncNow()
    } catch (error) { message.textContent = error.message }
    finally { if (!saved) button.disabled = false }
  }
  async incident(event) {
    if (!navigator.onLine) { this.driver.notice("Sin conexión", "El detalle actualizado requiere conexión. Los avisos descargados y las acciones guardadas se conservan."); return }
    try {
      const response = await fetch(`/repartidor/incidencias/${event.currentTarget.dataset.id}`, { credentials: "same-origin", cache: "no-store", redirect: "error", headers: { Accept: "application/json" }, signal: AbortSignal.timeout(12000) })
      if (!response.ok) throw new Error("La incidencia ya no está disponible")
      const data = await response.json()
      if (!this.connected || this.driver.locked) return
      this.detailBodyTarget.innerHTML = data.html
      this.detailTarget.showModal()
    } catch (error) { this.driver.notice("No se pudo abrir el detalle", error.message) }
  }
  closeDetail() { this.detailTarget.close(); this.refresh() }
}
