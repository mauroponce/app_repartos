class CreateCommunicationRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :communication_consents do |t|
      t.references :company, null: false, foreign_key: true
      t.references :customer, null: false
      t.references :user, null: false
      t.string :channel, null: false
      t.string :purpose, null: false
      t.string :decision, null: false
      t.string :evidence, null: false
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :communication_consents, [ :company_id, :customer_id, :channel, :purpose, :id ], name: "consent_latest_decision"
    add_check_constraint :communication_consents, "channel IN ('email','sms','whatsapp') AND purpose IN ('operational','marketing') AND decision IN ('granted','revoked')", name: "consents_codes"
    create_table :customer_notifications do |t|
      t.references :company, null: false, foreign_key: true
      t.references :customer, null: false
      t.bigint :delivery_order_id
      t.bigint :user_id
      t.uuid :operation_id, null: false
      t.string :channel, null: false
      t.string :purpose, null: false
      t.string :template_key, null: false
      t.string :recipient, null: false
      t.datetime :created_at, null: false
    end
    add_index :customer_notifications, [ :company_id, :id ], unique: true
    add_index :customer_notifications, [ :company_id, :operation_id ], unique: true
    add_check_constraint :customer_notifications, "channel IN ('email','sms','whatsapp') AND purpose IN ('operational','marketing')", name: "notifications_codes"
    create_table :notification_events do |t|
      t.references :company, null: false, foreign_key: true
      t.references :customer_notification, null: false
      t.string :event_key, null: false
      t.string :status, null: false
      t.string :provider
      t.string :provider_message_id
      t.string :error_code
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :notification_events, [ :company_id, :event_key ], unique: true
    add_check_constraint :notification_events, "status IN ('requested','accepted','delivered','failed','suppressed')", name: "notification_events_status"
    [ :communication_consents, :customer_notifications ].each do |table|
      [ :customer, :user ].each do |association|
        add_foreign_key table, association.to_s.pluralize.to_sym, column: [ :company_id, :"#{association}_id" ], primary_key: [ :company_id, :id ], name: "#{table}_#{association}_tenant"
      end
    end
    add_foreign_key :customer_notifications, :delivery_orders, column: [ :company_id, :customer_id, :delivery_order_id ], primary_key: [ :company_id, :customer_id, :id ], name: "notifications_order_customer_tenant"
    add_foreign_key :notification_events, :customer_notifications, column: [ :company_id, :customer_notification_id ], primary_key: [ :company_id, :id ], name: "notification_event_tenant"
  end
end
