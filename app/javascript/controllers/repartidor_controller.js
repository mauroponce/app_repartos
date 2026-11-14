import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["screen", "nav", "content", "delivery", "emptyList", "map", "mapMessage", "fullMap", "nextMap", "pauseStatus", "pauseLabel", "recordButton", "connection", "notice", "noticeTitle", "noticeBody", "toast", "locationButton", "locationSwitch", "visitDialog", "saveButton"]
  static values = { markers: Array, tilesUrl: String, invalidVisit: Number }

  connect() {
    this.connected = true
    this.filterName = "pending"
    this.query = ""
    this.paused = false
    this.gpsWatch = null
    this.filterDeliveries()
    this.visitDialogTargets.forEach(dialog => {
      const select = dialog.querySelector("select")
      if (select) this.resultChanged({ target: select })
    })
    this.connection()
    this.initMap()
    if (this.invalidVisitValue) this.showVisit(this.invalidVisitValue)
    if ("serviceWorker" in navigator && window.isSecureContext) {
      navigator.serviceWorker.register("/repartidor/service-worker.js", { scope: "/repartidor" })
        .catch(() => this.toast("No se pudo activar el acceso sin conexión. Podés seguir usando la app."))
    }
  }

  disconnect() {
    this.connected = false
    clearTimeout(this.toastTimer)
    if (this.gpsWatch !== null) navigator.geolocation.clearWatch(this.gpsWatch)
    this.map?.remove()
  }

  chooseRun(event) { event.target.form.requestSubmit() }

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
  closeDialog(event) { event.currentTarget.closest("dialog").close() }

  resultChanged(event) {
    const form = event.target.form
    const completed = event.target.value === "completed"
    const quantities = form.querySelector("[data-quantities]")
    quantities.hidden = !completed
    quantities.querySelectorAll("input").forEach(input => { input.disabled = !completed })
    form.querySelector("textarea").required = !completed
  }

  submitVisit(event) {
    if (!navigator.onLine || this.paused) {
      event.preventDefault()
      this.notice(this.paused ? "Jornada en pausa" : "Sin conexión", this.paused ? "Reanudá la jornada para registrar una visita." : "Reconectate para guardar. Tus datos siguen en el formulario y todavía no se registraron.")
      return
    }
    // Prevent a second click while the server records the visit.
    event.target.querySelector("[type=submit]").disabled = true
  }

  pause() {
    this.paused = !this.paused
    this.pauseStatusTarget.textContent = this.paused ? "EN PAUSA" : "EN RUTA"
    this.pauseStatusTarget.classList.toggle("paused", this.paused)
    this.pauseStatusTarget.setAttribute("aria-pressed", String(this.paused))
    this.pauseLabelTarget.textContent = this.paused ? "Reanudar jornada" : "Pausar jornada"
    this.recordButtonTargets.forEach(button => { button.disabled = this.paused })
    this.saveButtonTargets.forEach(button => { button.disabled = this.paused || !navigator.onLine })
    this.toast(this.paused ? "Jornada pausada en este dispositivo" : "Jornada reanudada")
  }

  connection() {
    this.connectionTarget.classList.toggle("visible", !navigator.onLine)
    this.saveButtonTargets.forEach(button => { button.disabled = !navigator.onLine || this.paused })
  }

  notifications() {
    const pending = this.deliveryTargets.filter(delivery => delivery.dataset.status === "pending").length
    this.notice("Avisos de la jornada", pending ? `Tenés ${pending} paradas pendientes en esta ruta. Detenete en un lugar seguro antes de usar el teléfono.` : "No tenés paradas pendientes en esta ruta. Actualizá la pantalla para consultar nuevas asignaciones.")
  }

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

  locate() {
    if (!navigator.geolocation) { this.toast("Este navegador no permite usar GPS"); return }
    if (this.gpsWatch !== null) {
      navigator.geolocation.clearWatch(this.gpsWatch)
      this.gpsWatch = null
      this.gpsMarker?.remove()
      this.gpsMarker = null
      this.locationSwitchTarget.classList.remove("on")
      this.locationButtonTarget.setAttribute("aria-pressed", "false")
      this.toast("Ubicación desactivada")
      return
    }
    this.gpsWatch = navigator.geolocation.watchPosition(position => {
      if (!this.connected) return
      const point = [position.coords.latitude, position.coords.longitude]
      this.locationSwitchTarget.classList.add("on")
      this.locationButtonTarget.setAttribute("aria-pressed", "true")
      if (this.map) {
        if (this.gpsMarker) this.gpsMarker.setLatLng(point)
        else this.gpsMarker = this.L.circleMarker(point, { radius: 8, color: "#fff", weight: 3, fillColor: "#3671ff", fillOpacity: 1 }).addTo(this.map)
        this.map.panTo(point)
      }
    }, () => {
      navigator.geolocation.clearWatch(this.gpsWatch)
      this.gpsWatch = null
      this.locationSwitchTarget.classList.remove("on")
      this.locationButtonTarget.setAttribute("aria-pressed", "false")
      this.toast("No pudimos acceder al GPS. Revisá los permisos de ubicación.")
    }, { enableHighAccuracy: true, maximumAge: 15000, timeout: 15000 })
    this.toast("Solicitando permiso para usar tu ubicación")
  }
}
