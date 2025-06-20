Rails.application.routes.draw do
  get "home/index"
  get "/home", to: "home#index"
  get "/howtouse", to: "home#howtouse"
  get "/concept", to: "home#concept"
  
  get "calculator/genotype"
  get "/genotype", to: "calculator#genotype", as: :genotype_calculator
  post "/calculator/process_genotype", to: "calculator#process_genotype", as: :process_genotype_calculator
  
  get "calculator/phenotype"
  get "/phenotype", to: "calculator#phenotype", as: :phenotype_calculator
  post "/calculator/process_phenotype", to: "calculator#process_phenotype", as: :process_phenotype_calculator

  get "calculator/punnet"
  get "/punnet", to: "calculator#punnet", as: :punnet_calculator
  post "/calculator/process_punnet", to: "calculator#process_punnet", as: :process_punnet_calculator
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
  root "home#index"
end
