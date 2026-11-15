import { Controller } from "@hotwired/stimulus"
import { OfflineStore, unresolved } from "offline/store"
import { SyncEngine } from "offline/sync"

export default class extends Controller {
  static targets = ["screen", "nav", "content", "delivery", "emptyList", "map", "mapMessage", "fullMap", "nextMap", "pauseStatus", "pauseLabel", "recordButton", "connection", "notice", "noticeTitle", "noticeBody", "toast", "visitDialog", "saveButton", "syncStatus", "queue", "queueRows", "downloadedRoutes", "planUpdate"]
  static values = { markers: Array, tilesUrl: String, invalidVisit: Number, account: String, runId: String, workRevision: String, paused: Boolean, initialTab: String, restored: Boolean }

  connect() {
    this.connected = true
    this.workerChanged = () => this.checkWorker()
    navigator.serviceWorker?.addEventListener("controllerchange", this.workerChanged)
    this.filterName = "pending"
    this.query = ""
    this.paused = this.pausedValue
    this.renderPause()
    this.filterDeliveries()
    this.visitDialogTargets.forEach(dialog => {
      const select = dialog.querySelector('[name="visit[status]"]')
      if (select) this.resultChanged({ target: select })
    })
    this.store = new OfflineStore()
    this.prepareOffline()
    this.connection()
    this.initMap()
    if (this.initialTabValue) this.tab({ currentTarget: { dataset: { tab: this.initialTabValue } } })
    if (this.invalidVisitValue) this.showVisit(this.invalidVisitValue)
    if ("serviceWorker" in navigator && window.isSecureContext) {
      navigator.serviceWorker.register("/repartidor/service-worker.js", { scope: "/repartidor" }).then(() => navigator.serviceWorker.ready).then(() => this.checkWorker())
        .catch(() => this.toast("No se pudo activar el acceso sin conexión. Podés seguir usando la app."))
    }
  }

  disconnect() {
    this.connected = false
    navigator.serviceWorker?.removeEventListener("controllerchange", this.workerChanged)
    clearTimeout(this.toastTimer)
    clearTimeout(this.syncTimer)
    this.channel?.close()
    this.store?.db?.close()
    this.map?.remove()
  }

  async chooseRun(event) {
    event.preventDefault()
    const packages = await this.store.packages(this.accountValue)
    const pack = packages.find(pack => String(pack.id) === event.target.value)
    if (pack) {
      if (this.element.querySelector("[data-work-dirty]") && !window.confirm("Hay una visita sin guardar. ¿Descartar ese borrador y cambiar de ruta? Los registros guardados se conservan.")) return
      await this.replaceWork(pack)
    }
    else this.toast("Descargá esta ruta con conexión antes de abrirla")
  }

  tab(event) {
    const tab = event.currentTarget.dataset.tab
    this.screenTargets.forEach(screen => { screen.hidden = screen.id !== `screen-${tab}` })
    this.navTargets.forEach(button => {
      button.classList.toggle("active", button.dataset.tab === tab)
      button.setAttribute("aria-current", button.dataset.tab === tab ? "page" : "false")
    })
    this.contentTarget.scrollTop = 0
    if (tab === "route") this.map?.invalidateSize()
  }

  filter(event) {
    this.filterName = event.currentTarget.dataset.filter
    this.element.querySelectorAll("[data-filter]").forEach(button => {
      button.classList.toggle("active", button.dataset.filter === this.filterName)
      button.setAttribute("aria-pressed", String(button.dataset.filter === this.filterName))
    })
    this.filterDeliveries()
  }

  search(event) { this.query = event.target.value.trim().toLocaleLowerCase("es-AR"); this.filterDeliveries() }

  filterDeliveries() {
    let visible = 0
    this.deliveryTargets.forEach(delivery => {
      delivery.hidden = (this.filterName !== "all" && delivery.dataset.status !== this.filterName) || !delivery.dataset.search.includes(this.query)
      if (!delivery.hidden) visible++
    })
    this.emptyListTarget.hidden = visible !== 0
  }

  showVisit(id) {
    const dialog = this.visitDialogTargets.find(dialog => dialog.id === `visit-${id}`)
    if (dialog && !dialog.open) dialog.showModal()
  }

  openVisit(event) { this.showVisit(event.currentTarget.dataset.visitId) }
  closeDialog(event) { event.currentTarget.closest("dialog").close(); this.applyWorkUpdates() }

  resultChanged(event) {
    const form = event.target.form
    const completed = event.target.value === "completed"
    const quantities = form.querySelector("[data-quantities]")
    quantities.hidden = !completed
    quantities.querySelectorAll("input").forEach(input => { input.disabled = !completed })
    form.querySelector("textarea").required = !completed
    this.application.getControllerForElementAndIdentifier(form, "delivery-proof")?.resultChanged(event.target.value)
  }

  async submitVisit(event) {
    event.preventDefault()
    if (this.paused) { this.notice("Jornada en pausa", "Reanudá la jornada para registrar una visita."); return }
    const form = event.target
    const button = form.querySelector("[type=submit]")
    button.disabled = true
    try {
      await this.ready
      // Keep the authorization paired with the plan displayed in this form,
      // even when another tab or a background download replaces stored work.
      const visit = JSON.parse(form.dataset.workSnapshot || "null")
      if (!visit?.proof || String(visit.id) !== form.dataset.visitId) throw new Error("Actualizá la pantalla con conexión antes de registrar esta visita. No se guardó la visita.")
      const status = form.querySelector("select").value
      const items = visit.items.map(item => {
        if (status !== "completed") return { id: item.id, delivered_quantity: "0" }
        const input = form.querySelector(`#quantity-${item.id}`)
        if (!input || input.value.trim() === "") throw new Error("Registrá la cantidad entregada de cada producto, incluso cero. Si falta un campo, actualizá la pantalla con conexión.")
        return { id: item.id, delivered_quantity: input.value }
      })
      const proofController = this.application.getControllerForElementAndIdentifier(form, "delivery-proof")
      const receipt = proofController ? await proofController.build(status, items, visit.items) : {}
      const operation = { ...receipt, operation_id: crypto.randomUUID(), visit_id: visit.id, status,
        notes: form.querySelector("textarea").value, recorded_at: new Date().toISOString(), proof: visit.proof,
        snapshot: { customer_name: visit.customer_name, customer_address: visit.customer_address, items: visit.items },
        items }
      const saved = await this.store.enqueue(this.accountValue, operation)
      if (!saved) throw new Error("Esta visita ya tiene un registro local. Revisá los registros de este dispositivo.")
      form.closest("dialog").close()
      await this.updateSyncStatus()
      this.toast("Visita guardada en este dispositivo. Se sincronizará cuando haya conexión")
      this.syncNow()
    } catch (error) { this.notice("No se guardó la visita", error.message) }
    finally { button.disabled = this.paused }
  }

  pause() {
    this.paused = !this.paused
    this.renderPause()
    this.toast(this.paused ? "Jornada pausada en este dispositivo" : "Jornada reanudada")
  }

  renderPause() {
    this.pauseStatusTarget.textContent = this.paused ? "EN PAUSA" : "EN RUTA"
    this.pauseStatusTarget.classList.toggle("paused", this.paused)
    this.pauseStatusTarget.setAttribute("aria-pressed", String(this.paused))
    this.pauseLabelTarget.textContent = this.paused ? "Reanudar jornada" : "Pausar jornada"
    this.recordButtonTargets.forEach(button => { button.disabled = this.paused })
    this.saveButtonTargets.forEach(button => { button.disabled = this.paused })
  }

  connection() {
    this.connectionTarget.classList.toggle("visible", !navigator.onLine)
    this.saveButtonTargets.forEach(button => { button.disabled = this.paused })
    if (this.engine && navigator.onLine) this.syncNow()
  }

  async checkWorker() {
    const worker = navigator.serviceWorker?.controller
    if (!worker) return
    this.workerReady = await new Promise(resolve => {
      const channel = new MessageChannel()
      const timer = setTimeout(() => { channel.port1.close(); resolve(false) }, 5000)
      channel.port1.onmessage = event => { clearTimeout(timer); channel.port1.close(); resolve(event.data.prepared === true) }
      worker.postMessage({ type: "OFFLINE_STATUS" }, [channel.port2])
    })
    await this.updateSyncStatus()
  }

  prepareOffline() {
    this.ready = this.initializeOffline().catch(error => {
      this.syncStatusTarget.textContent = `No se preparó el dispositivo: ${error.message}`
      throw error
    })
    this.ready.catch(() => {})
  }

  async initializeOffline() {
    await this.store.open()
    const active = await this.store.active()
    const verifiedPage = !this.restoredValue && document.querySelector('meta[name="offline-account"]')?.content === this.accountValue
    if (active !== this.accountValue) {
      if (verifiedPage) await this.store.activate(this.accountValue)
      else { this.lockAccount(); return }
    }
    if ("BroadcastChannel" in window) {
      this.channel = new BroadcastChannel("repartos-account")
      this.channel.onmessage = event => { if (event.data !== this.accountValue) this.lockAccount() }
    }
    this.engine = new SyncEngine({ store: this.store, account: this.accountValue, changed: () => this.updateSyncStatus() })
    await this.updateSyncStatus()
    navigator.storage?.persist?.().catch(() => {})
    this.syncNow()
  }

  lockAccount(message = "La cuenta está bloqueada o cambió. Volvé a iniciar sesión para recuperar sus registros.") {
    clearTimeout(this.syncTimer)
    this.locked = true
    this.element.replaceChildren()
    const text = document.createElement("p")
    text.textContent = message
    const link = document.createElement("a")
    link.href = "/session/new"
    link.textContent = "Iniciar sesión"
    this.element.append(text, link)
  }

  async resume() {
    if (document.visibilityState === "hidden" || this.locked || !this.engine) return
    if (await this.store.active() !== this.accountValue) { this.lockAccount(); return }
    this.syncNow()
  }

  async syncNow(event) {
    if (!this.engine || this.locked || this.syncing) return
    this.syncing = true
    clearTimeout(this.syncTimer)
    try {
      await this.updateSyncStatus()
      const result = await this.engine.run(event?.type === "click")
      if (this.locked) return
      if (result.locked) { this.lockAccount(result.message); return }
      this.networkError = result.ok ? null : result.message
      if (result.ok) await this.applyWorkUpdates()
      await this.updateSyncStatus()
    } finally {
      this.syncing = false
      await this.updateSyncStatus()
      if (!this.locked && this.connected) this.syncTimer = setTimeout(() => this.syncNow(), 15000)
    }
  }

  markDraft(event) {
    if (event.target.closest("[data-checkpoint]")) return
    const form = event.target.closest("form[data-visit-id], form[data-workflow-form]")
    if (form) form.dataset.workDirty = "true"
  }

  async discardDraftsAndUpdate() {
    if (!window.confirm("Se descartarán los campos, fotos y firmas que todavía no guardaste. Los registros guardados en este dispositivo se conservan. ¿Aplicar la ruta actualizada?")) return
    this.element.querySelectorAll("[data-work-dirty]").forEach(form => delete form.dataset.workDirty)
    this.element.querySelectorAll("dialog[open]").forEach(dialog => dialog.close())
    await this.applyWorkUpdates()
  }

  async applyWorkUpdates() {
    if (!this.connected || this.locked || !this.store || await this.store.active() !== this.accountValue) return
    const packages = await this.store.packages(this.accountValue)
    const pack = packages.find(pack => String(pack.id) === this.runIdValue) || packages[0]
    if (!pack?.revision || pack.revision === this.workRevisionValue) return
    await this.replaceWork(pack, { automatic: true })
  }

  async replaceWork(pack, { automatic = false } = {}) {
    const active = await this.store.active()
    if (!this.connected || this.locked || active !== this.accountValue) return
    if (automatic && this.element.querySelector("dialog[open], [data-work-dirty]")) {
      if (this.hasPlanUpdateTarget) this.planUpdateTarget.hidden = false
      return
    }
    const template = document.createElement("template")
    template.innerHTML = pack.html
    const root = template.content.firstElementChild
    root.dataset.repartidorPausedValue = String(this.paused)
    // A cached fragment must never reclaim a partition using the authentication
    // metadata of the older document after another tab changed accounts.
    root.dataset.repartidorRestoredValue = "true"
    root.dataset.repartidorInitialTabValue = this.navTargets.find(nav => nav.getAttribute("aria-current") === "page")?.dataset.tab || "route"
    history.replaceState(null, "", pack.id === "empty" ? "/repartidor" : `/repartidor?run_id=${pack.id}`)
    this.element.replaceWith(root)
  }

  async updateSyncStatus() {
    if (!this.connected || this.locked || !this.store) return
    if (await this.store.active() !== this.accountValue) { this.lockAccount(); return }
    const rows = await this.store.operations(this.accountValue)
    if (!this.connected || this.locked) return
    const waiting = rows.filter(row => ["pending", "syncing"].includes(row.state)).length
    const conflicts = rows.filter(row => ["conflict", "invalid"].includes(row.state)).length
    const packs = await this.store.packages(this.accountValue)
    this.downloadedRoutesTarget.replaceChildren(...packs.map(pack => {
      const option = document.createElement("option")
      option.value = pack.id
      option.textContent = `${pack.name || "Sin ruta hoy"} ${pack.scheduled_date || ""}`
      option.selected = String(pack.id) === this.runIdValue
      return option
    }))
    const downloaded = packs.length ? `Datos descargados ${new Date(packs.at(-1).downloaded_at).toLocaleString("es-AR")}. ` : "Datos aún sin descargar. "
    this.syncStatusTarget.textContent = `${downloaded}${waiting} pendientes · ${conflicts} requieren atención. ${this.syncing ? "Sincronizando…" : this.networkError ? "Sin confirmar conexión con el servidor." : rows.length && !waiting && !conflicts ? "Sincronizado." : ""}${this.workerReady ? " Acceso offline preparado." : ""}`
    this.syncStatusTarget.parentElement.dataset.error = String(conflicts > 0)
    for (const row of rows) this.overlayOperation(row)
    this.filterDeliveries()
    const states = this.deliveryTargets.map(row => row.dataset.status)
    const total = states.length, pending = states.filter(status => status === "pending").length
    const stats = this.element.querySelectorAll(".sum-stat strong")
    if (stats.length) { stats[1].textContent = String(pending).padStart(2, "0"); stats[2].textContent = String(states.filter(status => status === "completed").length).padStart(2, "0") }
    const progress = total ? Math.round((total - pending) * 100 / total) : 0
    const bar = this.element.querySelector(".progress-track")
    if (bar) { bar.setAttribute("aria-valuenow", progress); bar.firstElementChild.style.width = `${progress}%` }
    const label = this.element.querySelector(".progress-meta strong")
    if (label) label.textContent = `${total - pending} de ${total} guardadas; ver estado de sincronización`
  }

  overlayOperation(row) {
    if (["visit_checkpoint", "workflow"].includes(row.operation_type)) return
    const statusLabels = { completed: "Visita realizada", not_attended: "No atendido", closed: "Cerrado", rescheduled: "Reprogramar", rejected: "Rechazada" }
    const stateLabels = { pending: "Guardada en el dispositivo", syncing: "Sincronizando", synced: "Sincronizada", conflict: "Conflicto: requiere administración", invalid: "Error de validación: requiere revisión" }
    const card = this.deliveryTargets.find(card => card.dataset.visitId === String(row.visit_id))
    if (card) {
      card.dataset.status = row.status
      const badge = card.querySelector(".delivery-state")
      badge.textContent = `${statusLabels[row.status]} · ${stateLabels[row.state]}`
      badge.className = `delivery-state ${row.state === "synced" ? "state-done" : "state-issue"}`
    }
    const dialog = this.visitDialogTargets.find(dialog => dialog.id === `visit-${row.visit_id}`)
    if (dialog) {
      const form = dialog.querySelector("form[data-visit-id]")
      if (form) form.remove()
      let result = dialog.querySelector(".local-result")
      if (!result) { result = document.createElement("p"); result.className = "local-result"; dialog.append(result) }
      result.textContent = `${statusLabels[row.status]} · ${stateLabels[row.state]}. ${row.error || ""} Cantidades: ${row.items.map(item => {
        const planned = row.snapshot?.items.find(original => String(original.id) === String(item.id))
        return planned ? `${planned.description}: ${item.delivered_quantity} / ${planned.planned_quantity} ${planned.unit}` : `#${item.id}: ${item.delivered_quantity}`
      }).join("; ")}. ${row.notes || ""}`
      this.localEvidence(dialog, row)
    }
    this.element.querySelectorAll(`.next-card [data-visit-id="${row.visit_id}"], .mini-stop[data-visit-id="${row.visit_id}"]`).forEach(button => {
      button.closest(".next-card, .mini-stop")?.setAttribute("hidden", "")
    })
  }

  async showQueue() {
    const rows = await this.store.operations(this.accountValue)
    this.queueRowsTarget.replaceChildren()
    for (const row of rows) {
      const block = document.createElement("div")
      block.className = "queue-row"
      const title = document.createElement("strong")
      title.textContent = `${row.operation_type === "workflow" ? "Comunicación interna" : row.operation_type === "visit_checkpoint" ? `Horario: ${row.checkpoint}` : "Visita"} ${row.visit_id ? `#${row.visit_id}` : ""} · ${ { pending: "Pendiente", syncing: "Sincronizando", synced: "Sincronizada", conflict: "Conflicto", invalid: "Error de validación" }[row.state] }`
      const details = document.createElement("pre")
      details.textContent = `${row.snapshot?.customer_name || ""}\n${row.recorded_at}\n${row.operation_id}\n${row.error || ""}\n${row.notes || ""}\n${row.items.map(item => {
        const planned = row.snapshot?.items.find(original => String(original.id) === String(item.id))
        return planned ? `${planned.description}: ${item.delivered_quantity} / ${planned.planned_quantity} ${planned.unit}` : `Producto #${item.id}: ${item.delivered_quantity}`
      }).join("\n")}`
      block.append(title, details)
      this.localEvidence(block, row)
      this.queueRowsTarget.append(block)
    }
    if (!rows.length) this.queueRowsTarget.textContent = "No hay registros locales."
    this.queueTarget.showModal()
  }

  async exportQueue() {
    const rows = await this.store.operations(this.accountValue)
    const data = await Promise.all(rows.map(async ({ proof, key, account, owner, files, ...row }) => ({ ...row, files: await Promise.all((files || []).map(async ({ blob, ...file }) => ({ ...file, data_url: await new Promise((resolve, reject) => {
      const reader = new FileReader()
      reader.onload = () => resolve(reader.result)
      reader.onerror = () => reject(reader.error)
      reader.readAsDataURL(blob)
    }) }))) })))
    const url = URL.createObjectURL(new Blob([JSON.stringify({ version: 1, account: this.accountValue, operations: data }, null, 2)], { type: "application/json" }))
    const link = document.createElement("a")
    link.href = url
    link.download = `repartos-registros-${Date.now()}.json`
    link.click()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }

  localEvidence(container, row) {
    if (["visit_checkpoint", "workflow"].includes(row.operation_type)) return
    container.querySelectorAll(".local-evidence").forEach(node => node.remove())
    const section = document.createElement("div")
    section.className = "local-evidence"
    const info = document.createElement("p")
    info.textContent = `${row.evidence?.length || 0} archivos de evidencia. ${row.receiver_name ? `Receptor: ${row.receiver_name}. ` : ""}${row.location ? "Ubicación registrada." : "Sin ubicación registrada."}`
    section.append(info)
    if (row.state === "synced") {
      const link = document.createElement("a")
      link.href = `/comprobantes/${row.visit_id}`
      link.textContent = "Ver comprobante con conexión"
      section.append(link)
    } else if (row.files?.length) {
      const download = document.createElement("button")
      download.type = "button"
      download.className = "btn btn-secondary"
      download.textContent = "Descargar evidencias guardadas"
      download.addEventListener("click", () => {
        row.files.forEach(file => {
          const url = URL.createObjectURL(file.blob)
          const link = document.createElement("a")
          link.href = url
          link.download = `${file.kind}-${file.id}.${file.blob.type === "image/png" ? "png" : "jpg"}`
          link.click()
          setTimeout(() => URL.revokeObjectURL(url), 1000)
        })
      })
      section.append(download)
    }
    container.append(section)
  }

  async logout(event) {
    event.preventDefault()
    const rows = await this.store.operations(this.accountValue)
    const count = rows.filter(unresolved).length
    if (count && !window.confirm(`Hay ${count} registros sin sincronizar o para revisar. Se conservarán en este dispositivo y solamente se recuperarán al ingresar con esta misma cuenta. Podés cancelar para revisarlos o exportarlos. ¿Cerrar sesión conservándolos?`)) return
    try {
      const response = await fetch("/session", { method: "DELETE", credentials: "same-origin", headers: { "X-CSRF-Token": this.engine?.csrf || document.querySelector('meta[name="csrf-token"]')?.content || "" }, signal: AbortSignal.timeout(12000) })
      if (!response.ok) throw new Error("No se pudo cerrar la sesión. Conservá los registros y reintentá con conexión.")
      await this.store.activate(null)
      location.assign("/session/new")
    } catch (error) { this.notice("Sesión todavía activa", error.message) }
  }

  notifications() { this.tab({ currentTarget: { dataset: { tab: "inbox" } } }) }

  notice(title, body) {
    this.noticeTitleTarget.textContent = title
    this.noticeBodyTarget.textContent = body
    if (!this.noticeTarget.open) this.noticeTarget.showModal()
  }

  toast(message) {
    this.toastTarget.textContent = message
    this.toastTarget.classList.add("show")
    clearTimeout(this.toastTimer)
    this.toastTimer = setTimeout(() => this.toastTarget.classList.remove("show"), 4000)
  }

  prepareInstall(event) { event.preventDefault(); this.installEvent = event }

  async install() {
    if (window.matchMedia("(display-mode: standalone)").matches || navigator.standalone) {
      this.notice("Repartos ya está instalada", "Podés abrir la app desde tu pantalla de inicio.")
    } else if (this.installEvent) {
      await this.installEvent.prompt()
      await this.installEvent.userChoice
      this.installEvent = null
    } else {
      this.notice("Instalar Repartos", "En iPhone: abrí esta página en Safari, tocá Compartir y Agregar a inicio. En Android: abrí el menú de Chrome y elegí Instalar app o Agregar a pantalla principal. La instalación requiere HTTPS o localhost.")
    }
  }

  async initMap() {
    if (!this.hasMapTarget) return
    try {
      this.L = await import("leaflet")
      if (!this.connected) return
      const points = this.markersValue.map(stop => [stop.latitude, stop.longitude])
      if (!points.length) {
        this.mapMessageTarget.textContent = "Las paradas todavía no tienen coordenadas. Podés navegar usando su dirección."
        return
      }
      this.map = this.L.map(this.mapTarget, { zoomControl: false, scrollWheelZoom: false })
      this.L.tileLayer(this.tilesUrlValue, {
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
      }).on("tileerror", () => { this.mapMessageTarget.textContent = "No pudimos cargar el mapa. Las direcciones y el orden de las paradas siguen disponibles." }).addTo(this.map)
      // This line shows stop order; turn-by-turn directions open in Google Maps.
      if (points.length > 1) {
        this.L.polyline(points, { color: "#fff", weight: 9, interactive: false }).addTo(this.map)
        this.L.polyline(points, { color: "#4258f5", weight: 4, dashArray: "8 6", interactive: false }).addTo(this.map)
      }
      this.markersValue.forEach(stop => {
        const pin = document.createElement("span")
        pin.className = `stop-pin ${stop.status === "completed" ? "done" : stop.status !== "pending" ? "issue" : stop.current ? "current" : "future"}`
        pin.textContent = stop.status === "completed" ? "✓" : String(stop.position).padStart(2, "0")
        this.L.marker([stop.latitude, stop.longitude], {
          icon: this.L.divIcon({ className: "stop-icon-anchor", html: pin, iconSize: [39, 39], iconAnchor: [19, 19] }),
          title: `Parada ${stop.position}: ${stop.name}`
        }).addTo(this.map).on("click", () => this.showVisit(stop.id))
      })
      this.fitRoute()
    } catch {
      if (this.connected) this.mapMessageTarget.textContent = "El mapa no está disponible. Podés consultar las direcciones de tus entregas."
    }
  }

  fitRoute() {
    if (!this.map) return
    this.fullMapTarget.classList.add("active")
    this.nextMapTarget.classList.remove("active")
    this.map.fitBounds(this.markersValue.map(stop => [stop.latitude, stop.longitude]), { paddingTopLeft: [35, 65], paddingBottomRight: [35, 90], maxZoom: 15 })
  }

  nextStop() {
    const next = this.markersValue.find(stop => stop.current)
    if (!next || !this.map) { this.toast("La próxima parada no tiene ubicación disponible"); return }
    this.fullMapTarget.classList.remove("active")
    this.nextMapTarget.classList.add("active")
    this.map.setView([next.latitude, next.longitude], 16)
  }

}
