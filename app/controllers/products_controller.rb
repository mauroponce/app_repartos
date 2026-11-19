class ProductsController < ManagementController
  before_action :set_product, only: [ :show, :edit, :update ]

  def index
    @query = params[:q].to_s.strip.first(120)
    @active_filter = params.key?(:active) ? params[:active].presence_in(%w[true false]) : "true"
    sort_columns = { "name" => 'LOWER(products.name) COLLATE "es-x-icu"', "sku" => 'LOWER(products.sku) COLLATE "es-x-icu"', "unit" => "CASE products.unit WHEN 'unit' THEN 'unidad' WHEN 'pack' THEN 'paquete' WHEN 'bag' THEN 'bolsa' WHEN 'box' THEN 'caja' WHEN 'kg' THEN 'kilogramo' WHEN 'g' THEN 'gramo' WHEN 'l' THEN 'litro' END", "active" => "CASE WHEN products.active THEN 0 ELSE 1 END" }
    @sort = params[:sort].presence_in(sort_columns.keys) || "name"
    @direction = params[:direction] == "desc" ? "desc" : "asc"
    products = Current.company.products.order(Arel.sql("#{sort_columns.fetch(@sort)} #{@direction.upcase} NULLS LAST"), :id)
    products = products.search(@query) if @query.present?
    products = products.where(active: @active_filter == "true") if @active_filter
    @filtered_count = products.count
    @pages = [ (@filtered_count / 25.0).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @pages)
    @products = products.limit(25).offset((@page - 1) * 25)
  end

  def new
    @product = Current.company.products.new
  end

  def create
    @product = Current.company.products.new(product_params)
    if @product.save
      redirect_to products_path, notice: "Producto creado correctamente.", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
  end

  def edit
  end

  def update
    if @product.update(product_params)
      redirect_to products_path, notice: "Producto actualizado correctamente.", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_product
    @product = Current.company.products.find(params[:id])
  end

  def product_params
    params.expect(product: [ :sku, :name, :unit_price, :unit_cost, :unit, :package_content_quantity, :package_content_unit, :active ])
  end
end
