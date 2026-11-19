class ProductsController < ManagementController
  before_action :set_product, only: [ :show, :edit, :update ]

  def index
    @query = params[:q].to_s.strip.first(120)
    @active_filter = params.key?(:active) ? params[:active].presence_in(%w[true false]) : "true"
    products = Current.company.products.alphabetical
    products = products.search(@query) if @query.present?
    products = products.where(active: @active_filter == "true") if @active_filter
    @products = products
    @filtered_count = products.count
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
