require "sinatra"
require "net/http"
require "json"
require "uri"
require "thread"

set :bind, "0.0.0.0"
set :port, Integer(ENV.fetch("PORT", "4567"))
set :protection, true

API_BASE = "https://sendtim.com/api/v1"
EMAIL_PATTERN = /\A\S+@\S+\.\S+\z/
UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
PROPERTY_NAME_PATTERN = /\A[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,63}\z/
CONSENT_SOURCES = %w[import form api manual double_opt_in unknown].freeze
ALLOWED_FIELDS = %w[email firstName lastName company source customProperties listIds consentGiven consentSource].freeze
RATE_LIMIT_WINDOW = 10 * 60
RATE_LIMIT_MAX = 5
RATE_LIMITS = {}
RATE_LIMIT_LOCK = Mutex.new

def json_response(status, data = nil, **kwargs)
  data ||= kwargs
  content_type :json
  halt status, JSON.generate(data)
end

def error_response(status, code, message)
  json_response(status, error: { code: code, message: message })
end

def sendtim(path, method: :get, body: nil)
  key = ENV["SENDTIM_API_KEY"].to_s
  error_response(500, "configuration_error", "SENDTIM_API_KEY is required.") if key.empty?

  uri = URI("#{API_BASE}#{path}")
  upstream_request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
  upstream_request["Authorization"] = "Bearer #{key}"
  upstream_request["Accept"] = "application/json"
  if body
    upstream_request["Content-Type"] = "application/json"
    upstream_request.body = JSON.generate(body)
  end

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 10) do |http|
    http.request(upstream_request)
  end
  parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  json_response(response.code.to_i, parsed)
rescue JSON::ParserError
  error_response(502, "invalid_upstream_response", "Sendtim returned an invalid response.")
rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, EOFError
  error_response(502, "upstream_unavailable", "Sendtim could not be reached.")
end

def require_same_origin!
  origin = request.env["HTTP_ORIGIN"]
  return if origin.nil? || origin.empty?

  expected = ENV["APP_ORIGIN"].to_s
  expected = request.base_url if expected.empty?
  error_response(403, "origin_not_allowed", "Origin not allowed.") unless origin == expected
end

def check_rate_limit!
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  allowed = RATE_LIMIT_LOCK.synchronize do
    entry = RATE_LIMITS[request.env.fetch("REMOTE_ADDR", "unknown")]
    if entry.nil? || entry[:reset_at] <= now
      RATE_LIMITS[request.env.fetch("REMOTE_ADDR", "unknown")] = { count: 1, reset_at: now + RATE_LIMIT_WINDOW }
      true
    elsif entry[:count] >= RATE_LIMIT_MAX
      headers "Retry-After" => (entry[:reset_at] - now).ceil.to_s
      false
    else
      entry[:count] += 1
      true
    end
  end
  error_response(429, "rate_limited", "Too many requests.") unless allowed
end

def optional_string(body, field, max_length)
  value = body[field]
  return nil if value.nil? || value == ""
  error_response(400, "validation_failed", "#{field} is invalid.") unless value.is_a?(String) && value.strip.length <= max_length
  value.strip
end

get "/api/health" do
  json_response(200, ok: true, service: "sendtim-ruby-example")
end

post "/api/contacts" do
  require_same_origin!
  check_rate_limit!
  error_response(415, "unsupported_media_type", "Content-Type must be application/json.") unless request.media_type == "application/json"

  raw = request.body.read(10_001)
  error_response(413, "payload_too_large", "Request is too large.") if raw.bytesize > 10_000
  body = JSON.parse(raw)
  error_response(400, "validation_failed", "Expected a JSON object.") unless body.is_a?(Hash)

  unknown_fields = body.keys - ALLOWED_FIELDS
  error_response(400, "validation_failed", "Unknown fields: #{unknown_fields.join(', ')}.") unless unknown_fields.empty?

  email = body["email"].to_s.strip.downcase
  error_response(400, "validation_failed", "Enter a valid email address.") unless EMAIL_PATTERN.match?(email) && email.length <= 254

  payload = { email: email }
  { "firstName" => 120, "lastName" => 120, "company" => 200, "source" => 64 }.each do |field, max_length|
    value = optional_string(body, field, max_length)
    payload[field] = value unless value.nil?
  end

  if body.key?("customProperties")
    properties = body["customProperties"]
    error_response(400, "validation_failed", "customProperties must be an object.") unless properties.is_a?(Hash)
    properties.each do |key, value|
      valid_value = value.nil? || value.is_a?(Numeric) || value == true || value == false || (value.is_a?(String) && value.length <= 1000)
      error_response(400, "validation_failed", "customProperties contains an invalid key or value.") unless PROPERTY_NAME_PATTERN.match?(key) && valid_value
    end
    payload["customProperties"] = properties
  end

  if body.key?("listIds")
    list_ids = body["listIds"]
    valid = list_ids.is_a?(Array) && list_ids.length <= 50 && list_ids.all? { |id| id.is_a?(String) && UUID_PATTERN.match?(id) }
    error_response(400, "validation_failed", "listIds must contain at most 50 UUIDs.") unless valid
    payload["listIds"] = list_ids
  end

  if body.key?("consentGiven")
    consent = body["consentGiven"]
    error_response(400, "validation_failed", "consentGiven must be boolean.") unless consent == true || consent == false
    payload["consentGiven"] = consent
  end
  if body.key?("consentSource")
    source = body["consentSource"]
    error_response(400, "validation_failed", "consentSource is invalid.") unless CONSENT_SOURCES.include?(source)
    payload["consentSource"] = source
  end

  sendtim("/contacts", method: :post, body: payload)
rescue JSON::ParserError
  error_response(400, "validation_failed", "Body must be valid JSON.")
end
