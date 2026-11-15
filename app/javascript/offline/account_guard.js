import { OfflineStore } from "offline/store"

// Every authenticated/admin/login page updates the local access gate. A worker
// never stores or chooses a private account. Queues are retained when locked.
export async function guardAccount() {
  const identity = document.querySelector('meta[name="offline-account"]')?.content
  if (!identity || identity === "shell") return
  const store = new OfflineStore()
  try { await store.activate(identity === "locked" ? null : identity) } catch { /* The driver UI reports storage errors. */ }
  finally { store.db?.close() }
}
await guardAccount()
document.addEventListener("turbo:load", guardAccount)
window.addEventListener("pageshow", async event => {
  if (!event.persisted) return
  const expected = document.querySelector('meta[name="offline-account"]')?.content
  if (!expected || ["shell", "locked"].includes(expected)) return
  document.body.style.visibility = "hidden"
  const store = new OfflineStore()
  try {
    if (await store.active() !== expected) location.replace("/repartidor/shell")
    else document.body.style.visibility = ""
  } finally { store.db?.close() }
})
