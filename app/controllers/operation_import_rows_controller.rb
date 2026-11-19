class OperationImportRowsController < ManagementController
  before_action :set_row

  def edit
    @product_matches = Current.company.products.where(name_key: OperationImports::Normalizer.key(@row.original["nombre_producto"]))
      .order(:id).limit(30)
  end

  def update
    return redirect_to operation_import_path(@import), alert: "Esperá a que termine la confirmación." unless @import.state.in?(%w[review finished])
    unless @row.operation_import_group&.state.in?(%w[review ready pending])
      return redirect_to operation_import_path(@import), alert: "Esta fila ya no se puede corregir."
    end
    submitted = params.expect(row: OperationImports::Reader::HEADERS.map(&:to_sym) + %i[product_id new_product]).to_h
    raw = @row.original.merge(submitted.slice(*OperationImports::Reader::HEADERS))
    data, issues = OperationImports::Normalizer.call(raw)
    if submitted["new_product"] == "1"
      data["new_product"] = true
    elsif submitted["product_id"].present?
      product = Current.company.products.find(submitted["product_id"])
      unless product.name_key == OperationImports::Normalizer.key(data["nombre_producto"]) && product.active? && product.unit == "unit"
        return redirect_to edit_operation_import_row_path(@import, @row), alert: "El producto elegido no coincide con la fila."
      end
      data["product_id"] = product.id
    end
    @import.with_lock do
      return redirect_to operation_import_path(@import), alert: "Esperá a que termine la confirmación." unless @import.state.in?(%w[review finished])
      @row.reload
      old_group = @row.operation_import_group
      unless old_group&.state.in?(%w[review ready pending])
        return redirect_to operation_import_path(@import), alert: "Esta fila ya no se puede corregir."
      end
      groups = [ old_group ]
      if (other = @import.groups.find_by(group_key: data["group_key"])) && other.id != old_group.id
        unless other.state.in?(%w[review ready pending])
          return redirect_to edit_operation_import_row_path(@import, @row), alert: "El destino ya fue importado."
        end
        groups << other
      end
      groups.each do |group|
        @import.rows.where(operation_import_group_id: group.id).update_all(operation_import_group_id: nil)
        group.destroy!
      end
      @row.update!(original: raw, data: data, issues: issues)
      @import.update!(state: "analyzing")
    end
    OperationImportJob.perform_later(Current.company.id, @import.id, "analyze")
    redirect_to operation_import_path(@import), notice: "Fila corregida; se está analizando de nuevo."
  end

  private

  def set_row
    @import = Current.company.operation_imports.find(params[:operation_import_id])
    @row = @import.rows.find(params[:id])
  end
end
