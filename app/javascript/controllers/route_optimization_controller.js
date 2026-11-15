import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { pollUrl: String, pending: Boolean }
  static targets = ["status"]
  connect() { if (this.pendingValue) this.timer = setInterval(() => this.refresh(), 3000) }
  disconnect() { clearInterval(this.timer); this.request?.abort() }
  async refresh() {
    if (this.loading || document.visibilityState === "hidden") return
    this.loading = true
    this.request = new AbortController()
    try {
      const response = await fetch(this.pollUrlValue, { credentials: "same-origin", cache: "no-store", redirect: "error", headers: { Accept: "application/json" }, signal: AbortSignal.any([this.request.signal, AbortSignal.timeout(10000)]) })
      if (!response.ok) throw new Error("Actualización pendiente")
      const data = await response.json()
      if (!["queued", "processing"].includes(data.status)) { clearInterval(this.timer); Turbo.visit(data.location, { action: "replace" }) }
      else this.statusTarget.textContent = data.status === "queued" ? "Cálculo en cola. Podés salir y volver." : "Calculando la propuesta…"
    } catch { if (this.element.isConnected) this.statusTarget.textContent = "No se pudo consultar el resultado. Se conserva la hoja; reintentando al recuperar conexión…" }
    finally { this.loading = false }
  }
}
