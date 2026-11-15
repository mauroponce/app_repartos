namespace :demo do
  desc "Cargar onboarding demo (exclusivamente desarrollo, sin APIs externas)"
  task onboarding: :environment do
    abort "Los datos demo solo están habilitados en desarrollo." unless Rails.env.development?
    company = DemoOnboardingSeeds.call
    puts "#{company.name}: #{company.customers.count} clientes, #{company.products.count} productos, #{company.users.driver.count} repartidores, #{company.delivery_schedules.count} programaciones, #{company.delivery_orders.count} entregas, #{company.delivery_runs.count} hojas."
  end
end
