import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["step", "tab", "order", "stops", "count", "summary", "name", "date", "driver", "status", "error", "previous", "next", "proposalToken", "manualStops", "proposal", "depotLatitude", "depotLongitude", "vehicle", "optimizeButton", "evaluateButton", "releaseButton", "optimizationStatus", "confirmButton"]
  static values = { availableUrl: String, optimizeUrl: String, optimizedUrl: String, tilesUrl: String }

  connect() {
    this.currentStep = 0
    this.manualUrl = this.element.action
    this.pins = {}
    this.groupOrder = []
    this.selection()
    this.showStep()
  }

  disconnect() {
    this.cancelOptimization()
  }

  go(event) {
    const destination = Number(event.currentTarget.dataset.step)
    if (destination > this.currentStep && !this.validConfiguration()) return
    this.currentStep = destination
    this.showStep()
  }
  next() {
    if (!this.validConfiguration()) return
    this.currentStep = Math.min(3, this.currentStep + 1)
    this.showStep()
  }
  previous() {
    this.currentStep = Math.max(0, this.currentStep - 1)
    this.showStep()
  }
  showStep() {
    this.stepTargets.forEach((step, index) => step.hidden = index !== this.currentStep)
    this.tabTargets.forEach((tab, index) => {
      tab.setAttribute("aria-current", index === this.currentStep ? "step" : "false")
    })
    this.previousTarget.disabled = this.currentStep === 0
    this.nextTarget.hidden = this.currentStep === 3
    this.summary()
    if (this.currentStep > 0) {
      this.stepTargets[this.currentStep].querySelector("input,button,select")?.focus()
    }
  }
  validConfiguration() {
    const valid = this.nameTarget.reportValidity() && this.dateTarget.reportValidity()
    if (!valid) {
      this.currentStep = 0
      this.showStep()
      this.nameTarget.reportValidity()
      this.dateTarget.reportValidity()
    }
    return valid
  }
  dateChanged() {
    this.groupOrder = []
    const frame = this.element.querySelector("turbo-frame#available_orders")
    const url = new URL(this.availableUrlValue, window.location.origin)
    url.searchParams.set("date", this.dateTarget.value)
    this.loading = true
    this.orderTargets.forEach(order => { order.checked = false; order.disabled = true })
    this.selection()
    frame.src = url.toString()
    this.errorTarget.textContent = "Cargando entregas para la fecha…"
  }
  selection(event) {
    const optimized = this.optimizationRequired || this.proposal || this.optimizing
    this.useManual()
    if (optimized) {
      this.optimizationRequired = true
      this.optimizationStatusTarget.textContent = "La selección cambió. Volvé a optimizar o elegí planificación manual."
    }
    if (event?.type === "turbo:frame-load") {
      this.loading = false
      this.errorTarget.textContent = ""
    }
    const groups = new Map()
    this.orderTargets.filter(order => order.checked && !order.disabled).forEach(order => {
      const key = order.dataset.key
      if (!groups.has(key)) groups.set(key, [])
      groups.get(key).push(order)
    })
    this.groups = groups
    this.groupOrder = (this.groupOrder || []).filter(key => groups.has(key))
    groups.forEach((_, key) => { if (!this.groupOrder.includes(key)) this.groupOrder.push(key) })
    this.renderStops()
    this.countTarget.textContent = `${this.selectedCount} entregas · ${groups.size} paradas`
    this.summary()
  }
  get selectedCount() { return [...(this.groups?.values() || [])].reduce((total, rows) => total + rows.length, 0) }
  renderStops() {
    this.stopsTarget.replaceChildren()
    this.groupOrder.forEach((key, index) => {
      const orders = this.groups.get(key)
      const stop = document.createElement("li")
      stop.className = "planning-stop"
      const content = document.createElement("div")
      const title = document.createElement("strong")
      title.textContent = `${index + 1}. ${orders[0].dataset.customer}`
      content.append(title)
      const address = document.createElement("p")
      address.textContent = `${orders[0].dataset.address} · ${orders[0].dataset.time}`
      content.append(address)
      orders.forEach(order => {
        const line = document.createElement("p")
        line.textContent = `#${order.value} · ${order.dataset.merchandise}`
        content.append(line)
        const input = document.createElement("input")
        input.type = "hidden"
        input.name = "ordered_order_ids[]"
        input.value = order.value
        content.append(input)
        const remove = this.button(`Quitar entrega #${order.value}`, () => { order.checked = false; this.selection() })
        remove.className = "text-action"
        content.append(remove)
      })
      const actions = document.createElement("div")
      actions.className = "heading-actions"
      const up = this.button("↑", () => this.move(index, -1))
      up.setAttribute("aria-label", `Subir parada ${index + 1}`)
      up.disabled = index === 0
      const down = this.button("↓", () => this.move(index, 1))
      down.setAttribute("aria-label", `Bajar parada ${index + 1}`)
      down.disabled = index === this.groupOrder.length - 1
      actions.append(up, down)
      stop.append(content, actions)
      this.stopsTarget.append(stop)
    })
  }
  button(label, action) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn btn-white btn-sm"
    button.textContent = label
    button.addEventListener("click", action)
    return button
  }
  move(index, direction) {
    const destination = index + direction
    ;[this.groupOrder[index], this.groupOrder[destination]] = [this.groupOrder[destination], this.groupOrder[index]]
    this.renderStops()
    this.summary()
    this.stopsTarget.children[destination].querySelector(`button[aria-label^="${direction < 0 ? "Subir" : "Bajar"}"]`)?.focus()
  }
  summary() {
    if (!this.hasSummaryTarget) return
    this.summaryTarget.replaceChildren()
    const heading = document.createElement("h3")
    heading.textContent = `${this.nameTarget.value || "Sin nombre"} · ${this.dateTarget.value}`
    const driver = document.createElement("p")
    driver.textContent = `Repartidor: ${this.driverTarget.selectedOptions[0]?.textContent || "Sin repartidor"}`
    const totals = document.createElement("p")
    totals.textContent = `${this.selectedCount} entregas · ${this.groups?.size || 0} paradas`
    this.summaryTarget.append(heading, driver, totals)
    if (this.proposal) {
      driver.textContent = `${this.proposal.routes.filter(route => route.stops.length).length} hojas de ruta · ${this.proposal.unassigned.length} paradas sin asignar`
      const details = this.proposalTarget.cloneNode(true)
      details.removeAttribute("data-route-planner-target")
      details.querySelectorAll("button,label").forEach(control => control.remove())
      details.querySelectorAll("[data-controller='route-geometry']").forEach(map => map.remove())
      this.summaryTarget.append(details)
      return
    }
    this.groupOrder?.forEach((key, index) => {
      const orders = this.groups.get(key)
      const line = document.createElement("p")
      line.textContent = `${index + 1}. ${orders[0].dataset.customer} · ${orders[0].dataset.time} — ${orders.map(order => order.dataset.merchandise).join("; ")}`
      this.summaryTarget.append(line)
    })
  }
  search(event) {
    const query = event.target.value.toLocaleLowerCase("es").trim()
    this.orderTargets.forEach(order => order.closest("label").hidden = !order.closest("label").dataset.search.includes(query))
  }
  selectVisible() {
    this.orderTargets.filter(order => !order.disabled && !order.closest("label").hidden).forEach(order => order.checked = true)
    this.selection()
  }
  validateSubmission(event) {
    if (this.currentStep !== 3) {
      event.preventDefault()
      this.next()
      return
    }
    this.errorTarget.textContent = ""
    if (this.optimizing || ((this.optimizationRequired || this.proposal) && !this.proposalTokenTarget.value)) {
      event.preventDefault()
      this.errorTarget.textContent = this.optimizing ? "Esperá a que termine el cálculo." : "Validá los cambios o volvé a optimizar. Todos los pedidos deben quedar asignados sin incumplimientos."
      return
    }
    if (this.proposal) {
      this.element.action = this.optimizedUrlValue
      return
    }
    this.element.action = this.manualUrl
    if (this.loading) {
      event.preventDefault()
      this.errorTarget.textContent = "Esperá a que terminen de cargar las entregas."
      return
    }
    if ((this.statusTarget.value === "assigned" || event.submitter?.name === "confirm_and_optimize") && !this.driverTarget.value) {
      event.preventDefault()
      this.currentStep = 0
      this.showStep()
      this.errorTarget.textContent = "Elegí un repartidor para guardar la hoja como asignada."
      this.driverTarget.focus()
    }
  }

  cancelOptimization() {
    this.optimizationRequest?.abort()
    this.optimizationRequest = null
    this.optimizing = false
    if (this.hasOptimizeButtonTarget) this.optimizeButtonTarget.disabled = false
    if (this.hasEvaluateButtonTarget) this.evaluateButtonTarget.disabled = false
  }

  useManual() {
    this.cancelOptimization()
    this.proposal = null
    if (this.hasConfirmButtonTarget) this.confirmButtonTarget.hidden = false
    this.optimizationRequired = false
    this.pins = {}
    if (!this.hasProposalTokenTarget) return
    this.proposalTokenTarget.value = ""
    this.proposalTarget.replaceChildren()
    this.manualStopsTarget.hidden = false
    this.evaluateButtonTarget.hidden = true
    this.releaseButtonTarget.hidden = true
    this.optimizationStatusTarget.textContent = ""
    this.element.action = this.manualUrl
    this.summary()
  }

  optimizationSettingsChanged() {
    const hadProposal = !!this.proposal || this.optimizing || this.optimizationRequired
    this.useManual()
    if (hadProposal) {
      this.optimizationRequired = true
      this.optimizationStatusTarget.textContent = "La configuración cambió. Volvé a optimizar o elegí planificación manual."
    }
  }

  optimize() { return this.requestOptimization(false) }
  evaluate() { return this.requestOptimization(true) }
  releaseAssignments() {
    this.pins = {}
    return this.optimize()
  }

  async requestOptimization(evaluate) {
    if (this.optimizing || this.loading || !this.validConfiguration()) return
    if (!this.selectedCount) {
      this.optimizationStatusTarget.textContent = "Seleccioná al menos una entrega."
      return
    }
    if (evaluate && !this.proposal) return
    const vehicles = this.vehicleTargets.filter(row => row.querySelector("[data-fleet-enabled]").checked).map(row => ({
      driver_id: row.dataset.driverId,
      capacity: row.querySelector("[data-fleet-capacity]").value,
      start: row.querySelector("[data-fleet-start]").value,
      finish: row.querySelector("[data-fleet-finish]").value
    }))
    const input = {
      date: this.dateTarget.value,
      order_ids: this.orderTargets.filter(row => row.checked && !row.disabled).map(row => row.value),
      settings: { depot: [this.depotLongitudeTarget.value, this.depotLatitudeTarget.value], vehicles },
      pins: evaluate ? {} : this.pins
    }
    if (evaluate) {
      if (this.proposal.unassigned.length) {
        this.optimizationStatusTarget.textContent = "Asigná todas las paradas a un vehículo antes de validar, o volvé a optimizar."
        return
      }
      input.routes = this.proposal.routes.map(route => ({ driver_id: route.driver_id, job_ids: route.stops.map(stop => stop.id) }))
    }
    const request = new AbortController()
    this.optimizationRequest = request
    this.optimizing = true
    this.optimizeButtonTarget.disabled = true
    this.evaluateButtonTarget.disabled = true
    this.proposalTokenTarget.value = ""
    this.optimizationStatusTarget.textContent = evaluate ? "Validando recorrido sobre calles, horarios y capacidad…" : "Calculando recorridos sobre calles…"
    const timer = setTimeout(() => request.abort(), 40000)
    try {
      const response = await fetch(this.optimizeUrlValue, {
        method: "POST", signal: request.signal, credentials: "same-origin",
        headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
        body: JSON.stringify({ optimization: input })
      })
      if (response.redirected || [401, 403].includes(response.status)) throw new Error("Tu sesión no permite optimizar. Iniciá sesión nuevamente con una cuenta de administración.")
      if (!response.headers.get("Content-Type")?.includes("application/json")) throw new Error("No se pudo calcular la propuesta. Intentá nuevamente.")
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || "No se pudo calcular la propuesta. Revisá la selección.")
      if (this.optimizationRequest !== request) return
      this.proposal = data
      if (this.hasConfirmButtonTarget) this.confirmButtonTarget.hidden = true
      this.optimizationRequired = true
      this.proposalTokenTarget.value = data.token || ""
      this.manualStopsTarget.hidden = true
      this.renderProposal()
      this.optimizationStatusTarget.textContent = data.unassigned.length
        ? `${data.unassigned.length} paradas sin asignar. Revisá capacidades, horarios y ubicaciones. No se guardará una propuesta incompleta.`
        : data.violations.length ? "El recorrido incumple horarios o capacidad. Cambiá la propuesta o volvé a optimizar."
          : "Propuesta validada. Podés revisarla, modificarla o continuar para guardar las hojas. Vence en 30 minutos."
      this.summary()
    } catch (error) {
      if (this.optimizationRequest === request) this.optimizationStatusTarget.textContent = error.name === "AbortError" ? "El cálculo tardó demasiado. Intentá nuevamente." : error.message
    } finally {
      clearTimeout(timer)
      if (this.optimizationRequest === request) this.cancelOptimization()
    }
  }

  renderProposal() {
    this.proposalTarget.replaceChildren()
    this.evaluateButtonTarget.hidden = false
    this.releaseButtonTarget.hidden = Object.keys(this.pins).length === 0
    if (this.proposalTokenTarget.value && this.proposal.routes.length) {
      const map = document.createElement("div")
      map.className = "optimization-map"
      map.setAttribute("aria-label", "Recorridos sobre calles por vehículo")
      map.dataset.controller = "route-geometry"
      map.dataset.routeGeometryRoutesValue = JSON.stringify(this.proposal.routes)
      map.dataset.routeGeometryTilesUrlValue = this.tilesUrlValue
      this.proposalTarget.append(map)
    }
    this.proposal.routes.forEach(route => {
      if (!route.stops.length) return
      const section = document.createElement("section")
      section.className = "optimized-route"
      const heading = document.createElement("h3")
      heading.textContent = route.driver_name
      const metrics = document.createElement("p")
      metrics.textContent = this.proposalTokenTarget.value
        ? `${(route.distance / 1000).toFixed(1)} km · ${Math.ceil((route.finish - route.start) / 60)} min con descarga y esperas · ${route.load_units}/${route.capacity} unidades de carga`
        : "Recorrido pendiente de validación"
      const list = document.createElement("ol")
      list.className = "planning-stops"
      route.stops.forEach((stop, index) => list.append(this.proposalStop(stop, route, index)))
      section.append(heading, metrics, list)
      this.proposalTarget.append(section)
    })
    if (this.proposal.unassigned.length) {
      const heading = document.createElement("h3")
      heading.textContent = "Sin asignar"
      const list = document.createElement("ul")
      list.className = "planning-stops"
      this.proposal.unassigned.forEach((stop, index) => list.append(this.proposalStop(stop, null, index)))
      this.proposalTarget.append(heading, list)
    }
  }

  proposalStop(stop, route, index) {
    const item = document.createElement("li")
    item.className = "planning-stop"
    const content = document.createElement("div")
    const title = document.createElement("strong")
    title.textContent = `${index + 1}. ${stop.customer}`
    const details = document.createElement("p")
    const time = this.proposalTokenTarget.value && stop.arrival !== undefined ? ` · Inicio estimado ${this.clock(stop.arrival)}` : ""
    details.textContent = `${stop.address} · Pedidos ${stop.order_ids.map(id => `#${id}`).join(", ")} · ${stop.load_units} unidades · ${stop.service_minutes} min de descarga${time}`
    const label = document.createElement("label")
    label.textContent = "Vehículo (los cambios quedan fijos al volver a optimizar) "
    const select = document.createElement("select")
    select.setAttribute("aria-label", `Vehículo para ${stop.customer}`)
    select.add(new Option("Sin asignar", ""))
    this.proposal.vehicles.forEach(vehicle => select.add(new Option(vehicle.name, String(vehicle.driver_id))))
    select.value = route ? String(route.driver_id) : ""
    select.addEventListener("change", () => this.assignStop(stop, route, select.value))
    label.append(select)
    content.append(title, details, label)
    if (this.pins[stop.id]) {
      const pinned = document.createElement("p")
      pinned.textContent = "Asignación fija para la próxima optimización"
      content.append(pinned)
    }
    const actions = document.createElement("div")
    actions.className = "heading-actions"
    if (route) {
      const move = direction => {
        const destination = index + direction
        ;[route.stops[index], route.stops[destination]] = [route.stops[destination], route.stops[index]]
        this.proposalChanged()
      }
      const up = this.button("↑", () => move(-1))
      up.setAttribute("aria-label", `Subir ${stop.customer}`)
      up.disabled = index === 0
      const down = this.button("↓", () => move(1))
      down.setAttribute("aria-label", `Bajar ${stop.customer}`)
      down.disabled = index === route.stops.length - 1
      actions.append(up, down)
    }
    item.append(content, actions)
    return item
  }

  assignStop(stop, source, driverId) {
    const sourceStops = source ? source.stops : this.proposal.unassigned
    sourceStops.splice(sourceStops.indexOf(stop), 1)
    if (driverId) {
      let destination = this.proposal.routes.find(route => String(route.driver_id) === driverId)
      if (!destination) {
        const vehicle = this.proposal.vehicles.find(row => String(row.driver_id) === driverId)
        destination = { driver_id: vehicle.driver_id, driver_name: vehicle.name, capacity: vehicle.capacity, stops: [] }
        this.proposal.routes.push(destination)
      }
      destination.stops.push(stop)
      this.pins[stop.id] = Number(driverId)
    } else {
      this.proposal.unassigned.push(stop)
      delete this.pins[stop.id]
    }
    this.proposalChanged()
  }

  proposalChanged() {
    this.cancelOptimization()
    this.proposalTokenTarget.value = ""
    this.optimizationStatusTarget.textContent = "Cambiaste la propuesta. Validá el recorrido o volvé a optimizar antes de guardar."
    this.renderProposal()
    this.summary()
  }

  clock(seconds) {
    return `${String(Math.floor(seconds / 3600)).padStart(2, "0")}:${String(Math.floor(seconds % 3600 / 60)).padStart(2, "0")}`
  }
}
