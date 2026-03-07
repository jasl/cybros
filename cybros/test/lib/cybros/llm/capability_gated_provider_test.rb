require "test_helper"

class Cybros::LLM::CapabilityGatedProviderTest < ActiveSupport::TestCase
  class ExplodingProvider
    def chat(**)
      raise "should not be called"
    end
  end

  test "rejects tool calls when tools capability is false" do
    provider =
      Cybros::LLM::CapabilityGatedProvider.new(
        delegate: ExplodingProvider.new,
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
        api_model: "gpt-5.4",
        supports_tools: false,
        supports_images: true,
      )

    error =
      assert_raises(AgentCore::ValidationError) do
        provider.chat(messages: [], model: "gpt-5.4", tools: [{ name: "t" }], stream: false)
      end

    assert_equal "cybros.llm.capabilities.tools_not_supported", error.code
  end

  test "rejects image input when image capability is false" do
    provider =
      Cybros::LLM::CapabilityGatedProvider.new(
        delegate: ExplodingProvider.new,
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
        api_model: "gpt-5.4",
        supports_tools: true,
        supports_images: false,
      )

    msg =
      AgentCore::Message.new(
        role: :user,
        content: [
          AgentCore::ImageContent.new(source_type: :base64, data: "AA==", media_type: "image/png"),
        ],
      )

    error =
      assert_raises(AgentCore::ValidationError) do
        provider.chat(messages: [msg], model: "gpt-5.4", tools: nil, stream: false)
      end

    assert_equal "cybros.llm.capabilities.image_input_not_supported", error.code
  end
end
