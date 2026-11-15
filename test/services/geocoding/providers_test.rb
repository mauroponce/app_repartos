require "test_helper"
require_relative "../../test_helpers/customer_import_test_helper"

class GeocodingProvidersTest < ActiveSupport::TestCase
  include CustomerImportTestHelper

  def http(provider, payload = {}, code: 200, headers: {}, &transport)
    Geocoding::HttpClient.new(provider: provider, url: "https://example.test/api", transport: transport || ->(*) { Response.new(code.to_s, payload.is_a?(String) ? payload : payload.to_json, headers) })
  end

  def address(city = "Adrogué")
    Geocoding::Address.normalize("address" => "Belgrano 450", "city" => city, "province" => "Buenos Aires")
  end

  test "Georef bulk parser preserves partial and missing coordinate evidence and caches by tenant and context" do
    calls = []
    response = { resultados: [ { total: 1, direcciones: [ { calle: { nombre: "BELGRANO" }, altura: { valor: 450 }, localidad: { nombre: "Adrogué" }, provincia: { nombre: "Buenos Aires" }, ubicacion: { lat: nil, lon: nil }, nomenclatura: "BELGRANO 450" } ] } ] }
    client = http("georef") { |uri, request| calls << JSON.parse(request.body); Response.new("200", response.to_json) }
    stub_method(GeocodingProviderState, :reserve!, nil) do
      provider = Geocoding::Georef.new(company_id: companies(:one).id, http: client)
      result = provider.batch([ address, address ])
      assert_equal 1, calls.size
      assert_equal 1, calls.first["direcciones"].size
      assert_nil result.first.first["latitude"]
      assert_equal "interpolated", result.first.first["precision"]
      provider.search(address)
      assert_equal 1, calls.size
      provider.search(address("Banfield"))
      assert_equal 2, calls.size
      Geocoding::Georef.new(company_id: companies(:two).id, http: client).search(address)
      assert_equal 3, calls.size
    end
  end

  test "Photon sends a country filter and never trusts a locality merely because street matches" do
    response = { features: [ { geometry: { type: "Point", coordinates: [ -58.39, -34.80 ] }, properties: { countrycode: "AR", street: "Belgrano", housenumber: "450", city: "Morón", state: "Buenos Aires", osm_key: "building" } } ] }
    calls = []
    client = http("photon") { |uri, _| calls << uri; Response.new("200", response.to_json) }
    stub_method(GeocodingProviderState, :reserve!, nil) do
      provider = Geocoding::Photon.new(company_id: companies(:one).id, http: client)
      candidates = provider.search(address)
      assert_includes calls.first.query, "countrycode=ar"
      assert_equal "unlocated", Geocoding::Evaluator.new.call(address, candidates)["precision"]
      provider.search(address)
      assert_equal 1, calls.size
    end
  end

  test "HTTP errors timeouts invalid JSON oversized bodies and redirects are bounded" do
    stub_method(GeocodingProviderState, :reserve!, nil) do
      [ 429, 500 ].each { |code| assert_raises(Geocoding::Retryable) { http("georef", {}, code: code).call } }
      [ 301, 403, 404 ].each { |code| assert_raises(Geocoding::Error) { http("georef", {}, code: code).call } }
      [ "oops", "[]", "null", "x" * (Geocoding::HttpClient::MAX_BYTES + 1) ].each { |body| assert_raises(Geocoding::InvalidResponse) { http("georef", body).call } }
      assert_raises(Geocoding::Retryable) { http("georef") { raise Net::ReadTimeout }.call }
    end
    [ "file:///tmp/secrets", "https://name:pass@example.test", "https://example.test/?key=secret" ].each do |url|
      assert_raises(Geocoding::Error) { Geocoding::HttpClient.new(provider: "georef", url: url) }
    end
  end

  test "shared rate limiter enforces time spacing daily limits and keeps aggregated tokens" do
    GeocodingProviderState.reserve!("test-provider", interval: 1, limit: 2)
    assert_raises(Geocoding::Deferred) { GeocodingProviderState.reserve!("test-provider", interval: 1, limit: 2) }
    travel 2.seconds do
      GeocodingProviderState.reserve!("test-provider", interval: 1, limit: 2)
      assert_raises(Geocoding::QuotaExceeded) { GeocodingProviderState.reserve!("test-provider", interval: 1, limit: 2) }
    end
    travel 1.day do
      GeocodingProviderState.reserve!("test-provider", interval: 1, limit: 2)
      assert_equal 1, GeocodingProviderState.find_by!(provider: "test-provider").requests
    end
  end

  test "Gemini disabled or missing credentials makes zero HTTP requests" do
    with_env("GEMINI_ENABLED" => "false", "GEMINI_API_KEY" => nil, "GEMINI_MODEL" => "models/invalid-optional-model") do
      provider = Geocoding::Gemini.new(company_id: companies(:one).id, http: http("gemini") { flunk "No Gemini request expected" })
      assert_nil provider.interpret(address)
    end
  end

  test "Gemini schema enforces grounded facts and sends no customer contact information" do
    value = Geocoding::Gemini::TEXT_FIELDS.index_with { nil }.merge(Geocoding::Gemini::ARRAY_FIELDS.index_with { [] })
      .merge("street" => "Belgrano", "house_number" => "450", "city" => "Adrogué", "province" => "Buenos Aires", "country" => "Argentina", "house_number_approximate" => false, "geocodable" => true)
    value["evidence"] = value.slice(*Geocoding::Gemini::TEXT_FIELDS)
    captured = []
    client = http("gemini") do |uri, request|
      captured << JSON.parse(request.body)
      Response.new("200", { candidates: [ { finishReason: "STOP", content: { parts: [ { text: value.to_json } ] } } ], usageMetadata: { totalTokenCount: 123 } }.to_json)
    end
    with_env("GEMINI_ENABLED" => "true", "GEMINI_API_KEY" => "fake-test-value") do
      stub_method(GeocodingProviderState, :reserve!, nil) do
        provider = Geocoding::Gemini.new(company_id: companies(:one).id, http: client)
        assert_equal "450", provider.interpret(address.merge("name" => "Privado", "phone" => "555", "email" => "privado@example.test"))["house_number"]
        text = captured.first["contents"].first["parts"].first["text"]
        assert_not_includes text, "Privado"
        assert_not_includes text, "555"
        assert captured.first.dig("generationConfig", "responseJsonSchema", "additionalProperties") == false
        value["house_number"] = "999"
        assert_raises(Geocoding::InvalidResponse) { provider.interpret(address("Banfield")) }
        value["house_number"] = "450"
        value["city"] = "Inventada"
        assert_raises(Geocoding::InvalidResponse) { provider.interpret(address("Quilmes")) }
        value["latitude"] = -34.0
        assert_raises(Geocoding::InvalidResponse) { provider.interpret(address("Lanús")) }
      end
    end
  end
  test "real Photon city and subdivision inconsistencies require review" do
    response = { features: [ { geometry: { type: "Point", coordinates: [ -58.39, -34.80 ] }, properties: { countrycode: "AR", street: "Belgrano", housenumber: "450", city: "Adrogué", district: "Claypole", state: "Buenos Aires", type: "house" } } ] }
    stub_method(GeocodingProviderState, :reserve!, nil) do
      values = Geocoding::Photon.new(company_id: companies(:one).id, http: http("photon", response)).search(address)
      assert_equal "Claypole", values.first["sublocality"]
      assert_equal "ambiguous", Geocoding::Evaluator.new.call(address, values)["precision"]
    end
  end
end
