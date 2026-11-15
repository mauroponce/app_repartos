require "test_helper"
require_relative "../test_helpers/workflow_test_helper"
require "digest"

class WorkflowModulesControllerTest < ActionDispatch::IntegrationTest
  include WorkflowTestHelper
  setup do
    @company, @driver, @manager = companies(:one), users(:driver), users(:one)
    @order = workflow_order
    @run = workflow_plan([ @order ])
    @visit = @order.reload.visit
    sign_in_as @driver
  end

  def workflow_post(values, files: [])
    post "/repartidor/api/v1/workflow-operations", params: { operation: values.to_json, files: files }, as: :multipart_form
  end

  test "driver reports own route management decides and driver sees audited instruction" do
    id = SecureRandom.uuid
    data = { operation_id: id, command: "incident_report", visit_id: @visit.id, kind: "closed", description: "Local cerrado hasta las 14", priority: "high", occurred_at: Time.current.iso8601, photos: [] }
    # Rails chooses multipart automatically when files exist; JSON is carried
    # as a stable string so retry hashing never depends on multipart boundaries.
    post "/repartidor/api/v1/workflow-operations", params: { operation: data.to_json }
    assert_response :success
    result = response.parsed_body
    incident = @company.incidents.find(result["result"]["incident_id"])
    assert_difference "Incident.count", 0 do
      post "/repartidor/api/v1/workflow-operations", params: { operation: data.to_json }
      assert_response :success
    end
    sign_in_as @manager
    get incidents_path
    assert_response :success
    assert_match "Cliente cerrado", response.body
    get incident_path(incident)
    assert_response :success
    assert_match "Local cerrado hasta las 14", response.body
    post act_incident_path(incident), params: { operation_id: SecureRandom.uuid, decision: { version: incident.lock_version, action: "retry", message: "Reintentar a las 14:30", assignee_id: @driver.id } }
    assert_redirected_to incident_path(incident)
    assert_equal "retry", incident.workflow_events.order(:id).last.action
    assert_equal @manager.id, incident.workflow_events.order(:id).last.user_id
    sign_in_as @driver
    get driver_workflow_inbox_path
    assert_response :success
    assert_match "Reintentar a las 14:30", response.parsed_body["html"]
    assert response.parsed_body["pending"].positive?
    get driver_incident_path(incident)
    assert_response :success
    assert_match "Reintentar a las 14:30", response.parsed_body["html"]
    assert @visit.reload.pending?
  end

  test "other drivers tenants and commercial access are isolated" do
    incident = @company.incidents.find(workflow_report(@visit).fetch("incident_id"))
    colleague = @company.users.create!(name: "Otro repartidor", role: :driver, email_address: "colleague-workflow@example.test", password: "Password-test-2026")
    sign_in_as colleague
    get driver_incident_path(incident)
    assert_response :not_found
    get driver_workflow_inbox_path
    assert_no_match "El local está cerrado", response.parsed_body["html"]
    get reports_path
    assert_response :forbidden
    get workflow_tasks_path
    assert_response :forbidden
    post "/repartidor/api/v1/workflow-operations", params: { operation: { operation_id: SecureRandom.uuid, command: "incident_report", visit_id: @visit.id, kind: "other", description: "Ajena", occurred_at: Time.current.iso8601 }.to_json }
    assert_response :not_found
    sign_in_as users(:two)
    get incident_path(incident)
    assert_response :not_found
    patch workflow_task_path(123), params: { operation_id: SecureRandom.uuid, task: { action: "complete", version: 0, result: "Ajena" } }
    assert_response :not_found
    get reports_path(customer_id: @order.customer_id)
    assert_response :not_found
  end

  test "lookup filters are bounded tenant scoped and permit customers beyond initial choices" do
    sign_in_as @manager
    get workflow_lookup_path(kind: "customer", q: "San Martín")
    assert_response :success
    assert_equal [ @order.customer_id ], response.parsed_body.pluck("id")
    get workflow_lookup_path(kind: "customer", q: "Comercio Privado Norte")
    assert_empty response.parsed_body
    get workflow_lookup_path(kind: "unknown", q: "x")
    assert_response :bad_request
    sign_in_as @driver
    get workflow_lookup_path(kind: "customer", q: "San Martín")
    assert_response :forbidden
  end

  test "reports empty and populated views links filters and configuration render without invented monetary values" do
    sign_in_as @manager
    get reports_path
    assert_response :success
    assert_select "[data-report-kpi=programmed] strong", text: "1"
    assert_match "No hay oportunidades", response.body
    assert_select "a[href=?]", edit_commercial_rule_settings_path
    assert_no_match "Comercio Privado Norte", response.body
    get reports_path(customer_id: customers(:inactive).id)
    assert_response :success
    assert_select "[data-report-kpi=programmed] strong", text: "0"
    get edit_commercial_rule_settings_path
    assert_response :success
    patch commercial_rule_settings_path, params: { setting: { inactivity_min_days: 18, automatic_rules: [ "inactive" ], auto_assignee_id: users(:supervisor).id } }
    assert_redirected_to reports_path
    assert_equal 18, @company.reload.commercial_rule_setting.inactivity_min_days
    assert_equal [ "inactive" ], @company.commercial_rule_setting.automatic_rules
    post refresh_reports_path
    assert_redirected_to reports_path
    get workflow_counts_path
    assert_response :success
    assert response.parsed_body["counts"].key?("incidents")
    revision = response.parsed_body["revision"]
    travel 1.second do
      workflow_finish(@visit, quantities: [ 10 ])
      get workflow_counts_path
      assert_not_equal revision, response.parsed_body["revision"]
      get reports_path
      assert_select "[data-report-kpi=complete] strong", text: "1"
    end
  end

  test "administrator creates assigns starts and closes a commercial task" do
    sign_in_as users(:supervisor)
    get new_workflow_task_path
    assert_response :success
    id = SecureRandom.uuid
    values = { operation_id: id, task: { title: "Revisar caída de pedidos", category: "commercial", assignee_id: @manager.id, customer_id: @order.customer_id, description: "Llamar y registrar resultado" } }
    assert_difference "WorkflowTask.count", 1 do
      post workflow_tasks_path, params: values
      assert_response :see_other
      post workflow_tasks_path, params: values
    end
    task = @company.workflow_tasks.sole
    get workflow_task_path(task)
    assert_response :success
    patch workflow_task_path(task), params: { operation_id: SecureRandom.uuid, task: { action: "update", version: 0, assignee_id: users(:supervisor).id } }
    assert_redirected_to workflow_task_path(task)
    assert_equal users(:supervisor), task.reload.assignee
    patch workflow_task_path(task), params: { operation_id: SecureRandom.uuid, task: { action: "complete", version: task.lock_version, result: "Se acordó revisar la frecuencia semanal" } }
    assert_redirected_to workflow_task_path(task)
    assert_equal "completed", task.reload.status
    assert task.closed_at
    assert_equal 3, task.workflow_events.count
    get workflow_tasks_path
    assert_response :success
  end

  test "incident photographs are sanitized validated private and replay acknowledgements are idempotent" do
    image = Vips::Image.black(30, 20).write_to_buffer(".png")
    file_uuid = SecureRandom.uuid
    values = { operation_id: SecureRandom.uuid, command: "incident_report", visit_id: @visit.id, kind: "damaged", description: "Bulto dañado", occurred_at: Time.current.iso8601,
      photos: [ { id: file_uuid, sha256: Digest::SHA256.hexdigest(image) } ] }
    upload = Rack::Test::UploadedFile.new(StringIO.new(image), "image/png", original_filename: "foto.png")
    post "/repartidor/api/v1/workflow-operations", params: { operation: values.to_json, files: [ upload ] }
    assert_response :success
    assert_equal [ file_uuid ], response.parsed_body["result"]["attachment_ids"]
    photo = @company.incident_photos.sole
    assert_equal "image/jpeg", photo.file.blob.content_type
    get incident_photo_path(photo)
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    post "/repartidor/api/v1/workflow-operations", params: { operation: values.to_json }
    assert_response :success
    assert_equal 1, @company.incident_photos.count
    colleague = @company.users.create!(name: "Otro conductor", role: :driver, email_address: "other-photo@example.test", password: "Password-test-2026")
    sign_in_as colleague
    get incident_photo_path(photo)
    assert_response :not_found
    sign_in_as users(:two)
    get incident_photo_path(photo)
    assert_response :not_found
    sign_in_as @driver
    invalid = values.merge(operation_id: SecureRandom.uuid, photos: [ { id: SecureRandom.uuid, sha256: Digest::SHA256.hexdigest("<svg>malicioso</svg>") } ])
    assert_no_difference [ "Incident.count", "IncidentPhoto.count" ] do
      post "/repartidor/api/v1/workflow-operations", params: { operation: invalid.to_json, files: [ Rack::Test::UploadedFile.new(StringIO.new("<svg>malicioso</svg>"), "image/png", original_filename: "foto.png") ] }
      assert_response :unprocessable_entity
    end
  end
end
