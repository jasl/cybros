class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :identity, :account
  attribute :http_method, :request_id, :user_agent, :ip_address, :referrer

  def session=(value)
    super(value)
    self.identity = value&.identity
  end

  def identity=(value)
    super(value)
    self.user = value&.user
  end
end
