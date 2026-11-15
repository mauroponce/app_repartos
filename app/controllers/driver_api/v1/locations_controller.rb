module DriverApi
  module V1
    class LocationsController < ApplicationController
      prepend_before_action -> { response.headers["Cache-Control"] = "no-store" }
      before_action :require_driver
      rescue_from ArgumentError, KeyError, ActiveRecord::RecordInvalid, with: ->(error) { render json: { error: error.message }, status: :unprocessable_entity }

      def create
        attributes = params.expect(location: [ :latitude, :longitude, :accuracy, :captured_at, :sharing, :account ])
        unless attributes.delete(:account) == "#{Current.company.id}:#{Current.user.id}"
          return render json: { error: "account_changed" }, status: :forbidden
        end
        location = nil
        Current.company.with_lock do
          unless Current.user.reload.active? && Current.user.driver?
            return render json: { error: "driver_required" }, status: :forbidden
          end
          location = Current.company.driver_locations.find_by(user: Current.user)
          if attributes[:sharing] == false || attributes[:sharing] == "false"
            location&.update!(sharing: false, eta_data: {})
          else
            active = Current.company.delivery_runs.where(driver: Current.user, scheduled_date: Current.company.local_date, status: %w[assigned in_progress]).exists?
            raise ArgumentError, "No hay una jornada activa" unless active
            captured = Time.iso8601(attributes.fetch(:captured_at).to_s)
            raise ArgumentError, "La ubicación no es reciente" unless captured.between?(5.minutes.ago, 2.minutes.from_now)
            stopped = location && !location.sharing? && captured <= location.updated_at
            if !stopped && (!location || captured > location.captured_at)
              location ||= Current.company.driver_locations.new(user: Current.user)
              location.assign_attributes(attributes.except(:sharing).merge(captured_at: captured, sharing: true, eta_data: {}))
              location.save!
            end
          end
        end
        render json: { accepted: true, captured_at: location&.captured_at }
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
