import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["photos", "previews", "signature", "receiver", "reason", "message", "locationStatus", "locationButton", "discardError"]

  connect() {
    this.files = []
    this.urls = []
    this.drawingContext = this.signatureTarget.getContext("2d")
    this.clearSignature()
    this.resultChanged(this.element.querySelector('[name="visit[status]"]').value)
  }

  disconnect() {
    this.urls.forEach(url => URL.revokeObjectURL(url))
    this.disconnected = true
  }

  resultChanged(status) {
    this.reasonTarget.value = { not_attended: "absent", closed: "closed", rejected: "rejected", rescheduled: "customer_request" }[status] || ""
    this.reasonChanged()
  }

  reasonChanged() {
    this.element.querySelector("textarea").required = this.reasonTarget.value === "other"
  }

  photosChanged(event) {
    const selected = Array.from(event.target.files)
    event.target.value = ""
    this.processing = (this.processing || Promise.resolve()).then(() => this.addPhotos(selected))
  }

  async addPhotos(selected) {
    this.messageTarget.textContent = "Preparando fotografías…"
    this.photoError = null
    this.discardErrorTarget.hidden = true
    try {
      if (this.files.length + selected.length > 4) throw new Error("Podés adjuntar hasta 4 fotografías por visita.")
      const additions = []
      for (const file of selected) {
        if (!file.type.startsWith("image/") || file.size > 20 * 1024 * 1024) throw new Error("Elegí imágenes de hasta 20 MB; la app las reducirá antes de guardarlas.")
        const bitmap = await createImageBitmap(file)
        try {
          const scale = Math.min(1, 1600 / Math.max(bitmap.width, bitmap.height))
          const canvas = document.createElement("canvas")
          canvas.width = Math.max(1, Math.round(bitmap.width * scale))
          canvas.height = Math.max(1, Math.round(bitmap.height * scale))
          canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height)
          let blob = await this.canvasBlob(canvas, "image/jpeg", 0.82)
          if (blob.size > 2 * 1024 * 1024) blob = await this.canvasBlob(canvas, "image/jpeg", 0.6)
          if (blob.size > 2 * 1024 * 1024) throw new Error("No pudimos reducir esta foto a 2 MB. Elegí otra imagen.")
          additions.push(await this.evidence(blob, "photo"))
        } finally { bitmap.close() }
      }
      if (this.disconnected) return
      this.files.push(...additions)
      this.renderPhotos()
      this.messageTarget.textContent = `${this.files.length} de 4 fotografías preparadas para guardar con la visita.`
    } catch (error) {
      this.photoError = error.message || "No se pudo preparar la imagen. Probá con una fotografía JPEG o PNG."
      this.messageTarget.textContent = this.photoError
      this.discardErrorTarget.hidden = false
    }
  }

  discardPhotoError() {
    this.photoError = null
    this.discardErrorTarget.hidden = true
    this.messageTarget.textContent = "Se descartó la selección fallida. Las fotografías ya preparadas se conservan."
  }

  renderPhotos() {
    this.urls.forEach(url => URL.revokeObjectURL(url))
    this.urls = []
    this.previewsTarget.replaceChildren()
    this.files.forEach((file, index) => {
      const figure = document.createElement("figure")
      const image = document.createElement("img")
      image.src = URL.createObjectURL(file.blob)
      this.urls.push(image.src)
      image.alt = `Foto ${index + 1} de la entrega o incidencia`
      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "btn btn-secondary"
      remove.textContent = `Quitar foto ${index + 1}`
      remove.addEventListener("click", () => { this.files.splice(index, 1); this.renderPhotos() })
      figure.append(image, remove)
      this.previewsTarget.append(figure)
    })
  }

  clearSignature() {
    this.drawing = false
    this.drawingContext.fillStyle = "white"
    this.drawingContext.fillRect(0, 0, this.signatureTarget.width, this.signatureTarget.height)
    this.drawingContext.strokeStyle = "#20202a"
    this.drawingContext.lineWidth = 3
    this.drawingContext.lineCap = "round"
    this.signed = false
  }

  signatureStart(event) {
    event.preventDefault()
    this.drawing = true
    this.signatureTarget.setPointerCapture(event.pointerId)
    const point = this.point(event)
    this.drawingContext.beginPath()
    this.drawingContext.moveTo(point.x, point.y)
    this.drawingContext.lineTo(point.x + 0.1, point.y + 0.1)
    this.drawingContext.stroke()
    this.signed = true
  }

  signatureMove(event) {
    if (!this.drawing) return
    event.preventDefault()
    const point = this.point(event)
    this.drawingContext.lineTo(point.x, point.y)
    this.drawingContext.stroke()
  }

  signatureEnd() { this.drawing = false }
  point(event) {
    const rect = this.signatureTarget.getBoundingClientRect()
    return { x: (event.clientX - rect.left) * this.signatureTarget.width / rect.width, y: (event.clientY - rect.top) * this.signatureTarget.height / rect.height }
  }

  captureLocation() {
    if (!navigator.geolocation) { this.locationStatusTarget.textContent = "Este dispositivo no ofrece ubicación. Podés guardar igualmente."; return }
    this.locationButtonTarget.disabled = true
    this.location = null
    this.locationStatusTarget.textContent = "Buscando ubicación… Podés guardar sin ella si no está disponible."
    navigator.geolocation.getCurrentPosition(position => {
      if (this.disconnected) return
      this.location = { latitude: position.coords.latitude, longitude: position.coords.longitude, accuracy: position.coords.accuracy, captured_at: new Date(position.timestamp).toISOString() }
      this.locationStatusTarget.textContent = `Ubicación disponible · precisión aproximada ${Math.round(position.coords.accuracy)} m.`
      this.locationButtonTarget.disabled = false
    }, () => {
      if (this.disconnected) return
      this.location = null
      this.locationStatusTarget.textContent = "Ubicación no disponible o permiso denegado. Podés guardar el comprobante sin ella."
      this.locationButtonTarget.disabled = false
    }, { enableHighAccuracy: true, timeout: 8000, maximumAge: 60000 })
  }

  async build(status, items, plannedItems) {
    let pending
    do {
      pending = this.processing
      await pending
    } while (pending !== this.processing)
    if (this.photoError) throw new Error("Una foto no se pudo preparar. Elegí otra o descartá la selección fallida antes de guardar.")
    const partial = status === "completed" && items.some(item => Number(item.delivered_quantity) < Number(plannedItems.find(original => String(original.id) === String(item.id))?.planned_quantity))
    if ((partial || status !== "completed") && !this.reasonTarget.value) throw new Error("Elegí el motivo de la entrega parcial o fallida.")
    if (this.reasonTarget.value === "other" && !this.element.querySelector("textarea").value.trim()) throw new Error("Describí el motivo en observaciones.")
    const files = [...this.files]
    if (this.signed) {
      const signature = await this.canvasBlob(this.signatureTarget, "image/png")
      if (signature.size > 512 * 1024) throw new Error("La firma supera el tamaño permitido. Borrala e intentá de nuevo.")
      files.push(await this.evidence(signature, "signature"))
    }
    return { receipt_version: 1, failure_reason: this.reasonTarget.value || null, receiver_name: this.receiverTarget.value.trim(),
      location: this.location || null, evidence: files.map(({ id, kind, sha256 }) => ({ id, kind, sha256 })), files }
  }

  canvasBlob(canvas, type, quality) {
    return new Promise((resolve, reject) => canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error("No se pudo preparar la imagen")), type, quality))
  }

  async evidence(blob, kind) {
    const digest = await crypto.subtle.digest("SHA-256", await blob.arrayBuffer())
    const sha256 = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("")
    return { id: crypto.randomUUID(), kind, sha256, blob }
  }
}
