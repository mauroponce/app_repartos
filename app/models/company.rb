class Company < ApplicationRecord
  include RoutingChangeHooks
  has_many :route_publications, dependent: :restrict_with_error
  has_many :routing_cache_entries, dependent: :delete_all
  has_many :route_optimization_proposals, dependent: :restrict_with_error
  validates :depot_latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :depot_longitude, numericality: { in: -180..180 }, allow_nil: true
  validates :routing_departure, format: { with: /\A(?:[01]\d|2[0-3]):[0-5]\d\z/ }
  validates :routing_preferred_tolerance, numericality: { only_integer: true, in: 0..120 }
  validates :routing_service_minutes, numericality: { only_integer: true, in: 0..240 }
  validate do
    errors.add(:base, "Completá ambas coordenadas del depósito") if depot_latitude.nil? != depot_longitude.nil?
    errors.add(:routing_return_to_depot, "requiere un depósito configurado") if routing_return_to_depot && depot_latitude.nil?
  end
  has_one :commercial_rule_setting, dependent: :restrict_with_error
  has_many :incidents, dependent: :restrict_with_error
  has_many :workflow_tasks, dependent: :restrict_with_error
  has_many :commercial_opportunities, dependent: :restrict_with_error
  has_many :workflow_events, dependent: :restrict_with_error
  has_many :internal_notices, dependent: :restrict_with_error
  has_many :workflow_commands, dependent: :restrict_with_error
  has_many :incident_photos, dependent: :restrict_with_error
  has_many :users, dependent: :restrict_with_error
  has_many :customers, dependent: :restrict_with_error

  has_many :delivery_status_events, dependent: :restrict_with_error
  has_many :delivery_run_costs, dependent: :restrict_with_error
  has_many :run_stock_movements, dependent: :restrict_with_error
  has_many :communication_consents, dependent: :restrict_with_error
  has_many :customer_notifications, dependent: :restrict_with_error
  has_many :notification_events, dependent: :restrict_with_error
  has_many :products, dependent: :restrict_with_error
  has_many :delivery_schedules, dependent: :restrict_with_error
  has_many :delivery_orders, dependent: :restrict_with_error
  has_many :delivery_items, dependent: :restrict_with_error
  has_many :delivery_order_items, dependent: :restrict_with_error
  has_many :delivery_runs, dependent: :restrict_with_error
  has_many :visits, dependent: :restrict_with_error
  has_many :driver_sync_operations, dependent: :restrict_with_error
  has_many :driver_locations, dependent: :delete_all
  has_many :delivery_dispatch_changes, dependent: :restrict_with_error
  has_many :delivery_evidences, dependent: :restrict_with_error
  has_many :product_imports, dependent: :destroy
  normalizes :slug, with: ->(slug) { slug.strip.downcase }
  validates :currency, inclusion: { in: %w[ARS USD EUR] }
  validate :preserve_accounting_currency
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :time_zone, presence: true
  validate :valid_time_zone

  def local_date
    Time.current.in_time_zone(time_zone).to_date
  end

  private

  def preserve_accounting_currency
    return unless persisted? && will_save_change_to_currency?
    known = products.where.not(unit_price: nil).or(products.where.not(unit_cost: nil)).exists? ||
      delivery_order_items.where.not(unit_price: nil).or(delivery_order_items.where.not(unit_cost: nil)).exists? || delivery_run_costs.exists? || delivery_items.where.not(unit_price: nil).or(delivery_items.where.not(unit_cost: nil)).exists?
    errors.add(:currency, "no se puede cambiar después de registrar valores comerciales") if known
  end

  def valid_time_zone
    errors.add(:time_zone, "no es válida") unless ActiveSupport::TimeZone[time_zone]
  end
end
