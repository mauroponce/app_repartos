class CommercialRuleSettingsController < WorkflowManagementController
  before_action :workflow_options

  def edit
    @settings = Current.company.commercial_rule_setting || Current.company.build_commercial_rule_setting
  end

  def update
    saved = Current.company.with_lock do
      @settings = Current.company.commercial_rule_setting || Current.company.build_commercial_rule_setting
      values = params.expect(setting: [ :inactivity_min_days, :inactivity_multiplier, :comparison_days, :decline_min_orders, :decline_percent, :shortage_min_orders, :failure_min_orders, :partial_grace_days, :cooldown_days, :auto_assignee_id, automatic_rules: [] ]).to_h
      values["automatic_rules"] = Array(values["automatic_rules"]).reject(&:blank?)
      @settings.assign_attributes(values)
      @settings.save
    end
    if saved
      OpportunityRefreshRequest.call(Current.company.id)
      redirect_to reports_path, notice: "Umbrales guardados. El análisis se actualizará en segundo plano.", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end
end
