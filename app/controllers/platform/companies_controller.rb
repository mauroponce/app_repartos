module Platform
  class CompaniesController < BaseController
    def index
      @page = [ params[:page].to_i, 1 ].max
      @companies = Company.order(:name, :id).limit(50).offset((@page - 1) * 50)
    end

    def show
      @company = Company.find(params[:id])
    end

    def new
      @registration = PlatformCompanyRegistration.new
    end

    def create
      @registration = PlatformCompanyRegistration.new(params.expect(registration: [ :name, :slug, :province, :time_zone, :currency, :administrator_name, :administrator_email, :password ]))
      if @registration.save
        redirect_to platform_company_path(@registration.company), notice: "Empresa y administrador creados correctamente.", status: :see_other
      else
        render :new, status: :unprocessable_entity
      end
    end
  end
end
