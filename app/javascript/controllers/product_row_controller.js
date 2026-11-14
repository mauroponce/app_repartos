import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["product", "description", "unit"]

  select() {
    const option = this.productTarget.selectedOptions[0]
    if (!option?.value) return
    this.descriptionTarget.value = option.dataset.description
    this.unitTarget.value = option.dataset.unit
  }
}
