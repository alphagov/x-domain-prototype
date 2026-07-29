Rails.application.routes.draw do
  # 1. juggling-license
  get "/juggling-license" =>"juggling_license#index"

  # 2. juggling-videos.local:3000
  constraints ->(req) { req.host == "juggling-videos.local" } do
    root to: "juggling_videos#index", as: :video_root
  end

  # 3. example.gov.local:3000
  constraints ->(req) { req.host == "example.gov.local" } do
    root to: "example_gov#index", as: :example_gov_root
  end

  mount GovukPublishingComponents::Engine, at: "/component-guide" if Rails.env.development?

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
