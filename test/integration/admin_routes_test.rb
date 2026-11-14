require "test_helper"

class AdminRoutesTest < ActionDispatch::IntegrationTest
  test "management routes all use the admin prefix" do
    assert_equal "/admin", admin_root_path
    assert_equal "/admin/clientes", customers_path
    assert_equal "/admin/repartidores", drivers_path
    assert_equal "/admin/repartos", delivery_runs_path
    assert_equal "/admin/productos", products_path
    assert_equal "/admin/importaciones-productos/new", new_product_import_path
    assert_equal "/admin/clientes/#{customers(:one).id}/programaciones/new", new_customer_delivery_schedule_path(customers(:one))
    get root_path
    assert_redirected_to admin_root_path
    [ "/clientes", "/repartidores", "/repartos", "/productos", "/importaciones-productos/new" ].each do |path|
      get path
      assert_response :not_found
    end
  end

  test "admin home requires authentication and navigation points to admin routes" do
    get admin_root_path
    assert_redirected_to new_session_path
    sign_in_as users(:one)
    get admin_root_path
    assert_response :success
    assert_select ".side-nav a[href]" do |links|
      assert links.all? { |link| link["href"].start_with?("/admin/") }
    end
    get customer_path(customers(:one))
    assert_select "dialog[data-modal-return-url-value=?]", customers_path
  end
end
