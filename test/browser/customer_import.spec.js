import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"

const fixture = (action, id = "") => {
  const command = process.env.PWA_TEST_SERVER === "1" ? ["bin/rails"] : ["docker", "compose", "exec", "-T", "-e", "RAILS_ENV=test", "web", "bin/rails"]
  const output = execFileSync(command[0], [...command.slice(1), "runner", "test/browser/customer_import_fixtures.rb", action, String(id)], {
    encoding: "utf8", env: { ...process.env, RAILS_ENV: "test" }
  })
  return output.trim() ? JSON.parse(output.trim().split("\n").at(-1)) : null
}

test("mobile intelligent import: async progress, all precision states, manual map review and idempotent creation", async ({ page }) => {
  test.skip(process.env.PWA_TEST_SERVER !== "1", "Uses an isolated Rails test server")
  test.setTimeout(180000)
  const data = fixture("create")
  try {
    await page.goto("/session/new")
    await page.locator('[name="email_address"]').fill(data.email)
    await page.locator('[name="password"]').fill(data.password)
    await page.getByRole("button", { name: "Ingresar", exact: true }).click()
    await page.waitForURL(url => url.pathname.startsWith("/admin"))
    await page.goto("/admin/importaciones-clientes/new")
    const csv = "nombre,direccion,ciudad\nPreciso,Belgrano 450,Adrogué\nAproximado,Mitre 800,Adrogué\nAmbiguo,San Martin 1500,Adrogué\nPendiente,Imposible,Adrogué\n"
    await page.locator('input[type="file"]').setInputFiles({ name: "clientes.csv", mimeType: "text/csv", buffer: Buffer.from(csv) })
    await page.getByRole("button", { name: "Cargar y leer planilla" }).click()
    await page.waitForURL(/importaciones-clientes\/\d+/)
    const importUrl = page.url()
    fixture("drain", data.company_id)
    await expect(page.getByRole("heading", { name: "2. Elegir hoja y mapear columnas" })).toBeVisible({ timeout: 15000 })
    await page.getByRole("button", { name: "Procesar direcciones", exact: true }).click()
    await expect(page.locator("progress")).toBeVisible()
    let progressPolls = 0
    page.on("response", response => {
      if (response.url().startsWith(importUrl) && response.request().headers()["turbo-frame"] === "customer-import") progressPolls++
    })
    await expect.poll(() => progressPolls, { timeout: 15000 }).toBeGreaterThanOrEqual(2)
    fixture("drain", data.company_id)
    await expect(page.getByRole("heading", { name: "3. Revisar resultados" })).toBeVisible({ timeout: 15000 })
    await expect(page.locator(".import-summary-item")).toHaveCount(5)
    expect(await page.locator(".import-summary-item strong").allTextContents()).toEqual(["1", "1", "1", "1", "0"])
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    const approximate = page.locator("tbody tr").filter({ hasText: "Aproximado" })
    await approximate.getByRole("link", { name: /Revisar fila/ }).click()
    await expect(page.locator(".customer-map")).toBeVisible()
    await page.getByRole("button", { name: "Ver este candidato en el mapa", exact: true }).first().click()
    await expect(page.locator(".customer-map-pin")).toHaveCount(1)
    await expect(page.locator('[data-location-target="positionMessage"]')).toContainText("Punto de entrega")
    await page.locator('[name="row[latitude]"]').fill("-34.8000000")
    await page.locator('[name="row[longitude]"]').fill("-58.3900000")
    await page.locator('[name="next"]').uncheck()
    await page.getByRole("button", { name: "Confirmar manualmente la ubicación" }).click()
    await expect(page.locator("tbody").getByText("Confirmada manualmente", { exact: true })).toBeVisible()
    await page.locator('[name="acknowledge_pending"]').check()
    await page.getByRole("button", { name: "Confirmar importación", exact: true }).click()
    fixture("drain", data.company_id)
    await expect(page.getByRole("heading", { name: "Importación confirmada", exact: true })).toBeVisible({ timeout: 15000 })
    const result = fixture("inspect", data.company_id)
    expect(result.customers.map(row => row[1])).toEqual(["reliable", "manual", "pending", "pending"])
    expect(result.orders).toBe(0)
    expect(result.runs).toBe(0)
    await page.goto(importUrl)
    expect(fixture("inspect", data.company_id).customers).toHaveLength(4)
    await page.screenshot({ path: "tmp/importacion-clientes-mobile.png", fullPage: true })
  } finally {
    fixture("cleanup", data.company_id)
  }
})
