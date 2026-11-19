class OperationImportGroup < ApplicationRecord
  include TenantIntegrity
  belongs_to :operation_import
  belongs_to :customer, optional: true
  belongs_to :driver_profile, optional: true
  has_many :rows, class_name: "OperationImportRow", dependent: :nullify
  validates :group_key, presence: true, uniqueness: { scope: :operation_import_id }
  validate -> { same_company(:operation_import); same_company(:customer); same_company(:driver_profile) }
end
