lock "~> 3.20"

set :application, "app_repartos"
set :repo_url, ENV["DEPLOY_REPO_URL"]
set :branch, ENV.fetch("DEPLOY_BRANCH", "main")
set :deploy_to, "/var/www/app_repartos"
set :keep_releases, 5
set :rails_env, "production"
set :migration_command, "db:prepare"
set :default_env, { "PATH" => "/opt/ruby/bin:$PATH", "APP_ENV_FILE" => "/var/www/app_repartos/shared/.env.production" }
append :linked_files, ".env.production"
append :linked_dirs, "log", "tmp/pids", "tmp/cache", "tmp/sockets", "storage"
set :ssh_options, { forward_agent: true, verify_host_key: :always }

namespace :deploy do
  task :configure_bundle do
    SSHKit.config.command_map[:bundle] = release_path.join("bin/bundle-production").to_s
    fetch(:bundle_bins).each do |command|
      SSHKit.config.command_map.prefix[command.to_sym].replace([ "#{release_path.join('bin/bundle-production')} exec" ])
    end
  end

  task :restart do
    on roles(:app) do
      execute :sudo, "-n", :systemctl, :restart, "app-repartos-web.service", "app-repartos-jobs.service"
    end
  end
end

before "bundler:config", "deploy:configure_bundle"
after "deploy:published", "deploy:restart"
