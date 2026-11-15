module DriverApi
  module V1
    class LocationsController < ApplicationController
      prepend_before_action -> { response.headers["Cache-Control"] = "no-store" }
      before_action :require_driver
      rescue_from ArgumentError, KeyError, ActiveRecord::RecordInvalid, with: ->(error) { render json: { error: error.message }, status: :unprocessable_entity }
      rescue_from DriverLocationSharing::Unauthorized, with: ->(error) { render json: { error: error.message }, status: :unauthorized }
      rescue_from DriverLocationSharing::StaleConsent, with: ->(error) { render json: { error: error.message }, status: :conflict }

      def show
        render json: DriverLocationSharing.state(Current.user)
      end

      def create
        attributes = params.expect(location: [ :latitude, :longitude, :accuracy, :captured_at, :sharing, :account, :command, :consent_id, :expected_version ]).to_h.symbolize_keys
        unless attributes.delete(:account) == "#{Current.company.id}:#{Current.user.id}"
          return render json: { error: "account_changed" }, status: :forbidden
        end
        render json: DriverLocationSharing.call(user: Current.user, session: Current.session, attributes: attributes)
      end

      private

      def require_driver
        render json: { error: "driver_required" }, status: :forbidden unless Current.user.driver?
      end

      def request_authentication
        render json: { error: "authentication_required" }, status: :unauthorized
      end
    end
  end
end
