class ManagementController < ApplicationController
  before_action :require_management
  around_action :use_company_time_zone

  private

  def require_management
    render "errors/forbidden", status: :forbidden unless Current.user.administrator? || Current.user.supervisor?
  end

  def use_company_time_zone(&action)
    Time.use_zone(Current.company.time_zone, &action)
  end

  def paginate(relation)
    @filtered_count = relation.count
    @pages = [ (@filtered_count / 12.0).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @pages)
    relation.limit(12).offset((@page - 1) * 12)
  end
end
