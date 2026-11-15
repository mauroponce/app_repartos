import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"

const fixture = (action, id = "") => {
  const command = process.env.PWA_TEST_SERVER === "1" ? ["bin/rails"] : ["docker", "compose", "exec", "-T", "web", "bin/rails"]
  const output = execFileSync(command[0], [...command.slice(1), "runner", "test/browser/fixtures.rb", action, String(id)], {
    encoding: "utf8", env: process.env.PWA_TEST_SERVER === "1" ? { ...process.env, RAILS_ENV: "test" } : process.env
  })
  return output.trim() ? JSON.parse(output.trim().split("\n").at(-1)) : null
}

async function login(page, email, password) {
  await page.goto("/session/new")
  await page.locator('[name="email_address"]').fill(email)
  await page.locator('[name="password"]').fill(password)
  await page.getByRole("button", { name: "Ingresar" }).click()
  await page.waitForURL(url => ["/admin", "/repartidor"].includes(url.pathname))
}

async function ready(page) {
  await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Datos descargados", { timeout: 30000 })
}

async function forceSync(page) {
  await page.evaluate(async () => {
    const root = document.querySelector('[data-controller~="repartidor"]')
    const controller = window.Stimulus.getControllerForElementAndIdentifier(root, "repartidor")
    await controller.syncNow({ type: "click" })
  })
}

test("Turbo Streams update delivery counters and show driver GPS without polling", async ({ page, context, browser, baseURL }) => {
  test.setTimeout(150000)
  const data = fixture("create")
  const setup = fixture("operations", data.company_id)
  const adminContext = await browser.newContext({ baseURL, viewport: { width: 1365, height: 1000 } })
  try {
    await login(page, data.email, data.password)
    await ready(page)
    const admin = await adminContext.newPage()
    await login(admin, setup.manager_email, data.password)
    await admin.goto("/admin/operaciones")
    await expect(admin.locator('[data-count="pending"]')).toHaveText("3")
    await expect(admin.locator("turbo-cable-stream-source")).toHaveAttribute("connected", "", { timeout: 20000 })
    // Disable the fallback to prove the cross-user update arrived via Cable.
    await admin.evaluate(() => {
      const root = document.querySelector('[data-controller="operations"]')
      clearInterval(window.Stimulus.getControllerForElementAndIdentifier(root, "operations").timer)
    })
    await page.locator('[data-repartidor-target="nav"][data-tab="deliveries"]').click()
    await page.locator(`.delivery-item[data-visit-id="${data.visit_ids[0]}"]`).click()
    const dialog = page.locator(`#visit-${data.visit_ids[0]}`)
    await dialog.locator(`#quantity-${data.item_ids[0]}`).fill("20")
    await dialog.locator('input[type="checkbox"]').check()
    await dialog.getByRole("button", { name: "Guardar visita", exact: true }).click()
    await expect(admin.locator('[data-count="completed"]')).toHaveText("1", { timeout: 12000 })
    await expect(admin.locator('[data-count="pending"]')).toHaveText("2")
    await ready(page)
    await context.grantPermissions(["geolocation"])
    await context.setGeolocation({ latitude: -34.8, longitude: -58.34, accuracy: 12 })
    await page.locator('[data-repartidor-target="nav"][data-tab="profile"]').click()
    await page.getByRole("button", { name: "Compartir mi ubicación con la empresa", exact: true }).click()
    await expect(page.locator('[data-driver-tracking-target="status"]')).toContainText("Última ubicación enviada", { timeout: 15000 })
    await expect(admin.locator('[data-run-id]').first()).toContainText("Ubicación reciente", { timeout: 12000 })
    await expect(admin.locator('[data-operations-target="mapStatus"]')).toContainText("1 repartidores")
    await page.getByRole("button", { name: "Detener ubicación", exact: true }).click()
    await expect(page.locator('[data-driver-tracking-target="status"]')).toHaveText("Ubicación desactivada.")
    await expect(admin.locator('[data-run-id]').first()).toContainText("Sin ubicación compartida", { timeout: 12000 })
    await admin.screenshot({ path: "tmp/operations-desktop.png", fullPage: true })
    await admin.setViewportSize({ width: 390, height: 844 })
    await expect.poll(async () => { const box = await admin.locator(".sidebar").boundingBox(); return box.x + box.width }).toBeLessThanOrEqual(0)
    await admin.screenshot({ path: "tmp/operations-mobile.png", fullPage: true })
    expect(await admin.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  } finally {
    await adminContext.close()
    fixture("cleanup", data.company_id)
  }
})

test("dispatch changes update the PWA automatically and preserve an open delivery draft", async ({ page, browser, baseURL }) => {
  test.setTimeout(150000)
  const data = fixture("create")
  const setup = fixture("operations", data.company_id)
  const adminContext = await browser.newContext({ baseURL })
  try {
    await login(page, data.email, data.password)
    await ready(page)
    await page.locator('[data-repartidor-target="nav"][data-tab="deliveries"]').click()
    await page.locator(`.delivery-item[data-visit-id="${data.visit_ids[1]}"]`).click()
    const draft = page.locator(`#visit-${data.visit_ids[1]}`)
    await draft.locator('[name="visit[notes]"]').fill("Borrador que no debe perderse")
    const admin = await adminContext.newPage()
    await login(admin, setup.manager_email, data.password)
    await admin.goto("/admin/operaciones")
    await admin.locator(`[data-order-id="${setup.order_ids[1]}"] button`).click()
    const dispatch = admin.locator(`#dispatch-${setup.order_ids[1]}`)
    await dispatch.locator("select").selectOption(String(setup.target_run_id))
    await dispatch.locator("textarea").fill("Vehículo de refuerzo")
    // An already-received stream may render after the edit dialog opens.
    await admin.evaluate(async () => {
      const imports = JSON.parse(document.querySelector('script[type="importmap"]').textContent).imports
      const { Turbo } = await import(imports["@hotwired/turbo-rails"])
      Turbo.renderStreamMessage('<turbo-stream action="replace" target="operations-board"><template><div id="operations-board">Obsolete render</div></template></turbo-stream>')
    })
    await expect(admin.locator("turbo-stream")).toHaveCount(0)
    await expect(dispatch.locator("textarea")).toHaveValue("Vehículo de refuerzo")
    await dispatch.getByRole("button", { name: "Guardar cambio", exact: true }).click()
    await expect(admin.locator(".flash-message, .flash, [role=status]").filter({ hasText: "Entrega actualizada" }).first()).toBeVisible()
    await forceSync(page)
    await expect(page.locator('[data-repartidor-target="planUpdate"]')).not.toHaveAttribute("hidden")
    await expect(draft.locator('[name="visit[notes]"]')).toHaveValue("Borrador que no debe perderse")
    await expect(draft).toBeVisible()
    await draft.getByRole("button", { name: "Cerrar", exact: true }).click()
    page.once("dialog", dialog => dialog.accept())
    await page.getByRole("button", { name: "Aplicar ruta actualizada", exact: true }).click()
    await expect(page.locator(`.delivery-item[data-visit-id="${data.visit_ids[1]}"]`)).toHaveCount(0)
    await expect(page.locator(`.delivery-item[data-visit-id="${data.visit_ids[2]}"]`)).toHaveCount(1)
    await page.locator('[data-repartidor-target="pauseStatus"]').click()
    // With no draft, an unassignment is applied as soon as fresh work arrives.
    await admin.locator(`[data-order-id="${setup.order_ids[2]}"] button`).click()
    const reprogram = admin.locator(`#dispatch-${setup.order_ids[2]}`)
    const tomorrow = new Date(`${setup.date}T12:00:00Z`)
    tomorrow.setUTCDate(tomorrow.getUTCDate() + 1)
    await reprogram.locator('input[type="date"]').fill(tomorrow.toISOString().slice(0, 10))
    await reprogram.locator("textarea").fill("Entregar mañana")
    await reprogram.getByRole("button", { name: "Guardar cambio", exact: true }).click()
    await ready(page)
    await forceSync(page)
    await expect(page.locator(`.delivery-item[data-visit-id="${data.visit_ids[2]}"]`)).toHaveCount(0)
    await expect(page.locator('[data-repartidor-target="pauseStatus"]')).toHaveText("EN PAUSA")
    expect(fixture("inspect", data.company_id).operations).toEqual([])
    // A downloaded fragment cannot reactivate an old account using the stale
    // authentication metadata of its original document.
    await page.evaluate(async () => {
      const root = document.querySelector('[data-controller~="repartidor"]')
      const fragment = root.outerHTML
      const imports = JSON.parse(document.querySelector('script[type="importmap"]').textContent).imports
      const { OfflineStore } = await import(imports["offline/store"])
      const store = new OfflineStore()
      await store.activate("999:999")
      root.outerHTML = fragment
    })
    await expect(page.locator('[data-controller~="repartidor"]')).toContainText("La cuenta está bloqueada")
    expect(await page.evaluate(async () => {
      const imports = JSON.parse(document.querySelector('script[type="importmap"]').textContent).imports
      const { OfflineStore } = await import(imports["offline/store"])
      return new OfflineStore().active()
    })).toBe("999:999")
  } finally {
    await adminContext.close()
    fixture("cleanup", data.company_id)
  }
})
