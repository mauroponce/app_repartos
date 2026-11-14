class HomeController < ApplicationController
  def index
    redirect_to Current.user.driver? ? repartidor_root_path : admin_root_path
  end
end
