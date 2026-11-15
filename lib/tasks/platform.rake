namespace :platform do
  desc "Crear un administrador de plataforma usando PLATFORM_ADMIN_NAME, PLATFORM_ADMIN_EMAIL y PLATFORM_ADMIN_PASSWORD (no modifica cuentas existentes)"
  task bootstrap: :environment do
    email = ENV.fetch("PLATFORM_ADMIN_EMAIL").strip.downcase
    abort "La cuenta ya existe; no se modificó su contraseña." if PlatformAdmin.exists?(email_address: email)
    PlatformAdmin.create!(name: ENV.fetch("PLATFORM_ADMIN_NAME"), email_address: email, password: ENV.fetch("PLATFORM_ADMIN_PASSWORD"))
    puts "Administrador de plataforma creado."
  end
end
