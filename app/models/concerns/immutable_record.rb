module ImmutableRecord
  extend ActiveSupport::Concern
  included do
    before_update :reject_history_mutation
    before_destroy :reject_history_mutation
  end

  private

  def reject_history_mutation
    errors.add(:base, "El registro conserva su historial; registrá una corrección por separado")
    throw :abort
  end
end
