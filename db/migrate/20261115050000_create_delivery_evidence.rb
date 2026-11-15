class CreateDeliveryEvidence < ActiveRecord::Migration[8.1]
  def change
    create_table :active_storage_blobs do |t|
      t.string :key, null: false
      t.string :filename, null: false
      t.string :content_type
      t.text :metadata
      t.string :service_name, null: false
      t.bigint :byte_size, null: false
      t.string :checksum
      t.datetime :created_at, null: false
      t.index :key, unique: true
    end
    create_table :active_storage_attachments do |t|
      t.string :name, null: false
      t.references :record, null: false, polymorphic: true, index: false
      t.references :blob, null: false, foreign_key: { to_table: :active_storage_blobs }
      t.datetime :created_at, null: false
      t.index [ :record_type, :record_id, :name, :blob_id ], unique: true, name: "index_active_storage_attachments_uniqueness"
    end
    create_table :active_storage_variant_records do |t|
      t.belongs_to :blob, null: false, index: false, foreign_key: { to_table: :active_storage_blobs }
      t.string :variation_digest, null: false
      t.index [ :blob_id, :variation_digest ], unique: true, name: "index_active_storage_variant_records_uniqueness"
    end

    add_column :visits, :receipt_version, :integer, null: false, default: 0
    add_column :visits, :recorded_at, :datetime
    add_column :visits, :recorded_latitude, :decimal, precision: 10, scale: 7
    add_column :visits, :recorded_longitude, :decimal, precision: 10, scale: 7
    add_column :visits, :location_accuracy, :decimal, precision: 10, scale: 2
    add_column :visits, :location_captured_at, :datetime
    add_column :visits, :failure_reason, :string
    add_column :visits, :receiver_name, :string
    remove_check_constraint :visits, name: "visits_valid_status"
    add_check_constraint :visits, "status IN ('pending','completed','not_attended','closed','rescheduled','rejected')", name: "visits_valid_status"
    add_check_constraint :visits, "receipt_version IN (0,1)", name: "visits_receipt_version"
    add_check_constraint :visits, "(recorded_latitude IS NULL AND recorded_longitude IS NULL AND location_accuracy IS NULL AND location_captured_at IS NULL) OR (recorded_latitude IS NOT NULL AND recorded_longitude IS NOT NULL AND recorded_latitude BETWEEN -90 AND 90 AND recorded_longitude BETWEEN -180 AND 180 AND location_accuracy IS NOT NULL AND location_accuracy >= 0 AND location_captured_at IS NOT NULL)", name: "visits_receipt_location"
    add_check_constraint :visits, "failure_reason IS NULL OR failure_reason IN ('shortage','damaged','customer_request','absent','closed','rejected','other')", name: "visits_failure_reason"

    add_index :driver_sync_operations, [ :company_id, :id ], unique: true
    create_table :delivery_evidences do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, null: false
      t.references :driver_sync_operation
      t.bigint :visit_id, null: false
      t.uuid :operation_id, null: false
      t.uuid :evidence_uuid, null: false
      t.string :kind, null: false
      t.string :sha256, null: false
      t.datetime :purged_at
      t.timestamps
      t.index [ :company_id, :user_id, :evidence_uuid ], unique: true, name: "evidence_unique_uuid"
      t.index [ :company_id, :user_id, :operation_id ], name: "evidence_operation"
      t.index [ :company_id, :user_id, :operation_id ], unique: true, where: "kind = 'signature'", name: "evidence_one_signature"
    end
    add_foreign_key :delivery_evidences, :users, column: [ :company_id, :user_id ], primary_key: [ :company_id, :id ], name: "evidence_user_tenant"
    add_foreign_key :delivery_evidences, :driver_sync_operations, column: [ :company_id, :driver_sync_operation_id ], primary_key: [ :company_id, :id ], name: "evidence_operation_tenant"
    add_check_constraint :delivery_evidences, "kind IN ('photo','signature')", name: "evidence_valid_kind"
    add_check_constraint :delivery_evidences, "sha256 ~ '^[0-9a-f]{64}$'", name: "evidence_valid_digest"
  end
end
