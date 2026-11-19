class OperationImport < ApplicationRecord
  include TenantIntegrity
  belongs_to :initiated_by, class_name: "User", optional: true
  has_one_attached :source_file
  has_many :groups, class_name: "OperationImportGroup", dependent: :destroy
  has_many :rows, class_name: "OperationImportRow", dependent: :delete_all
  validates :sha256, presence: true
  validate -> { same_company(:initiated_by) }
end
