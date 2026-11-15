import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { url: String, state: String }
  static targets = ["message"]

  connect() {
    this.dirty = false
    this.events = new AbortController()
    const markDirty = event => { if (event.target.closest("form")) this.dirty = true }
    document.addEventListener("input", markDirty, { signal: this.events.signal })
    document.addEventListener("change", markDirty, { signal: this.events.signal })
    if (this.stateValue === "pending") this.timer = setInterval(() => this.refresh(), 3000)
  }

  disconnect() { clearInterval(this.timer); this.request?.abort(); this.events?.abort() }

  async refresh() {
    if (this.loading || document.visibilityState === "hidden") return
    this.loading = true
    this.request = new AbortController()
    try {
      const response = await fetch(this.urlValue, { cache: "no-store", credentials: "same-origin", redirect: "error", headers: { Accept: "application/json" }, signal: AbortSignal.any([this.request.signal, AbortSignal.timeout(10000)]) })
      if (!response.ok) return
      const data = await response.json()
      if (data.state !== this.stateValue) {
        clearInterval(this.timer)
        // Keep administrators' unsaved forms intact. The status remains
        // available by refreshing once they finish editing.
        if (!this.dirty) Turbo.visit(data.location, { action: "replace" })
        else this.messageTarget.textContent = "El cálculo terminó. Guardá tus cambios y actualizá la hoja para consultar el resultado."
      }
    } catch { /* Connectivity never implies successful publication. */ }
    finally { this.loading = false }
  }
}
