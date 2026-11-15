import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = ["board", "status", "map", "mapStatus"]
  static values = { url: String, tiles: String }

  connect() {
    this.connected = true
    this.timer = setInterval(() => this.refresh(), 15000)
    this.initMap()
    this.renderStatus()
  }

  disconnect() {
    this.connected = false
    clearInterval(this.timer)
    clearTimeout(this.debounce)
    clearTimeout(this.locationExpiry)
    this.request?.abort()
    this.map?.remove()
  }

  boardTargetConnected() { this.boardSeenAt = performance.now(); this.expireLocations(); if (this.connected) this.renderStatus() }
  expireLocations() {
    if (!this.hasBoardTarget) return
    clearTimeout(this.locationExpiry)
    const elapsed = performance.now() - this.boardSeenAt
    const remaining = []
    this.boardTarget.querySelectorAll("[data-location-fresh-ms]").forEach(label => {
      const left = Number(label.dataset.locationFreshMs) - elapsed
      if (left <= 0) label.textContent = label.textContent.replace("Ubicación reciente", "Ubicación sin actualizar")
      else remaining.push(left)
    })
    this.updateMap()
    if (remaining.length) this.locationExpiry = setTimeout(() => this.expireLocations(), Math.min(...remaining) + 10)
  }
  renderStatus() { this.statusTarget.textContent = `Actualizado ${this.boardTarget.dataset.updatedAt}. Consulta de respaldo cada 15 segundos.` }
  schedule() { clearTimeout(this.debounce); this.debounce = setTimeout(() => this.refresh(), 250) }

  guardUpdate(event) {
    if (!["operations-board", "operations-stats"].includes(event.target.getAttribute("target"))) return
    const render = event.detail.render
    event.detail.render = async element => {
      if (this.element.querySelector("dialog[open]")) {
        this.statusTarget.textContent = "Los cambios se aplicarán al cerrar la edición."
        return
      }
      await render(element)
    }
  }

  async refresh() {
    if (!this.connected || this.loading || document.visibilityState === "hidden") return
    if (this.element.querySelector("dialog[open]")) {
      this.statusTarget.textContent = "Los cambios se aplicarán al cerrar la edición."
      return
    }
    this.loading = true
    this.request = new AbortController()
    try {
      const response = await fetch(this.urlValue, { credentials: "same-origin", cache: "no-store", redirect: "error", signal: AbortSignal.any([this.request.signal, AbortSignal.timeout(12000)]), headers: { Accept: "text/vnd.turbo-stream.html" } })
      if (!response.ok || !response.headers.get("content-type")?.includes("turbo-stream")) throw new Error("No se pudo verificar el estado")
      const html = await response.text()
      if (!this.connected) return
      // A dialog may have opened while the request was in flight.
      if (!this.element.querySelector("dialog[open]")) Turbo.renderStreamMessage(html)
    } catch {
      if (this.connected) this.statusTarget.textContent = "Sin actualización del servidor. Se conserva el último estado; reintentando…"
    } finally { this.loading = false }
  }

  openDispatch(event) { document.getElementById(event.currentTarget.dataset.dialogId)?.showModal() }
  closeDispatch(event) { event.currentTarget.closest("dialog").close() }

  async initMap() {
    try {
      this.L = await import("leaflet")
      if (!this.connected) return
      this.map = this.L.map(this.mapTarget, { scrollWheelZoom: false }).setView([-34.6, -58.4], 10)
      this.L.tileLayer(this.tilesValue, { maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>' }).addTo(this.map)
      this.pins = this.L.layerGroup().addTo(this.map)
      this.updateMap()
    } catch { if (this.connected) this.mapStatusTarget.textContent = "No se pudo cargar el mapa. Las ubicaciones siguen disponibles en cada hoja." }
  }

  updateMap() {
    if (!this.pins || !this.hasBoardTarget) return
    const markers = JSON.parse(this.boardTarget.dataset.markers || "[]")
    this.pins.clearLayers()
    markers.forEach(point => {
      point.fresh = point.fresh && performance.now() - this.boardSeenAt < point.fresh_for_ms
      const label = document.createElement("span")
      label.textContent = `${point.name} · ${point.captured_at} · ±${Math.round(point.accuracy)} m · ${point.fresh ? "reciente" : "sin actualizar"}`
      this.L.circleMarker([point.latitude, point.longitude], { color: point.fresh ? "#7552b4" : "#777", fillOpacity: .8, radius: 10 }).bindTooltip(label).addTo(this.pins)
    })
    if (markers.length && !this.fitted) {
      this.map.fitBounds(markers.map(point => [point.latitude, point.longitude]), { padding: [35, 35], maxZoom: 15 })
      this.fitted = true
    }
    this.mapStatusTarget.textContent = markers.length ? `${markers.length} repartidores con última ubicación conocida.` : "Todavía no hay ubicaciones compartidas."
  }
}
