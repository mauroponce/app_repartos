import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "query", "sort", "direction"]

  disconnect() {
    clearTimeout(this.timer)
  }

  search(event) {
    if (event.isComposing) return
    clearTimeout(this.timer)
    const length = this.queryTarget.value.trim().length
    if (length === 0 || length >= 3) this.timer = setTimeout(() => this.submit(), 250)
  }

  sort(event) {
    this.sortTarget.value = event.currentTarget.dataset.sort
    this.directionTarget.value = event.currentTarget.dataset.direction
  }

  submit() {
    clearTimeout(this.timer)
    this.formTarget.requestSubmit()
  }
}
