# Canvas ships config/puma.rb with `threads 0, 1` and no workers, i.e. one request
# at a time — it expects Passenger in front. This replaces it for Railway.
#
# Threads stay at 1 (Canvas' own default) and concurrency comes from worker
# processes, sized from WEB_CONCURRENCY rather than the host's core count: Railway
# hosts report 48 cores against an 8 GB container quota, and each Canvas worker
# costs roughly 700 MB resident.

workers Integer(ENV.fetch("WEB_CONCURRENCY", "2"))

threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", "1"))
threads threads_count, threads_count

bind "tcp://0.0.0.0:#{ENV.fetch('PORT', '3000')}"

environment ENV.fetch("RAILS_ENV", "production")

# Canvas' own config disables preload (phased restarts), so each worker boots the
# app itself. Booting Canvas is slow enough to need a generous window.
preload_app! false
worker_boot_timeout 300
worker_timeout 300

# Railway sends SIGTERM and, with RAILWAY_DEPLOYMENT_DRAINING_SECONDS, waits.
on_worker_boot do
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord::Base)
end
