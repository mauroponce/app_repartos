class PlatformCompanyRegistration
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :name, :string
  attribute :slug, :string
  attribute :province, :string, default: "Buenos Aires"
  attribute :time_zone, :string, default: "America/Argentina/Buenos_Aires"
  attribute :currency, :string, default: "ARS"
  attribute :administrator_name, :string
  attribute :administrator_email, :string
  attribute :password, :string
  attr_reader :company

  validates :password, presence: true, length: { minimum: 12 }, format: { with: /\A(?=.*[a-zA-Z])(?=.*\d).+\z/, message: "debe incluir letras y números" }

  def save
    return false unless valid?
    Company.transaction do
      @company = Company.create!(attributes.slice("name", "slug", "province", "time_zone", "currency"))
      administrator = @company.users.create!(name: administrator_name, email_address: administrator_email,
        password: password, role: :administrator, status: :active)
      @company.update!(primary_administrator: administrator)
    end
    true
  rescue ActiveRecord::RecordInvalid => error
    error.record.errors.full_messages.each { |message| errors.add(:base, message) }
    false
  rescue ActiveRecord::RecordNotUnique
    errors.add(:base, "El slug o el email ya está registrado.")
    false
  end
end
