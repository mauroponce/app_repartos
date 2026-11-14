require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "inactive drivers cannot receive new runs while existing runs remain editable" do
    driver = users(:driver)
    run = companies(:one).delivery_runs.create!(driver: driver, name: "Existente", scheduled_date: "2026-11-17")
    driver.update!(status: :inactive)
    assert run.reload.update(name: "Actualizado")
    new_run = companies(:one).delivery_runs.new(driver: driver, name: "Nuevo", scheduled_date: "2026-11-18")
    assert_not new_run.valid?
    assert_includes new_run.errors[:driver], "debe estar activo para asignarle un reparto"
  end
end
