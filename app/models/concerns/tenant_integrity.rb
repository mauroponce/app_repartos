module TenantIntegrity
  extend ActiveSupport::Concern

  included do
    belongs_to :company
    validate :company_is_immutable, on: :update
  end

  private

  def same_company(association)
    linked = public_send(association)
    errors.add(association, "no existe") if public_send("#{association}_id").present? && linked.nil?
    errors.add(association, "debe pertenecer a la misma empresa") if linked && linked.company_id != company_id
  end

  def company_is_immutable
    errors.add(:company, "no se puede cambiar") if will_save_change_to_company_id?
  end
end
