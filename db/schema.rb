# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_15_010000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "companies", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "time_zone", default: "America/Argentina/Buenos_Aires", null: false
    t.index ["slug"], name: "index_companies_on_slug", unique: true
  end

  create_table "customers", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", limit: 90, null: false
    t.string "contact"
    t.string "phone", null: false
    t.string "email"
    t.string "address", null: false
    t.string "city", null: false
    t.string "status", default: "active", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "latitude", precision: 10, scale: 7
    t.decimal "longitude", precision: 10, scale: 7
    t.index ["company_id", "id"], name: "index_customers_on_company_id_and_id", unique: true
    t.index ["company_id", "name", "id"], name: "index_customers_on_company_id_and_name_and_id"
    t.index ["company_id", "status"], name: "index_customers_on_company_id_and_status"
    t.index ["company_id"], name: "index_customers_on_company_id"
    t.check_constraint "latitude IS NULL AND longitude IS NULL OR latitude IS NOT NULL AND longitude IS NOT NULL AND latitude >= '-90'::integer::numeric AND latitude <= 90::numeric AND longitude >= '-180'::integer::numeric AND longitude <= 180::numeric", name: "customers_valid_coordinates"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'inactive'::character varying]::text[])", name: "customers_valid_status"
  end

  create_table "delivery_items", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "visit_id", null: false
    t.bigint "product_id"
    t.string "description", null: false
    t.string "unit", null: false
    t.decimal "planned_quantity", precision: 12, scale: 3, null: false
    t.decimal "delivered_quantity", precision: 12, scale: 3
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "delivery_order_item_id"
    t.index ["company_id"], name: "index_delivery_items_on_company_id"
    t.index ["delivery_order_item_id"], name: "index_delivery_items_on_delivery_order_item_id", unique: true
    t.index ["product_id"], name: "index_delivery_items_on_product_id"
    t.index ["visit_id"], name: "index_delivery_items_on_visit_id"
    t.check_constraint "(unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR planned_quantity = trunc(planned_quantity)", name: "delivery_items_integer_quantity"
    t.check_constraint "btrim(description::text) <> ''::text AND (unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[])) AND planned_quantity > 0::numeric", name: "delivery_items_valid_merchandise"
    t.check_constraint "delivered_quantity IS NULL OR (unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR delivered_quantity = trunc(delivered_quantity)", name: "items_integer_delivered"
    t.check_constraint "delivered_quantity IS NULL OR delivered_quantity >= 0::numeric", name: "items_nonnegative_delivered"
    t.check_constraint "planned_quantity < 1000000000::numeric AND (delivered_quantity IS NULL OR delivered_quantity < 1000000000::numeric)", name: "items_finite_quantities"
  end

  create_table "delivery_order_items", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "delivery_order_id", null: false
    t.bigint "product_id"
    t.string "description", null: false
    t.decimal "quantity", precision: 12, scale: 3, null: false
    t.string "unit", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "id"], name: "index_delivery_order_items_on_company_id_and_id", unique: true
    t.index ["company_id"], name: "index_delivery_order_items_on_company_id"
    t.index ["delivery_order_id"], name: "index_delivery_order_items_on_delivery_order_id"
    t.index ["product_id"], name: "index_delivery_order_items_on_product_id"
    t.check_constraint "(unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR quantity = trunc(quantity)", name: "order_items_integer_quantity"
    t.check_constraint "\"position\" >= 0", name: "order_items_valid_position"
    t.check_constraint "btrim(description::text) <> ''::text AND (unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[])) AND quantity > 0::numeric AND quantity < 1000000000::numeric", name: "order_items_valid_merchandise"
  end

  create_table "delivery_orders", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "customer_id", null: false
    t.bigint "delivery_schedule_id"
    t.bigint "visit_id"
    t.date "scheduled_date", null: false
    t.time "preferred_time"
    t.time "window_start"
    t.time "window_end"
    t.string "customer_name", null: false
    t.string "customer_address", null: false
    t.string "status", default: "pending", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "delivery_schedule_id", "scheduled_date"], name: "orders_unique_schedule_date", unique: true, where: "(delivery_schedule_id IS NOT NULL)"
    t.index ["company_id", "id"], name: "index_delivery_orders_on_company_id_and_id", unique: true
    t.index ["company_id", "scheduled_date", "status"], name: "idx_on_company_id_scheduled_date_status_b6fe95a943"
    t.index ["company_id"], name: "index_delivery_orders_on_company_id"
    t.index ["customer_id"], name: "index_delivery_orders_on_customer_id"
    t.index ["delivery_schedule_id"], name: "index_delivery_orders_on_delivery_schedule_id"
    t.index ["visit_id"], name: "index_delivery_orders_on_visit_id"
    t.check_constraint "btrim(customer_name::text) <> ''::text AND btrim(customer_address::text) <> ''::text", name: "orders_customer_snapshot"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'completed'::character varying, 'cancelled'::character varying]::text[])", name: "orders_valid_status"
    t.check_constraint "window_start IS NULL AND window_end IS NULL OR preferred_time IS NULL AND window_start IS NOT NULL AND window_end IS NOT NULL AND window_end > window_start", name: "orders_valid_times"
  end

  create_table "delivery_runs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "driver_id"
    t.date "scheduled_date", null: false
    t.string "name", null: false
    t.string "status", default: "draft", null: false
    t.string "generation_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "generation_key"], name: "index_delivery_runs_on_company_id_and_generation_key", unique: true, where: "(generation_key IS NOT NULL)"
    t.index ["company_id", "id"], name: "index_delivery_runs_on_company_id_and_id", unique: true
    t.index ["company_id", "scheduled_date"], name: "index_delivery_runs_on_company_id_and_scheduled_date"
    t.index ["company_id"], name: "index_delivery_runs_on_company_id"
    t.index ["driver_id"], name: "index_delivery_runs_on_driver_id"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'assigned'::character varying, 'in_progress'::character varying, 'completed'::character varying, 'cancelled'::character varying]::text[])", name: "runs_valid_status"
  end

  create_table "delivery_schedule_items", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "delivery_schedule_id", null: false
    t.bigint "product_id"
    t.string "description", null: false
    t.decimal "quantity", precision: 12, scale: 3, null: false
    t.string "unit", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_delivery_schedule_items_on_company_id"
    t.index ["delivery_schedule_id"], name: "index_delivery_schedule_items_on_delivery_schedule_id"
    t.index ["product_id"], name: "index_delivery_schedule_items_on_product_id"
    t.check_constraint "(unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR quantity = trunc(quantity)", name: "delivery_schedule_items_integer_quantity"
    t.check_constraint "btrim(description::text) <> ''::text AND (unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[])) AND quantity > 0::numeric", name: "delivery_schedule_items_valid_merchandise"
    t.check_constraint "quantity < 1000000000::numeric AND \"position\" >= 0", name: "schedule_items_finite_quantity_position"
  end

  create_table "delivery_schedules", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "customer_id", null: false
    t.integer "weekday", null: false
    t.time "preferred_time"
    t.time "window_start"
    t.time "window_end"
    t.date "starts_on", null: false
    t.date "ends_on"
    t.boolean "active", default: true, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "active", "weekday"], name: "index_delivery_schedules_on_company_id_and_active_and_weekday"
    t.index ["company_id", "customer_id", "id"], name: "index_schedules_tenant_customer_id", unique: true
    t.index ["company_id", "id"], name: "index_delivery_schedules_on_company_id_and_id", unique: true
    t.index ["company_id"], name: "index_delivery_schedules_on_company_id"
    t.index ["customer_id"], name: "index_delivery_schedules_on_customer_id"
    t.check_constraint "ends_on IS NULL OR ends_on >= starts_on", name: "schedules_valid_dates"
    t.check_constraint "weekday >= 1 AND weekday <= 7", name: "schedules_valid_weekday"
    t.check_constraint "window_start IS NULL AND window_end IS NULL OR preferred_time IS NULL AND window_start IS NOT NULL AND window_end IS NOT NULL AND window_end > window_start", name: "schedules_valid_times"
  end

  create_table "product_imports", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.jsonb "headers", default: [], null: false
    t.jsonb "rows", default: [], null: false
    t.jsonb "mapping", default: {}, null: false
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_product_imports_on_company_id"
  end

  create_table "products", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "sku"
    t.string "name", null: false
    t.string "unit", null: false
    t.decimal "package_content_quantity", precision: 12, scale: 3
    t.string "package_content_unit"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "active", "name"], name: "index_products_on_company_id_and_active_and_name"
    t.index ["company_id", "id"], name: "index_products_on_company_id_and_id", unique: true
    t.index ["company_id", "sku"], name: "index_products_on_company_id_and_sku", unique: true, where: "(sku IS NOT NULL)"
    t.index ["company_id"], name: "index_products_on_company_id"
    t.check_constraint "btrim(name::text) <> ''::text", name: "products_nonblank_name"
    t.check_constraint "package_content_quantity IS NULL AND package_content_unit IS NULL OR package_content_quantity IS NOT NULL AND package_content_quantity > 0::numeric AND package_content_quantity < 1000000000::numeric AND package_content_unit IS NOT NULL AND (package_content_unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[]))", name: "products_valid_package"
    t.check_constraint "package_content_unit IS NULL OR (package_content_unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR package_content_quantity = trunc(package_content_quantity)", name: "products_integer_package"
    t.check_constraint "sku IS NULL OR btrim(sku::text) <> ''::text", name: "products_nonblank_sku"
    t.check_constraint "unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[])", name: "products_valid_unit"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "role", default: "administrator", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "phone"
    t.string "status", default: "active", null: false
    t.index ["company_id", "id"], name: "index_users_on_company_id_and_id", unique: true
    t.index ["company_id", "role", "status"], name: "index_users_on_company_id_and_role_and_status"
    t.index ["company_id"], name: "index_users_on_company_id"
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.check_constraint "role::text = ANY (ARRAY['administrator'::character varying, 'supervisor'::character varying, 'driver'::character varying]::text[])", name: "users_valid_role"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'inactive'::character varying]::text[])", name: "users_valid_status"
  end

  create_table "visits", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "delivery_run_id", null: false
    t.bigint "customer_id", null: false
    t.bigint "delivery_schedule_id"
    t.integer "position", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.string "customer_name", null: false
    t.string "customer_address", null: false
    t.text "notes"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "customer_id", "id"], name: "visits_tenant_customer_id", unique: true
    t.index ["company_id", "id"], name: "index_visits_on_company_id_and_id", unique: true
    t.index ["company_id"], name: "index_visits_on_company_id"
    t.index ["customer_id"], name: "index_visits_on_customer_id"
    t.index ["delivery_run_id", "delivery_schedule_id"], name: "index_visits_on_delivery_run_id_and_delivery_schedule_id", unique: true, where: "(delivery_schedule_id IS NOT NULL)"
    t.index ["delivery_run_id", "position"], name: "index_visits_on_delivery_run_id_and_position"
    t.index ["delivery_run_id"], name: "index_visits_on_delivery_run_id"
    t.index ["delivery_schedule_id"], name: "index_visits_on_delivery_schedule_id"
    t.check_constraint "\"position\" >= 0", name: "visits_nonnegative_position"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'completed'::character varying, 'not_attended'::character varying, 'closed'::character varying, 'rescheduled'::character varying]::text[])", name: "visits_valid_status"
  end

  add_foreign_key "customers", "companies"
  add_foreign_key "delivery_items", "companies"
  add_foreign_key "delivery_items", "delivery_order_items", column: ["company_id", "delivery_order_item_id"], primary_key: ["company_id", "id"], name: "fk_delivery_items_delivery_order_item_id_tenant"
  add_foreign_key "delivery_items", "products"
  add_foreign_key "delivery_items", "products", column: ["company_id", "product_id"], primary_key: ["company_id", "id"], name: "fk_delivery_items_product_id_tenant"
  add_foreign_key "delivery_items", "visits"
  add_foreign_key "delivery_items", "visits", column: ["company_id", "visit_id"], primary_key: ["company_id", "id"], name: "fk_delivery_items_visit_id_tenant"
  add_foreign_key "delivery_order_items", "companies"
  add_foreign_key "delivery_order_items", "delivery_orders", column: ["company_id", "delivery_order_id"], primary_key: ["company_id", "id"], name: "fk_delivery_order_items_delivery_order_id_tenant"
  add_foreign_key "delivery_order_items", "products", column: ["company_id", "product_id"], primary_key: ["company_id", "id"], name: "fk_delivery_order_items_product_id_tenant"
  add_foreign_key "delivery_orders", "companies"
  add_foreign_key "delivery_orders", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "fk_delivery_orders_customer_id_tenant"
  add_foreign_key "delivery_orders", "delivery_schedules", column: ["company_id", "customer_id", "delivery_schedule_id"], primary_key: ["company_id", "customer_id", "id"], name: "orders_schedule_customer_tenant"
  add_foreign_key "delivery_orders", "visits", column: ["company_id", "customer_id", "visit_id"], primary_key: ["company_id", "customer_id", "id"], name: "orders_visit_customer_tenant"
  add_foreign_key "delivery_runs", "companies"
  add_foreign_key "delivery_runs", "users", column: "driver_id"
  add_foreign_key "delivery_runs", "users", column: ["company_id", "driver_id"], primary_key: ["company_id", "id"], name: "fk_delivery_runs_driver_id_tenant"
  add_foreign_key "delivery_schedule_items", "companies"
  add_foreign_key "delivery_schedule_items", "delivery_schedules"
  add_foreign_key "delivery_schedule_items", "delivery_schedules", column: ["company_id", "delivery_schedule_id"], primary_key: ["company_id", "id"], name: "fk_delivery_schedule_items_delivery_schedule_id_tenant"
  add_foreign_key "delivery_schedule_items", "products"
  add_foreign_key "delivery_schedule_items", "products", column: ["company_id", "product_id"], primary_key: ["company_id", "id"], name: "fk_delivery_schedule_items_product_id_tenant"
  add_foreign_key "delivery_schedules", "companies"
  add_foreign_key "delivery_schedules", "customers"
  add_foreign_key "delivery_schedules", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "fk_delivery_schedules_customer_id_tenant"
  add_foreign_key "product_imports", "companies"
  add_foreign_key "products", "companies"
  add_foreign_key "sessions", "users"
  add_foreign_key "users", "companies"
  add_foreign_key "visits", "companies"
  add_foreign_key "visits", "customers"
  add_foreign_key "visits", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "fk_visits_customer_id_tenant"
  add_foreign_key "visits", "delivery_runs"
  add_foreign_key "visits", "delivery_runs", column: ["company_id", "delivery_run_id"], primary_key: ["company_id", "id"], name: "fk_visits_delivery_run_id_tenant"
  add_foreign_key "visits", "delivery_schedules"
  add_foreign_key "visits", "delivery_schedules", column: ["company_id", "customer_id", "delivery_schedule_id"], primary_key: ["company_id", "customer_id", "id"], name: "fk_visits_schedule_customer_tenant"
end
