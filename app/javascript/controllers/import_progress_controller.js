import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  connect() {
    this.timer = setTimeout(() => {
      if (!this.element.isConnected) return
      if (document.hidden) return this.connect()
      const frame = this.element.closest("turbo-frame")
      if (!frame) return
      const url = new URL(this.urlValue, window.location.origin).href
      if (frame.src === url) frame.reload()
      else frame.src = url
    }, 3000)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
