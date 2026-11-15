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
async function login(page, baseURL, email, password) {
  await page.goto(`${baseURL}/session/new`)
  await page.locator('[name="email_address"]').fill(email)
  await page.locator('[name="password"]').fill(password)
  await page.getByRole("button", { name: "Ingresar", exact: true }).click()
  await page.waitForURL(url => url.pathname.startsWith("/admin") || url.pathname.startsWith("/repartidor"), { timeout: 30000 })
}
const queue = page => page.evaluate(async () => {
  const imports = JSON.parse(document.querySelector('script[type="importmap"]').textContent).imports
  const { OfflineStore } = await import(imports["offline/store"])
  const store = new OfflineStore()
  const rows = await store.operations(await store.active())
  store.db.close()
  return rows.filter(row => row.operation_type === "workflow").map(row => ({ id: row.operation_id, state: row.state, command: row.workflow.command, files: row.files.length, error: row.error }))
})

test("offline incident with photo survives restart then receives an administrative decision and confirms execution", async ({ baseURL, launchOptions, browser }) => {
  test.setTimeout(240000)
  const data = fixture("create"), management = fixture("operations", data.company_id)
  const profile = mkdtempSync(path.join(tmpdir(), "repartos-workflow-"))
  let context, adminContext
  try {
    context = await chromium.launchPersistentContext(profile, { ...launchOptions, headless: true, viewport: { width: 390, height: 844 } })
    let page = await context.newPage()
    await login(page, baseURL, data.email, data.password)
    await page.waitForURL("**/repartidor")
    await expect(page.locator('[data-repartidor-target="syncStatus"]')).toContainText("Acceso offline preparado", { timeout: 30000 })
    await context.setOffline(true)
    await page.locator('[data-tab="deliveries"][data-repartidor-target="nav"]').click()
    await page.locator(`.delivery-item[data-visit-id="${data.visit_ids[0]}"]`).click()
    const dialog = page.locator(`#visit-${data.visit_ids[0]}`)
    await dialog.locator("summary").filter({ hasText: "Informar problema" }).click()
    const form = dialog.locator('[data-command="incident_report"]')
    await form.locator('[name="kind"]').selectOption("address")
    await form.locator('[name="description"]').fill("La numeración no coincide con la dirección de la hoja")
    const photo = await page.evaluate(() => {
      const canvas = document.createElement("canvas"); canvas.width = 50; canvas.height = 30
      return canvas.toDataURL("image/png").split(",")[1]
    })
    await form.locator('[name="photos"]').setInputFiles({ name: "direccion.png", mimeType: "image/png", buffer: Buffer.from(photo, "base64") })
    await form.getByRole("button", { name: "Guardar incidencia" }).click()
    await expect(form.locator('[data-workflow-message]')).toContainText("Pendiente de confirmación del servidor")
    const original = (await queue(page))[0]
    expect(original.state).toBe("pending")
    expect(original.files).toBe(1)
    await context.close()

    context = await chromium.launchPersistentContext(profile, { ...launchOptions, headless: true, viewport: { width: 390, height: 844 } })
    await context.setOffline(true)
    page = await context.newPage()
    await page.goto(`${baseURL}/repartidor`)
    await expect.poll(async () => (await queue(page))[0]?.id).toBe(original.id)
    let lost = false
    await page.route("**/repartidor/api/v1/workflow-operations", async route => {
      if (!lost) { lost = true; await route.fetch(); await route.abort("failed") }
      else await route.continue()
    })
    await context.setOffline(false)
    await page.getByRole("button", { name: "Sincronizar ahora" }).click()
    await expect.poll(async () => (await queue(page))[0]?.state, { timeout: 60000 }).toBe("synced")
    const state = fixture("workflow_inspect", data.company_id)
    expect(state.incidents).toHaveLength(1)
    expect(state.photos).toBe(1)
    expect(state.visits).toEqual(["pending", "pending", "pending"])
    expect(state.commands).toBe(1)
    const incidentId = state.incidents[0][0]

    adminContext = await browser.newContext({ viewport: { width: 1280, height: 900 } })
    const admin = await adminContext.newPage()
    await login(admin, baseURL, management.manager_email, data.password)
    await admin.goto(`${baseURL}/admin/incidencias/${incidentId}`)
    await expect(admin.getByRole("heading", { name: "Dirección incorrecta", exact: true })).toBeVisible()
    await expect(admin.locator(".evidence-gallery img")).toHaveCount(1)
    await admin.locator('[name="decision[action]"]').selectOption("retry")
    await admin.locator('[name="decision[message]"]').fill("Confirmar el número 123 en la esquina y volver a intentar")
    await admin.getByRole("button", { name: "Registrar decisión y avisar" }).click()
    await expect(admin.getByText("Decisión registrada y aviso interno generado.", { exact: true })).toBeVisible()
    await page.locator('[data-tab="inbox"][data-repartidor-target="nav"]').click()
    await expect(page.locator('[data-driver-workflow-target="inbox"]')).toContainText("Confirmar el número 123", { timeout: 30000 })
    const task = page.locator("[data-task-id]").first()
    await task.locator('[name="result"]').fill("Se ubicó la dirección correcta y se realizó el reintento")
    await task.getByRole("button", { name: "Confirmar ejecución" }).click()
    await expect.poll(async () => (await queue(page)).filter(row => row.command === "task_complete").at(-1)?.state, { timeout: 45000 }).toBe("synced")
    const finished = fixture("workflow_inspect", data.company_id)
    expect(finished.tasks[0][1]).toBe("completed")
    expect(finished.visits).toEqual(["pending", "pending", "pending"])
    expect(finished.events).toContain("task_complete")
    await admin.reload()
    await expect(admin.getByRole("link", { name: /Reintentar entrega/ })).toBeVisible()
  } finally {
    await context?.close(); await adminContext?.close()
    fixture("cleanup", data.company_id)
    rmSync(profile, { recursive: true, force: true })
  }
})

test("report opportunity evidence creates assigns and closes a commercial task on mobile administration", async ({ page, baseURL }) => {
  test.setTimeout(120000)
  const data = fixture("create"), management = fixture("operations", data.company_id)
  const opportunity = fixture("opportunities", data.company_id)
  try {
    await login(page, baseURL, management.manager_email, data.password)
    await page.goto(`${baseURL}/admin/reportes`)
    await expect(page.getByRole("heading", { name: "Reportes", exact: true })).toBeVisible()
    await expect(page.locator('[data-report-kpi="programmed"] strong')).toHaveText("3")
    await page.screenshot({ path: "tmp/reportes-mobile.png", fullPage: true })
    await page.setViewportSize({ width: 1280, height: 900 })
    await page.screenshot({ path: "tmp/reportes-desktop.png", fullPage: true })
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto(`${baseURL}/admin/oportunidades/${opportunity.opportunity_id}`)
    await expect(page.getByRole("heading", { name: "Evidencia de la detección" })).toBeVisible()
    await expect(page.locator(".workflow-evidence").first()).toContainText("Pedidos del período anterior")
    await page.locator('[name="opportunity[assignee_id]"]').selectOption({ label: "Dispatch Manager" })
    await page.locator('[name="opportunity[message]"]').fill("Contactar al comercio y revisar la frecuencia de reposición")
    await page.getByRole("button", { name: "Registrar gestión" }).click()
    await expect(page).toHaveURL(/\/admin\/tareas\/\d+/)
    await expect(page.getByRole("heading", { name: /Revisar disminución/ })).toBeVisible()
    await page.locator('[name="task[action]"]').selectOption("complete")
    await page.locator('[name="task[result]"]').fill("Se registró una nueva frecuencia acordada con el comercio")
    await page.getByRole("button", { name: "Guardar acción" }).click()
    await expect(page.locator(".workflow-badge")).toHaveText("Completada")
    expect(fixture("workflow_inspect", data.company_id).tasks[0][2]).toBe("commercial")
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  } finally { fixture("cleanup", data.company_id) }
})
