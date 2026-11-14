require "csv"

class ProductImportsController < ManagementController
  before_action :set_import, only: [ :show, :update, :confirm ]

  def new
  end

  def template
    send_data CSV.generate { |csv| csv << ProductImporter::FIELDS; csv << [ "PAN-01", "Pan lactal", "pack", nil, nil, "true" ] }, filename: "plantilla_productos.csv", type: "text/csv; charset=utf-8"
  end

  def create
    data = ProductImportReader.call(params[:file])
    @product_import = Current.company.product_imports.create!(**data, mapping: ProductImporter.default_mapping(data[:headers]))
    redirect_to product_import_path(@product_import), status: :see_other
  rescue ProductImportReader::InvalidFile => error
    flash.now[:alert] = error.message
    render :new, status: :unprocessable_entity
  end

  def show
    @preview = ProductImporter.new(@product_import).preview
  end

  def update
    if @product_import.confirmed_at || @product_import.expired?
      redirect_to product_import_path(@product_import), alert: "La importación está confirmada o vencida.", status: :see_other
    else
      @product_import.update!(mapping: params.expect(mapping: ProductImporter::FIELDS).to_h)
      redirect_to product_import_path(@product_import), status: :see_other
    end
  end

  def confirm
    count = ProductImporter.new(@product_import).confirm!(acknowledge_without_sku: params[:acknowledge_without_sku] == "1")
    redirect_to products_path, notice: count.zero? ? "Esta importación ya fue confirmada; no se repitió." : "Se importaron #{count} productos correctamente.", status: :see_other
  rescue ProductImporter::InvalidImport, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    flash.now[:alert] = error.message
    @preview = ProductImporter.new(@product_import).preview
    render :show, status: :unprocessable_entity
  end

  private

  def set_import
    @product_import = Current.company.product_imports.find(params[:id])
  end
end
