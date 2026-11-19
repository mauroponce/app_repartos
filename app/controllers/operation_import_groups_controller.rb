require "set"

class OperationImportGroupsController < ManagementController
  def update
    batch = Current.company.operation_imports.find(params[:operation_import_id])
    group = batch.groups.find(params[:id])
    batch.with_lock do
      return redirect_to operation_import_path(batch), alert: "Esperá a que termine la confirmación." unless batch.state.in?(%w[review finished])
      group.reload
      return redirect_to operation_import_path(batch), alert: "El grupo ya fue guardado." unless group.state.in?(%w[review ready excluded pending])
      action = params[:decision].to_s
      case action
      when "exclude", "pending"
        group.update!(state: action == "exclude" ? "excluded" : "pending")
      when "use", "create"
        customer = params[:customer_id].present? ? Current.company.customers.find(params[:customer_id]) : nil
        driver = params[:driver_profile_id].present? ? Current.company.driver_profiles.find(params[:driver_profile_id]) : nil
        if action == "use" && customer.nil? && driver.nil?
          return redirect_to operation_import_path(batch), alert: "Elegí al menos una coincidencia."
        end
        corrections = params.permit(:cliente, :calle, :localidad, :repartidor).to_h
        normalized = nil
        issues = []
        seen_products = Set.new
        unresolved_products = Set.new
        repeated_product = false
        fields = %w[cliente calle localidad codigo_cliente repartidor tipo_pedido fecha_puntual dia_semana hora_desde hora_hasta orden_visita]
        group.rows.find_each(batch_size: 200) do |row|
          data, row_issues = OperationImports::Normalizer.call(row.original.merge(corrections))
          normalized ||= data
          issues.concat(row_issues)
          issues << "Las filas del grupo siguen siendo incompatibles" if fields.any? { |field| data[field] != normalized[field] }
          name = OperationImports::Normalizer.key(data["nombre_producto"])
          repeated_product = true if name.present? && seen_products.include?(name)
          seen_products.add(name) if name.present?
          unresolved_products.add(name) if name.present? && row.data["product_id"].blank? && !row.data["new_product"]
        end
        issues.uniq!
        return redirect_to operation_import_path(batch), alert: "El grupo no tiene filas." unless normalized
        issues.concat(OperationImports::Processor.product_issues(Current.company, unresolved_products))
        if normalized["referencia_pedido"].blank? && repeated_product
          issues << "Posibles pedidos independientes; corregí la referencia de cada fila"
        end
        if issues.any?
          group.update!(issues: issues)
        else
          if normalized["group_key"] != group.group_key
            return redirect_to operation_import_path(batch), alert: "Corregí primero las filas que cambian la identidad del pedido."
          end
          group.transaction do
            group.rows.find_each(batch_size: 200) do |row|
              data = OperationImports::Normalizer.call(row.original.merge(corrections)).first
              data["product_id"] = row.data["product_id"] if row.data["product_id"].present?
              data["new_product"] = true if row.data["new_product"]
              row.update!(data: data)
            end
            group.update!(data: normalized, decisions: { "customer_id" => customer&.id, "driver_profile_id" => driver&.id,
              "new_customer" => params[:new_customer] == "1", "new_driver" => params[:new_driver] == "1" }, issues: [], state: "ready")
          end
        end
      end
    end
    redirect_to operation_import_path(batch)
  end
end
