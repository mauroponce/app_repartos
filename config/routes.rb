Rails.application.routes.draw do
  resource :session, only: [ :new, :create, :destroy ]
  get "up" => "rails/health#show", as: :rails_health_check
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
    resources :delivery_runs, path: "repartos", except: :destroy do
      post :generate, on: :member
      resources :visits, path: "visitas", only: [ :new, :create, :edit, :update ]
    end
  end
  root to: redirect("/admin")
end
