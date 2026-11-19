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

ActiveRecord::Schema[8.1].define(version: 2026_11_19_050000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "commercial_opportunities", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "customer_id"
    t.bigint "product_id"
    t.bigint "delivery_order_id"
    t.string "rule", null: false
    t.string "stable_key", null: false
    t.string "title", null: false
    t.jsonb "evidence", default: {}, null: false
    t.string "fingerprint", null: false
    t.string "acknowledged_fingerprint"
    t.string "status", default: "open", null: false
    t.integer "generation", default: 1, null: false
    t.datetime "detected_at", null: false
    t.datetime "last_evaluated_at", null: false
    t.datetime "state_changed_at", null: false
    t.datetime "snoozed_until"
    t.text "resolution"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "id"], name: "index_commercial_opportunities_on_company_id_and_id", unique: true
    t.index ["company_id", "stable_key"], name: "opportunities_stable_key", unique: true
    t.index ["company_id", "status", "detected_at"], name: "opportunities_inbox"
    t.index ["company_id"], name: "index_commercial_opportunities_on_company_id"
    t.index ["customer_id"], name: "index_commercial_opportunities_on_customer_id"
    t.index ["delivery_order_id"], name: "index_commercial_opportunities_on_delivery_order_id"
    t.index ["product_id"], name: "index_commercial_opportunities_on_product_id"
    t.check_constraint "(status::text = ANY (ARRAY['open'::character varying, 'managed'::character varying, 'snoozed'::character varying, 'dismissed'::character varying, 'cleared'::character varying]::text[])) AND (rule::text = ANY (ARRAY['inactive'::character varying, 'decline'::character varying, 'shortage'::character varying, 'repeated_failure'::character varying, 'unfollowed_partial'::character varying]::text[])) AND generation > 0", name: "opportunities_codes"
    t.check_constraint "status::text <> 'snoozed'::text OR snoozed_until IS NOT NULL", name: "opportunities_snoozed_until"
  end

  create_table "commercial_rule_settings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.integer "inactivity_min_days", default: 14, null: false
    t.decimal "inactivity_multiplier", precision: 4, scale: 1, default: "2.5", null: false
    t.integer "comparison_days", default: 30, null: false
    t.integer "decline_min_orders", default: 3, null: false
    t.integer "decline_percent", default: 40, null: false
    t.integer "shortage_min_orders", default: 3, null: false
    t.integer "failure_min_orders", default: 3, null: false
    t.integer "partial_grace_days", default: 2, null: false
    t.integer "cooldown_days", default: 30, null: false
    t.string "automatic_rules", default: [], null: false, array: true
    t.bigint "auto_assignee_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["auto_assignee_id"], name: "index_commercial_rule_settings_on_auto_assignee_id"
    t.index ["company_id"], name: "index_commercial_rule_settings_on_company_id", unique: true
    t.check_constraint "automatic_rules <@ ARRAY['inactive'::character varying, 'decline'::character varying, 'shortage'::character varying, 'repeated_failure'::character varying, 'unfollowed_partial'::character varying] AND (cardinality(automatic_rules) = 0 OR auto_assignee_id IS NOT NULL)", name: "commercial_automatic_rules"
    t.check_constraint "inactivity_min_days >= 1 AND inactivity_min_days <= 365 AND comparison_days >= 1 AND comparison_days <= 365 AND partial_grace_days >= 1 AND partial_grace_days <= 365 AND cooldown_days >= 1 AND cooldown_days <= 365 AND inactivity_multiplier >= 1::numeric AND inactivity_multiplier <= 10::numeric AND decline_percent >= 1 AND decline_percent <= 100 AND decline_min_orders >= 1 AND decline_min_orders <= 1000 AND shortage_min_orders >= 1 AND shortage_min_orders <= 1000 AND failure_min_orders >= 1 AND failure_min_orders <= 1000", name: "commercial_rule_thresholds"
  end

  create_table "communication_consents", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "customer_id", null: false
    t.bigint "user_id", null: false
    t.string "channel", null: false
    t.string "purpose", null: false
    t.string "decision", null: false
    t.string "evidence", null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.string "recipient", default: "", null: false
    t.index ["company_id", "customer_id", "channel", "purpose", "id"], name: "consent_latest_decision"
    t.index ["company_id"], name: "index_communication_consents_on_company_id"
    t.index ["customer_id"], name: "index_communication_consents_on_customer_id"
    t.index ["user_id"], name: "index_communication_consents_on_user_id"
    t.check_constraint "(channel::text = ANY (ARRAY['email'::character varying, 'sms'::character varying, 'whatsapp'::character varying]::text[])) AND (purpose::text = ANY (ARRAY['operational'::character varying, 'marketing'::character varying]::text[])) AND (decision::text = ANY (ARRAY['granted'::character varying, 'revoked'::character varying]::text[]))", name: "consents_codes"
  end

  create_table "companies", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "time_zone", default: "America/Argentina/Buenos_Aires", null: false
    t.string "currency", default: "ARS", null: false
    t.datetime "opportunities_changed_at"
    t.datetime "opportunities_evaluated_at"
    t.datetime "opportunities_job_enqueued_at"
    t.decimal "depot_latitude", precision: 10, scale: 7
    t.decimal "depot_longitude", precision: 10, scale: 7
    t.string "routing_departure", default: "08:00", null: false
    t.boolean "routing_return_to_depot", default: false, null: false
    t.integer "routing_preferred_tolerance", default: 15, null: false
    t.integer "routing_service_minutes", default: 5, null: false
    t.string "province", default: "Buenos Aires", null: false
    t.bigint "primary_administrator_id"
    t.index ["primary_administrator_id"], name: "index_companies_on_primary_administrator_id"
    t.index ["slug"], name: "index_companies_on_slug", unique: true
    t.check_constraint "currency::text = ANY (ARRAY['ARS'::character varying, 'USD'::character varying, 'EUR'::character varying]::text[])", name: "companies_currency"
    t.check_constraint "depot_latitude IS NULL AND depot_longitude IS NULL OR depot_latitude IS NOT NULL AND depot_longitude IS NOT NULL AND depot_latitude >= '-90'::integer::numeric AND depot_latitude <= 90::numeric AND depot_longitude >= '-180'::integer::numeric AND depot_longitude <= 180::numeric", name: "company_depot_coordinates"
    t.check_constraint "length(btrim(province::text)) > 0 AND length(province::text) <= 100", name: "company_province_present"
    t.check_constraint "routing_preferred_tolerance >= 0 AND routing_preferred_tolerance <= 120 AND routing_service_minutes >= 0 AND routing_service_minutes <= 240 AND routing_departure::text ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text AND (NOT routing_return_to_depot OR depot_latitude IS NOT NULL)", name: "company_routing_settings"
  end

  create_table "customer_import_rows", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "customer_import_id", null: false
    t.bigint "customer_id"
    t.integer "number", null: false
    t.jsonb "original", default: [], null: false
    t.jsonb "data", default: {}, null: false
    t.jsonb "normalized", default: {}, null: false
    t.jsonb "candidates", default: [], null: false
    t.jsonb "issues", default: [], null: false
    t.jsonb "warnings", default: [], null: false
    t.jsonb "duplicates", default: [], null: false
    t.string "address_key"
    t.string "duplicate_key"
    t.string "precision", default: "unlocated", null: false
    t.string "review_state", default: "pending", null: false
    t.string "provider"
    t.decimal "latitude", precision: 10, scale: 7
    t.decimal "longitude", precision: 11, scale: 7
    t.boolean "excluded", default: false, null: false
    t.boolean "manual_confirmation", default: false, null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "customer_import_id, ((data ->> 'external_code'::text))", name: "customer_import_rows_external_code"
    t.index ["company_id"], name: "index_customer_import_rows_on_company_id"
    t.index ["customer_id"], name: "customer_import_rows_created_customer", unique: true, where: "(customer_id IS NOT NULL)"
    t.index ["customer_id"], name: "index_customer_import_rows_on_customer_id"
    t.index ["customer_import_id", "address_key"], name: "customer_import_rows_addresses"
    t.index ["customer_import_id", "duplicate_key"], name: "customer_import_rows_duplicates"
    t.index ["customer_import_id", "number"], name: "index_customer_import_rows_on_customer_import_id_and_number", unique: true
    t.index ["customer_import_id", "precision", "id"], name: "customer_import_rows_precision"
    t.index ["customer_import_id", "processed_at", "id"], name: "customer_import_rows_pending"
    t.index ["customer_import_id"], name: "index_customer_import_rows_on_customer_import_id"
    t.check_constraint "(\"precision\"::text = ANY (ARRAY['reliable'::character varying, 'approximate'::character varying, 'ambiguous'::character varying, 'unlocated'::character varying]::text[])) AND (review_state::text = ANY (ARRAY['pending'::character varying, 'automatic'::character varying, 'manual'::character varying, 'unlocated'::character varying]::text[]))", name: "customer_import_row_states"
    t.check_constraint "NOT manual_confirmation OR review_state::text = 'manual'::text AND latitude IS NOT NULL AND longitude IS NOT NULL", name: "customer_import_row_manual"
    t.check_constraint "latitude IS NULL AND longitude IS NULL OR latitude IS NOT NULL AND longitude IS NOT NULL AND latitude >= '-90'::integer::numeric AND latitude <= 90::numeric AND longitude >= '-180'::integer::numeric AND longitude <= 180::numeric", name: "customer_import_row_coordinates"
    t.check_constraint "review_state::text <> 'automatic'::text OR \"precision\"::text = 'reliable'::text AND latitude IS NOT NULL AND longitude IS NOT NULL", name: "customer_import_row_automatic"
  end

  create_table "customer_imports", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.jsonb "headers", default: [], null: false
    t.jsonb "rows", default: [], null: false
    t.jsonb "mapping", default: {}, null: false
    t.jsonb "excluded_rows", default: [], null: false
    t.boolean "overwrite_blanks", default: false, null: false
    t.jsonb "summary", default: {}, null: false
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "initiated_by_id"
    t.string "state", default: "legacy", null: false
    t.integer "generation", default: 0, null: false
    t.jsonb "sheet_names", default: [], null: false
    t.integer "sheet_index", default: 0, null: false
    t.integer "header_row", default: 1, null: false
    t.jsonb "geographic_context", default: {}, null: false
    t.integer "total_rows", default: 0, null: false
    t.integer "processed_rows", default: 0, null: false
    t.text "last_error"
    t.datetime "heartbeat_at"
    t.index ["company_id", "id"], name: "index_customer_imports_on_company_id_and_id", unique: true
    t.index ["company_id"], name: "index_customer_imports_on_company_id"
    t.index ["initiated_by_id"], name: "index_customer_imports_on_initiated_by_id"
    t.index ["state", "heartbeat_at"], name: "index_customer_imports_on_state_and_heartbeat_at"
    t.check_constraint "state::text = ANY (ARRAY['legacy'::character varying, 'reading'::character varying, 'mapping'::character varying, 'preparing'::character varying, 'processing'::character varying, 'review'::character varying, 'importing'::character varying, 'completed'::character varying, 'cancelled'::character varying, 'failed'::character varying]::text[])", name: "customer_import_state"
    t.check_constraint "total_rows >= 0 AND processed_rows >= 0 AND processed_rows <= total_rows AND generation >= 0", name: "customer_import_progress"
  end

  create_table "customer_notifications", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "customer_id", null: false
    t.bigint "delivery_order_id"
    t.bigint "user_id"
    t.uuid "operation_id", null: false
    t.string "channel", null: false
    t.string "purpose", null: false
    t.string "template_key", null: false
    t.string "recipient", null: false
    t.datetime "created_at", null: false
    t.index ["company_id", "id"], name: "index_customer_notifications_on_company_id_and_id", unique: true
    t.index ["company_id", "operation_id"], name: "index_customer_notifications_on_company_id_and_operation_id", unique: true
    t.index ["company_id"], name: "index_customer_notifications_on_company_id"
    t.index ["customer_id"], name: "index_customer_notifications_on_customer_id"
    t.check_constraint "(channel::text = ANY (ARRAY['email'::character varying, 'sms'::character varying, 'whatsapp'::character varying]::text[])) AND (purpose::text = ANY (ARRAY['operational'::character varying, 'marketing'::character varying]::text[]))", name: "notifications_codes"
  end

  create_table "customers", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", limit: 90, null: false
    t.string "contact"
    t.string "phone"
    t.string "email"
    t.string "address", null: false
    t.string "city", null: false
    t.string "status", default: "active", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "latitude", precision: 10, scale: 7
    t.decimal "longitude", precision: 10, scale: 7
    t.string "external_code"
    t.string "location_verification", default: "legacy", null: false
    t.string "geocoding_precision"
    t.datetime "geocoding_checked_at"
    t.string "import_identity_key"
    t.index ["company_id", "external_code"], name: "index_customers_on_company_id_and_external_code", unique: true, where: "(external_code IS NOT NULL)"
    t.index ["company_id", "id"], name: "index_customers_on_company_id_and_id", unique: true
    t.index ["company_id", "import_identity_key"], name: "index_customers_on_company_id_and_import_identity_key"
    t.index ["company_id", "name", "id"], name: "index_customers_on_company_id_and_name_and_id"
    t.index ["company_id", "status"], name: "index_customers_on_company_id_and_status"
    t.index ["company_id"], name: "index_customers_on_company_id"
    t.check_constraint "external_code IS NULL OR length(btrim(external_code::text)) > 0 AND length(external_code::text) <= 255", name: "customers_external_code_present"
    t.check_constraint "latitude IS NULL AND longitude IS NULL OR latitude IS NOT NULL AND longitude IS NOT NULL AND latitude >= '-90'::integer::numeric AND latitude <= 90::numeric AND longitude >= '-180'::integer::numeric AND longitude <= 180::numeric", name: "customers_valid_coordinates"
    t.check_constraint "location_verification::text = ANY (ARRAY['legacy'::character varying, 'pending'::character varying, 'provided'::character varying, 'reliable'::character varying, 'manual'::character varying]::text[])", name: "customers_location_verification"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'inactive'::character varying]::text[])", name: "customers_valid_status"
  end

  create_table "delivery_dispatch_changes", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.bigint "delivery_order_id", null: false
    t.jsonb "before_data", null: false
    t.jsonb "after_data", null: false
    t.string "reason", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_delivery_dispatch_changes_on_company_id"
    t.index ["delivery_order_id"], name: "index_delivery_dispatch_changes_on_delivery_order_id"
    t.index ["user_id"], name: "index_delivery_dispatch_changes_on_user_id"
  end

  create_table "delivery_evidences", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.bigint "driver_sync_operation_id"
    t.bigint "visit_id", null: false
    t.uuid "operation_id", null: false
    t.uuid "evidence_uuid", null: false
    t.string "kind", null: false
    t.string "sha256", null: false
    t.datetime "purged_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "user_id", "evidence_uuid"], name: "evidence_unique_uuid", unique: true
    t.index ["company_id", "user_id", "operation_id"], name: "evidence_one_signature", unique: true, where: "((kind)::text = 'signature'::text)"
    t.index ["company_id", "user_id", "operation_id"], name: "evidence_operation"
    t.index ["company_id"], name: "index_delivery_evidences_on_company_id"
    t.index ["driver_sync_operation_id"], name: "index_delivery_evidences_on_driver_sync_operation_id"
    t.index ["user_id"], name: "index_delivery_evidences_on_user_id"
    t.check_constraint "kind::text = ANY (ARRAY['photo'::character varying, 'signature'::character varying]::text[])", name: "evidence_valid_kind"
    t.check_constraint "sha256::text ~ '^[0-9a-f]{64}$'::text", name: "evidence_valid_digest"
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
    t.decimal "unit_price", precision: 16, scale: 4
    t.decimal "unit_cost", precision: 16, scale: 4
    t.string "currency"
    t.datetime "commercial_captured_at"
    t.string "commercial_source"
    t.index ["company_id", "id"], name: "index_delivery_items_on_company_id_and_id", unique: true
    t.index ["company_id"], name: "index_delivery_items_on_company_id"
    t.index ["delivery_order_item_id"], name: "index_delivery_items_on_delivery_order_item_id", unique: true
    t.index ["product_id"], name: "index_delivery_items_on_product_id"
    t.index ["visit_id"], name: "index_delivery_items_on_visit_id"
    t.check_constraint "(unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR planned_quantity = trunc(planned_quantity)", name: "delivery_items_integer_quantity"
    t.check_constraint "btrim(description::text) <> ''::text AND (unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[])) AND planned_quantity > 0::numeric", name: "delivery_items_valid_merchandise"
    t.check_constraint "currency IS NULL OR (currency::text = ANY (ARRAY['ARS'::character varying, 'USD'::character varying, 'EUR'::character varying]::text[]))", name: "delivery_items_currency"
    t.check_constraint "delivered_quantity IS NULL OR (unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR delivered_quantity = trunc(delivered_quantity)", name: "items_integer_delivered"
    t.check_constraint "delivered_quantity IS NULL OR delivered_quantity >= 0::numeric", name: "items_nonnegative_delivered"
    t.check_constraint "planned_quantity < 1000000000::numeric AND (delivered_quantity IS NULL OR delivered_quantity < 1000000000::numeric)", name: "items_finite_quantities"
    t.check_constraint "unit_cost IS NULL OR unit_cost >= 0::numeric AND unit_cost < '1000000000000'::bigint::numeric", name: "delivery_items_unit_cost_range"
    t.check_constraint "unit_price IS NULL AND unit_cost IS NULL OR commercial_source IS NOT NULL", name: "delivery_items_known_value_source"
    t.check_constraint "unit_price IS NULL AND unit_cost IS NULL OR currency IS NOT NULL AND commercial_captured_at IS NOT NULL AND (commercial_source::text = ANY (ARRAY['catalog'::character varying, 'manual'::character varying, 'order'::character varying, 'legacy'::character varying]::text[]))", name: "delivery_items_commercial_snapshot"
    t.check_constraint "unit_price IS NULL OR unit_price >= 0::numeric AND unit_price < '1000000000000'::bigint::numeric", name: "delivery_items_unit_price_range"
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
    t.decimal "unit_price", precision: 16, scale: 4
    t.decimal "unit_cost", precision: 16, scale: 4
    t.string "currency"
    t.datetime "commercial_captured_at"
    t.string "commercial_source"
    t.index ["company_id", "id"], name: "index_delivery_order_items_on_company_id_and_id", unique: true
    t.index ["company_id", "product_id", "delivery_order_id"], name: "order_items_reporting_product"
    t.index ["company_id"], name: "index_delivery_order_items_on_company_id"
    t.index ["delivery_order_id"], name: "index_delivery_order_items_on_delivery_order_id"
    t.index ["product_id"], name: "index_delivery_order_items_on_product_id"
    t.check_constraint "(unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR quantity = trunc(quantity)", name: "order_items_integer_quantity"
    t.check_constraint "\"position\" >= 0", name: "order_items_valid_position"
    t.check_constraint "btrim(description::text) <> ''::text AND (unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[])) AND quantity > 0::numeric AND quantity < 1000000000::numeric", name: "order_items_valid_merchandise"
    t.check_constraint "currency IS NULL OR (currency::text = ANY (ARRAY['ARS'::character varying, 'USD'::character varying, 'EUR'::character varying]::text[]))", name: "delivery_order_items_currency"
    t.check_constraint "unit_cost IS NULL OR unit_cost >= 0::numeric AND unit_cost < '1000000000000'::bigint::numeric", name: "delivery_order_items_unit_cost_range"
    t.check_constraint "unit_price IS NULL AND unit_cost IS NULL OR commercial_source IS NOT NULL", name: "delivery_order_items_known_value_source"
    t.check_constraint "unit_price IS NULL AND unit_cost IS NULL OR currency IS NOT NULL AND commercial_captured_at IS NOT NULL AND (commercial_source::text = ANY (ARRAY['catalog'::character varying, 'manual'::character varying, 'order'::character varying, 'legacy'::character varying]::text[]))", name: "delivery_order_items_commercial_snapshot"
    t.check_constraint "unit_price IS NULL OR unit_price >= 0::numeric AND unit_price < '1000000000000'::bigint::numeric", name: "delivery_order_items_unit_price_range"
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
    t.bigint "rescheduled_from_id"
    t.integer "load_units", default: 1, null: false
    t.integer "service_minutes", default: 10, null: false
    t.bigint "driver_profile_id"
    t.string "import_key"
    t.index ["company_id", "customer_id", "id"], name: "orders_tenant_customer_id", unique: true
    t.index ["company_id", "delivery_schedule_id", "scheduled_date"], name: "orders_unique_schedule_date", unique: true, where: "(delivery_schedule_id IS NOT NULL)"
    t.index ["company_id", "id"], name: "index_delivery_orders_on_company_id_and_id", unique: true
    t.index ["company_id", "import_key"], name: "index_delivery_orders_on_company_id_and_import_key", unique: true, where: "(import_key IS NOT NULL)"
    t.index ["company_id", "scheduled_date", "customer_id"], name: "orders_reporting_date"
    t.index ["company_id", "scheduled_date", "status"], name: "idx_on_company_id_scheduled_date_status_b6fe95a943"
    t.index ["company_id"], name: "index_delivery_orders_on_company_id"
    t.index ["customer_id"], name: "index_delivery_orders_on_customer_id"
    t.index ["delivery_schedule_id"], name: "index_delivery_orders_on_delivery_schedule_id"
    t.index ["driver_profile_id"], name: "index_delivery_orders_on_driver_profile_id"
    t.index ["rescheduled_from_id"], name: "index_delivery_orders_on_rescheduled_from_id", unique: true
    t.index ["visit_id"], name: "index_delivery_orders_on_visit_id"
    t.check_constraint "btrim(customer_name::text) <> ''::text AND btrim(customer_address::text) <> ''::text", name: "orders_customer_snapshot"
    t.check_constraint "load_units >= 1 AND load_units <= 1000000", name: "orders_load_units"
    t.check_constraint "rescheduled_from_id IS NULL OR rescheduled_from_id <> id", name: "orders_no_self_reschedule"
    t.check_constraint "service_minutes >= 0 AND service_minutes <= 1440", name: "orders_service_minutes"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'completed'::character varying, 'needs_attention'::character varying, 'cancelled'::character varying]::text[])", name: "orders_valid_status"
    t.check_constraint "window_start IS NULL AND window_end IS NULL OR preferred_time IS NULL AND window_start IS NOT NULL AND window_end IS NOT NULL AND window_end > window_start", name: "orders_valid_times"
  end

  create_table "delivery_run_costs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "delivery_run_id", null: false
    t.bigint "user_id", null: false
    t.uuid "operation_id", null: false
    t.string "category", null: false
    t.string "description", null: false
    t.string "vehicle_label"
    t.string "currency", null: false
    t.decimal "amount", precision: 16, scale: 4, null: false
    t.boolean "estimated", default: false, null: false
    t.datetime "incurred_at", null: false
    t.bigint "reversal_of_id"
    t.datetime "created_at", null: false
    t.index ["company_id", "id"], name: "index_delivery_run_costs_on_company_id_and_id", unique: true
    t.index ["company_id", "operation_id"], name: "index_delivery_run_costs_on_company_id_and_operation_id", unique: true
    t.index ["company_id"], name: "index_delivery_run_costs_on_company_id"
    t.index ["delivery_run_id"], name: "index_delivery_run_costs_on_delivery_run_id"
    t.index ["reversal_of_id"], name: "index_delivery_run_costs_on_reversal_of_id", unique: true
    t.index ["user_id"], name: "index_delivery_run_costs_on_user_id"
    t.check_constraint "(category::text = ANY (ARRAY['vehicle'::character varying, 'fuel'::character varying, 'toll'::character varying, 'driver'::character varying, 'other'::character varying]::text[])) AND (currency::text = ANY (ARRAY['ARS'::character varying, 'USD'::character varying, 'EUR'::character varying]::text[]))", name: "run_costs_codes"
    t.check_constraint "amount > '-1000000000000'::bigint::numeric AND amount < '1000000000000'::bigint::numeric AND (reversal_of_id IS NULL AND amount >= 0::numeric OR reversal_of_id IS NOT NULL AND amount <= 0::numeric)", name: "run_costs_amount"
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
    t.integer "assignment_version", default: 0, null: false
    t.string "optimization_key"
    t.jsonb "optimization_data", default: {}, null: false
    t.string "currency"
    t.string "vehicle_label"
    t.datetime "costs_closed_at"
    t.bigint "costs_closed_by_id"
    t.string "routing_origin", default: "company", null: false
    t.boolean "routing_return_to_depot"
    t.index ["company_id", "generation_key"], name: "index_delivery_runs_on_company_id_and_generation_key", unique: true, where: "(generation_key IS NOT NULL)"
    t.index ["company_id", "id"], name: "index_delivery_runs_on_company_id_and_id", unique: true
    t.index ["company_id", "optimization_key", "driver_id"], name: "runs_unique_optimization_vehicle", unique: true, where: "(optimization_key IS NOT NULL)"
    t.index ["company_id", "scheduled_date"], name: "index_delivery_runs_on_company_id_and_scheduled_date"
    t.index ["company_id"], name: "index_delivery_runs_on_company_id"
    t.index ["costs_closed_by_id"], name: "index_delivery_runs_on_costs_closed_by_id"
    t.index ["driver_id"], name: "index_delivery_runs_on_driver_id"
    t.check_constraint "assignment_version >= 0", name: "runs_assignment_version"
    t.check_constraint "costs_closed_at IS NULL AND costs_closed_by_id IS NULL OR costs_closed_at IS NOT NULL AND costs_closed_by_id IS NOT NULL", name: "runs_cost_closure"
    t.check_constraint "currency IS NULL OR (currency::text = ANY (ARRAY['ARS'::character varying, 'USD'::character varying, 'EUR'::character varying]::text[]))", name: "runs_currency"
    t.check_constraint "routing_origin::text = ANY (ARRAY['company'::character varying, 'open'::character varying]::text[])", name: "run_routing_origin"
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
    t.bigint "driver_profile_id"
    t.string "operation_kind", default: "pedido_semanal", null: false
    t.integer "visit_order"
    t.string "import_key"
    t.index ["company_id", "active", "weekday"], name: "index_delivery_schedules_on_company_id_and_active_and_weekday"
    t.index ["company_id", "customer_id", "id"], name: "index_schedules_tenant_customer_id", unique: true
    t.index ["company_id", "id"], name: "index_delivery_schedules_on_company_id_and_id", unique: true
    t.index ["company_id", "import_key"], name: "index_delivery_schedules_on_company_id_and_import_key", unique: true, where: "(import_key IS NOT NULL)"
    t.index ["company_id"], name: "index_delivery_schedules_on_company_id"
    t.index ["customer_id"], name: "index_delivery_schedules_on_customer_id"
    t.index ["driver_profile_id"], name: "index_delivery_schedules_on_driver_profile_id"
    t.check_constraint "ends_on IS NULL OR ends_on >= starts_on", name: "schedules_valid_dates"
    t.check_constraint "operation_kind::text = ANY (ARRAY['visita_semanal'::character varying, 'pedido_semanal'::character varying]::text[])", name: "schedule_operation_kind"
    t.check_constraint "visit_order IS NULL OR visit_order > 0", name: "schedule_visit_order"
    t.check_constraint "weekday >= 1 AND weekday <= 7", name: "schedules_valid_weekday"
    t.check_constraint "window_start IS NULL AND window_end IS NULL OR preferred_time IS NULL AND window_start IS NOT NULL AND window_end IS NOT NULL AND window_end > window_start", name: "schedules_valid_times"
  end

  create_table "delivery_status_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "delivery_run_id"
    t.bigint "visit_id"
    t.bigint "delivery_order_id"
    t.bigint "user_id"
    t.string "from_status"
    t.string "to_status", null: false
    t.string "source", null: false
    t.uuid "operation_id"
    t.datetime "occurred_at"
    t.datetime "client_occurred_at"
    t.datetime "created_at", null: false
    t.jsonb "context", default: {}, null: false
    t.index ["company_id", "delivery_order_id", "id"], name: "status_events_delivery_order_id"
    t.index ["company_id", "delivery_run_id", "id"], name: "status_events_delivery_run_id"
    t.index ["company_id", "visit_id", "id"], name: "status_events_visit_id"
    t.index ["company_id"], name: "index_delivery_status_events_on_company_id"
    t.check_constraint "num_nonnulls(delivery_run_id, visit_id, delivery_order_id) = 1", name: "status_events_one_subject"
    t.check_constraint "source::text = 'baseline'::text AND occurred_at IS NULL OR (source::text = ANY (ARRAY['system'::character varying, 'manager'::character varying, 'driver'::character varying, 'offline'::character varying]::text[])) AND occurred_at IS NOT NULL", name: "status_events_source"
  end

  create_table "driver_locations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.decimal "latitude", precision: 10, scale: 7, null: false
    t.decimal "longitude", precision: 10, scale: 7, null: false
    t.decimal "accuracy", precision: 10, scale: 2, null: false
    t.datetime "captured_at", null: false
    t.boolean "sharing", default: true, null: false
    t.jsonb "eta_data", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_driver_locations_on_company_id"
    t.index ["user_id"], name: "index_driver_locations_on_user_id", unique: true
    t.check_constraint "latitude >= '-90'::integer::numeric AND latitude <= 90::numeric AND longitude >= '-180'::integer::numeric AND longitude <= 180::numeric AND accuracy >= 0::numeric AND accuracy < 100000000::numeric", name: "driver_location_coordinates"
  end

  create_table "driver_profiles", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id"
    t.string "name", null: false
    t.string "name_key", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "id"], name: "index_driver_profiles_on_company_id_and_id", unique: true
    t.index ["company_id", "name_key"], name: "index_driver_profiles_on_company_id_and_name_key"
    t.index ["company_id", "user_id"], name: "index_driver_profiles_on_company_id_and_user_id", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["company_id"], name: "index_driver_profiles_on_company_id"
    t.index ["user_id"], name: "index_driver_profiles_on_user_id"
  end

  create_table "driver_sync_operations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.bigint "visit_id", null: false
    t.uuid "operation_id", null: false
    t.jsonb "payload", null: false
    t.string "payload_digest", null: false
    t.string "status", null: false
    t.jsonb "result", default: {}, null: false
    t.datetime "recorded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "id"], name: "index_driver_sync_operations_on_company_id_and_id", unique: true
    t.index ["company_id", "status", "created_at"], name: "driver_sync_review_queue"
    t.index ["company_id", "user_id", "operation_id"], name: "driver_sync_unique_operation", unique: true
    t.index ["company_id"], name: "index_driver_sync_operations_on_company_id"
    t.index ["user_id"], name: "index_driver_sync_operations_on_user_id"
    t.check_constraint "status::text = ANY (ARRAY['synced'::character varying, 'conflict'::character varying, 'invalid'::character varying]::text[])", name: "driver_sync_valid_status"
  end

  create_table "geocoding_cache_entries", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "key", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "key"], name: "index_geocoding_cache_entries_on_company_id_and_key", unique: true
    t.index ["company_id"], name: "index_geocoding_cache_entries_on_company_id"
    t.index ["expires_at"], name: "index_geocoding_cache_entries_on_expires_at"
  end

  create_table "geocoding_provider_states", force: :cascade do |t|
    t.string "provider", null: false
    t.datetime "available_at"
    t.date "quota_date"
    t.integer "requests", default: 0, null: false
    t.integer "error_count", default: 0, null: false
    t.bigint "tokens", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider"], name: "index_geocoding_provider_states_on_provider", unique: true
  end

  create_table "incident_photos", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "incident_id", null: false
    t.bigint "user_id", null: false
    t.uuid "file_uuid", null: false
    t.string "sha256", null: false
    t.datetime "purged_at"
    t.datetime "created_at", null: false
    t.index ["company_id", "file_uuid"], name: "index_incident_photos_on_company_id_and_file_uuid", unique: true
    t.index ["company_id"], name: "index_incident_photos_on_company_id"
    t.index ["incident_id"], name: "index_incident_photos_on_incident_id"
    t.index ["user_id"], name: "index_incident_photos_on_user_id"
  end

  create_table "incidents", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "reporter_id"
    t.bigint "driver_id"
    t.bigint "assigned_to_id"
    t.bigint "delivery_run_id"
    t.bigint "visit_id"
    t.bigint "customer_id"
    t.string "source_key", null: false
    t.string "source", default: "manual", null: false
    t.string "kind", null: false
    t.string "priority", default: "normal", null: false
    t.string "status", default: "needs_decision", null: false
    t.text "description", null: false
    t.datetime "occurred_at"
    t.datetime "due_at"
    t.datetime "resolved_at"
    t.text "resolution"
    t.jsonb "context", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "company_id, COALESCE(occurred_at, created_at)", name: "incidents_reporting_time"
    t.index ["assigned_to_id"], name: "index_incidents_on_assigned_to_id"
    t.index ["company_id", "assigned_to_id", "due_at"], name: "index_incidents_on_company_id_and_assigned_to_id_and_due_at"
    t.index ["company_id", "driver_id", "occurred_at"], name: "index_incidents_on_company_id_and_driver_id_and_occurred_at"
    t.index ["company_id", "id"], name: "index_incidents_on_company_id_and_id", unique: true
    t.index ["company_id", "source_key"], name: "index_incidents_on_company_id_and_source_key", unique: true
    t.index ["company_id", "status", "created_at"], name: "index_incidents_on_company_id_and_status_and_created_at"
    t.index ["company_id"], name: "index_incidents_on_company_id"
    t.index ["customer_id"], name: "index_incidents_on_customer_id"
    t.index ["delivery_run_id"], name: "index_incidents_on_delivery_run_id"
    t.index ["driver_id"], name: "index_incidents_on_driver_id"
    t.index ["reporter_id"], name: "index_incidents_on_reporter_id"
    t.index ["visit_id"], name: "index_incidents_on_visit_id"
    t.check_constraint "(status::text <> ALL (ARRAY['resolved'::character varying, 'dismissed'::character varying]::text[])) OR resolution IS NOT NULL", name: "incidents_resolution_present"
    t.check_constraint "(status::text = ANY (ARRAY['open'::character varying, 'needs_decision'::character varying, 'follow_up'::character varying, 'resolved'::character varying, 'dismissed'::character varying]::text[])) AND (priority::text = ANY (ARRAY['low'::character varying, 'normal'::character varying, 'high'::character varying, 'urgent'::character varying]::text[])) AND (kind::text = ANY (ARRAY['closed'::character varying, 'absent'::character varying, 'rejected'::character varying, 'shortage'::character varying, 'damaged'::character varying, 'address'::character varying, 'vehicle'::character varying, 'other'::character varying]::text[])) AND (source::text = ANY (ARRAY['manual'::character varying, 'automatic'::character varying]::text[]))", name: "incidents_codes"
    t.check_constraint "(status::text = ANY (ARRAY['resolved'::character varying, 'dismissed'::character varying]::text[])) AND resolved_at IS NOT NULL AND length(btrim(resolution)) > 0 OR (status::text <> ALL (ARRAY['resolved'::character varying, 'dismissed'::character varying]::text[])) AND resolved_at IS NULL", name: "incident_resolution"
  end

  create_table "internal_notices", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.bigint "sender_id"
    t.bigint "incident_id"
    t.bigint "workflow_task_id"
    t.string "source_key", null: false
    t.string "title", null: false
    t.text "body", null: false
    t.datetime "read_at"
    t.datetime "acknowledged_at"
    t.datetime "created_at", null: false
    t.index ["company_id", "user_id", "read_at", "id"], name: "notices_inbox"
    t.index ["company_id", "user_id", "source_key"], name: "notices_deduplication", unique: true
    t.index ["company_id"], name: "index_internal_notices_on_company_id"
    t.index ["incident_id"], name: "index_internal_notices_on_incident_id"
    t.index ["sender_id"], name: "index_internal_notices_on_sender_id"
    t.index ["user_id"], name: "index_internal_notices_on_user_id"
    t.index ["workflow_task_id"], name: "index_internal_notices_on_workflow_task_id"
    t.check_constraint "acknowledged_at IS NULL OR read_at IS NOT NULL AND acknowledged_at >= read_at", name: "notices_acknowledgement"
  end

  create_table "notification_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "customer_notification_id", null: false
    t.string "event_key", null: false
    t.string "status", null: false
    t.string "provider"
    t.string "provider_message_id"
    t.string "error_code"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.index ["company_id", "event_key"], name: "index_notification_events_on_company_id_and_event_key", unique: true
    t.index ["company_id"], name: "index_notification_events_on_company_id"
    t.index ["customer_notification_id"], name: "index_notification_events_on_customer_notification_id"
    t.check_constraint "status::text = ANY (ARRAY['requested'::character varying, 'accepted'::character varying, 'delivered'::character varying, 'failed'::character varying, 'suppressed'::character varying]::text[])", name: "notification_events_status"
  end

  create_table "operation_import_groups", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "operation_import_id", null: false
    t.string "group_key", null: false
    t.string "state", default: "pending", null: false
    t.jsonb "data", default: {}, null: false
    t.jsonb "issues", default: [], null: false
    t.jsonb "decisions", default: {}, null: false
    t.bigint "customer_id"
    t.bigint "driver_profile_id"
    t.integer "row_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "id"], name: "index_operation_import_groups_on_company_id_and_id", unique: true
    t.index ["company_id", "state"], name: "index_operation_import_groups_on_company_id_and_state"
    t.index ["company_id"], name: "index_operation_import_groups_on_company_id"
    t.index ["customer_id"], name: "index_operation_import_groups_on_customer_id"
    t.index ["driver_profile_id"], name: "index_operation_import_groups_on_driver_profile_id"
    t.index ["operation_import_id", "group_key"], name: "operation_groups_unique_key", unique: true
    t.index ["operation_import_id"], name: "index_operation_import_groups_on_operation_import_id"
  end

  create_table "operation_import_rows", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "operation_import_id", null: false
    t.bigint "operation_import_group_id"
    t.integer "number", null: false
    t.jsonb "original", default: {}, null: false
    t.jsonb "data", default: {}, null: false
    t.jsonb "issues", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "operation_import_id, ((data ->> 'customer_key'::text)), ((data ->> 'address_identity_key'::text))", name: "operation_rows_customer_identity"
    t.index "operation_import_id, ((data ->> 'group_key'::text))", name: "operation_rows_pending_group_key", where: "(operation_import_group_id IS NULL)"
    t.index ["company_id"], name: "index_operation_import_rows_on_company_id"
    t.index ["operation_import_group_id", "id"], name: "operation_rows_group"
    t.index ["operation_import_group_id"], name: "index_operation_import_rows_on_operation_import_group_id"
    t.index ["operation_import_id", "number"], name: "operation_rows_source_number", unique: true
    t.index ["operation_import_id"], name: "index_operation_import_rows_on_operation_import_id"
  end

  create_table "operation_imports", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "initiated_by_id"
    t.string "state", default: "reading", null: false
    t.string "sha256", null: false
    t.integer "total_rows", default: 0, null: false
    t.integer "processed_rows", default: 0, null: false
    t.integer "imported_groups", default: 0, null: false
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "id"], name: "index_operation_imports_on_company_id_and_id", unique: true
    t.index ["company_id", "sha256"], name: "index_operation_imports_on_company_id_and_sha256"
    t.index ["company_id", "sha256"], name: "operation_imports_active_file", unique: true, where: "((state)::text <> 'failed'::text)"
    t.index ["company_id"], name: "index_operation_imports_on_company_id"
    t.index ["initiated_by_id"], name: "index_operation_imports_on_initiated_by_id"
  end

  create_table "platform_admins", force: :cascade do |t|
    t.string "name", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_platform_admins_on_email_address", unique: true
  end

  create_table "platform_sessions", force: :cascade do |t|
    t.bigint "platform_admin_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["platform_admin_id"], name: "index_platform_sessions_on_platform_admin_id"
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
    t.decimal "unit_price", precision: 16, scale: 4
    t.decimal "unit_cost", precision: 16, scale: 4
    t.string "name_key"
    t.index ["company_id", "active", "name"], name: "index_products_on_company_id_and_active_and_name"
    t.index ["company_id", "id"], name: "index_products_on_company_id_and_id", unique: true
    t.index ["company_id", "name_key"], name: "index_products_on_company_id_and_name_key"
    t.index ["company_id", "sku"], name: "index_products_on_company_id_and_sku", unique: true, where: "(sku IS NOT NULL)"
    t.index ["company_id"], name: "index_products_on_company_id"
    t.check_constraint "btrim(name::text) <> ''::text", name: "products_nonblank_name"
    t.check_constraint "package_content_quantity IS NULL AND package_content_unit IS NULL OR package_content_quantity IS NOT NULL AND package_content_quantity > 0::numeric AND package_content_quantity < 1000000000::numeric AND package_content_unit IS NOT NULL AND (package_content_unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[]))", name: "products_valid_package"
    t.check_constraint "package_content_unit IS NULL OR (package_content_unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR package_content_quantity = trunc(package_content_quantity)", name: "products_integer_package"
    t.check_constraint "sku IS NULL OR btrim(sku::text) <> ''::text", name: "products_nonblank_sku"
    t.check_constraint "unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[])", name: "products_valid_unit"
    t.check_constraint "unit_cost IS NULL OR unit_cost >= 0::numeric AND unit_cost < '1000000000000'::bigint::numeric", name: "products_unit_cost_range"
    t.check_constraint "unit_price IS NULL OR unit_price >= 0::numeric AND unit_price < '1000000000000'::bigint::numeric", name: "products_unit_price_range"
  end

  create_table "route_optimization_proposals", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "delivery_run_id", null: false
    t.bigint "requested_by_id", null: false
    t.bigint "applied_by_id"
    t.string "status", default: "queued", null: false
    t.string "fingerprint", null: false
    t.string "request_key", null: false
    t.jsonb "settings", default: {}, null: false
    t.jsonb "result", default: {}, null: false
    t.text "error_message"
    t.datetime "expires_at", null: false
    t.datetime "applied_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "auto_publish", default: false, null: false
    t.index ["applied_by_id"], name: "index_route_optimization_proposals_on_applied_by_id"
    t.index ["company_id", "delivery_run_id", "created_at"], name: "route_proposals_history"
    t.index ["company_id", "delivery_run_id", "request_key"], name: "unique_active_route_proposal", unique: true, where: "((status)::text = ANY ((ARRAY['queued'::character varying, 'processing'::character varying, 'ready'::character varying])::text[]))"
    t.index ["company_id"], name: "index_route_optimization_proposals_on_company_id"
    t.index ["delivery_run_id"], name: "index_route_optimization_proposals_on_delivery_run_id"
    t.index ["id", "company_id"], name: "index_route_optimization_proposals_on_id_and_company_id", unique: true
    t.index ["requested_by_id"], name: "index_route_optimization_proposals_on_requested_by_id"
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying, 'processing'::character varying, 'ready'::character varying, 'failed'::character varying, 'applied'::character varying, 'discarded'::character varying, 'expired'::character varying]::text[])", name: "route_proposal_status"
  end

  create_table "route_publications", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "delivery_run_id", null: false
    t.bigint "requested_by_id", null: false
    t.bigint "proposal_id"
    t.string "state", default: "pending", null: false
    t.string "input_key"
    t.jsonb "settings", default: {}, null: false
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "state", "updated_at"], name: "pending_route_publications"
    t.index ["company_id"], name: "index_route_publications_on_company_id"
    t.index ["delivery_run_id"], name: "index_route_publications_on_delivery_run_id", unique: true
    t.index ["proposal_id"], name: "index_route_publications_on_proposal_id"
    t.index ["requested_by_id"], name: "index_route_publications_on_requested_by_id"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying, 'ready'::character varying, 'failed'::character varying, 'manual'::character varying]::text[])", name: "route_publication_state"
  end

  create_table "routing_cache_entries", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "kind", null: false
    t.string "input_digest", null: false
    t.jsonb "data", null: false
    t.datetime "last_used_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "kind", "input_digest"], name: "unique_routing_cache_entry", unique: true
    t.index ["company_id"], name: "index_routing_cache_entries_on_company_id"
    t.index ["last_used_at"], name: "index_routing_cache_entries_on_last_used_at"
    t.check_constraint "kind::text = ANY (ARRAY['matrix'::character varying, 'solution'::character varying, 'geometry'::character varying]::text[])", name: "routing_cache_kind"
  end

  create_table "run_stock_movements", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "delivery_run_id", null: false
    t.bigint "user_id"
    t.bigint "product_id"
    t.bigint "delivery_item_id"
    t.uuid "operation_id", null: false
    t.string "kind", null: false
    t.string "description", null: false
    t.string "unit", null: false
    t.decimal "quantity", precision: 12, scale: 3, null: false
    t.string "reason"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.index ["company_id", "operation_id"], name: "index_run_stock_movements_on_company_id_and_operation_id", unique: true
    t.index ["company_id"], name: "index_run_stock_movements_on_company_id"
    t.index ["delivery_item_id"], name: "index_run_stock_movements_on_delivery_item_id", unique: true, where: "((kind)::text = 'delivery'::text)"
    t.index ["delivery_run_id"], name: "index_run_stock_movements_on_delivery_run_id"
    t.check_constraint "(kind::text = ANY (ARRAY['load'::character varying, 'delivery'::character varying, 'return'::character varying, 'waste'::character varying, 'adjustment_in'::character varying, 'adjustment_out'::character varying]::text[])) AND quantity > 0::numeric AND quantity < 1000000000::numeric", name: "stock_movement_quantity"
    t.check_constraint "(unit::text = ANY (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying, 'kg'::character varying, 'g'::character varying, 'l'::character varying]::text[])) AND ((unit::text <> ALL (ARRAY['unit'::character varying, 'pack'::character varying, 'bag'::character varying, 'box'::character varying]::text[])) OR quantity = trunc(quantity))", name: "stock_movement_unit"
    t.check_constraint "kind::text <> 'delivery'::text OR delivery_item_id IS NOT NULL", name: "stock_movement_delivery_source"
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
    t.boolean "location_sharing_enabled", default: false, null: false
    t.uuid "location_consent_id"
    t.bigint "location_consent_version", default: 0, null: false
    t.datetime "location_activated_at"
    t.datetime "location_deactivated_at"
    t.index ["company_id", "id"], name: "index_users_on_company_id_and_id", unique: true
    t.index ["company_id", "role", "status"], name: "index_users_on_company_id_and_role_and_status"
    t.index ["company_id"], name: "index_users_on_company_id"
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.check_constraint "location_consent_version >= 0 AND (NOT location_sharing_enabled OR location_consent_id IS NOT NULL AND location_activated_at IS NOT NULL)", name: "users_location_consent"
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
    t.bigint "confirmed_by_id"
    t.datetime "confirmed_at"
    t.integer "receipt_version", default: 0, null: false
    t.datetime "recorded_at"
    t.decimal "recorded_latitude", precision: 10, scale: 7
    t.decimal "recorded_longitude", precision: 10, scale: 7
    t.decimal "location_accuracy", precision: 10, scale: 2
    t.datetime "location_captured_at"
    t.string "failure_reason"
    t.string "receiver_name"
    t.datetime "arrived_at"
    t.datetime "unloading_started_at"
    t.datetime "unloading_finished_at"
    t.string "recorded_at_source"
    t.index ["company_id", "confirmed_by_id", "confirmed_at"], name: "visits_confirmation_history"
    t.index ["company_id", "customer_id", "id"], name: "visits_tenant_customer_id", unique: true
    t.index ["company_id", "id"], name: "index_visits_on_company_id_and_id", unique: true
    t.index ["company_id"], name: "index_visits_on_company_id"
    t.index ["customer_id"], name: "index_visits_on_customer_id"
    t.index ["delivery_run_id", "delivery_schedule_id"], name: "index_visits_on_delivery_run_id_and_delivery_schedule_id", unique: true, where: "(delivery_schedule_id IS NOT NULL)"
    t.index ["delivery_run_id", "position"], name: "index_visits_on_delivery_run_id_and_position"
    t.index ["delivery_run_id"], name: "index_visits_on_delivery_run_id"
    t.index ["delivery_schedule_id"], name: "index_visits_on_delivery_schedule_id"
    t.check_constraint "(unloading_started_at IS NULL OR arrived_at IS NOT NULL AND unloading_started_at >= arrived_at) AND (unloading_finished_at IS NULL OR unloading_started_at IS NOT NULL AND unloading_finished_at >= unloading_started_at)", name: "visits_timing_order"
    t.check_constraint "\"position\" >= 0", name: "visits_nonnegative_position"
    t.check_constraint "confirmed_by_id IS NULL AND confirmed_at IS NULL OR confirmed_by_id IS NOT NULL AND confirmed_at IS NOT NULL AND status::text <> 'pending'::text", name: "visits_confirmation_pair"
    t.check_constraint "failure_reason IS NULL OR (failure_reason::text = ANY (ARRAY['shortage'::character varying, 'damaged'::character varying, 'customer_request'::character varying, 'absent'::character varying, 'closed'::character varying, 'rejected'::character varying, 'other'::character varying]::text[]))", name: "visits_failure_reason"
    t.check_constraint "receipt_version = ANY (ARRAY[0, 1])", name: "visits_receipt_version"
    t.check_constraint "recorded_at_source IS NULL OR (recorded_at_source::text = ANY (ARRAY['device'::character varying, 'server'::character varying]::text[])) AND recorded_at IS NOT NULL", name: "visits_recorded_clock_source"
    t.check_constraint "recorded_latitude IS NULL AND recorded_longitude IS NULL AND location_accuracy IS NULL AND location_captured_at IS NULL OR recorded_latitude IS NOT NULL AND recorded_longitude IS NOT NULL AND recorded_latitude >= '-90'::integer::numeric AND recorded_latitude <= 90::numeric AND recorded_longitude >= '-180'::integer::numeric AND recorded_longitude <= 180::numeric AND location_accuracy IS NOT NULL AND location_accuracy >= 0::numeric AND location_captured_at IS NOT NULL", name: "visits_receipt_location"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'completed'::character varying, 'not_attended'::character varying, 'closed'::character varying, 'rescheduled'::character varying, 'rejected'::character varying]::text[])", name: "visits_valid_status"
  end

  create_table "workflow_commands", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.uuid "operation_id", null: false
    t.string "payload_digest", null: false
    t.jsonb "result", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["company_id", "operation_id"], name: "index_workflow_commands_on_company_id_and_operation_id", unique: true
    t.index ["company_id"], name: "index_workflow_commands_on_company_id"
    t.index ["user_id"], name: "index_workflow_commands_on_user_id"
  end

  create_table "workflow_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id"
    t.bigint "incident_id"
    t.bigint "workflow_task_id"
    t.bigint "commercial_opportunity_id"
    t.string "action", null: false
    t.text "message"
    t.jsonb "changeset", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["commercial_opportunity_id"], name: "index_workflow_events_on_commercial_opportunity_id"
    t.index ["company_id", "id"], name: "workflow_events_company_revision"
    t.index ["company_id"], name: "index_workflow_events_on_company_id"
    t.index ["incident_id"], name: "index_workflow_events_on_incident_id"
    t.index ["user_id"], name: "index_workflow_events_on_user_id"
    t.index ["workflow_task_id"], name: "index_workflow_events_on_workflow_task_id"
    t.check_constraint "num_nonnulls(incident_id, workflow_task_id, commercial_opportunity_id) = 1", name: "workflow_event_subject"
  end

  create_table "workflow_tasks", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "creator_id"
    t.bigint "assignee_id"
    t.bigint "customer_id"
    t.bigint "visit_id"
    t.bigint "delivery_run_id"
    t.bigint "delivery_order_id"
    t.bigint "incident_id"
    t.bigint "commercial_opportunity_id"
    t.string "source_key", null: false
    t.string "title", null: false
    t.text "description"
    t.string "category", null: false
    t.string "priority", default: "normal", null: false
    t.string "status", default: "pending", null: false
    t.datetime "due_at"
    t.datetime "closed_at"
    t.text "result"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assignee_id"], name: "index_workflow_tasks_on_assignee_id"
    t.index ["commercial_opportunity_id"], name: "index_workflow_tasks_on_commercial_opportunity_id"
    t.index ["company_id", "assignee_id", "status", "due_at"], name: "tasks_inbox"
    t.index ["company_id", "category", "status"], name: "index_workflow_tasks_on_company_id_and_category_and_status"
    t.index ["company_id", "id"], name: "index_workflow_tasks_on_company_id_and_id", unique: true
    t.index ["company_id", "source_key"], name: "index_workflow_tasks_on_company_id_and_source_key", unique: true
    t.index ["company_id"], name: "index_workflow_tasks_on_company_id"
    t.index ["creator_id"], name: "index_workflow_tasks_on_creator_id"
    t.index ["customer_id"], name: "index_workflow_tasks_on_customer_id"
    t.index ["delivery_order_id"], name: "index_workflow_tasks_on_delivery_order_id"
    t.index ["delivery_run_id"], name: "index_workflow_tasks_on_delivery_run_id"
    t.index ["incident_id"], name: "index_workflow_tasks_on_incident_id"
    t.index ["visit_id"], name: "index_workflow_tasks_on_visit_id"
    t.check_constraint "(category::text = ANY (ARRAY['operational'::character varying, 'commercial'::character varying, 'administrative'::character varying]::text[])) AND (priority::text = ANY (ARRAY['low'::character varying, 'normal'::character varying, 'high'::character varying, 'urgent'::character varying]::text[])) AND (status::text = ANY (ARRAY['pending'::character varying, 'in_progress'::character varying, 'completed'::character varying, 'cancelled'::character varying]::text[]))", name: "tasks_codes"
    t.check_constraint "(status::text = ANY (ARRAY['completed'::character varying, 'cancelled'::character varying]::text[])) AND closed_at IS NOT NULL AND result IS NOT NULL AND length(btrim(result)) > 0 OR (status::text = ANY (ARRAY['pending'::character varying, 'in_progress'::character varying]::text[])) AND closed_at IS NULL", name: "tasks_closure"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "commercial_opportunities", "companies"
  add_foreign_key "commercial_opportunities", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "commercial_opportunities_customer_tenant"
  add_foreign_key "commercial_opportunities", "delivery_orders", column: ["company_id", "delivery_order_id"], primary_key: ["company_id", "id"], name: "commercial_opportunities_delivery_order_tenant"
  add_foreign_key "commercial_opportunities", "products", column: ["company_id", "product_id"], primary_key: ["company_id", "id"], name: "commercial_opportunities_product_tenant"
  add_foreign_key "commercial_rule_settings", "companies"
  add_foreign_key "commercial_rule_settings", "users", column: ["company_id", "auto_assignee_id"], primary_key: ["company_id", "id"], name: "commercial_rule_settings_auto_assignee_tenant"
  add_foreign_key "communication_consents", "companies"
  add_foreign_key "communication_consents", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "communication_consents_customer_tenant"
  add_foreign_key "communication_consents", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "communication_consents_user_tenant"
  add_foreign_key "companies", "users", column: "primary_administrator_id"
  add_foreign_key "customer_import_rows", "companies"
  add_foreign_key "customer_import_rows", "customer_imports", column: ["company_id", "customer_import_id"], primary_key: ["company_id", "id"], name: "customer_import_row_tenant"
  add_foreign_key "customer_import_rows", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "customer_import_row_customer_tenant"
  add_foreign_key "customer_imports", "companies"
  add_foreign_key "customer_imports", "users", column: "initiated_by_id"
  add_foreign_key "customer_imports", "users", column: ["company_id", "initiated_by_id"], primary_key: ["company_id", "id"], name: "customer_import_initiator_tenant"
  add_foreign_key "customer_notifications", "companies"
  add_foreign_key "customer_notifications", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "customer_notifications_customer_tenant"
  add_foreign_key "customer_notifications", "delivery_orders", column: ["company_id", "customer_id", "delivery_order_id"], primary_key: ["company_id", "customer_id", "id"], name: "notifications_order_customer_tenant"
  add_foreign_key "customer_notifications", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "customer_notifications_user_tenant"
  add_foreign_key "customers", "companies"
  add_foreign_key "delivery_dispatch_changes", "companies"
  add_foreign_key "delivery_dispatch_changes", "delivery_orders", column: ["company_id", "delivery_order_id"], primary_key: ["company_id", "id"]
  add_foreign_key "delivery_dispatch_changes", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"]
  add_foreign_key "delivery_evidences", "companies"
  add_foreign_key "delivery_evidences", "driver_sync_operations", column: ["company_id", "driver_sync_operation_id"], primary_key: ["company_id", "id"], name: "evidence_operation_tenant"
  add_foreign_key "delivery_evidences", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "evidence_user_tenant"
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
  add_foreign_key "delivery_orders", "delivery_orders", column: ["company_id", "customer_id", "rescheduled_from_id"], primary_key: ["company_id", "customer_id", "id"], name: "orders_reschedule_customer_tenant"
  add_foreign_key "delivery_orders", "delivery_schedules", column: ["company_id", "customer_id", "delivery_schedule_id"], primary_key: ["company_id", "customer_id", "id"], name: "orders_schedule_customer_tenant"
  add_foreign_key "delivery_orders", "driver_profiles"
  add_foreign_key "delivery_orders", "driver_profiles", column: ["company_id", "driver_profile_id"], primary_key: ["company_id", "id"], name: "orders_driver_profile_tenant"
  add_foreign_key "delivery_orders", "visits", column: ["company_id", "customer_id", "visit_id"], primary_key: ["company_id", "customer_id", "id"], name: "orders_visit_customer_tenant"
  add_foreign_key "delivery_run_costs", "companies"
  add_foreign_key "delivery_run_costs", "delivery_run_costs", column: ["company_id", "reversal_of_id"], primary_key: ["company_id", "id"], name: "run_costs_reversal_tenant"
  add_foreign_key "delivery_run_costs", "delivery_runs", column: ["company_id", "delivery_run_id"], primary_key: ["company_id", "id"], name: "delivery_run_costs_delivery_run_tenant"
  add_foreign_key "delivery_run_costs", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "delivery_run_costs_user_tenant"
  add_foreign_key "delivery_runs", "companies"
  add_foreign_key "delivery_runs", "users", column: "costs_closed_by_id"
  add_foreign_key "delivery_runs", "users", column: "driver_id"
  add_foreign_key "delivery_runs", "users", column: ["company_id", "costs_closed_by_id"], primary_key: ["company_id", "id"], name: "runs_cost_closer_tenant"
  add_foreign_key "delivery_runs", "users", column: ["company_id", "driver_id"], primary_key: ["company_id", "id"], name: "fk_delivery_runs_driver_id_tenant"
  add_foreign_key "delivery_schedule_items", "companies"
  add_foreign_key "delivery_schedule_items", "delivery_schedules"
  add_foreign_key "delivery_schedule_items", "delivery_schedules", column: ["company_id", "delivery_schedule_id"], primary_key: ["company_id", "id"], name: "fk_delivery_schedule_items_delivery_schedule_id_tenant"
  add_foreign_key "delivery_schedule_items", "products"
  add_foreign_key "delivery_schedule_items", "products", column: ["company_id", "product_id"], primary_key: ["company_id", "id"], name: "fk_delivery_schedule_items_product_id_tenant"
  add_foreign_key "delivery_schedules", "companies"
  add_foreign_key "delivery_schedules", "customers"
  add_foreign_key "delivery_schedules", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "fk_delivery_schedules_customer_id_tenant"
  add_foreign_key "delivery_schedules", "driver_profiles"
  add_foreign_key "delivery_schedules", "driver_profiles", column: ["company_id", "driver_profile_id"], primary_key: ["company_id", "id"], name: "schedules_driver_profile_tenant"
  add_foreign_key "delivery_status_events", "companies"
  add_foreign_key "delivery_status_events", "delivery_orders", column: ["company_id", "delivery_order_id"], primary_key: ["company_id", "id"], name: "status_events_delivery_order_tenant"
  add_foreign_key "delivery_status_events", "delivery_runs", column: ["company_id", "delivery_run_id"], primary_key: ["company_id", "id"], name: "status_events_delivery_run_tenant"
  add_foreign_key "delivery_status_events", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "status_events_user_tenant"
  add_foreign_key "driver_locations", "companies"
  add_foreign_key "driver_locations", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"]
  add_foreign_key "driver_profiles", "companies"
  add_foreign_key "driver_profiles", "users"
  add_foreign_key "driver_profiles", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "driver_profiles_user_tenant"
  add_foreign_key "driver_sync_operations", "companies"
  add_foreign_key "driver_sync_operations", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "driver_sync_user_tenant"
  add_foreign_key "geocoding_cache_entries", "companies"
  add_foreign_key "incident_photos", "companies"
  add_foreign_key "incident_photos", "incidents", column: ["company_id", "incident_id"], primary_key: ["company_id", "id"], name: "incident_photos_incident_tenant"
  add_foreign_key "incident_photos", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "incident_photos_user_tenant"
  add_foreign_key "incidents", "companies"
  add_foreign_key "incidents", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "incidents_customer_tenant"
  add_foreign_key "incidents", "delivery_runs", column: ["company_id", "delivery_run_id"], primary_key: ["company_id", "id"], name: "incidents_delivery_run_tenant"
  add_foreign_key "incidents", "users", column: ["company_id", "assigned_to_id"], primary_key: ["company_id", "id"], name: "incidents_assigned_to_tenant"
  add_foreign_key "incidents", "users", column: ["company_id", "driver_id"], primary_key: ["company_id", "id"], name: "incidents_driver_tenant"
  add_foreign_key "incidents", "users", column: ["company_id", "reporter_id"], primary_key: ["company_id", "id"], name: "incidents_reporter_tenant"
  add_foreign_key "internal_notices", "companies"
  add_foreign_key "internal_notices", "incidents", column: ["company_id", "incident_id"], primary_key: ["company_id", "id"], name: "internal_notices_incident_tenant"
  add_foreign_key "internal_notices", "users", column: ["company_id", "sender_id"], primary_key: ["company_id", "id"], name: "internal_notices_sender_tenant"
  add_foreign_key "internal_notices", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "internal_notices_user_tenant"
  add_foreign_key "internal_notices", "workflow_tasks", column: ["company_id", "workflow_task_id"], primary_key: ["company_id", "id"], name: "internal_notices_workflow_task_tenant"
  add_foreign_key "notification_events", "companies"
  add_foreign_key "notification_events", "customer_notifications", column: ["company_id", "customer_notification_id"], primary_key: ["company_id", "id"], name: "notification_event_tenant"
  add_foreign_key "operation_import_groups", "companies"
  add_foreign_key "operation_import_groups", "customers"
  add_foreign_key "operation_import_groups", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "operation_groups_customer_tenant"
  add_foreign_key "operation_import_groups", "driver_profiles"
  add_foreign_key "operation_import_groups", "driver_profiles", column: ["company_id", "driver_profile_id"], primary_key: ["company_id", "id"], name: "operation_groups_driver_tenant"
  add_foreign_key "operation_import_groups", "operation_imports"
  add_foreign_key "operation_import_groups", "operation_imports", column: ["company_id", "operation_import_id"], primary_key: ["company_id", "id"], name: "operation_groups_import_tenant"
  add_foreign_key "operation_import_rows", "companies"
  add_foreign_key "operation_import_rows", "operation_import_groups"
  add_foreign_key "operation_import_rows", "operation_import_groups", column: ["company_id", "operation_import_group_id"], primary_key: ["company_id", "id"], name: "operation_rows_group_tenant"
  add_foreign_key "operation_import_rows", "operation_imports"
  add_foreign_key "operation_import_rows", "operation_imports", column: ["company_id", "operation_import_id"], primary_key: ["company_id", "id"], name: "operation_rows_import_tenant"
  add_foreign_key "operation_imports", "companies"
  add_foreign_key "operation_imports", "users", column: "initiated_by_id"
  add_foreign_key "operation_imports", "users", column: ["company_id", "initiated_by_id"], primary_key: ["company_id", "id"], name: "operation_import_user_tenant"
  add_foreign_key "platform_sessions", "platform_admins"
  add_foreign_key "product_imports", "companies"
  add_foreign_key "products", "companies"
  add_foreign_key "route_optimization_proposals", "companies"
  add_foreign_key "route_optimization_proposals", "delivery_runs"
  add_foreign_key "route_optimization_proposals", "delivery_runs", column: ["delivery_run_id", "company_id"], primary_key: ["id", "company_id"]
  add_foreign_key "route_optimization_proposals", "users", column: "applied_by_id"
  add_foreign_key "route_optimization_proposals", "users", column: "requested_by_id"
  add_foreign_key "route_optimization_proposals", "users", column: ["applied_by_id", "company_id"], primary_key: ["id", "company_id"]
  add_foreign_key "route_optimization_proposals", "users", column: ["requested_by_id", "company_id"], primary_key: ["id", "company_id"]
  add_foreign_key "route_publications", "companies"
  add_foreign_key "route_publications", "delivery_runs"
  add_foreign_key "route_publications", "delivery_runs", column: ["delivery_run_id", "company_id"], primary_key: ["id", "company_id"]
  add_foreign_key "route_publications", "route_optimization_proposals", column: "proposal_id"
  add_foreign_key "route_publications", "route_optimization_proposals", column: ["proposal_id", "company_id"], primary_key: ["id", "company_id"]
  add_foreign_key "route_publications", "users", column: "requested_by_id"
  add_foreign_key "route_publications", "users", column: ["requested_by_id", "company_id"], primary_key: ["id", "company_id"]
  add_foreign_key "routing_cache_entries", "companies"
  add_foreign_key "run_stock_movements", "companies"
  add_foreign_key "run_stock_movements", "delivery_items", column: ["company_id", "delivery_item_id"], primary_key: ["company_id", "id"], name: "stock_execution_tenant"
  add_foreign_key "run_stock_movements", "delivery_runs", column: ["company_id", "delivery_run_id"], primary_key: ["company_id", "id"], name: "run_stock_movements_delivery_run_tenant"
  add_foreign_key "run_stock_movements", "products", column: ["company_id", "product_id"], primary_key: ["company_id", "id"], name: "stock_product_tenant"
  add_foreign_key "run_stock_movements", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "run_stock_movements_user_tenant"
  add_foreign_key "sessions", "users"
  add_foreign_key "users", "companies"
  add_foreign_key "visits", "companies"
  add_foreign_key "visits", "customers"
  add_foreign_key "visits", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "fk_visits_customer_id_tenant"
  add_foreign_key "visits", "delivery_runs"
  add_foreign_key "visits", "delivery_runs", column: ["company_id", "delivery_run_id"], primary_key: ["company_id", "id"], name: "fk_visits_delivery_run_id_tenant"
  add_foreign_key "visits", "delivery_schedules"
  add_foreign_key "visits", "delivery_schedules", column: ["company_id", "customer_id", "delivery_schedule_id"], primary_key: ["company_id", "customer_id", "id"], name: "fk_visits_schedule_customer_tenant"
  add_foreign_key "visits", "users", column: ["company_id", "confirmed_by_id"], primary_key: ["company_id", "id"], name: "visits_confirmer_tenant"
  add_foreign_key "workflow_commands", "companies"
  add_foreign_key "workflow_commands", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "workflow_commands_user_tenant"
  add_foreign_key "workflow_events", "commercial_opportunities", column: ["company_id", "commercial_opportunity_id"], primary_key: ["company_id", "id"], name: "workflow_events_commercial_opportunity_tenant"
  add_foreign_key "workflow_events", "companies"
  add_foreign_key "workflow_events", "incidents", column: ["company_id", "incident_id"], primary_key: ["company_id", "id"], name: "workflow_events_incident_tenant"
  add_foreign_key "workflow_events", "users", column: ["company_id", "user_id"], primary_key: ["company_id", "id"], name: "workflow_events_user_tenant"
  add_foreign_key "workflow_events", "workflow_tasks", column: ["company_id", "workflow_task_id"], primary_key: ["company_id", "id"], name: "workflow_events_workflow_task_tenant"
  add_foreign_key "workflow_tasks", "commercial_opportunities", column: ["company_id", "commercial_opportunity_id"], primary_key: ["company_id", "id"], name: "workflow_tasks_commercial_opportunity_tenant"
  add_foreign_key "workflow_tasks", "companies"
  add_foreign_key "workflow_tasks", "customers", column: ["company_id", "customer_id"], primary_key: ["company_id", "id"], name: "workflow_tasks_customer_tenant"
  add_foreign_key "workflow_tasks", "delivery_orders", column: ["company_id", "customer_id", "delivery_order_id"], primary_key: ["company_id", "customer_id", "id"], name: "task_order_customer_tenant"
  add_foreign_key "workflow_tasks", "delivery_orders", column: ["company_id", "delivery_order_id"], primary_key: ["company_id", "id"], name: "workflow_tasks_delivery_order_tenant"
  add_foreign_key "workflow_tasks", "delivery_runs", column: ["company_id", "delivery_run_id"], primary_key: ["company_id", "id"], name: "workflow_tasks_delivery_run_tenant"
  add_foreign_key "workflow_tasks", "incidents", column: ["company_id", "incident_id"], primary_key: ["company_id", "id"], name: "workflow_tasks_incident_tenant"
  add_foreign_key "workflow_tasks", "users", column: ["company_id", "assignee_id"], primary_key: ["company_id", "id"], name: "workflow_tasks_assignee_tenant"
  add_foreign_key "workflow_tasks", "users", column: ["company_id", "creator_id"], primary_key: ["company_id", "id"], name: "workflow_tasks_creator_tenant"
end
