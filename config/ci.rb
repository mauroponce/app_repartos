# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"
  step "Setup: JavaScript", "npm ci"
  step "Build: CSS", "bin/rails tailwindcss:build"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit check --update"
  step "Security: JavaScript audit", "npm audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Tests: Rails", "bin/rails test"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"
  step "Tests: JavaScript (including offline)", "npm run test:js"
  step "Tests: Offline browser", "env PWA_TEST_SERVER=1 npm run test:browser"
end
