require "test_helper"
require_relative "../../test_helpers/customer_import_test_helper"

class GeocodingAddressAndEvaluatorTest < ActiveSupport::TestCase
  include CustomerImportTestHelper

  test "normalizes mixed addresses without assigning an arbitrary locality" do
    cases = [
      [ "av h yrigoyen 12500 burzaco", "Avenida h yrigoyen", "12500", "burzaco" ],
      [ "san martin al 800 adrogue", "san martin", "800", "adrogue" ],
      [ "hipolito irigoyen 3500, lanus", "hipolito irigoyen", "3500", "lanus" ],
      [ "avda san martin 1500", "Avenida san martin", "1500", nil ],
      [ "25 de mayo 123, Quilmes", "25 de mayo", "123", "Quilmes" ],
      [ "belgrano 450", "belgrano", "450", nil ]
    ]
    cases.each do |text, street, number, city|
      address = Geocoding::Address.normalize("address" => text)
      assert_equal street, address["street"], text
      assert_equal number, address["house_number"], text
      city ? assert_equal(city, address["city"], text) : assert_nil(address["city"], text)
    end
    assert Geocoding::Address.normalize("address" => "san martin al 800 adrogue")["house_number_approximate"]
  end

  test "intersections between roads routes and references do not invent a house number" do
    [ "alsina esq mitre banfield", "calle 25 de mayo entre mitre y rivadavia", "ruta 4 km 21 cerca estacion", "esquina lavalle y tucuman, lomas", "cerca de la estacion", "dirección imposible" ].each do |text|
      assert_nil Geocoding::Address.normalize("address" => text)["house_number"], text
    end
    result = Geocoding::Address.normalize("address" => "av espora 1200 a dos cuadras de la plaza")
    assert_nil result["city"]
    assert_equal [ "a dos cuadras de la plaza" ], result["references"]
  end

  test "exact addresses are reliable while interpolation and approximate numbers require review" do
    evaluator = Geocoding::Evaluator.new
    address = Geocoding::Address.normalize("address" => "Belgrano 450", "city" => "Adrogué")
    assert_equal "reliable", evaluator.call(address, [ candidate ])["precision"]
    assert_equal "approximate", evaluator.call(address, [ candidate(provider: "georef", precision: "interpolated") ])["precision"]
    assert_equal "approximate", evaluator.call(address.merge("house_number_approximate" => true), [ candidate ])["precision"]
    assert_equal "approximate", evaluator.call(address.except("house_number"), [ candidate(type: "street", precision: "unknown") ])["precision"]
    assert_equal "approximate", evaluator.call(address.except("city"), [ candidate ])["precision"]
  end

  test "rejects wrong city province district street number and absent coordinates" do
    address = Geocoding::Address.normalize("address" => "Belgrano 450", "city" => "Adrogué", "province" => "Buenos Aires", "district" => "Almirante Brown")
    [ { city: "Morón" }, { province: "Córdoba" }, { district: "Lanús" }, { street: "Mitre" }, { house_number: "451" }, { latitude: nil }, { latitude: 90 }, { longitude: 0 } ].each do |changes|
      result = Geocoding::Evaluator.new.call(address, [ candidate(**changes) ])
      assert_equal "unlocated", result["precision"], changes.inspect
      assert result["candidates"].first["rejections"].any?
    end
  end

  test "disagreement between providers and truncated or conflicting evidence is ambiguous" do
    address = Geocoding::Address.normalize("address" => "Belgrano 450", "city" => "Adrogué")
    result = Geocoding::Evaluator.new.call(address, [ candidate, candidate(provider: "georef", precision: "interpolated", latitude: -34.82) ])
    assert_equal "ambiguous", result["precision"]
    assert_equal "ambiguous", Geocoding::Evaluator.new.call(address, [ candidate(truncated: true) ])["precision"]
    conflicting = Geocoding::Address.normalize("address" => "Belgrano 450 Lanús", "city" => "Adrogué")
    assert_equal "ambiguous", Geocoding::Evaluator.new.call(conflicting, [ candidate ])["precision"]
    assert_equal "reliable", Geocoding::Evaluator.new.call(address, [ candidate(provider: "georef", precision: "interpolated"), candidate ])["precision"]
  end

  test "country bounds detect swapped coordinates and points outside Argentina" do
    assert Geocoding::Address.valid_point?(-34.8, -58.4, country: "Argentina")
    [ [ -58.4, -34.8 ], [ "NaN", -58 ], [ -34, "Infinity" ], [ nil, -58 ], [ 91, 0 ], [ 0, 0 ] ].each do |lat, lon|
      assert_not Geocoding::Address.valid_point?(lat, lon, country: "Argentina")
    end
  end
end
