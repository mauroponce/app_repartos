class WorkflowLookupsController < WorkflowManagementController
  def show
    query = params[:q].to_s.strip.first(80)
    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    relation = case params[:kind]
    when "customer" then Current.company.customers.alphabetical
    when "product" then Current.company.products.alphabetical
    when "route" then Current.company.delivery_runs.order(scheduled_date: :desc, id: :desc)
    when "driver" then Current.company.users.driver.alphabetical
    when "manager" then Current.company.users.active.where(role: %w[administrator supervisor]).alphabetical
    when "staff" then Current.company.users.active.alphabetical
    else
      return render json: { error: "Tipo de búsqueda no válido" }, status: :bad_request
    end
    if query.present?
      relation = case params[:kind]
      when "customer" then relation.where("name ILIKE :q OR address ILIKE :q OR city ILIKE :q OR phone ILIKE :q", q: pattern)
      when "product" then relation.search(query)
      when "driver", "manager", "staff" then relation.search(query)
      else relation.where("name ILIKE ?", pattern)
      end
    end
    render json: relation.limit(30).map { |row|
      label = case row
      when Customer then "#{row.name} · #{row.address}, #{row.city}"
      when DeliveryRun then "##{row.id} · #{row.scheduled_date} · #{row.name}"
      when Product then "#{row.name}#{row.sku.present? ? " · #{row.sku}" : ""}"
      else row.name
      end
      { id: row.id, name: label }
    }
  end
end
