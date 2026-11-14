import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "query", "autocomplete", "suggestions", "message"]
  static values = { url: String }

  disconnect() { this.cancel() }
  cancel() {
    clearTimeout(this.timeout)
    this.request?.abort()
    this.matches = []
    this.activeIndex = -1
    if (this.hasSuggestionsTarget) this.suggestionsTarget.hidden = true
    if (this.hasQueryTarget) {
      this.queryTarget.setAttribute("aria-expanded", "false")
      this.queryTarget.removeAttribute("aria-activedescendant")
    }
    if (this.hasMessageTarget) this.messageTarget.textContent = ""
  }
  search(event) {
    if (event.isComposing) return
    this.cancel()
    if (!this.queryTarget.value.trim()) return this.submit()
    this.timeout = setTimeout(() => this.suggest(), 200)
  }
  async suggest() {
    const query = this.queryTarget.value.trim()
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("q", query)
    url.searchParams.set("status", this.formTarget.elements.status.value)
    this.request = new AbortController()
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" }, signal: this.request.signal })
      if (!response.ok || response.redirected) throw new Error("Suggestions unavailable")
      const matches = await response.json()
      if (this.queryTarget.value.trim() !== query || document.activeElement !== this.queryTarget) return
      this.matches = matches
      this.renderSuggestions()
    } catch (error) {
      if (error.name !== "AbortError" && this.hasMessageTarget) {
        this.messageTarget.textContent = "No pudimos cargar sugerencias. Podés buscar con el botón Buscar."
      }
    }
  }
  renderSuggestions() {
    this.suggestionsTarget.replaceChildren()
    this.matches.forEach((match, index) => {
      const option = document.createElement("li")
      option.id = `customer-suggestion-${index}`
      option.setAttribute("role", "option")
      option.setAttribute("aria-selected", "false")
      option.dataset.index = index
      option.dataset.action = "pointerdown->filter#retainFocus click->filter#choose"
      const name = document.createElement("strong")
      name.textContent = match.name
      const detail = document.createElement("span")
      detail.textContent = [match.contact, match.city].filter(Boolean).join(" · ")
      option.append(name, detail)
      this.suggestionsTarget.append(option)
    })
    if (!this.matches.length) {
      const empty = document.createElement("li")
      empty.setAttribute("role", "presentation")
      empty.className = "suggestion-empty"
      empty.textContent = "Sin coincidencias. Probá otra búsqueda."
      this.suggestionsTarget.append(empty)
    }
    this.suggestionsTarget.hidden = false
    this.queryTarget.setAttribute("aria-expanded", "true")
    this.messageTarget.textContent = `${this.matches.length} sugerencias disponibles.`
  }
  retainFocus(event) { event.preventDefault() }
  choose(event) {
    const match = this.matches[Number(event.currentTarget.dataset.index)]
    if (!match) return
    this.queryTarget.value = match.name
    this.submit()
  }
  navigate(event) {
    if (event.isComposing) return
    if (event.key === "Escape" || event.key === "Tab") {
      if (event.key === "Escape" && !this.suggestionsTarget.hidden) event.preventDefault()
      this.cancel()
      return
    }
    if (this.suggestionsTarget.hidden || !this.matches?.length) return
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      const count = this.matches.length
      this.activeIndex = this.activeIndex < 0 ? (event.key === "ArrowDown" ? 0 : count - 1) : (this.activeIndex + (event.key === "ArrowDown" ? 1 : -1) + count) % count
      const options = this.suggestionsTarget.querySelectorAll("[role=option]")
      options.forEach((option, index) => option.setAttribute("aria-selected", String(index === this.activeIndex)))
      const active = options[this.activeIndex]
      this.queryTarget.setAttribute("aria-activedescendant", active.id)
      active.scrollIntoView({ block: "nearest" })
    } else if (event.key === "Enter" && this.activeIndex >= 0) {
      event.preventDefault()
      this.queryTarget.value = this.matches[this.activeIndex].name
      this.submit()
    }
  }
  outside(event) {
    if (!this.autocompleteTarget.contains(event.target)) this.cancel()
  }
  leave(event) {
    if (!this.autocompleteTarget.contains(event.relatedTarget)) this.cancel()
  }
  submit() {
    this.cancel()
    this.formTarget.requestSubmit()
  }
  rememberFocus() {
    this.refocus = document.activeElement === this.queryTarget
    this.selection = this.queryTarget.selectionStart
  }
  restoreFocus() {
    if (this.refocus) {
      this.queryTarget.focus({ preventScroll: true })
      this.queryTarget.setSelectionRange(this.selection, this.selection)
      this.refocus = false
    }
  }
}
