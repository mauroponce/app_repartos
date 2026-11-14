import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  reset() { this.element.classList.remove("menu-open") }
  toggle() { this.element.classList.toggle("collapsed") }
  mobile() { this.element.classList.toggle("menu-open") }
}
