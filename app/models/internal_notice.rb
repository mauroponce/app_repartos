class InternalNotice < ApplicationRecord
  include TenantIntegrity
  include WorkflowUpdates
  belongs_to :user
  belongs_to :sender, class_name: "User", optional: true
  belongs_to :incident, optional: true
  belongs_to :workflow_task, optional: true
  validates :title, :body, :source_key, presence: true
  validates :title, length: { maximum: 255 }
  validates :body, length: { maximum: 4000 }
  validates :source_key, uniqueness: { scope: %i[company_id user_id] }
  validate -> { %i[user sender incident workflow_task].each { |key| same_company(key) } }
  validate do
    if persisted? && (changes_to_save.keys - %w[read_at acknowledged_at]).any?
      errors.add(:base, "El aviso conserva su instrucción original")
    end
    %w[read_at acknowledged_at].each do |field|
      errors.add(field, "conserva la confirmación registrada") if persisted? && attribute_in_database(field) && will_save_change_to_attribute?(field)
    end
  end
  before_destroy { errors.add(:base, "Los avisos conservan su historial"); throw :abort }
  scope :unread, -> { where(read_at: nil) }
end
