import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"

const fixture = (action, id = "") => {
  const command = process.env.PWA_TEST_SERVER === "1" ? ["bin/rails"] : ["docker", "compose", "exec", "-T", "web", "bin/rails"]
  const output = execFileSync(command[0], [...command.slice(1), "runner", "test/browser/route_optimization_fixtures.rb", action, String(id)], {
    encoding: "utf8", env: process.env.PWA_TEST_SERVER === "1" ? { ...process.env, RAILS_ENV: "test" } : process.env
  })
  return output.trim() ? JSON.parse(output.trim().split("\n").at(-1)) : null
}

test("review several vehicles, reassign a stop, validate and save the proposed routes", async ({ page }) => {
  const data = fixture("create")
  const errors = []
  let fixedAssignments
  page.on("pageerror", error => errors.push(error.message))
  try {
    await page.route("**/admin/optimizaciones", async route => {
      const input = route.request().postDataJSON().optimization
      expect(input.order_ids.map(Number).sort()).toEqual([...data.order_ids].sort())
      if (Object.keys(input.pins || {}).length) fixedAssignments = input.pins
      await route.fulfill({ json: input.routes || Object.keys(input.pins || {}).length ? data.adjusted : data.initial })
    })
    await page.goto("/session/new")
    await page.locator('[name="email_address"]').fill(data.email)
    await page.locator('[name="password"]').fill(data.password)
    await page.getByRole("button", { name: "Ingresar" }).click()
    await page.waitForURL(/\/admin\/?$/)
    await page.goto(`/admin/repartos/new?date=${data.date}&${data.order_ids.map(id => `order_ids[]=${id}`).join("&")}`)
    await page.getByLabel("Nombre de la hoja").fill("Optimización de prueba")
    await page.getByRole("button", { name: "Organizar paradas" }).click()
    await page.getByText("Optimización automática entre varios vehículos", { exact: true }).click()
    await page.getByLabel("Latitud del depósito").fill("-34.8")
    await page.getByLabel("Longitud del depósito").fill("-58.34")
    await page.getByLabel("Vehículo de Juan", { exact: true }).check()
    await page.getByLabel("Vehículo de Pedro", { exact: true }).check()
    await page.getByRole("button", { name: "Optimizar rutas", exact: true }).click()
    await expect(page.locator('[data-route-planner-target="optimizationStatus"]')).toContainText("Propuesta validada")
    await expect(page.locator('[data-route-planner-target="proposal"] .optimized-route')).toHaveCount(2)
    await expect(page.locator(".optimization-map .leaflet-overlay-pane path")).toHaveCount(2)
    await page.getByRole("combobox", { name: "Vehículo para Almacén", exact: true }).selectOption(String(data.driver_ids[1]))
    await expect(page.locator('[data-route-planner-target="proposalToken"]')).toHaveValue("")
    await expect(page.locator('[data-route-planner-target="proposal"]').getByText("Asignación fija para la próxima optimización", { exact: true })).toBeVisible()
    await page.getByRole("button", { name: "Confirmación" }).click()
    await page.getByRole("button", { name: "Guardar hoja de ruta", exact: true }).click()
    await expect(page.locator('[data-route-planner-target="error"]')).toContainText("Validá los cambios")
    await page.getByRole("button", { name: "Organizar paradas" }).click()
    await page.getByRole("button", { name: "Optimizar rutas", exact: true }).click()
    await expect(page.locator('[data-route-planner-target="optimizationStatus"]')).toContainText("Propuesta validada")
    expect(fixedAssignments).toEqual({ [data.order_ids[0]]: data.driver_ids[1] })
    await page.getByRole("button", { name: "Bajar Kiosco", exact: true }).click()
    await page.getByRole("button", { name: "Bajar Almacén", exact: true }).click()
    await page.getByRole("button", { name: "Validar cambios manuales", exact: true }).click()
    await expect(page.locator('[data-route-planner-target="optimizationStatus"]')).toContainText("Propuesta validada")
    await expect(page.locator('[data-route-planner-target="proposal"] .optimized-route')).toHaveCount(1)
    await page.getByRole("button", { name: "Confirmación" }).click()
    await page.getByLabel("Guardar como", { exact: true }).selectOption("assigned")
    await page.getByRole("button", { name: "Guardar hoja de ruta", exact: true }).click()
    await expect(page).toHaveURL(/\/admin\/repartos\?date=/)
    const result = fixture("inspect", data.company_id)
    expect(result.runs).toEqual([{ driver_id: data.driver_ids[1], order_ids: [...data.order_ids].reverse() }])
    expect(errors).toEqual([])
  } finally {
    fixture("cleanup", data.company_id)
  }
})
