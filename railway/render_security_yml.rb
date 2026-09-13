# Renders config/security.yml as plain YAML before any rake task runs.
#
# Every other Canvas config file can be ERB, because ConfigFile.load runs
# `ERB.new(path.read).result` before YAML. security.yml is the exception:
# `db:generate_security_key`, which `db:initial_setup` depends on, reads it with a
# bare `YAML.load_file`, so an ERB template there fails the whole task with
#   Psych::SyntaxError: mapping values are not allowed in this context
# pointing at the first real YAML line rather than at the template.
#
# The same task rewrites the file with a random key when `encryption_key` is shorter
# than 20 characters, so writing a real key here is also what stops Canvas minting an
# ephemeral one that changes on every deploy.

require "yaml"

key = ENV["CANVAS_ENCRYPTION_KEY"].to_s
abort("[render_security_yml] CANVAS_ENCRYPTION_KEY is unset") if key.empty?
abort("[render_security_yml] CANVAS_ENCRYPTION_KEY must be 20+ characters") if key.length < 20

jwt = ENV["CANVAS_JWT_ENCRYPTION_KEY"].to_s
jwt = key if jwt.empty?

previous = ENV["CANVAS_PREVIOUS_ENCRYPTION_KEYS"].to_s.split(",").map(&:strip).reject(&:empty?)

domain = ENV["CANVAS_DOMAIN"].to_s
domain = ENV["RAILWAY_PUBLIC_DOMAIN"].to_s if domain.empty?

conf = {
  "encryption_key" => key,
  "jwt_encryption_keys" => [jwt]
}
conf["previous_encryption_keys"] = previous unless previous.empty?
conf["lti_iss"] = domain.empty? ? "https://canvas.instructure.com" : "https://#{domain}"

path = File.expand_path("../config/security.yml", __dir__)
File.write(path, YAML.dump("production" => conf))
File.chmod(0o600, path)

warn "[render_security_yml] wrote #{path}"
