import { Controller } from "@hotwired/stimulus"
import { OfflineStore } from "offline/store"

export default class extends Controller {
  async connect() {
    try {
      const store = new OfflineStore()
      const account = await store.active()
      const packages = account ? await store.packages(account) : []
      store.db?.close()
      const desired = new URL(location.href).searchParams.get("run_id")
      const pack = packages.find(pack => String(pack.id) === desired) || packages.sort((a, b) => b.downloaded_at.localeCompare(a.downloaded_at))[0]
      if (!pack) throw new Error("No hay una cuenta con datos descargados habilitada. Conectate e iniciá sesión. Los registros de otras cuentas se conservan protegidos.")
      // This HTML came from Rails' escaped templates and is private, partitioned
      // IndexedDB data. It contains no CSRF tokens or credentials.
      this.element.outerHTML = pack.html
    } catch (error) {
      this.element.querySelector("[role=status]").textContent = error.message
      const link = document.createElement("a")
      link.href = "/session/new"
      link.textContent = "Iniciar sesión con conexión"
      this.element.append(link)
    }
  }
}
