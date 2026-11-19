import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["link"]

  open(event) {
    if (event.target.closest("a, button, input, select, textarea")) return
    this.linkTarget.click()
  }
}
