import { Controller } from "@hotwired/stimulus"
import { OfflineStore } from "offline/store"

export default class extends Controller {
  static targets = ["step", "status"]
  static values = { recorded: Object }
  connect() {
    this.connected = true
    this.store = new OfflineStore()
    this.visit = JSON.parse(this.element.dataset.workSnapshot)
    this.parent = this.element.closest('[data-controller~="repartidor"]')
    this.account = this.parent.dataset.repartidorAccountValue
    this.load()
  }
  disconnect() { this.connected = false; this.store.db?.close() }

  async load() {
    try {
      const rows = await this.store.operations(this.account)
      if (!this.connected) return
      this.times = { ...this.recordedValue }
      for (const row of rows) {
        if (row.operation_type === "visit_checkpoint" && String(row.visit_id) === String(this.visit.id) && row.plan_revision === this.visit.revision && ["pending", "syncing", "synced"].includes(row.state)) this.times[row.checkpoint] = row.occurred_at
      }
      this.render()
    } catch (error) { if (this.connected) this.statusTarget.textContent = `No se pudieron recuperar horarios: ${error.message}` }
  }

  async record(event) {
    const button = event.currentTarget
    button.disabled = true
    try {
      const driver = this.application.getControllerForElementAndIdentifier(this.parent, "repartidor")
      await driver.ready
      const checkpoint = button.dataset.checkpoint
      const time = new Date().toISOString()
      const saved = await this.store.enqueue(this.account, { operation_id: crypto.randomUUID(), operation_type: "visit_checkpoint", visit_id: this.visit.id,
        checkpoint, occurred_at: time, recorded_at: time, proof: this.visit.proof, plan_revision: this.visit.revision,
        status: "pending", notes: checkpoint, items: [], files: [], evidence: [], snapshot: this.visit })
      if (!saved) throw new Error("La etapa ya está guardada o la visita ya tiene un resultado. Revisá los registros del dispositivo.")
      await this.load()
      this.statusTarget.textContent = "Horario guardado en este dispositivo; consultá el estado de sincronización."
      driver.syncNow()
    } catch (error) { this.statusTarget.textContent = error.message; button.disabled = false }
  }

  render() {
    const fields = ["arrived_at", "unloading_started_at", "unloading_finished_at"]
    this.stepTargets.forEach(button => {
      const stage = button.dataset.checkpoint, index = fields.indexOf(stage)
      const time = this.times[stage]
      button.disabled = Boolean(time) || (index > 0 && !this.times[fields[index - 1]])
      button.textContent = time ? `${button.dataset.label}: ${new Date(time).toLocaleTimeString("es-AR")}` : button.dataset.label
    })
  }
}
