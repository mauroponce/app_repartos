// Only live memory can carry an active decision across Turbo replacements.
// Persistent storage carries a revocation marker, never permission to restart.
export class LocationSharing {
  constructor({ account, storage, geolocation }) {
    Object.assign(this, { account, storage, geolocation })
    this.key = `repartos-location-v2:${account}`
    try { this.marker = JSON.parse(storage.getItem(this.key) || "null") } catch { this.marker = null }
    this.enabled = false
    this.stopping = !!this.marker
    this.generation = 0
  }

  attach({ allowed, request, changed }) { Object.assign(this, { allowed, request, changed }); this.render() }
  render(message) { this.changed?.({ enabled: this.enabled, stopping: this.stopping, message }) }
  persist(marker) { this.storage.setItem(this.key, JSON.stringify(marker)); this.marker = marker }
  suspend() {
    this.generation++
    this.abort?.abort()
    this.cancelPosition?.()
  }

  async enable() {
    if (this.enabled || this.activating || this.busy) return
    this.activating = true
    const decision = ++this.generation
    try { await this.activate(decision) } finally { this.activating = false }
  }

  async activate(decision) {
    if (this.stopping) { await this.tick(); return }
    if (this.busy || !await this.allowed()) { this.render("Se requiere conexión verificada y una jornada activa para compartir ubicación."); return }
    if (decision !== this.generation) return
    try {
      // Durably record how to revoke BEFORE any request can enable sharing.
      this.persist({ consent_id: crypto.randomUUID() })
    } catch { this.render("No se pudo guardar el control de ubicación en este dispositivo. La ubicación sigue desactivada."); return }
    const generation = decision
    this.abort = new AbortController()
    this.busy = true
    try {
      const state = await this.request("GET", null, this.abort.signal)
      if (generation !== this.generation || !await this.allowed()) return
      const activated = await this.request("POST", { command: "activate", consent_id: this.marker.consent_id, expected_version: state.version }, this.abort.signal)
      if (generation !== this.generation || !await this.allowed()) return
      this.version = activated.version
      this.enabled = activated.sharing === true
      this.render()
    } catch (error) {
      this.enabled = false
      this.stopping = true
      this.render(error.message || "No se pudo activar la ubicación.")
    } finally {
      this.busy = false
      if (!this.enabled && this.marker) this.stopping = true
      if (this.enabled || this.stopping) this.tick()
    }
  }

  async disable() {
    this.enabled = false
    this.suspend()
    try { if (!this.marker) this.persist({ consent_id: crypto.randomUUID() }) } catch { /* No prior server activation could occur without its durable marker. */ }
    this.stopping = !!this.marker
    this.render()
    return this.tick()
  }

  position() {
    return new Promise((resolve, reject) => {
      if (!this.geolocation) { reject(new Error("Este dispositivo no ofrece ubicación.")); return }
      let watch
      const finish = (callback, value) => {
        if (watch !== undefined) this.geolocation.clearWatch(watch)
        this.cancelPosition = null
        callback(value)
      }
      this.cancelPosition = () => finish(reject, new Error("Ubicación cancelada"))
      watch = this.geolocation.watchPosition(position => finish(resolve, position), error => finish(reject, error), { enableHighAccuracy: true, maximumAge: 15000, timeout: 12000 })
    })
  }

  async tick() {
    if (this.busy || (!this.enabled && !this.stopping) || !await this.allowed({ stopping: this.stopping })) return
    if (this.busy) return
    this.busy = true
    const generation = this.generation
    const revoking = this.stopping
    this.abort = new AbortController()
    try {
      if (this.stopping) {
        await this.request("POST", { command: "deactivate", consent_id: this.marker.consent_id }, this.abort.signal)
        if (generation !== this.generation) return
        this.storage.removeItem(this.key)
        this.marker = null
        this.stopping = false
        this.render()
      } else {
        const position = await this.position()
        if (generation !== this.generation || !this.enabled || !await this.allowed()) return
        const result = await this.request("POST", { command: "sample", consent_id: this.marker.consent_id, expected_version: this.version,
          latitude: position.coords.latitude, longitude: position.coords.longitude, accuracy: position.coords.accuracy, captured_at: new Date(position.timestamp).toISOString() }, this.abort.signal)
        if (generation !== this.generation || !this.enabled) return
        if (!result.sharing || result.version !== this.version) throw new Error("El consentimiento cambió. Volvé a activarlo voluntariamente.")
        this.render(`Última ubicación enviada ${new Date(result.captured_at).toLocaleTimeString("es-AR")}.`)
      }
    } catch (error) {
      if (generation !== this.generation) return
      if (!revoking && (error.code === 1 || [401, 403, 409].includes(error.status))) {
        this.enabled = false
        this.stopping = !!this.marker
        this.generation++
        this.render(error.code === 1 ? "Permiso de ubicación denegado. El envío quedó desactivado." : "Sesión o consentimiento vencido. El envío quedó desactivado.")
      } else this.render(error.message || "No se pudo enviar ubicación; se reintentará con conexión.")
    } finally {
      this.busy = false
      if (generation !== this.generation && this.stopping) this.tick()
    }
  }
}

let liveSharing
export function locationSharingFor(account, dependencies) {
  if (liveSharing?.account !== account) {
    liveSharing?.disable()
    liveSharing = new LocationSharing({ account, ...dependencies })
  }
  return liveSharing
}
