import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { returnUrl: String }

  connect() {
    this.previousFocus = document.activeElement
    this.element.removeAttribute("open")
    this.element.showModal()
  }

  disconnect() {
    if (this.element.open) this.element.close()
  }

  close(event) {
    // A direct visit needs normal navigation; a Turbo frame can close in place.
    if (!document.querySelector("#directory, #product-results")) return
    event?.preventDefault()
    this.element.close()
  }

  backdrop(event) {
    const bounds = this.element.getBoundingClientRect()
    if (event.target === this.element && (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom)) this.close(event)
  }

  closed() {
    if (document.querySelector("#directory, #product-results")) {
      this.element.closest("turbo-frame").removeAttribute("src")
      this.previousFocus?.focus()
    } else {
      window.Turbo.visit(this.returnUrlValue || "/admin")
    }
  }
}
