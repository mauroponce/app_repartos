Rails.application.routes.draw do
  resource :session, only: [ :new, :create, :destroy ]
  get "up" => "rails/health#show", as: :rails_health_check
  get "/repartidor/manifest.webmanifest", to: "repartidor_pwa#manifest", as: :repartidor_manifest, defaults: { format: :json }
  get "/repartidor/service-worker.js", to: "repartidor_pwa#service_worker", as: :repartidor_service_worker
  get "/repartidor/shell", to: "repartidor_pwa#shell", as: :repartidor_shell
  get "/repartidor/api/v1/work", to: "driver_api/v1/sync#work"
  post "/repartidor/api/v1/operations", to: "driver_api/v1/sync#create"
  post "/repartidor/api/v1/evidences", to: "driver_api/v1/evidences#create"
  post "/repartidor/api/v1/location", to: "driver_api/v1/locations#create"
  get "/repartidor/api/v1/location", to: "driver_api/v1/locations#show"
  get "/repartidor/avisos", to: "driver_api/v1/workflows#inbox", as: :driver_workflow_inbox
  get "/repartidor/incidencias/:id", to: "driver_api/v1/workflows#incident", as: :driver_incident
  post "/repartidor/api/v1/workflow-operations", to: "driver_api/v1/workflows#create"
  resources :incident_photos, path: "fotos-incidencias", only: :show
  resources :delivery_evidences, path: "evidencias", only: :show
  resources :delivery_receipts, path: "comprobantes", only: :show
  get "/repartidor/api/v1/operations/:id", to: "driver_api/v1/sync#show"
  get "/repartidor", to: "repartidor#index", as: :repartidor_root
  patch "/repartidor/visitas/:id", to: "repartidor#update", as: :repartidor_visit
  scope "/admin" do
    resource :routing_settings, path: "configuracion-rutas", only: [ :edit, :update ]
    resources :incidents, path: "incidencias", only: [ :index, :show ] do
      post :act, on: :member, path: "acciones"
    end
    resources :workflow_tasks, path: "tareas", only: [ :index, :new, :create, :show, :update ]
    post "avisos/:id/leido", to: "workflow_tasks#read_notice", as: :read_internal_notice
    get "trabajo/buscar", to: "workflow_lookups#show", as: :workflow_lookup
    get "trabajo/contadores", to: "workflow_counts#show", as: :workflow_counts
    get "reportes", to: "reports#show", as: :reports
    post "reportes/recalcular", to: "reports#refresh", as: :refresh_reports
    resource :commercial_rule_settings, path: "reportes/configuracion", only: [ :edit, :update ]
    resources :commercial_opportunities, path: "oportunidades", only: [ :index, :show ] do
      post :act, on: :member, path: "acciones"
    end
    get "clientes/:customer_id/comunicaciones", to: "customer_communications#show", as: :customer_communications
    post "clientes/:customer_id/comunicaciones", to: "customer_communications#create"
    get "repartos/:delivery_run_id/datos", to: "delivery_run_data#show", as: :delivery_run_data
    post "repartos/:delivery_run_id/datos/costos", to: "delivery_run_data#create_cost", as: :create_cost_delivery_run_data
    post "repartos/:delivery_run_id/datos/costos/:cost_id/anular", to: "delivery_run_data#reverse_cost", as: :reverse_cost_delivery_run_data
    post "repartos/:delivery_run_id/datos/cerrar-costos", to: "delivery_run_data#close_costs", as: :close_costs_delivery_run_data
    post "repartos/:delivery_run_id/datos/movimientos", to: "delivery_run_data#create_stock", as: :create_stock_delivery_run_data
    get "operaciones", to: "operations#show", as: :operations
    get "operaciones/estado", to: "operations#snapshot", as: :operations_snapshot
    post "operaciones/entregas/:order_id/despachar", to: "operations#change_assignment", as: :operations_dispatch
    resources :driver_sync_operations, path: "sincronizaciones", only: [ :index, :show ]
    get "/", to: "customers#index", as: :admin_root
    resources :drivers, path: "repartidores", path_names: { new: "nuevo", edit: "editar" } do
      get :autocomplete, on: :collection, path: "sugerencias"
    end
    resources :customers, path: "clientes", only: [ :index, :new, :create, :show, :edit, :update ], path_names: { new: "nuevo", edit: "editar" } do
      get :autocomplete, on: :collection, path: "sugerencias"
    end
    resources :products, path: "productos", except: [ :show, :destroy ], path_names: { new: "nuevo", edit: "editar" }
    resources :product_imports, path: "importaciones-productos", only: [ :new, :create, :show, :update ] do
      get :template, on: :collection
      post :confirm, on: :member
    end
    resources :customer_imports, path: "importaciones-clientes", only: [ :new, :create, :show, :update ] do
      get :template, on: :collection
      get :errors, on: :member
      post :confirm, on: :member
    end
    resources :customers, path: "clientes", only: [] do
      resources :delivery_schedules, path: "programaciones", only: [ :new, :create, :edit, :update ]
    end
    resources :delivery_orders, path: "entregas", except: :destroy, path_names: { new: "nueva", edit: "editar" } do
      post :generate, on: :collection, path: "generar"
      post :cancel, on: :member, path: "cancelar"
      post :reschedule, on: :member, path: "reprogramar"
    end
    resources :delivery_runs, path: "repartos", except: :destroy do
      post :create_optimized, on: :collection, path: "crear-optimizadas"
      get :available, on: :collection, path: "entregas-disponibles"
      post :add_orders, on: :member, path: "agregar-entregas"
      delete :remove_order, on: :member, path: "quitar-entrega/:order_id"
      patch :reorder, on: :member, path: "ordenar"
      resource :route_publication, controller: "route_publications", path: "confirmacion", only: [ :create, :show ] do
        post :manual, path: "publicar-manual"
      end
      resources :optimization_proposals, controller: "route_optimization_proposals", path: "optimizacion", only: [ :new, :create, :show, :destroy ] do
        post :apply, on: :member, path: "aplicar"
      end
      resources :visits, path: "visitas", only: [ :new, :create, :edit, :update ]
    end
    resources :route_optimizations, path: "optimizaciones", only: :create
  end
  root to: "home#index"
end
