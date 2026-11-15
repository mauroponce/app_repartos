import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { routes: Array, tilesUrl: String }

  async connect() {
    const connection = this.connection = Symbol()
    try {
      const L = await import("leaflet")
      if (this.connection !== connection || !this.element.isConnected) return
      this.map = L.map(this.element, { scrollWheelZoom: false })
      L.tileLayer(this.tilesUrlValue || "https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
      }).addTo(this.map)
      const colors = ["#7958b6", "#227a53", "#b35a20", "#286fa6"]
      const lines = this.routesValue.filter(route => route.geometry).map((route, index) => {
        const line = L.polyline(this.decode(route.geometry), { color: colors[index % colors.length], weight: 4 })
        const label = document.createElement("span")
        label.textContent = route.driver_name
        return line.bindTooltip(label).addTo(this.map)
      })
      if (lines.length) this.map.fitBounds(L.featureGroup(lines).getBounds(), { padding: [20, 20] })
      this.resizeObserver = new ResizeObserver(() => {
        if (!this.map || !this.element.clientWidth || !this.element.clientHeight) return
        this.map.invalidateSize({ pan: false })
        if (lines.length) this.map.fitBounds(L.featureGroup(lines).getBounds(), { padding: [20, 20] })
      })
      this.resizeObserver.observe(this.element)
    } catch {
      this.map?.remove()
      this.map = null
      if (this.connection === connection) this.element.textContent = "No se pudo mostrar el mapa. El orden y las estimaciones del recorrido se conservan."
    }
  }

  disconnect() {
    this.connection = null
    this.resizeObserver?.disconnect()
    this.map?.remove()
    this.map = null
  }

  decode(encoded) {
    let index = 0, latitude = 0, longitude = 0
    const points = []
    const read = () => {
      let result = 0, shift = 0, byte
      do {
        if (index >= encoded.length || shift > 30) throw new Error("Invalid polyline")
        byte = encoded.charCodeAt(index++) - 63
        result |= (byte & 0x1f) << shift
        shift += 5
      } while (byte >= 0x20)
      return (result & 1) ? ~(result >> 1) : (result >> 1)
    }
    while (index < encoded.length) {
      latitude += read()
      longitude += read()
      points.push([latitude / 1e5, longitude / 1e5])
    }
    return points
  }
}
