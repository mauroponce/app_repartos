Rails.application.routes.draw do
  resource :session, only: [ :new, :create, :destroy ]
  get "up" => "rails/health#show", as: :rails_health_check
  get "/repartidor/manifest.webmanifest", to: "repartidor_pwa#manifest", as: :repartidor_manifest, defaults: { format: :json }
  get "/repartidor/service-worker.js", to: "repartidor_pwa#service_worker", as: :repartidor_service_worker
  get "/repartidor", to: "repartidor#index", as: :repartidor_root
  patch "/repartidor/visitas/:id", to: "repartidor#update", as: :repartidor_visit
  scope "/admin" do
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
    resources :customers, path: "clientes", only: [] do
      resources :delivery_schedules, path: "programaciones", only: [ :new, :create, :edit, :update ]
    end
    resources :delivery_orders, path: "entregas", except: :destroy, path_names: { new: "nueva", edit: "editar" } do
      post :generate, on: :collection, path: "generar"
      post :cancel, on: :member, path: "cancelar"
    end
    resources :delivery_runs, path: "repartos", except: :destroy do
      get :available, on: :collection, path: "entregas-disponibles"
      post :add_orders, on: :member, path: "agregar-entregas"
      delete :remove_order, on: :member, path: "quitar-entrega/:order_id"
      patch :reorder, on: :member, path: "ordenar"
      resources :visits, path: "visitas", only: [ :new, :create, :edit, :update ]
    end
  end
  root to: "home#index"
end
