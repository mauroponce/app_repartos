import { defineConfig } from "@playwright/test"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"

const managedServer = process.env.PWA_TEST_SERVER === "1"
const launchOptions = {
  executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ||
    (!managedServer && existsSync("/usr/bin/google-chrome") ? "/usr/bin/google-chrome" : undefined),
  args: ["--no-sandbox"]
}

export default defineConfig({
  testDir: ".", testMatch: "*.spec.js", workers: 1, timeout: 90000,
  forbidOnly: !!process.env.CI,
  retries: 0,
  webServer: managedServer ? [{
    command: "node test/browser/vroom_health_stub.js",
    cwd: fileURLToPath(new URL("../../", import.meta.url)),
    env: { PWA_BROWSER_TEST: "1" },
    url: `http://127.0.0.1:${process.env.PWA_VROOM_HEALTH_PORT || 3199}/health`,
    reuseExistingServer: false
  }, {
    command: "bin/rails server -b 127.0.0.1 -p 3006 -P tmp/pids/pwa-ci.pid",
    cwd: fileURLToPath(new URL("../../", import.meta.url)),
    url: "http://127.0.0.1:3006/up",
    env: { RAILS_ENV: "test", PWA_BROWSER_TEST: "1", MULTIVEHICLE_OPTIMIZATION_ENABLED: "true", VROOM_URL: `http://127.0.0.1:${process.env.PWA_VROOM_HEALTH_PORT || 3199}` },
    reuseExistingServer: false,
    timeout: 120000
  }] : undefined,
  use: { baseURL: (managedServer ? undefined : process.env.PWA_TEST_URL) || "http://127.0.0.1:3006", viewport: { width: 390, height: 844 }, trace: "retain-on-failure",
    launchOptions }
})
