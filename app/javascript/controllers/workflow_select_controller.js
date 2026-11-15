import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { kind: String, url: String }
  connect() {
    const labels = { customer: "cliente", product: "producto", route: "ruta", driver: "repartidor", manager: "responsable", staff: "responsable" }
    this.input = document.createElement("input")
    this.input.type = "search"
    this.input.placeholder = `Buscar ${labels[this.kindValue]}…`
    this.input.setAttribute("aria-label", `Buscar ${labels[this.kindValue]} para este campo`)
    this.input.autocomplete = "off"
    this.search = () => { clearTimeout(this.timer); this.timer = setTimeout(() => this.lookup(), 250) }
    this.input.addEventListener("input", this.search)
    this.input.addEventListener("keydown", event => { if (event.key === "Enter") { event.preventDefault(); this.element.focus() } })
    this.status = document.createElement("small")
    this.status.setAttribute("role", "status")
    this.element.before(this.input)
    this.element.after(this.status)
  }
  disconnect() { clearTimeout(this.timer); this.request?.abort(); this.input?.remove(); this.status?.remove() }
  async lookup() {
    this.request?.abort()
    this.request = new AbortController()
    try {
      const needle = this.input.value
      const url = new URL(this.urlValue, location.origin)
      url.searchParams.set("kind", this.kindValue)
      url.searchParams.set("q", this.input.value)
      const response = await fetch(url, { cache: "no-store", credentials: "same-origin", redirect: "error", headers: { Accept: "application/json" }, signal: this.request.signal })
      if (!response.ok) throw new Error("No se pudo buscar")
      const rows = await response.json()
      if (!this.element.isConnected || needle !== this.input.value) return
      const selected = this.element.selectedOptions[0]?.cloneNode(true)
      this.element.querySelectorAll("option[value]:not([value=''])").forEach(option => option.remove())
      if (selected?.value) this.element.append(selected)
      for (const row of rows) {
        if (String(row.id) === selected?.value) continue
        const option = new Option(row.name, row.id)
        this.element.add(option)
      }
      this.status.textContent = rows.length ? `${rows.length} resultados. Elegí una opción de la lista.` : "No se encontraron coincidencias."
    } catch (error) { if (error.name !== "AbortError") this.status.textContent = "No se pudo actualizar la búsqueda. Se conserva la selección." }
  }
}
