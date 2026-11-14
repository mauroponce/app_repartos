import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item", "count", "submit"]
  connect() { this.update() }
  all(event) {
    this.itemTargets.forEach(item => item.checked = event.target.checked)
    this.update()
  }
  update() {
    const count = this.itemTargets.filter(item => item.checked).length
    this.countTarget.textContent = `${count} entregas seleccionadas`
    this.submitTarget.disabled = count === 0
  }
}
