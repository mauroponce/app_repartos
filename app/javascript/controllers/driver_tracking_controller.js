import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "status"]
  static values = { account: String }

  connect() {
    this.connected = true
    this.key = `repartos-location:${this.accountValue}`
    try { this.preference = sessionStorage.getItem(this.key) } catch { this.preference = null }
    this.enabled = this.preference === "enabled"
    this.stopping = this.preference === "stopping"
    this.render()
    this.timer = setInterval(() => this.tick(), 30000)
    this.tick()
  }

  disconnect() { this.connected = false; clearInterval(this.timer); clearTimeout(this.readinessTimer) }

  async toggle() {
    this.enabled = !this.enabled
    this.stopping = !this.enabled
    try { sessionStorage.setItem(this.key, this.enabled ? "enabled" : "stopping") } catch { /* Sharing still works for this screen. */ }
    this.render()
    await this.tick()
  }

  render(message) {
    this.buttonTarget.textContent = this.enabled ? "Detener ubicación" : "Compartir ubicación"
    this.buttonTarget.setAttribute("aria-pressed", String(this.enabled))
    this.statusTarget.textContent = message || (this.enabled ? "Ubicación activada mientras la app esté visible." : this.stopping ? "Deteniendo envío; se confirmará con conexión." : "Ubicación desactivada.")
  }

  async tick() {
    if (!this.connected || this.busy || document.visibilityState !== "visible" || !navigator.onLine || (!this.enabled && !this.stopping)) return
    const parent = this.element.closest('[data-controller~="repartidor"]')
    const driver = parent && this.application.getControllerForElementAndIdentifier(parent, "repartidor")
    if (!driver?.engine?.csrf) {
      // A freshly replaced route can be visible before its authentication
      // refresh finishes. Do not make the driver wait a full GPS interval.
      if (driver && !driver.locked) {
        this.render("Esperando conexión verificada para actualizar ubicación.")
        clearTimeout(this.readinessTimer)
        this.readinessTimer = setTimeout(() => this.tick(), 1000)
      }
      return
    }
    if (driver.locked || await driver.store.active() !== this.accountValue || this.busy) return
    this.busy = true
    const sharing = this.enabled
    try {
      let location = { sharing: false }
      if (sharing) {
        if (!navigator.geolocation) throw new Error("Este dispositivo no ofrece ubicación.")
        const position = await new Promise((resolve, reject) => navigator.geolocation.getCurrentPosition(resolve, reject, { enableHighAccuracy: true, maximumAge: 15000, timeout: 12000 }))
        location = { sharing: true, latitude: position.coords.latitude, longitude: position.coords.longitude, accuracy: position.coords.accuracy, captured_at: new Date(position.timestamp).toISOString() }
      }
      if (!this.connected || this.enabled !== sharing || driver.locked || document.visibilityState !== "visible" || await driver.store.active() !== this.accountValue) return
      const response = await fetch("/repartidor/api/v1/location", { method: "POST", credentials: "same-origin", cache: "no-store", redirect: "error", signal: AbortSignal.timeout(12000), headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": driver.engine.csrf }, body: JSON.stringify({ location: { ...location, account: this.accountValue } }) })
      if (!response.ok) throw new Error("No se pudo enviar ubicación; se reintentará con una jornada activa y conexión.")
      if (!this.connected || this.enabled !== sharing) return
      if (!sharing) { this.stopping = false; try { sessionStorage.removeItem(this.key) } catch { /* No stored preference. */ } }
      this.render(sharing ? `Última ubicación enviada ${new Date().toLocaleTimeString("es-AR")}.` : "Ubicación desactivada.")
    } catch (error) {
      if (!this.connected) return
      if (error.code === 1) {
        this.enabled = false
        this.stopping = true
        try { sessionStorage.setItem(this.key, "stopping") } catch { /* Retry while this screen remains open. */ }
        this.render("Permiso de ubicación denegado. Podés habilitarlo en el navegador.")
      } else this.render(error.message || "La ubicación no está disponible. Se reintentará.")
    } finally {
      this.busy = false
      // Apply a toggle immediately after an in-flight position or stop request.
      if (this.connected && sharing !== this.enabled && (this.enabled || this.stopping)) this.tick()
    }
  }
}
