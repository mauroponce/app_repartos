import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "query"]

  disconnect() {
    clearTimeout(this.timer)
  }

  search(event) {
    if (event.isComposing) return
    clearTimeout(this.timer)
    const length = this.queryTarget.value.trim().length
    if (length === 0 || length >= 3) this.timer = setTimeout(() => this.submit(), 250)
  }

  submit() {
    clearTimeout(this.timer)
    this.formTarget.requestSubmit()
  }
}
