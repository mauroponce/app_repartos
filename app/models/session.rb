class Session < ApplicationRecord
  belongs_to :user
  after_destroy -> { DriverLocationSharing.revoke!(user) }
end
