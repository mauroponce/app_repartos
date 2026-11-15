import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = ["status"]
  static values = { countsUrl: String }
  connect() { this.connected = true; this.refresh(); this.timer = setInterval(() => this.refresh(), 20000) }
  disconnect() { this.connected = false; clearInterval(this.timer); clearTimeout(this.debounce); this.request?.abort() }
  schedule() { clearTimeout(this.debounce); this.debounce = setTimeout(() => this.refresh(), 300) }
  reload() { Turbo.visit(location.href, { action: "replace" }) }
  async refresh() {
    if (this.loading || document.visibilityState === "hidden") return
    this.loading = true
    this.request = new AbortController()
    try {
      const response = await fetch(this.countsUrlValue, { credentials: "same-origin", cache: "no-store", redirect: "error", headers: { Accept: "application/json" }, signal: AbortSignal.any([this.request.signal, AbortSignal.timeout(12000)]) })
      if (!response.ok) throw new Error("No se pudo actualizar")
      const data = await response.json()
      if (!this.connected) return
      Object.entries(data.counts).forEach(([key, value]) => document.querySelectorAll(`[data-workflow-count="${key}"]`).forEach(node => { node.textContent = value }))
      const revision = JSON.stringify(data.revision)
      if (this.revision && this.revision !== revision) {
        const target = document.getElementById("workflow-results")
        if (target && !target.querySelector("form[data-edited]")) {
          const page = await fetch(location.href, { cache: "no-store", credentials: "same-origin", redirect: "error", signal: AbortSignal.timeout(12000) })
          if (!page.ok) throw new Error("Actualización pendiente")
          const next = new DOMParser().parseFromString(await page.text(), "text/html").getElementById("workflow-results")
          if (this.connected && next && !target.querySelector("form[data-edited]")) target.replaceChildren(...next.childNodes)
        } else this.statusTarget.textContent = "Hay cambios del servidor. Terminá la edición y actualizá la pantalla."
      }
      this.revision = revision
      document.querySelectorAll("#workflow-results form").forEach(form => { form.oninput = () => { form.dataset.edited = "true" } })
    } catch { if (this.connected) this.statusTarget.textContent = "Sin actualización confirmada. Se conserva el último estado; reintentando…" }
    finally { this.loading = false }
  }
}
