import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import path from "node:path"

const examples = path.resolve("docs/ejemplos/onboarding")
const source = JSON.parse(readFileSync(path.join(examples, "datos_demo.json")))
const fixture = (action, slug = "") => JSON.parse(execFileSync("bin/rails", ["runner", "test/browser/onboarding_fixtures.rb", action, slug], {
  encoding: "utf8", env: { ...process.env, RAILS_ENV: "test", CI: "" }
}).trim().split("\n").at(-1) || "null")
const inspect = data => fixture("inspect", data.slug)
async function login(page, email, password, platform = false) {
  await page.goto(platform ? "/plataforma/session/new" : "/session/new")
  await page.getByLabel("Email", { exact: true }).fill(email)
  await page.getByLabel("Contraseña", { exact: true }).fill(password)
  await page.getByRole("button", { name: platform ? "Ingresar a plataforma" : "Ingresar", exact: true }).click()
  await page.waitForURL(url => !url.pathname.endsWith("/session/new"))
}
async function request(page, url, method, values = {}) {
  return page.evaluate(async ({ url, method, values }) => {
    const response = await fetch(url, { method, headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content, "Content-Type": "application/x-www-form-urlencoded", "Accept": "text/html" }, body: new URLSearchParams(values) })
    return { status: response.status, url: response.url }
  }, { url, method, values })
}
async function createCompany(page, data) {
  await page.getByRole("link", { name: "Crear empresa", exact: true }).click()
  await page.getByLabel("Nombre comercial").fill(`Distribuidora ${data.slug}`)
  await page.getByLabel("Slug único").fill(data.slug)
  await page.getByLabel("Provincia", { exact: true }).selectOption("Buenos Aires")
  await expect(page.getByLabel("Zona horaria")).toHaveValue("America/Argentina/Buenos_Aires")
  await page.getByLabel("Nombre del administrador").fill("Administración E2E")
  await page.getByLabel("Email del administrador").fill(data.email)
  await page.getByLabel("Contraseña inicial").fill(data.password)
  await page.getByRole("button", { name: "Crear empresa y administrador", exact: true }).click()
  await expect(page.getByText("Empresa y administrador creados correctamente.")).toBeVisible()
  await expect(page.getByText(data.email, { exact: false })).toBeVisible()
}
async function importCustomers(page, data, filename) {
  await page.goto("/admin/importaciones-clientes/new")
  await page.locator('input[type="file"]').setInputFiles(path.join(examples, filename))
  await page.getByRole("button", { name: "Cargar y leer planilla" }).click()
  await page.waitForURL(/importaciones-clientes\/\d+$/)
  const url = page.url()
  fixture("drain", data.slug)
  await page.reload()
  await expect(page.getByRole("heading", { name: "2. Elegir hoja y mapear columnas" })).toBeVisible()
  await expect(page.locator('[name="mapping[name]"]')).toHaveValue("0")
  await expect(page.locator('[name="mapping[phone]"]')).toHaveValue("1")
  await expect(page.locator('[name="mapping[address]"]')).toHaveValue("2")
  await page.getByRole("button", { name: "Procesar direcciones", exact: true }).click()
  await expect(page.locator("progress")).toBeVisible()
  fixture("drain", data.slug)
  await page.reload()
  await expect(page.getByRole("heading", { name: "3. Revisar resultados" })).toBeVisible()
  return url
}
async function importProducts(page) {
  await page.goto("/admin/productos")
  await page.getByRole("link", { name: "Importar CSV / Excel" }).click()
  await page.locator('input[type="file"]').setInputFiles(path.join(examples, "productos_demo.xlsx"))
  await page.getByRole("button", { name: /Cargar|Previsualizar/ }).click()
  await expect(page.getByRole("heading", { name: "Previsualización de productos" })).toBeVisible()
  await expect(page.locator('[name="mapping[package_content_unit]"]')).toHaveValue("4")
  await expect(page.locator("tbody tr")).toHaveCount(16)
  await expect(page.locator("tbody tr").filter({ hasText: "HAR-025" })).toContainText("bag")
  await page.getByRole("button", { name: "Confirmar importación", exact: true }).click()
  await expect(page.getByText("Se importaron 16 productos correctamente.")).toBeVisible()
}
async function createDriver(page, name, email, password) {
  await page.goto("/admin/repartidores/nuevo")
  await page.getByLabel("Nombre y apellido").fill(name)
  await page.getByLabel("Email de acceso").fill(email)
  await page.getByLabel("Contraseña *", { exact: true }).fill(password)
  await page.getByLabel("Confirmar contraseña", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Guardar repartidor" }).click()
  await expect(page.getByText("Repartidor creado correctamente.")).toBeVisible()
}
async function merchandise(page, products, quantityLabel) {
  for (let i = 0; i < products.length; i++) {
    if (i) await page.getByRole("button", { name: "+ Agregar producto o ítem manual", exact: true }).click()
    const row = page.locator("fieldset.merchandise-row").nth(i)
    await row.getByLabel("Producto del catálogo o ítem manual").selectOption({ label: products[i] })
    await expect(row.getByLabel("Descripción *", { exact: true })).toHaveValue(products[i])
    await row.getByLabel(quantityLabel).fill(String(i + 2))
  }
}
async function schedule(page, customer, weekday, start, end, monday) {
  await page.goto(`/admin/clientes/${customer.id}`)
  await page.getByRole("link", { name: /Nueva programación|Agregar programación/ }).click()
  await page.getByLabel("Día semanal").selectOption(String(weekday))
  await page.getByLabel("Desde *", { exact: true }).fill(monday)
  await page.getByLabel("Franja: inicio").fill(start)
  await page.getByLabel("Franja: fin").fill(end)
  await merchandise(page, ["Harina bolsa 25 kg", "Gaseosa 2 litros"], "Cantidad habitual")
  await page.getByRole("button", { name: "Guardar programación" }).click()
  await expect(page.getByText("Programación creada correctamente.")).toBeVisible()
}
async function generate(page, date) {
  await page.goto("/admin/entregas")
  await page.getByText("Generar entregas desde programaciones", { exact: true }).click()
  await page.getByLabel("Fecha a generar").fill(date)
  await page.getByRole("button", { name: "Generar entregas", exact: true }).click()
  await expect(page.getByText(/Programaciones procesadas/)).toBeVisible()
}
async function createRun(page, date, name, driver, orderIds) {
  await page.goto(`/admin/repartos/new?date=${date}`)
  await page.getByLabel("Nombre de la hoja").fill(name)
  await page.getByLabel("Repartidor (opcional)").selectOption(String(driver.id))
  await page.getByRole("button", { name: "Continuar →", exact: true }).click()
  for (const id of orderIds) await page.locator(`input[name="order_ids[]"][value="${id}"]`).check()
  await page.getByRole("button", { name: "Continuar →", exact: true }).click()
  await expect(page.locator(".planning-stop")).toHaveCount(orderIds.length)
  await page.getByRole("button", { name: "Continuar →", exact: true }).click()
  await page.getByRole("button", { name: "Guardar hoja de ruta", exact: true }).click()
  await expect(page.getByRole("heading", { name, exact: true })).toBeVisible()
  page.once("dialog", dialog => dialog.accept())
  await page.getByRole("button", { name: "Publicar con orden manual", exact: true }).click()
  await expect(page.getByText(/Hoja publicada con el orden manual/)).toBeVisible()
}

test("onboarding completo: plataforma → Excel → geocodificación → catálogo → repartidores → planificación → PWA y aislamiento", async ({ page, browser }, testInfo) => {
  test.skip(process.env.PWA_TEST_SERVER !== "1", "Requires the isolated managed test server")
  test.setTimeout(600000)
  const data = fixture("bootstrap")
  const other = { ...data, slug: `${data.slug}-otra`, email: `${data.slug}-otra@admin.test` }
  let otherContext
  try {
    await login(page, data.platform_email, data.password, true)
    await createCompany(page, data)
    expect(inspect(data).customers).toHaveLength(0)
    expect(inspect(data).administrator.role).toBe("administrator")
    await page.getByRole("button", { name: "Cerrar sesión de plataforma" }).click()
    await login(page, data.email, data.password)
    await expect(page.locator("body")).toContainText(`Distribuidora ${data.slug}`)

    const importUrl = await importCustomers(page, data, "clientes_demo.xlsx")
    expect(inspect(data).imports[0].precision).toEqual({ reliable: 20, approximate: 2, ambiguous: 2, unlocated: 6 })
    await page.goto(`${importUrl}?q=${encodeURIComponent(source.customers[20].name)}`)
    await page.getByRole("link", { name: /Revisar fila/ }).click()
    await page.getByRole("button", { name: "Ver este candidato en el mapa" }).first().click()
    await expect(page.locator(".customer-map-pin")).toHaveCount(1)
    await page.locator('[name="next"]').uncheck()
    await page.getByRole("button", { name: "Confirmar manualmente la ubicación" }).click()
    await expect(page.locator('.import-summary-item[href*="manual"] strong')).toHaveText("1")
    await page.locator('[name="acknowledge_pending"]').check()
    await page.getByRole("button", { name: "Confirmar importación", exact: true }).click()
    fixture("drain", data.slug)
    await page.reload()
    await expect(page.getByRole("heading", { name: "Importación confirmada", exact: true })).toBeVisible()
    await request(page, `${new URL(importUrl).pathname}/confirm`, "POST")
    fixture("drain", data.slug)
    let state = inspect(data)
    expect(state.customers).toHaveLength(30)
    expect(state.customers.filter(row => row.routing)).toHaveLength(21)
    expect(state.customers.filter(row => row.location_verification === "pending").every(row => !row.latitude && !row.longitude)).toBe(true)
    expect(state.imports[0].summary).toMatchObject({ created: 30, reliable: 20, manual: 1, pending_location: 9, approximate: 1, ambiguous: 2, unlocated: 6 })
    await page.getByRole("link", { name: "Ver clientes", exact: true }).click()
    await expect(page.getByRole("heading", { name: "Clientes", exact: true })).toBeVisible()
    await page.goto(`/admin/clientes/${state.customers[0].id}`)
    await expect(page.locator(".customer-map")).toBeVisible()

    await importProducts(page)
    await importProducts(page)
    state = inspect(data)
    expect(state.products).toHaveLength(16)
    expect(state.products.map(row => row.sku).sort()).toEqual(source.products.map(row => row.sku).sort())
    expect(state.products.find(row => row.sku === "HAR-025")).toMatchObject({ unit: "bag", package_content_unit: "kg", package_content_quantity: "25.0" })
    for (const [i, name] of ["Juan Rodríguez", "Camila Fernández", "Martín López"].entries()) {
      await createDriver(page, name, `${data.slug}-driver${i}@piloto.test`, data.password)
    }
    state = inspect(data)
    expect(state.drivers.map(row => row.name)).toEqual(["Juan Rodríguez", "Camila Fernández", "Martín López"])
    expect(state.drivers.every(row => row.role === "driver" && row.status === "active" && row.company_id === state.id)).toBe(true)
    // All planning operations are performed with real forms on an initially empty tenant.
    for (let i = 0; i < 18; i++) await schedule(page, state.customers[i], i < 12 ? 1 : 2, i >= 6 && i < 12 ? "14:00" : "08:00", i >= 6 && i < 12 ? "18:00" : "12:00", data.monday)
    await schedule(page, state.customers[18], 3, "09:00", "13:00", data.monday)
    const datePlus = days => { const date = new Date(`${data.monday}T12:00:00Z`); date.setUTCDate(date.getUTCDate() + days); return date.toISOString().slice(0, 10) }
    await generate(page, data.monday)
    await generate(page, data.monday)
    await generate(page, datePlus(1))
    await generate(page, datePlus(2))
    state = inspect(data)
    expect(state.schedules).toHaveLength(19)
    expect(state.orders).toHaveLength(19)
    expect(state.orders[0]).toMatchObject({ start: "08:00", end: "12:00", quantities: ["2.0", "3.0"] })
    for (let i = 0; i < 3; i++) await createRun(page, i === 2 ? datePlus(1) : data.monday, `Onboarding hoja ${i + 1}`, state.drivers[i], state.orders.slice(i * 6, i * 6 + 6).map(row => row.id))
    // The PWA intentionally executes today's work. Add a real punctual order
    // for today as well, so this test works on every weekday without time travel.
    await page.goto("/admin/entregas/nueva")
    await page.getByLabel("Cliente *", { exact: true }).selectOption(String(state.customers[0].id))
    await page.getByLabel("Fecha de entrega").fill(data.today)
    await merchandise(page, ["Harina bolsa 25 kg", "Gaseosa 2 litros"], "Cantidad solicitada")
    await page.getByRole("button", { name: "Guardar entrega", exact: true }).click()
    await expect(page.getByText(/Entrega creada/)).toBeVisible()
    state = inspect(data)
    const punctual = state.orders.at(-1)
    await createRun(page, data.today, "Onboarding jornada de hoy", state.drivers[0], [punctual.id])
    state = inspect(data)
    expect(state.runs.map(run => run.visits.length)).toEqual([6, 6, 6, 1])
    expect(state.runs.every(run => run.status === "assigned" && !run.blocked)).toBe(true)
    await request(page, "/session", "DELETE")
    await login(page, state.drivers[0].email_address, data.password)
    const run = state.runs.at(-1), visit = run.visits[0]
    await page.goto(`/repartidor?run_id=${run.id}`)
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Datos descargados", { timeout: 30000 })
    await page.locator('[data-repartidor-target="nav"][data-tab="deliveries"]').click()
    await page.locator(`.delivery-item[data-visit-id="${visit.id}"]`).click()
    const dialog = page.locator(`#visit-${visit.id}`)
    for (let i = 0; i < visit.items.length; i++) await dialog.locator(`#quantity-${visit.items[i]}`).fill(String(i + 2))
    await dialog.locator('input[type="checkbox"]').check()
    await dialog.getByRole("button", { name: "Guardar visita", exact: true }).click()
    await expect(dialog).not.toBeVisible()
    await expect.poll(() => inspect(data).operations, { timeout: 30000 }).toContain("synced")
    expect(inspect(data).runs.at(-1).visits[0].status).toBe("completed")
    expect(await page.evaluate(() => navigator.permissions.query({ name: "geolocation" }).then(permission => permission.state))).not.toBe("granted")
    await request(page, "/session", "DELETE")
    await login(page, state.drivers[1].email_address, data.password)
    const ownResponse = await page.goto(`/repartidor/hojas/${state.runs[1].id}`)
    expect(ownResponse.status()).toBe(200)
    await expect(page.getByRole("heading", { name: "Onboarding hoja 2" })).toBeVisible()
    expect((await page.goto(`/repartidor/hojas/${run.id}`)).status()).toBe(404)
    await page.goto("/repartidor")
    expect((await request(page, `/repartidor/visitas/${visit.id}`, "PATCH", { "visit[status]": "closed", "visit[notes]": "Manipulado" })).status).toBe(404)
    await request(page, "/session", "DELETE")
    await login(page, data.email, data.password)
    await page.goto(`/admin/repartos/${run.id}`)
    await expect(page.locator(".visit-card .chip")).toContainText("Completado")

    otherContext = await browser.newContext({ baseURL: new URL(page.url()).origin })
    const otherPage = await otherContext.newPage()
    await login(otherPage, data.platform_email, data.password, true)
    await createCompany(otherPage, other)
    await otherPage.getByRole("button", { name: "Cerrar sesión de plataforma" }).click()
    await login(otherPage, other.email, other.password)
    for (const url of [`/admin/clientes/${state.customers[0].id}`, `/admin/importaciones-clientes/${state.imports[0].id}`, `/admin/importaciones-productos/${state.product_import_id}`, `/admin/repartos/${run.id}`]) expect((await otherPage.goto(url)).status()).toBe(404)
    await otherPage.goto("/admin")
    expect((await request(otherPage, `/admin/productos/${state.products[0].id}`, "PATCH", { "product[name]": "Intruso", "product[company_id]": String(inspect(other).id) })).status).toBe(404)
    await otherPage.goto("/plataforma")
    await expect(otherPage).toHaveURL(/plataforma\/session\/new/)
    await otherPage.goto("/admin")
    await createDriver(otherPage, "Repartidor otra empresa", `${other.slug}@driver.test`, other.password)
    const foreignDriver = inspect(other).drivers[0]
    await page.goto(`/admin/repartos/${state.runs[0].id}`)
    expect((await request(page, `/admin/repartos/${state.runs[0].id}`, "PATCH", { "delivery_run[driver_id]": String(foreignDriver.id), "delivery_run[company_id]": String(inspect(other).id) })).status).toBe(404)
    expect(inspect(data).runs[0].driver_id).toBe(state.drivers[0].id)
    await testInfo.attach("onboarding-results", { body: JSON.stringify(inspect(data), null, 2), contentType: "application/json" })
  } finally {
    await otherContext?.close()
    for (const record of [other, data]) fixture("cleanup", record.slug)
  }
})

test("Excel mínimo: extrae localidad de Dirección sin inventar coordenadas", async ({ page }) => {
  test.skip(process.env.PWA_TEST_SERVER !== "1", "Requires the isolated managed test server")
  const data = fixture("bootstrap")
  try {
    await login(page, data.platform_email, data.password, true)
    await createCompany(page, data)
    await page.getByRole("button", { name: "Cerrar sesión de plataforma" }).click()
    await login(page, data.email, data.password)
    await importCustomers(page, data, "clientes_demo_minimo.xlsx")
    await page.getByRole("button", { name: "Confirmar importación", exact: true }).click()
    fixture("drain", data.slug)
    await page.reload()
    await expect(page.getByRole("heading", { name: "Importación confirmada", exact: true })).toBeVisible()
    const customers = inspect(data).customers
    expect(customers).toHaveLength(6)
    expect(customers.map(row => row.city)).toEqual(source.customers.slice(0, 6).map(row => row.city))
    expect(customers.every(row => row.location_verification === "reliable" && row.routing)).toBe(true)
    expect(customers[0].address).toBe("Mitre 450, Adrogué, Buenos Aires")
  } finally { fixture("cleanup", data.slug) }
})

test("Solid Queue procesa lectura, preparación, geocodificación y confirmación asíncronas", async () => {
  test.skip(process.env.PWA_TEST_SERVER !== "1", "Requires the isolated managed test server")
  test.setTimeout(120000)
  const result = execFileSync("bin/rails", ["runner", "test/browser/onboarding_queue_check.rb"], {
    encoding: "utf8", env: { ...process.env, RAILS_ENV: "test", CI: "" }
  }).trim().split("\n").at(-1)
  expect(JSON.parse(result)).toEqual({ solid_queue: "OK", finished_jobs: 4, customers: 6, state: "completed" })
})
