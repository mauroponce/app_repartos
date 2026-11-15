require "test_helper"
require_relative "../../test_helpers/customer_import_test_helper"

class GeocodingProvinceBoundaryTest < ActiveSupport::TestCase
  include CustomerImportTestHelper

  test "official geometry distinguishes Buenos Aires CABA Cordoba and other countries" do
    assert_equal 24, Geocoding::ProvinceBoundary.names.size
    assert Geocoding::ProvinceBoundary.contains?("Buenos Aires", -34.80, -58.39)
    assert Geocoding::ProvinceBoundary.contains?("Buenos Aires", -38.0, -57.55)
    assert_not Geocoding::ProvinceBoundary.contains?("Buenos Aires", -34.60, -58.38)
    assert Geocoding::ProvinceBoundary.contains?("Ciudad Autónoma de Buenos Aires", -34.60, -58.38)
    assert_not Geocoding::ProvinceBoundary.contains?("Buenos Aires", -31.42, -64.18)
    assert Geocoding::ProvinceBoundary.contains?("Córdoba", -31.42, -64.18)
    assert_not Geocoding::ProvinceBoundary.contains?("Buenos Aires", -34.90, -56.16)
    assert_not Geocoding::ProvinceBoundary.contains?("Buenos Aires", nil, nil)
  end

  test "a provider cannot bypass the province restriction by lying about the province name" do
    address = Geocoding::Address.normalize("address" => "Belgrano 450", "city" => "Adrogué", "province" => "Buenos Aires")
    result = Geocoding::Evaluator.new.call(address, [ candidate(latitude: -34.60, longitude: -58.38) ])
    assert_equal "unlocated", result["precision"]
    assert_includes result["candidates"].first["rejections"], "Las coordenadas no pertenecen a la provincia indicada"
  end
end
