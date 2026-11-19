class OperationImportRow < ApplicationRecord
  include TenantIntegrity
  belongs_to :operation_import
  belongs_to :operation_import_group, optional: true
  validate -> { same_company(:operation_import); same_company(:operation_import_group) }
end
