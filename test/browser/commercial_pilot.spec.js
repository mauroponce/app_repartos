import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"

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
}

test("Excel onboarding is asynchronous and repeated external codes never overwrite customers", async ({ page }) => {
  test.skip(process.env.PWA_TEST_SERVER !== "1", "Uses an isolated Rails test server")
  test.setTimeout(180000)
  const imports = (action, id = "") => {
    const output = execFileSync("bin/rails", ["runner", "test/browser/customer_import_fixtures.rb", action, String(id)], { encoding: "utf8", env: { ...process.env, RAILS_ENV: "test" } })
    return output.trim() ? JSON.parse(output.trim().split("\n").at(-1)) : null
  }
  const data = imports("create")
  try {
    await login(page, data.email, data.password)
    await page.waitForURL(/\/admin\/?$/)
    await page.getByRole("link", { name: "Importar clientes", exact: true }).click()
    await page.locator('input[type="file"]').setInputFiles(fileURLToPath(new URL("../fixtures/files/customers.xlsx", import.meta.url)))
    await page.getByRole("button", { name: "Cargar y leer planilla", exact: true }).click()
    await page.waitForURL(/importaciones-clientes\/\d+/)
    imports("drain", data.company_id)
    await expect(page.getByRole("heading", { name: "2. Elegir hoja y mapear columnas" })).toBeVisible({ timeout: 15000 })
    await expect(page.locator("td")).toContainText(["000123"])
    await page.getByRole("button", { name: "Procesar direcciones", exact: true }).click()
    imports("drain", data.company_id)
    await expect(page.getByRole("heading", { name: "3. Revisar resultados" })).toBeVisible({ timeout: 15000 })
    await page.locator('[name="acknowledge_pending"]').check()
    await page.getByRole("button", { name: "Confirmar importación", exact: true }).click()
    imports("drain", data.company_id)
    await expect(page.getByRole("heading", { name: "Importación confirmada" })).toBeVisible({ timeout: 15000 })
    const original = imports("inspect", data.company_id).customers
    expect(original).toHaveLength(1)
    await page.getByRole("link", { name: "Cargar otra planilla", exact: true }).click()
    await page.locator('input[type="file"]').setInputFiles({ name: "clientes.csv", mimeType: "text/csv", buffer: Buffer.from("Zona;Negocio;Calle;Identificador\nAdrogué;Comercio actualizado;Mitre 123;000123\n") })
    await page.getByRole("button", { name: "Cargar y leer planilla", exact: true }).click()
    await page.waitForURL(/importaciones-clientes\/\d+/)
    imports("drain", data.company_id)
    await expect(page.getByRole("heading", { name: "2. Elegir hoja y mapear columnas" })).toBeVisible({ timeout: 15000 })
    await page.locator("#mapping_external_code").selectOption("3")
    await page.locator("#mapping_name").selectOption("1")
    await page.locator("#mapping_address").selectOption("2")
    await page.locator("#mapping_city").selectOption("0")
    await page.getByRole("button", { name: "Guardar mapeo / leer hoja", exact: true }).click()
    await page.getByRole("button", { name: "Procesar direcciones", exact: true }).click()
    imports("drain", data.company_id)
    await expect(page.getByRole("heading", { name: "3. Revisar resultados" })).toBeVisible({ timeout: 15000 })
    await expect(page.getByText(/mismo código.*no se modificará/)).toBeVisible()
    await expect(page.getByRole("button", { name: "Confirmar importación", exact: true })).toBeDisabled()
    expect(imports("inspect", data.company_id).customers).toEqual(original)
  } finally { imports("cleanup", data.company_id) }
})

test("GPS stays off with browser permission and an offline stop survives reload without reactivating", async ({ page, context }) => {
  const data = fixture("create")
  await context.grantPermissions(["geolocation"])
  await context.setGeolocation({ latitude: -34.8, longitude: -58.34, accuracy: 12 })
  await context.addInitScript(() => {
    window.gpsCalls = 0
    const original = navigator.geolocation.watchPosition.bind(navigator.geolocation)
    navigator.geolocation.watchPosition = (...args) => { window.gpsCalls++; return original(...args) }
  })
  try {
    await login(page, data.email, data.password)
    await page.waitForURL("**/repartidor")
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Datos descargados", { timeout: 30000 })
    await page.waitForFunction(() => navigator.serviceWorker.controller)
    expect(await page.evaluate(() => window.gpsCalls)).toBe(0)
    await page.locator('[data-repartidor-target="nav"][data-tab="profile"]').click()
    const button = page.locator('[data-driver-tracking-target="button"]')
    await expect(button).toHaveAttribute("aria-pressed", "false")
    await button.click()
    await expect(page.locator('[data-driver-tracking-target="status"]')).toContainText("Última ubicación enviada", { timeout: 15000 })
    await context.setOffline(true)
    await button.click()
    await expect(page.locator('[data-driver-tracking-target="status"]')).toContainText("Revocación pendiente")
    await page.reload()
    await expect(page.locator('[data-repartidor-target="connection"]')).toHaveClass(/visible/, { timeout: 15000 })
    await page.locator('[data-repartidor-target="nav"][data-tab="profile"]').click()
    await expect(page.locator('[data-driver-tracking-target="button"]')).toHaveAttribute("aria-pressed", "false")
    expect(await page.evaluate(() => window.gpsCalls)).toBe(0)
    await context.setOffline(false)
    await page.getByRole("button", { name: "Sincronizar ahora" }).click()
    await expect.poll(() => page.evaluate(async () => (await (await fetch("/repartidor/api/v1/location", { cache: "no-store" })).json()).sharing), { timeout: 15000 }).toBe(false)
    expect(await page.evaluate(() => window.gpsCalls)).toBe(0)
  } finally { await context.setOffline(false); fixture("cleanup", data.company_id) }
})
