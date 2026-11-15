
module CustomerImportTestHelper
  Response = Struct.new(:code, :body, :headers) do
    def [](key)
      (headers || {})[key]
    end
  end

  def stub_method(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name) do |*args, **kwargs, &block|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &block) : replacement
    end
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def offline_providers
    constructor = Geocoding::HttpClient.method(:new)
    transport = lambda do |uri, request|
      body = if uri.path.end_with?("direcciones")
        { resultados: JSON.parse(request.body).fetch("direcciones").map { { direcciones: [], total: 0 } } }
      else
        { features: [] }
      end
      Response.new("200", JSON.generate(body))
    end
    with_env("GEMINI_ENABLED" => "false") do
      stub_method(GeocodingProviderState, :reserve!, nil) do
        stub_method(Geocoding::HttpClient, :new, ->(**arguments) { constructor.call(**arguments, transport: transport) }) { yield }
      end
    end
  end

  def smart_import(content = "nombre,direccion,ciudad\nNuevo,Calle 450,Adrogué\n")
    import = companies(:one).customer_imports.create!(state: "reading", initiated_by: users(:one), header_row: 0)
    import.source_file.attach(io: StringIO.new(content), filename: "clientes.csv", content_type: "text/csv")
    CustomerImportJob.perform_now(import.company_id, import.id, import.generation, "read")
    import.reload
  end

  def drain_import_jobs
    500.times do
      break unless enqueued_jobs.any? { |job| job[:job] == CustomerImportJob }
      perform_enqueued_jobs(only: CustomerImportJob)
    end
    assert_not enqueued_jobs.any? { |job| job[:job] == CustomerImportJob }, "Import jobs did not finish"
  end

  def prepare_smart_import(import)
    CustomerImports::Workflow.start!(import)
    offline_providers do
      drain_import_jobs
    end
    import.reload
  end

  def candidate(**overrides)
    { "provider" => "photon", "street" => "Belgrano", "house_number" => "450", "city" => "Adrogué", "district" => "Almirante Brown",
      "province" => "Buenos Aires", "country" => "Argentina", "latitude" => -34.80, "longitude" => -58.39,
      "precision" => "address", "type" => "address", "label" => "Belgrano 450, Adrogué" }.merge(overrides.stringify_keys)
  end
end
