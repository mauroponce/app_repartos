import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list"]
  connect() { this.number() }
  up(event) {
    const row = event.currentTarget.closest("li")
    if (row.previousElementSibling) row.previousElementSibling.before(row)
    this.number()
    row.querySelector("button[data-action='stop-order#up']").focus()
  }
  down(event) {
    const row = event.currentTarget.closest("li")
    if (row.nextElementSibling) row.nextElementSibling.after(row)
    this.number()
    row.querySelector("button[data-action='stop-order#down']").focus()
  }
  number() {
    const rows = [...this.listTarget.children]
    rows.forEach((row, index) => {
      row.querySelector("[data-position]").textContent = index + 1
      row.querySelector("button[data-action='stop-order#up']").disabled = index === 0
      row.querySelector("button[data-action='stop-order#down']").disabled = index === rows.length - 1
    })
  }
}
