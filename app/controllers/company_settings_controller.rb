class CompanySettingsController < ManagementController
  before_action :require_administrator

  def edit
    @company = Current.company
  end

  def update
    @company = Current.company
    @company.with_lock { @company.update!(params.expect(company: [ :province ])) }
    redirect_to new_customer_import_path, notice: "Provincia de la empresa actualizada.", status: :see_other
  rescue ActiveRecord::RecordInvalid
    render :edit, status: :unprocessable_entity
  end

  private

  def require_administrator
    render "errors/forbidden", layout: "authentication", status: :forbidden unless Current.user.administrator?
  end
end
