require "test_helper"

class CustomerTest < ActiveSupport::TestCase
  test "requires a company and required commerce data" do
    customer = Customer.new
    assert_not customer.valid?
    [ :company, :name, :phone, :address, :city ].each { |field| assert customer.errors[field].any? }
  end

  test "normalizes input and permits an absent email" do
    customer = customers(:one)
    customer.update!(name: "  Comercio  ", email: "  PEDIDOS@LOCAL.TEST  ")
    assert_equal "Comercio", customer.name
    assert_equal "pedidos@local.test", customer.email
    assert customer.update(email: " ")
    assert_nil customer.email
  end

  test "validates status and maximum name length" do
    customer = customers(:one)
    customer.assign_attributes(status: "unknown", name: "a" * 91)
    assert_not customer.valid?
    assert customer.errors[:status].any?
    assert customer.errors[:name].any?
  end

  test "database enforces company and status constraints" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Customer.transaction(requires_new: true) { customers(:one).update_columns(company_id: -1) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      Customer.transaction(requires_new: true) { customers(:one).update_columns(status: "invalid") }
    end
  end
  test "coordinates must be a pair of finite values within geographic bounds" do
    customer = customers(:one)
    [ [ nil, 20 ], [ 20, nil ], [ 91, 10 ], [ 10, -181 ], [ "invalid", 10 ], [ "NaN", 10 ], [ 10, "Infinity" ] ].each do |latitude, longitude|
      customer.assign_attributes(latitude: latitude, longitude: longitude)
      assert_not customer.valid?, "Accepted invalid coordinates #{latitude.inspect}, #{longitude.inspect}"
    end
    customer.assign_attributes(latitude: 0, longitude: 0)
    assert customer.valid?
    assert customer.located?
    customer.assign_attributes(latitude: -90, longitude: 180)
    assert customer.valid?
  end

  test "legacy records can remain unlocated but admin saves require a location" do
    customer = customers(:inactive)
    assert customer.valid?
    assert_not customer.located?
    assert_not customer.valid?(:geocoded)
  end

  test "changing an address without reconfirming clears the obsolete coordinates" do
    customer = customers(:one)
    customer.update!(address: "Dirección nueva")
    assert_nil customer.latitude
    assert_nil customer.longitude
  end

  test "database rejects out of range and incomplete coordinates" do
    [ { latitude: 91 }, { longitude: -181 }, { latitude: nil } ].each do |attributes|
      assert_raises(ActiveRecord::StatementInvalid) do
        Customer.transaction(requires_new: true) { customers(:one).update_columns(attributes) }
      end
    end
  end
end
