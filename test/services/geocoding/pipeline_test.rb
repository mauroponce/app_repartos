require "test_helper"
require_relative "../../test_helpers/customer_import_test_helper"

class GeocodingPipelineTest < ActiveSupport::TestCase
  include CustomerImportTestHelper

  def provider(values, calls, name)
    Object.new.tap do |object|
      object.define_singleton_method(:search) { |_address, **_| calls << name; values }
    end
  end

  def ai(value, calls)
    Object.new.tap do |object|
      object.define_singleton_method(:interpret) { |_| calls << :gemini; value }
    end
  end

  test "Georef and Photon precede Gemini and trustworthy evidence avoids AI" do
    calls = []
    pipeline = Geocoding::Pipeline.new(company_id: companies(:one).id,
      georef: provider([ candidate(provider: "georef", precision: "interpolated") ], calls, :georef),
      photon: provider([ candidate ], calls, :photon), gemini: ai(nil, calls))
    result = pipeline.call({ "address" => "Belgrano 450", "city" => "Adrogué" })
    assert_equal "reliable", result["precision"]
    assert_equal [ :georef, :photon ], calls
  end

  test "Gemini interprets only unresolved addresses and all interpreted points still require review" do
    calls = []
    georef = Object.new
    georef.define_singleton_method(:search) do |address|
      calls << :georef
      address["street"] == "Belgrano" ? [ { "provider" => "georef", "street" => "Belgrano", "house_number" => "450", "city" => "Adrogué", "district" => "Almirante Brown", "province" => "Buenos Aires", "country" => "Argentina", "latitude" => -34.8, "longitude" => -58.39, "precision" => "interpolated", "type" => "address" } ] : []
    end
    interpretation = { "street" => "Belgrano", "house_number" => "450", "city" => "Adrogué", "province" => nil, "country" => nil, "geocodable" => true }
    pipeline = Geocoding::Pipeline.new(company_id: companies(:one).id, georef: georef, photon: provider([], calls, :photon), gemini: ai(interpretation, calls))
    result = pipeline.call({ "address" => "calle belgrano al 450 adrogue", "city" => "Adrogué" })
    assert_equal "approximate", result["precision"]
    assert_equal [ :georef, :photon, :gemini, :georef, :photon ], calls
    assert_equal "Buenos Aires", result["normalized"]["province"]
  end

  test "an explicit wrong province or out of province supplied point never reaches a provider" do
    calls = []
    pipeline = Geocoding::Pipeline.new(company_id: companies(:one).id, georef: provider([], calls, :georef), photon: provider([], calls, :photon), gemini: ai(nil, calls))
    result = pipeline.call({ "address" => "Belgrano 450", "city" => "Córdoba", "province" => "Córdoba" })
    assert_equal "unlocated", result["precision"]
    result = pipeline.call({ "address" => "Belgrano 450", "city" => "Adrogué", "latitude" => -34.60, "longitude" => -58.38 })
    assert_equal "unlocated", result["precision"]
    assert_empty calls
  end

  test "permanent failures remain recoverable without crashing the rest of the pipeline" do
    calls = []
    broken = Object.new
    broken.define_singleton_method(:search) { |_| raise Geocoding::InvalidResponse, "JSON inválido" }
    pipeline = Geocoding::Pipeline.new(company_id: companies(:one).id, georef: broken, photon: provider([], calls, :photon), gemini: ai(nil, calls))
    result = pipeline.call({ "address" => "Belgrano 450", "city" => "Adrogué" })
    assert_equal "unlocated", result["precision"]
    assert_includes result["warnings"], "JSON inválido"
  end
  test "a complete interpolated address needs manual review without spending Gemini tokens" do
    calls = []
    pipeline = Geocoding::Pipeline.new(company_id: companies(:one).id,
      georef: provider([ candidate(provider: "georef", precision: "interpolated") ], calls, :georef),
      photon: provider([], calls, :photon), gemini: ai(nil, calls))
    result = pipeline.call({ "address" => "Belgrano 450", "city" => "Adrogué" })
    assert_equal "approximate", result["precision"]
    assert_equal [ :georef, :photon ], calls
  end
  test "AI-assisted matches retained from an initial search cannot become automatically reliable" do
    calls = []
    interpretation = { "street" => "Belgrano", "house_number" => "450", "city" => "Adrogué", "geocodable" => true }
    pipeline = Geocoding::Pipeline.new(company_id: companies(:one).id,
      georef: provider([], calls, :georef), photon: provider([ candidate ], calls, :photon), gemini: ai(interpretation, calls))
    result = pipeline.call({ "address" => "Blegnrano 450", "city" => "Adrogué" })
    assert_equal "approximate", result["precision"]
    assert result["candidates"].all? { |value| value["interpreted"] }
  end
end
