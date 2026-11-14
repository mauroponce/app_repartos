import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "template", "row"]

  add() {
    this.sequence = (this.sequence || 0) + 1
    const key = `${Date.now()}${this.sequence}`
    this.listTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML.replaceAll("NEW_RECORD", key))
    this.listTarget.lastElementChild.querySelector("select, input:not([type=hidden])")?.focus()
  }

  remove(event) {
    const row = event.target.closest("[data-nested-items-target=row]")
    row.querySelector("[data-nested-items-destroy]").value = "1"
    row.hidden = true
    row.querySelectorAll("[required]").forEach(input => input.required = false)
  }
}
