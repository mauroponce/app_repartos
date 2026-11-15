import { Controller } from "@hotwired/stimulus"
import { photonPlaces } from "photon_places"

export default class extends Controller {
  static targets = ["map", "query", "results", "searchMessage", "positionMessage", "latitude", "longitude", "confirmed", "address", "city", "name"]
  static values = { readonly: Boolean, latitude: String, longitude: String, photonUrl: String, tilesUrl: String }

  async connect() {
    this.connection = Symbol()
    const connection = this.connection
    this.requestVersion = 0
    this.places = []
    this.activeIndex = -1
    this.tileErrorShown = false
    try {
      this.L = await import("leaflet")
      if (this.connection !== connection || !this.element.isConnected) return
      const [latitude, longitude] = this.currentCoordinates()
      const located = this.validCoordinates(latitude, longitude)
      this.map = this.L.map(this.mapTarget, { scrollWheelZoom: false }).setView(
        located ? [latitude, longitude] : [-34.8003128, -58.337029], located ? 16 : 12
      )
      this.L.tileLayer(this.tilesUrlValue, {
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
      }).on("tileerror", () => {
        if (!this.connection || this.tileErrorShown) return
        this.tileErrorShown = true
        this.positionMessageTarget.textContent = "No pudimos cargar las imágenes del mapa. Las coordenadas se conservan y podés ingresarlas directamente."
      }).addTo(this.map)
      if (located) this.setPosition(latitude, longitude, { write: false })
      if (!this.readonlyValue) {
        this.map.on("click", event => {
          const point = event.latlng.wrap()
          this.setPosition(point.lat, point.lng, { confirm: true })
        })
      }
      this.resizeObserver = new ResizeObserver(() => {
        cancelAnimationFrame(this.resizeFrame)
        this.resizeFrame = requestAnimationFrame(() => this.map?.invalidateSize({ pan: false }))
      })
      this.resizeObserver.observe(this.mapTarget)
    } catch {
      if (this.connection === connection) this.positionMessageTarget.textContent = "No pudimos cargar el mapa. Podés ingresar latitud y longitud directamente."
    }
  }

  disconnect() {
    this.connection = null
    this.cancelSearch()
    this.resizeObserver?.disconnect()
    cancelAnimationFrame(this.resizeFrame)
    this.map?.remove()
    this.map = null
    this.marker = null
  }

  currentCoordinates() {
    return [
      this.number(this.hasLatitudeTarget ? this.latitudeTarget.value : this.latitudeValue),
      this.number(this.hasLongitudeTarget ? this.longitudeTarget.value : this.longitudeValue)
    ]
  }

  number(value) {
    return value == null || String(value).trim() === "" ? NaN : Number(value)
  }

  validCoordinates(latitude, longitude) {
    return Number.isFinite(latitude) && Math.abs(latitude) <= 90 && Number.isFinite(longitude) && Math.abs(longitude) <= 180
  }

  setPosition(latitude, longitude, { write = true, confirm = false, pan = false } = {}) {
    if (!this.validCoordinates(latitude, longitude)) return
    if (this.map) {
      if (this.marker) {
        this.marker.setLatLng([latitude, longitude])
      } else {
        this.marker = this.L.marker([latitude, longitude], {
          draggable: !this.readonlyValue,
          title: this.readonlyValue ? "Ubicación del cliente" : "Punto de entrega: arrastrá para ajustar",
          icon: this.L.divIcon({ className: "customer-map-pin", html: '<span aria-hidden="true"></span>', iconSize: [28, 28], iconAnchor: [14, 14] })
        }).addTo(this.map)
        if (!this.readonlyValue) this.marker.on("dragend", () => {
          const point = this.marker.getLatLng().wrap()
          this.setPosition(point.lat, point.lng, { confirm: true })
        })
      }
      if (pan) this.map.setView([latitude, longitude], 16, { animate: false })
    }
    if (write && this.hasLatitudeTarget) {
      this.latitudeTarget.value = latitude.toFixed(7)
      this.longitudeTarget.value = longitude.toFixed(7)
    }
    if (confirm && this.hasConfirmedTarget) this.confirmedTarget.value = "true"
    this.positionMessageTarget.textContent = this.readonlyValue ? "Punto de entrega guardado." : `Punto de entrega: ${latitude.toFixed(7)}, ${longitude.toFixed(7)}.`
  }

  coordinatesChanged() {
    const [latitude, longitude] = this.currentCoordinates()
    if (this.validCoordinates(latitude, longitude)) {
      this.setPosition(latitude, longitude, { write: false, confirm: true, pan: true })
    } else {
      this.marker?.remove()
      this.marker = null
      this.confirmedTarget.value = "false"
      this.positionMessageTarget.textContent = "Completá una latitud entre -90 y 90 y una longitud entre -180 y 180."
    }
  }

  addressChanged() {
    this.cancelSearch()
    this.hideResults()
    this.latitudeTarget.value = ""
    this.longitudeTarget.value = ""
    this.confirmedTarget.value = "false"
    this.marker?.remove()
    this.marker = null
    this.positionMessageTarget.textContent = "La dirección cambió. Buscala nuevamente o confirmá el punto en el mapa."
  }

  cancelSearch() {
    clearTimeout(this.searchTimer)
    clearTimeout(this.requestTimeout)
    this.abortController?.abort()
    this.requestVersion = (this.requestVersion || 0) + 1
  }

  scheduleSearch() {
    this.cancelSearch()
    this.hideResults()
    this.searchMessageTarget.textContent = ""
    if (this.queryTarget.value.trim().length >= 3) this.searchTimer = setTimeout(() => this.search(), 350)
  }

  async search() {
    this.cancelSearch()
    this.hideResults()
    const query = this.queryTarget.value.trim().slice(0, 255)
    if (query.length < 3) {
      this.searchMessageTarget.textContent = "Escribí al menos 3 caracteres para buscar."
      return
    }
    const version = this.requestVersion
    const controller = new AbortController()
    this.abortController = controller
    this.requestTimeout = setTimeout(() => controller.abort(), 8000)
    this.searchMessageTarget.textContent = "Buscando direcciones…"
    try {
      const url = new URL(this.photonUrlValue, window.location.origin)
      const center = this.map?.getCenter().wrap() || { lat: -34.8003128, lng: -58.337029 }
      url.search = new URLSearchParams({ q: query, limit: "8", lat: center.lat, lon: center.lng }).toString()
      url.searchParams.append("countrycode", "ar")
      url.searchParams.append("countrycode", "uy")
      const response = await fetch(url, { signal: controller.signal, credentials: "omit", headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error("Photon unavailable")
      const data = await response.json()
      if (version !== this.requestVersion || !this.element.isConnected) return
      if (!Array.isArray(data.features)) throw new Error("Invalid Photon response")
      this.places = photonPlaces(data.features)
      this.renderResults()
      this.searchMessageTarget.textContent = this.places.length ? "Elegí una dirección de la lista." : "No encontramos direcciones. Agregá la ciudad a la búsqueda o marcá el punto en el mapa."
    } catch {
      if (version === this.requestVersion && this.element.isConnected) {
        this.searchMessageTarget.textContent = "No pudimos buscar direcciones. Podés marcar el punto en el mapa o ingresar las coordenadas."
      }
    } finally {
      if (version === this.requestVersion) clearTimeout(this.requestTimeout)
    }
  }

  renderResults() {
    this.resultsTarget.replaceChildren()
    this.activeIndex = -1
    this.places.forEach((place, index) => {
      const item = document.createElement("li")
      item.role = "presentation"
      const option = document.createElement("button")
      option.type = "button"
      option.role = "option"
      option.id = `customer-location-result-${index}`
      option.tabIndex = -1
      option.setAttribute("aria-selected", "false")
      const title = document.createElement("span")
      title.className = "location-result-title"
      const name = document.createElement("strong")
      name.textContent = place.title
      const category = document.createElement("span")
      category.className = "location-result-type"
      category.textContent = place.category
      title.append(name, category)
      const description = document.createElement("span")
      description.className = "location-result-description"
      description.textContent = place.description
      option.append(title, description)
      if (!place.completeAddress) {
        const warning = document.createElement("span")
        warning.className = "location-result-warning"
        warning.textContent = "Dirección incompleta · Revisá calle, altura y punto de entrega."
        option.append(warning)
      }
      option.addEventListener("click", () => this.selectPlace(index))
      item.append(option)
      this.resultsTarget.append(item)
    })
    this.resultsTarget.hidden = this.places.length === 0
    this.queryTarget.setAttribute("aria-expanded", String(this.places.length > 0))
  }

  hideResults() {
    if (!this.hasResultsTarget) return
    this.resultsTarget.hidden = true
    this.resultsTarget.replaceChildren()
    this.queryTarget.setAttribute("aria-expanded", "false")
    this.queryTarget.removeAttribute("aria-activedescendant")
    this.activeIndex = -1
    this.places = []
  }

  keydown(event) {
    if (event.key === "Escape" && !this.resultsTarget.hidden) {
      event.preventDefault()
      event.stopPropagation()
      this.cancelSearch()
      this.hideResults()
    } else if (["ArrowDown", "ArrowUp"].includes(event.key) && this.places.length) {
      event.preventDefault()
      this.activeIndex = this.activeIndex < 0 ?
        (event.key === "ArrowDown" ? 0 : this.places.length - 1) :
        (this.activeIndex + (event.key === "ArrowDown" ? 1 : -1) + this.places.length) % this.places.length
      const options = this.resultsTarget.querySelectorAll("[role=option]")
      options.forEach((option, index) => option.setAttribute("aria-selected", String(index === this.activeIndex)))
      this.queryTarget.setAttribute("aria-activedescendant", options[this.activeIndex].id)
      options[this.activeIndex].scrollIntoView({ block: "nearest" })
    } else if (event.key === "Enter") {
      event.preventDefault()
      if (this.activeIndex >= 0) this.selectPlace(this.activeIndex)
      else this.search()
    }
  }

  selectCandidate(event) {
    const { latitude, longitude, address, city } = event.currentTarget.dataset
    if (address && this.hasAddressTarget) this.addressTarget.value = address
    if (city && this.hasCityTarget) this.cityTarget.value = city
    this.setPosition(Number(latitude), Number(longitude), { confirm: true, pan: true })
  }

  selectPlace(index) {
    const place = this.places[index]
    if (!place) return
    this.cancelSearch()
    this.hideResults()
    this.queryTarget.value = place.label
    this.addressTarget.value = place.address
    this.cityTarget.value = place.city
    if (!this.nameTarget.value.trim() && place.name) this.nameTarget.value = place.name
    this.setPosition(place.latitude, place.longitude, { confirm: true, pan: true })
    this.searchMessageTarget.textContent = place.completeAddress ?
      "Dirección seleccionada. Revisá los datos y ajustá el punto si hace falta." :
      "Ubicación seleccionada con dirección incompleta. Revisá calle y altura y confirmá el punto de entrega en el mapa."
    this.queryTarget.focus({ preventScroll: true })
  }
}
