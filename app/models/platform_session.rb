class PlatformSession < ApplicationRecord
  belongs_to :platform_admin
  scope :active, -> { where("expires_at > ?", Time.current) }
end
