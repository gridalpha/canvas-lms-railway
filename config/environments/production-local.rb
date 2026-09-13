# Evaluated by config/environments/production.rb, which ends with
#   Dir[.../production-*.rb].each { |f| eval(File.new(f).read, ...) }
# so `config` here is the same Rails::Application::Configuration the surrounding
# `Rails.application.configure` block is building. This is the only supported hook
# for the three production settings Canvas hardcodes for a fronting web server that
# Railway does not have.

# Railway routes straight to the container: there is no nginx or Apache in front to
# serve public/, so Rails has to. Without this every compiled asset 404s and the app
# renders as a blank page behind a healthy container.
config.public_file_server.enabled = true
config.public_file_server.headers = {
  "Cache-Control" => "public, max-age=31536000, immutable"
}

# The edge terminates TLS and speaks plain HTTP to the container. Canvas sets
# force_ssl with redirect: false, so without this `request.ssl?` is false on every
# request and the session cookie ships without its Secure flag. AssumeSSL rewrites
# the scheme for every request, including the anonymous health-check prober, which
# still gets its 200 because the redirect is already disabled.
config.assume_ssl = true

# Railway's edge reaches containers from 100.64.0.0/10 and appends its own entry to
# X-Forwarded-For from the public 152.233.0.0/17. Rails' built-in trusted_proxies
# list covers RFC1918 only, so without these three ranges request.remote_ip returns
# a rotating Railway address instead of the real client.
config.action_dispatch.trusted_proxies = ActionDispatch::RemoteIp::TRUSTED_PROXIES + [
  IPAddr.new("100.64.0.0/10"),
  IPAddr.new("152.233.0.0/17"),
  IPAddr.new("fd00::/8")
]
