require "test_helper"

class Conduits::DirectiveTokenTest < ActiveSupport::TestCase
  test "encode and decode round-trip" do
    token = Conduits::DirectiveToken.encode(
      directive_id: "dir-123",
      territory_id: "ter-456"
    )

    claims = Conduits::DirectiveToken.decode(token)
    assert_equal "dir-123", claims[:directive_id]
    assert_equal "ter-456", claims[:territory_id]
  end

  test "token with custom TTL expires" do
    token = Conduits::DirectiveToken.encode(
      directive_id: "dir-123",
      territory_id: "ter-456",
      ttl: 1.second
    )

    travel 3.seconds do
      assert_raises(Conduits::DirectiveToken::ExpiredToken) do
        Conduits::DirectiveToken.decode(token)
      end
    end
  end

  test "invalid token raises InvalidToken" do
    assert_raises(Conduits::DirectiveToken::InvalidToken) do
      Conduits::DirectiveToken.decode("not-a-valid-jwt")
    end
  end

  test "tampered token raises InvalidToken" do
    token = Conduits::DirectiveToken.encode(
      directive_id: "dir-123",
      territory_id: "ter-456"
    )

    tampered = token + "x"
    assert_raises(Conduits::DirectiveToken::InvalidToken) do
      Conduits::DirectiveToken.decode(tampered)
    end
  end

  test "default TTL is 1 hour" do
    assert_equal 5.minutes, Conduits::DirectiveToken::DEFAULT_TTL
  end
end
