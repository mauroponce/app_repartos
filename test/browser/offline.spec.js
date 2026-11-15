import { test, expect, chromium } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"

const fixture = (action, id = "") => {
  const command = process.env.PWA_TEST_SERVER === "1" ? ["bin/rails"] : ["docker", "compose", "exec", "-T", "web", "bin/rails"]
  const output = execFileSync(command[0], [...command.slice(1), "runner", "test/browser/fixtures.rb", action, String(id)], {
    encoding: "utf8", env: process.env.PWA_TEST_SERVER === "1" ? { ...process.env, RAILS_ENV: "test" } : process.env
  })
  return output.trim() ? JSON.parse(output.trim().split("\n").at(-1)) : null
}
const storeModule = async page => page.evaluate(async () => {
  const map = JSON.parse(document.querySelector('script[type="importmap"]').textContent)
  const { OfflineStore } = await import(map.imports["offline/store"])
  const store = new OfflineStore()
  return store.operations(await store.active())
})
async function signIn(page, data, baseURL) {
  await page.goto(`${baseURL}/session/new`)
  await page.locator('[name="email_address"]').fill(data.email)
  await page.locator('[name="password"]').fill(data.password)
  await page.getByRole("button", { name: "Ingresar" }).click()
  await page.waitForURL("**/repartidor")
  await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Datos descargados", { timeout: 30000 })
  await page.waitForFunction(() => navigator.serviceWorker.controller, null, { timeout: 15000 })
}
async function record(page, visitId, itemId, { status = "completed", quantity = "18", notes = "Registro sin conexión" } = {}) {
  await page.locator(`[data-repartidor-target="nav"][data-tab="deliveries"]`).click()
  await page.locator(`.delivery-item[data-visit-id="${visitId}"]`).click()
  const dialog = page.locator(`#visit-${visitId}`)
  if (status !== "completed") await dialog.locator(`#quantity-${itemId}`).fill("7")
  await dialog.locator('[name="visit[status]"]').selectOption(status)
  if (status === "completed") await dialog.locator(`#quantity-${itemId}`).fill(quantity)
  if (status === "completed" && Number(quantity) < 20) await dialog.locator('[data-delivery-proof-target="reason"]').selectOption("shortage")
  await dialog.locator('[name="visit[notes]"]').fill(notes)
  await dialog.locator('input[type="checkbox"]').check()
  await dialog.getByRole("button", { name: "Guardar visita" }).click()
  await expect(dialog).not.toBeVisible()
  await expect(page.locator("[data-repartidor-target=toast]")).toContainText("Visita guardada en este dispositivo")
}

test("several offline records survive a complete browser restart, worker update and safe synchronization", async ({ baseURL, launchOptions }) => {
  const data = fixture("create")
  const profile = mkdtempSync(path.join(tmpdir(), "repartos-pwa-"))
  const launch = { ...launchOptions, headless: true, viewport: { width: 390, height: 844 } }
  let context
  try {
    context = await chromium.launchPersistentContext(profile, launch)
    let page = await context.newPage()
    const errors = []
    page.on("pageerror", error => errors.push(error.message))
    await signIn(page, data, baseURL)
    await context.setOffline(true)
    await record(page, data.visit_ids[0], data.item_ids[0], { quantity: "20" })
    await record(page, data.visit_ids[1], data.item_ids[1], { quantity: "18" })
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("2 pendientes")
    expect((await storeModule(page)).map(row => row.state)).toEqual(["pending", "pending"])
    await context.close()

    context = await chromium.launchPersistentContext(profile, launch)
    await context.setOffline(true)
    page = await context.newPage()
    page.on("pageerror", error => errors.push(error.message))
    await page.goto(`${baseURL}/repartidor`)
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("2 pendientes")
    await expect(page.locator(".delivery-info strong").first()).toHaveText("Offline Test Customer")
    await record(page, data.visit_ids[2], data.item_ids[2], { status: "closed", notes: "Local cerrado" })
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("3 pendientes")
    // Upgrade path: replace the old worker/cache without touching IndexedDB.
    await page.route("**/repartidor/api/v1/operations", route => route.abort("failed"))
    await context.setOffline(false)
    await page.evaluate(async () => {
      await caches.open("repartidor-offline-obsolete")
      const controlled = new Promise((resolve, reject) => {
        navigator.serviceWorker.addEventListener("controllerchange", resolve, { once: true })
        setTimeout(() => reject(new Error("Updated worker did not activate")), 15000)
      })
      await navigator.serviceWorker.register(`/repartidor/service-worker.js?upgrade=${Date.now()}`, { scope: "/repartidor" })
      await controlled
    })
    await expect.poll(() => page.evaluate(async () => (await caches.keys()).includes("repartidor-offline-obsolete")), { timeout: 15000 }).toBe(false)
    expect((await storeModule(page)).filter(row => row.state !== "synced")).toHaveLength(3)
    await page.unroute("**/repartidor/api/v1/operations")
    // Let the durable queue's backoff expire; manual sync never fabricates an acknowledgement.
    await page.getByRole("button", { name: "Sincronizar ahora" }).click()
    await expect.poll(async () => (await storeModule(page)).map(row => row.state), { timeout: 45000 }).toEqual(["synced", "synced", "synced"])
    await page.reload()
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Sincronizado")
    const result = fixture("inspect", data.company_id)
    expect(result.operations).toEqual(["synced", "synced", "synced"])
    expect(result.quantities).toEqual(["20.0", "18.0", "0.0"])
    expect(result.orders).toEqual(["completed", "needs_attention", "needs_attention"])
    const keys = await page.evaluate(async () => {
      const entries = await Promise.all((await caches.keys()).map(async name => (await (await caches.open(name)).keys()).map(request => request.url)))
      return entries.flat()
    })
    expect(keys.some(url => url.includes("/api/") || new URL(url).pathname === "/repartidor")).toBe(false)
    expect(keys.some(url => url.includes("tile.openstreetmap"))).toBe(false)
    expect(errors).toEqual([])
  } finally {
    await context?.close()
    fixture("cleanup", data.company_id)
    rmSync(profile, { recursive: true, force: true })
  }
})

test("open forms preserve the displayed plan when a background download changes products or quantities", async ({ page, context, baseURL }) => {
  const data = fixture("create")
  try {
    await signIn(page, data, baseURL)
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).not.toContainText("Sincronizando")
    await page.locator('[data-repartidor-target="nav"][data-tab="deliveries"]').click()
    await page.locator(`.delivery-item[data-visit-id="${data.visit_ids[0]}"]`).click()
    const dialog = page.locator(`#visit-${data.visit_ids[0]}`)
    await dialog.locator(`#quantity-${data.item_ids[0]}`).fill("20")
    fixture("replan", data.company_id)
    // Run the same synchronization used by the background timer, with a dialog open.
    await page.evaluate(() => document.querySelector('[data-action="repartidor#syncNow"]').click())
    await expect.poll(() => page.evaluate(async runId => {
      const map = JSON.parse(document.querySelector('script[type="importmap"]').textContent)
      const { OfflineStore } = await import(map.imports["offline/store"])
      const store = new OfflineStore()
      try {
        const pack = (await store.packages(await store.active())).find(pack => pack.id === runId)
        return pack?.visits.map(visit => visit.items.map(item => item.planned_quantity))
      } finally { store.db?.close() }
    }, data.run_id), { timeout: 30000 }).toEqual([["20.0", "7.0"], ["25.0"], ["9.0"]])
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).not.toContainText("Sincronizando")
    await expect(dialog.locator(".record-item")).toHaveCount(1)
    await expect(dialog.locator("[data-quantities]")).toContainText("Previsto: 20")
    await expect(dialog.locator(`#quantity-${data.item_ids[0]}`)).toHaveValue("20")
    await context.setOffline(true)
    await dialog.getByRole("button", { name: "Cerrar", exact: true }).click()
    for (let index = 0; index < data.visit_ids.length; index++) {
      await record(page, data.visit_ids[index], data.item_ids[index], { quantity: "20" })
    }
    const rows = await storeModule(page)
    expect(rows.map(row => row.items)).toEqual(data.item_ids.map(id => [{ id, delivered_quantity: "20" }]))
    expect(rows.map(row => row.snapshot.items.map(item => item.planned_quantity))).toEqual([["20.0"], ["20.0"], ["20.0"]])
    await context.setOffline(false)
    await page.getByRole("button", { name: "Sincronizar ahora" }).click()
    await expect.poll(async () => (await storeModule(page)).map(row => row.state), { timeout: 45000 }).toEqual(["conflict", "conflict", "conflict"])
    const result = fixture("inspect", data.company_id)
    expect(result.operations).toEqual(["conflict", "conflict", "conflict"])
    expect(result.quantities).toEqual([null, null, null, null])
    expect(result.visits.map(([status]) => status)).toEqual(["pending", "pending", "pending"])
    expect(result.orders).toEqual(["pending", "pending", "pending"])
  } finally { await context.setOffline(false); fixture("cleanup", data.company_id) }
})

test("a missing quantity input is rejected instead of silently recording zero", async ({ page, baseURL }) => {
  const data = fixture("create")
  try {
    await signIn(page, data, baseURL)
    await page.locator('[data-repartidor-target="nav"][data-tab="deliveries"]').click()
    await page.locator(`.delivery-item[data-visit-id="${data.visit_ids[0]}"]`).click()
    const dialog = page.locator(`#visit-${data.visit_ids[0]}`)
    await dialog.locator(`#quantity-${data.item_ids[0]}`).evaluate(input => input.remove())
    await dialog.locator('input[type="checkbox"]').check()
    await dialog.getByRole("button", { name: "Guardar visita" }).click()
    await expect(page.locator('[data-repartidor-target="notice"]')).toContainText("No se guardó la visita")
    expect(await storeModule(page)).toEqual([])
    expect(fixture("inspect", data.company_id).quantities).toEqual([null, null, null])
  } finally { fixture("cleanup", data.company_id) }
})

test("account changes hide the previous queue without deleting unsent operations", async ({ page, context, baseURL }) => {
  const first = fixture("create"), second = fixture("create")
  try {
    await signIn(page, first, baseURL)
    await context.setOffline(true)
    await record(page, first.visit_ids[0], first.item_ids[0])
    await page.locator('[data-repartidor-target="nav"][data-tab="profile"]').click()
    page.once("dialog", dialog => dialog.dismiss())
    await page.getByRole("button", { name: "Cerrar sesión" }).click()
    expect((await storeModule(page))).toHaveLength(1)
    await page.route("**/repartidor/api/v1/operations", route => route.abort("failed"))
    await context.setOffline(false)
    // Visiting login locks data immediately, without replaying the old queue.
    await page.goto(`${baseURL}/session/new`)
    await signIn(page, second, baseURL)
    expect(await storeModule(page)).toEqual([])
    await context.setOffline(true)
    await page.reload()
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("0 pendientes")
    const old = await page.evaluate(async first => {
      const map = JSON.parse(document.querySelector('script[type="importmap"]').textContent)
      const { OfflineStore } = await import(map.imports["offline/store"])
      return new OfflineStore().operations(`${first.company_id}:${first.user_id}`)
    }, first)
    expect(old).toHaveLength(1)
    expect(old[0].state).toBe("pending")
    expect(fixture("inspect", first.company_id).operations).toEqual([])
  } finally {
    await context.setOffline(false)
    fixture("cleanup", first.company_id)
    fixture("cleanup", second.company_id)
  }
})

test("temporary server failure retains a record and retries after connectivity recovers", async ({ page, context, baseURL }) => {
  const data = fixture("create")
  try {
    await signIn(page, data, baseURL)
    await context.setOffline(true)
    await record(page, data.visit_ids[0], data.item_ids[0])
    let failed = 0
    await page.route("**/repartidor/api/v1/operations", async route => {
      failed++
      await route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: "temporary" }) })
    })
    await context.setOffline(false)
    await page.getByRole("button", { name: "Sincronizar ahora" }).click()
    await expect.poll(() => failed, { timeout: 25000 }).toBeGreaterThan(0)
    await expect.poll(async () => (await storeModule(page))[0].state).toBe("pending")
    expect(fixture("inspect", data.company_id).operations).toEqual([])
    await page.unroute("**/repartidor/api/v1/operations")
    await expect.poll(async () => (await storeModule(page))[0].state, { timeout: 45000 }).toBe("synced")
    expect(fixture("inspect", data.company_id).operations).toEqual(["synced"])
  } finally { await context.setOffline(false); fixture("cleanup", data.company_id) }
})

test("a revoked session locks private data and the same user recovers the durable queue after login", async ({ page, context, baseURL }) => {
  const data = fixture("create")
  try {
    await signIn(page, data, baseURL)
    await context.setOffline(true)
    await record(page, data.visit_ids[0], data.item_ids[0])
    fixture("revoke", data.company_id)
    await context.setOffline(false)
    await expect(page.getByRole("link", { name: "Iniciar sesión", exact: true })).toBeVisible({ timeout: 25000 })
    await expect(page.getByText("Offline Test Customer", { exact: true })).toHaveCount(0)
    expect(fixture("inspect", data.company_id).operations).toEqual([])
    await signIn(page, data, baseURL)
    await expect.poll(async () => (await storeModule(page))[0].state, { timeout: 45000 }).toBe("synced")
    expect(fixture("inspect", data.company_id).operations).toEqual(["synced"])
  } finally { await context.setOffline(false); fixture("cleanup", data.company_id) }
})
