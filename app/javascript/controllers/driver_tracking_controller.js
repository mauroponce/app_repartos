import { Controller } from "@hotwired/stimulus"
import { locationSharingFor } from "offline/location_sharing"

export default class extends Controller {
  static targets = ["button", "status"]
  static values = { account: String }

  connect() {
    this.connected = true
    this.sharing = locationSharingFor(this.accountValue, { storage: localStorage, geolocation: navigator.geolocation })
    this.sharing.attach({ allowed: options => this.allowed(options), request: (...args) => this.request(...args), changed: state => this.render(state) })
    this.timer = setInterval(() => this.tick(), 30000)
    this.tick()
  }

  disconnect() { this.connected = false; clearInterval(this.timer); clearTimeout(this.readinessTimer); this.sharing?.suspend() }
  async toggle() { return this.sharing.enabled ? this.sharing.disable() : this.sharing.enable() }
  stop() { this.sharing?.disable() }
  tick() {
    if (document.visibilityState !== "visible") this.sharing?.suspend()
    return this.sharing?.tick()
  }

  async allowed({ stopping = false } = {}) {
    if (!this.connected || !navigator.onLine || (!stopping && document.visibilityState !== "visible")) return false
    const parent = this.element.closest('[data-controller~="repartidor"]')
    const driver = parent && this.application.getControllerForElementAndIdentifier(parent, "repartidor")
    if (!driver?.engine?.csrf) {
      if (driver && !driver.locked) {
        clearTimeout(this.readinessTimer)
        this.readinessTimer = setTimeout(() => this.tick(), 1000)
      }
      return false
    }
    if (driver.locked || (!stopping && driver.paused) || await driver.store.active() !== this.accountValue) {
      if (this.sharing.enabled) this.sharing.disable()
      return false
    }
    this.csrf = driver.engine.csrf
    return true
  }

  async request(method, attributes, signal) {
    const timeout = setTimeout(() => this.sharing.abort?.abort(), 12000)
    try {
      const response = await fetch("/repartidor/api/v1/location", { method, signal, credentials: "same-origin", cache: "no-store", redirect: "error",
        headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": this.csrf },
        ...(attributes ? { body: JSON.stringify({ location: { ...attributes, account: this.accountValue } }) } : {}) })
      if (!response.ok) {
        const error = new Error("No se pudo enviar ubicación. Revisá la sesión, la jornada activa y la conexión.")
        error.status = response.status
        throw error
      }
      return await response.json()
    } finally { clearTimeout(timeout) }
  }

  render({ enabled, stopping, message }) {
    if (!this.connected) return
    this.buttonTarget.textContent = enabled ? "Detener ubicación" : "Compartir mi ubicación con la empresa"
    this.buttonTarget.setAttribute("aria-pressed", String(enabled))
    this.statusTarget.textContent = message || (enabled ? "Ubicación activada mientras la PWA esté visible y la jornada activa." : stopping ? "Ubicación desactivada en este dispositivo. Revocación pendiente de confirmar con conexión." : "Ubicación desactivada.")
  }
}
