# frozen_string_literal: true

require "test_helper"

class IdentityTest < ActiveSupport::TestCase
  test "normalizes email by downcasing and stripping whitespace" do
    identity =
      Identity.create!(
        email: "  Admin@Example.com  ",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    assert_equal "admin@example.com", identity.email
  end

  test "validates email uniqueness case-insensitively" do
    Identity.create!(
      email: "admin@example.com",
      password: "Passw0rd",
      password_confirmation: "Passw0rd",
    )

    dupe =
      Identity.new(
        email: "ADMIN@EXAMPLE.COM",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    refute dupe.valid?
    assert dupe.errors.added?(:email, :taken) || dupe.errors[:email].any?
  end
end

