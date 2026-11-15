import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "menu"]

  toggle() {
    const open = this.menuTarget.classList.toggle("open")
    this.buttonTarget.setAttribute("aria-expanded", String(open))
  }

  close() {
    this.menuTarget.classList.remove("open")
    this.buttonTarget.setAttribute("aria-expanded", "false")
  }

  closeOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  closeOnFocusOut(event) {
    if (!this.element.contains(event.relatedTarget)) this.close()
  }

  escape() {
    if (!this.menuTarget.classList.contains("open")) return

    this.close()
    this.buttonTarget.focus()
  }
}
