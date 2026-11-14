# Supply the actual Git repository and Hetzner host when preparing the first deploy.
raise "Falta DEPLOY_REPO_URL" if ENV["DEPLOY_REPO_URL"].to_s.empty?
raise "Falta DEPLOY_HOST" if ENV["DEPLOY_HOST"].to_s.empty?

server ENV.fetch("DEPLOY_HOST"), user: ENV.fetch("DEPLOY_USER", "deploy"), roles: %w[app db web]
