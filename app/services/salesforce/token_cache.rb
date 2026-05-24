module Salesforce
  # Caches Salesforce JWT-Bearer access tokens between job invocations so
  # multiple workers don't each trigger a fresh login. Restforce does NOT
  # cache JWT-issued tokens out of the box (it only caches Username-Password).
  #
  # Three behaviors that matter:
  #   1. Single-flight: when the cache is cold, only one worker performs the
  #      JWT exchange; others wait. Implemented via a Postgres advisory lock
  #      keyed on the cache key.
  #   2. TTL margin: tokens are cached for `token_lifetime - 5.minutes` so
  #      in-flight requests never use a token that's about to expire.
  #   3. Explicit invalidation: on 401 or 404 (sandbox refresh / instance
  #      migration), callers invalidate and retry once.
  module TokenCache
    extend self

    # Token entries look like { access_token:, instance_url:, fetched_at: }
    Token = Struct.new(:access_token, :instance_url, :fetched_at, keyword_init: true) do
      def expired?(lifetime_seconds:)
        Time.current - fetched_at > (lifetime_seconds - 5.minutes)
      end
    end

    # Fetch (or fetch-and-store) the current token. Yields to the block to
    # do the JWT exchange when nothing is cached. Holds a Postgres advisory
    # lock during the exchange so concurrent workers don't stampede.
    def fetch(consumer_key:, sandbox:, lifetime_seconds: 2.hours.to_i, &block)
      key = cache_key(consumer_key: consumer_key, sandbox: sandbox)

      existing = Rails.cache.read(key)
      return existing if existing && !existing.expired?(lifetime_seconds: lifetime_seconds)

      with_advisory_lock(key) do
        # Re-check under the lock — another worker may have written it while
        # we were waiting.
        existing = Rails.cache.read(key)
        return existing if existing && !existing.expired?(lifetime_seconds: lifetime_seconds)

        token = block.call
        write(key, token, lifetime_seconds: lifetime_seconds)
        token
      end
    end

    # Read the current cached token without triggering an exchange. Returns
    # nil if absent. Used by long-running clients (Bulk API 2.0) that need
    # to grab a fresh token mid-loop.
    def read(consumer_key:, sandbox:)
      Rails.cache.read(cache_key(consumer_key: consumer_key, sandbox: sandbox))
    end

    # Drop a specific token entry. Called on 401/404 (sandbox refresh,
    # instance migration) before the next call re-triggers a JWT exchange.
    def invalidate(consumer_key:, sandbox:)
      Rails.cache.delete(cache_key(consumer_key: consumer_key, sandbox: sandbox))
    end

    # Drop every cached Salesforce token. Used after cert rotation.
    def purge!
      Rails.cache.delete_matched("sf-token:*") if Rails.cache.respond_to?(:delete_matched)
    end

    def cache_key(consumer_key:, sandbox:)
      digest = Digest::SHA256.hexdigest(consumer_key.to_s)[0, 16]
      env = Rails.env
      env_tag = sandbox ? "sandbox" : "production"
      "sf-token:#{env}:#{env_tag}:#{digest}"
    end

    private

    def write(key, token, lifetime_seconds:)
      ttl = [ lifetime_seconds - 5.minutes.to_i, 60 ].max
      Rails.cache.write(key, token, expires_in: ttl, race_condition_ttl: 30)
    end

    # Postgres advisory lock keyed on the hash of the cache key. Two args
    # form is used to support arbitrary 64-bit keys; we map the cache key
    # to a stable signed int pair. Uses exec_query with bind parameters so
    # Brakeman doesn't flag the integer interpolation as SQL injection
    # (the values come from SHA256 hashes so they were already safe, but
    # parameterized SQL is the right pattern regardless).
    def with_advisory_lock(key)
      lock_id_high, lock_id_low = advisory_lock_ids(key)
      conn = ActiveRecord::Base.connection
      conn.exec_query("SELECT pg_advisory_lock($1, $2)", "pg_advisory_lock", [ lock_id_high, lock_id_low ])
      yield
    ensure
      conn&.exec_query("SELECT pg_advisory_unlock($1, $2)", "pg_advisory_unlock", [ lock_id_high, lock_id_low ])
    end

    def advisory_lock_ids(key)
      digest = Digest::SHA256.digest(key)
      # Map first 8 bytes to two signed 32-bit ints (Postgres advisory_lock(int, int))
      hi, lo = digest.unpack("l>l>")
      [ hi, lo ]
    end
  end
end
