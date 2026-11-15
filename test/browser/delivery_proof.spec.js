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
const rows = page => page.evaluate(async () => {
  const imports = JSON.parse(document.querySelector('script[type="importmap"]').textContent).imports
  const { OfflineStore } = await import(imports["offline/store"])
  const store = new OfflineStore()
  return (await store.operations(await store.active())).map(row => ({ state: row.state, operation_id: row.operation_id,
    files: row.files.map(file => ({ id: file.id, kind: file.kind, bytes: file.blob.size })), evidence: row.evidence, error: row.error || null }))
})

test("saving waits for two photo selections that are still being prepared", async ({ page, context }) => {
  const data = fixture("create")
  try {
    await page.goto("/session/new")
    await page.locator('[name="email_address"]').fill(data.email)
    await page.locator('[name="password"]').fill(data.password)
    await page.getByRole("button", { name: "Ingresar" }).click()
    await page.waitForURL("**/repartidor")
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Datos descargados", { timeout: 30000 })
    await context.setOffline(true)
    await page.locator('[data-repartidor-target="nav"][data-tab="deliveries"]').click()
    await page.locator(`.delivery-item[data-visit-id="${data.visit_ids[0]}"]`).click()
    const dialog = page.locator(`#visit-${data.visit_ids[0]}`)
    await dialog.locator(`#quantity-${data.item_ids[0]}`).fill("20")
    const photo = await page.evaluate(() => {
      const canvas = document.createElement("canvas")
      canvas.width = 40; canvas.height = 30
      const original = window.createImageBitmap.bind(window)
      window.createImageBitmap = async (...args) => { await new Promise(resolve => setTimeout(resolve, 800)); return original(...args) }
      return canvas.toDataURL("image/png").split(",")[1]
    })
    const input = dialog.locator('[data-delivery-proof-target="photos"]')
    await input.setInputFiles({ name: "first.png", mimeType: "image/png", buffer: Buffer.from(photo, "base64") })
    await input.setInputFiles({ name: "second.png", mimeType: "image/png", buffer: Buffer.from(photo, "base64") })
    await dialog.locator('input[type="checkbox"]').check()
    await dialog.getByRole("button", { name: "Guardar visita", exact: true }).click()
    await expect(dialog).not.toBeVisible()
    const saved = (await rows(page))[0]
    expect(saved.files).toHaveLength(2)
    expect(new Set(saved.files.map(file => file.id)).size).toBe(2)
    expect(saved.files.every(file => file.kind === "photo" && file.bytes > 0)).toBe(true)
    expect(saved.evidence).toHaveLength(2)
  } finally {
    fixture("cleanup", data.company_id)
  }
})

test("photos signature GPS and partial delivery survive offline browser restart and idempotent retry", async ({ baseURL, launchOptions }) => {
  test.setTimeout(180000)
  const data = fixture("create")
  const profile = mkdtempSync(path.join(tmpdir(), "repartos-proof-"))
  const launch = { ...launchOptions, headless: true, viewport: { width: 390, height: 844 }, permissions: ["geolocation"], geolocation: { latitude: -34.8, longitude: -58.34 } }
  let context
  try {
    context = await chromium.launchPersistentContext(profile, launch)
    let page = await context.newPage()
    await page.goto(`${baseURL}/session/new`)
    await page.locator('[name="email_address"]').fill(data.email)
    await page.locator('[name="password"]').fill(data.password)
    await page.getByRole("button", { name: "Ingresar" }).click()
    await page.waitForURL("**/repartidor")
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Datos descargados", { timeout: 30000 })
    await page.waitForFunction(() => navigator.serviceWorker.controller)
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Acceso offline preparado")
    await context.setOffline(true)
    await page.locator('[data-repartidor-target="nav"][data-tab="deliveries"]').click()
    await page.locator(`.delivery-item[data-visit-id="${data.visit_ids[0]}"]`).click()
    const dialog = page.locator(`#visit-${data.visit_ids[0]}`)
    await dialog.locator(`#quantity-${data.item_ids[0]}`).fill("18")
    await dialog.locator('[data-delivery-proof-target="reason"]').selectOption("shortage")
    const photo = await page.evaluate(() => {
      const canvas = document.createElement("canvas")
      canvas.width = 60; canvas.height = 40
      canvas.getContext("2d").fillRect(0, 0, 60, 40)
      return canvas.toDataURL("image/png").split(",")[1]
    })
    await dialog.locator('[data-delivery-proof-target="photos"]').setInputFiles({ name: "entrega.png", mimeType: "image/png", buffer: Buffer.from(photo, "base64") })
    await expect(dialog.locator('[data-delivery-proof-target="message"]')).toContainText("1 de 4 fotografías")
    await dialog.getByLabel("Nombre del receptor").fill("María receptora")
    const pad = dialog.locator("canvas")
    await pad.scrollIntoViewIfNeeded()
    const bounds = await pad.boundingBox()
    await page.mouse.move(bounds.x + 20, bounds.y + 30)
    await page.mouse.down()
    await page.mouse.move(bounds.x + 90, bounds.y + 50, { steps: 5 })
    await page.mouse.move(bounds.x + 140, bounds.y + 20, { steps: 4 })
    await page.mouse.up()
    await dialog.getByRole("button", { name: "Registrar ubicación actual" }).click()
    await expect(dialog.locator('[data-delivery-proof-target="locationStatus"]')).toContainText("Ubicación disponible")
    await dialog.locator('input[type="checkbox"]').check()
    await dialog.getByRole("button", { name: "Guardar visita", exact: true }).click()
    await expect(dialog).not.toBeVisible()
    const original = (await rows(page))[0]
    expect(original.files.map(file => file.kind)).toEqual(["photo", "signature"])
    expect(original.files.every(file => file.bytes > 0)).toBe(true)
    await context.close()

    context = await chromium.launchPersistentContext(profile, launch)
    await context.setOffline(true)
    page = await context.newPage()
    const errors = []
    page.on("pageerror", error => errors.push(error.message))
    await page.goto(`${baseURL}/repartidor`)
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("1 pendientes")
    expect((await rows(page))[0]).toEqual(original)
    let rejectedUploads = 0
    await page.route("**/repartidor/api/v1/evidences", async route => { rejectedUploads++; await route.fulfill({ status: 503, json: { error: "temporary storage failure" } }) })
    await context.setOffline(false)
    await page.getByRole("button", { name: "Sincronizar ahora" }).click()
    await expect.poll(() => rejectedUploads, { timeout: 25000 }).toBeGreaterThan(0)
    await expect.poll(async () => (await rows(page))[0].state).toBe("pending")
    expect((await rows(page))[0].files).toHaveLength(2)
    expect(fixture("inspect", data.company_id).operations).toEqual([])
    await page.unroute("**/repartidor/api/v1/evidences")
    let lostResponse = false
    await page.route("**/repartidor/api/v1/operations", async route => {
      if (!lostResponse) {
        lostResponse = true
        await route.fetch()
        await route.abort("failed")
      } else await route.continue()
    })
    await page.getByRole("button", { name: "Sincronizar ahora" }).click()
    await expect.poll(() => lostResponse, { timeout: 45000 }).toBe(true)
    await expect.poll(async () => { const row = (await rows(page))[0]; return { state: row.state, error: row.error } }, { timeout: 60000 }).toMatchObject({ state: "synced" })
    const saved = (await rows(page))[0]
    expect(saved.operation_id).toBe(original.operation_id)
    expect(saved.evidence).toEqual(original.evidence)
    expect(saved.files).toEqual([])
    const result = fixture("inspect", data.company_id)
    expect(result.operations).toEqual(["synced"])
    expect(result.evidence.map(file => file.kind)).toEqual(["photo", "signature"])
    expect(result.evidence.every(file => file.linked && file.attached)).toBe(true)
    expect(result.quantities).toEqual(["18.0", null, null])
    expect(result.receipts[0]).toEqual([1, "shortage", "María receptora", "-34.8", "-58.34"])
    await page.goto(`${baseURL}/comprobantes/${data.visit_ids[0]}`)
    await expect(page.getByRole("heading", { name: `Comprobante de entrega #${data.visit_ids[0]}` })).toBeVisible()
    await expect(page.getByText("Entrega parcial", { exact: true })).toBeVisible()
    await expect(page.locator(".evidence-gallery img")).toHaveCount(2)
    expect(errors).toEqual([])
  } finally {
    await context?.close()
    fixture("cleanup", data.company_id)
    rmSync(profile, { recursive: true, force: true })
  }
})

test("arrival and unloading survive an offline restart before the final delivery is recorded", async ({ baseURL, launchOptions }) => {
  test.setTimeout(180000)
  const data = fixture("create")
  const profile = mkdtempSync(path.join(tmpdir(), "repartos-timing-"))
  const launch = { ...launchOptions, headless: true, viewport: { width: 390, height: 844 } }
  let context
  const openVisit = async page => {
    await page.locator('[data-repartidor-target="nav"][data-tab="deliveries"]').click()
    await page.locator(`.delivery-item[data-visit-id="${data.visit_ids[0]}"]`).click()
    return page.locator(`#visit-${data.visit_ids[0]}`)
  }
  try {
    context = await chromium.launchPersistentContext(profile, launch)
    let page = await context.newPage()
    await page.goto(`${baseURL}/session/new`)
    await page.locator('[name="email_address"]').fill(data.email)
    await page.locator('[name="password"]').fill(data.password)
    await page.getByRole("button", { name: "Ingresar" }).click()
    await page.waitForURL("**/repartidor")
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Acceso offline preparado", { timeout: 30000 })
    await context.setOffline(true)
    let dialog = await openVisit(page)
    await expect(dialog.getByRole("button", { name: "Iniciar descarga", exact: true })).toBeDisabled()
    await dialog.getByRole("button", { name: "Registrar llegada", exact: true }).click()
    await expect(dialog.locator('[data-visit-timing-target="status"]')).toContainText("Horario guardado")
    await expect.poll(async () => (await rows(page)).length).toBe(1)
    const arrival = (await rows(page))[0].operation_id
    await context.close()

    context = await chromium.launchPersistentContext(profile, launch)
    await context.setOffline(true)
    page = await context.newPage()
    await page.goto(`${baseURL}/repartidor`)
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("1 pendientes")
    dialog = await openVisit(page)
    await expect(dialog.getByRole("button", { name: /^Registrar llegada:/ })).toBeDisabled()
    await dialog.getByRole("button", { name: "Iniciar descarga", exact: true }).click()
    await expect(dialog.getByRole("button", { name: /^Iniciar descarga:/ })).toBeDisabled()
    await dialog.getByRole("button", { name: "Finalizar descarga", exact: true }).click()
    await expect(dialog.getByRole("button", { name: /^Finalizar descarga:/ })).toBeDisabled()
    await dialog.locator(`#quantity-${data.item_ids[0]}`).fill("20")
    await dialog.locator('input[type="checkbox"]').check()
    await dialog.getByRole("button", { name: "Guardar visita", exact: true }).click()
    await expect(dialog).not.toBeVisible()
    await expect.poll(async () => (await rows(page)).length).toBe(4)
    expect((await rows(page))[0].operation_id).toBe(arrival)
    await context.setOffline(false)
    await page.getByRole("button", { name: "Sincronizar ahora" }).click()
    await expect.poll(async () => (await rows(page)).map(row => row.state), { timeout: 60000 }).toEqual(["synced", "synced", "synced", "synced"])
    const result = fixture("inspect", data.company_id)
    expect(result.operations).toEqual(["synced", "synced", "synced", "synced"])
    const times = result.timings[0].map(time => Date.parse(time))
    expect(times.every(Number.isFinite)).toBe(true)
    expect(times[0]).toBeLessThanOrEqual(times[1])
    expect(times[1]).toBeLessThanOrEqual(times[2])
    expect(result.stock_deliveries).toBe(1)
    expect(result.final_events).toBe(1)
    expect(result.orders[0]).toBe("completed")
  } finally {
    await context?.close()
    fixture("cleanup", data.company_id)
    rmSync(profile, { recursive: true, force: true })
  }
})
