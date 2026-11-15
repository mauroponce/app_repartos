import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"

const fixture = (action,id="") => {
  const command = process.env.PWA_TEST_SERVER === "1" ? ["bin/rails"] : ["docker","compose","exec","-T","web","bin/rails"]
  const output = execFileSync(command[0], [...command.slice(1),"runner","test/browser/single_route_fixtures.rb",action,String(id)], {encoding:"utf8",env:process.env.PWA_TEST_SERVER === "1" ? {...process.env,RAILS_ENV:"test"}:process.env})
  return output.trim() ? JSON.parse(output.trim().split("\n").at(-1)) : null
}
async function login(page,email,password) {
  await page.goto("/session/new")
  await page.locator('[name="email_address"]').fill(email)
  await page.locator('[name="password"]').fill(password)
  await page.getByRole("button",{name:"Ingresar",exact:true}).click()
  await page.waitForURL(url=>url.pathname.startsWith("/admin")||url.pathname.startsWith("/repartidor"))
}
test("review a road proposal on mobile, apply only positions and download the confirmed order in the driver PWA", async ({page,browser})=>{
  test.setTimeout(180000)
  const data = fixture("create")
  let driverContext
  try {
    if (process.env.OSRM_BROWSER_LIVE !== "1") {
      await page.route(`**/admin/repartos/${data.run_id}/optimizacion`,async route=>{
        if(route.request().method()!=="POST") return route.continue()
        const response = await route.fetch({maxRedirects:0})
        expect(response.status()).toBe(303)
        fixture("calculate",data.company_id)
        await route.fulfill({response,body:""})
      })
    }
    await login(page,data.manager_email,data.password)
    await page.goto(`/admin/repartos/${data.run_id}`)
    await page.getByRole("link",{name:"Optimizar ruta",exact:true}).click()
    await page.getByRole("button",{name:"Calcular propuesta",exact:true}).click()
    await expect(page.getByRole("heading",{name:"Ruta propuesta",exact:true})).toBeVisible({timeout:60000})
    await expect(page.locator(".route-preview-map svg polyline")).toHaveCount(1)
    await expect(page.locator(".route-preview-map svg circle")).toHaveCount(5)
    expect(await page.evaluate(()=>document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    const preview = fixture("inspect",data.company_id)
    expect(preview.actual_ids).toEqual(data.original_ids)
    expect(preview.orders).toEqual(data.orders)
    expect(preview.items).toEqual(data.items)
    await page.screenshot({path:"tmp/ruta-optimizada-mobile.png",fullPage:true})
    page.once("dialog",dialog=>dialog.accept())
    await page.getByRole("button",{name:"Confirmar orden propuesto",exact:true}).click()
    await expect(page).toHaveURL(new RegExp(`/admin/repartos/${data.run_id}$`),{timeout:30000})
    const applied = fixture("inspect",data.company_id)
    expect(applied.status).toBe("applied")
    expect(applied.actual_ids).toEqual(applied.proposed_ids)
    expect(applied.orders).toEqual(data.orders)
    expect(applied.items).toEqual(data.items)
    driverContext = await browser.newContext({viewport:{width:390,height:844}})
    const driver = await driverContext.newPage()
    await login(driver,data.driver_email,data.password)
    await expect(driver.locator('[data-repartidor-target="syncStatus"]')).toContainText("Acceso offline preparado",{timeout:30000})
    const actualIds = await driver.locator(".delivery-item[data-visit-id]").evaluateAll(nodes=>nodes.map(node=>Number(node.dataset.visitId)))
    expect(actualIds).toEqual(applied.proposed_ids)
  } finally { await driverContext?.close(); fixture("cleanup",data.company_id) }
})

test("confirm a route asynchronously and publish the final order to the driver without repeated optimization", async ({page,browser})=>{
  test.setTimeout(180000)
  const data = fixture("create")
  let driverContext
  try {
    await login(page,data.manager_email,data.password)
    await page.goto(`/admin/repartos/${data.run_id}`)
    await page.getByRole("button",{name:"Confirmar y optimizar",exact:true}).click()
    await expect(page).toHaveURL(new RegExp(`/admin/repartos/${data.run_id}$`),{timeout:30000})
    if (process.env.OSRM_BROWSER_LIVE !== "1") fixture("publish",data.company_id)
    await expect(page.getByRole("heading",{name:"Recorrido confirmado",exact:true})).toBeVisible({timeout:60000})
    const published = fixture("inspect",data.company_id)
    expect(published.status).toBe("applied")
    expect(published.actual_ids).toEqual(published.proposed_ids)
    expect(published.orders).toEqual(data.orders)
    expect(published.items).toEqual(data.items)
    await page.reload()
    await expect(page.getByRole("heading",{name:"Recorrido confirmado",exact:true})).toBeVisible()
    expect(await page.evaluate(()=>document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    await page.screenshot({path:"tmp/ruta-confirmada-mobile.png",fullPage:true})
    driverContext = await browser.newContext({viewport:{width:390,height:844}})
    const driver = await driverContext.newPage()
    await login(driver,data.driver_email,data.password)
    await expect(driver.locator('[data-repartidor-target="syncStatus"]')).toContainText("Acceso offline preparado",{timeout:30000})
    const ids = await driver.locator(".delivery-item[data-visit-id]").evaluateAll(nodes=>nodes.map(node=>Number(node.dataset.visitId)))
    expect(ids).toEqual(published.proposed_ids)
  } finally { await driverContext?.close(); fixture("cleanup",data.company_id) }
})
