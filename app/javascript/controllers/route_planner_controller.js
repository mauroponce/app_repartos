import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["step", "tab", "order", "stops", "count", "summary", "name", "date", "driver", "status", "error", "previous", "next"]
  static values = { availableUrl: String }

  connect() {
    this.currentStep = 0
    this.groupOrder = []
    this.selection()
    this.showStep()
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
    if (this.loading) {
      event.preventDefault()
      this.errorTarget.textContent = "Esperá a que terminen de cargar las entregas."
      return
    }
    if (this.statusTarget.value === "assigned" && !this.driverTarget.value) {
      event.preventDefault()
      this.currentStep = 0
      this.showStep()
      this.errorTarget.textContent = "Elegí un repartidor para guardar la hoja como asignada."
      this.driverTarget.focus()
    }
  }
}
